import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/boot_record.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Preferences {
  static Preferences? _instance;
  var _store = ResolveOnce(_open);
  final _hwidQueue = TaskPool(1);

  static const _hwidConsentKey = 'subscriptionHwidConsent';
  static const _hwidSeedKey = 'subscriptionHwidSeed';

  Future<bool> get isInit async => await _store.value != null;

  Preferences._internal();

  static Future<SharedPreferences?> _open() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  Future<void> rebind() async {
    _store = ResolveOnce(_open);
    await _store.value;
  }

  factory Preferences() {
    _instance ??= Preferences._internal();
    return _instance!;
  }

  Future<int> getVersion() async {
    final preferences = await _store.value;
    return preferences?.getInt('version') ?? 0;
  }

  Future<void> setVersion(int version) async {
    final preferences = await _store.value;
    await preferences?.setInt('version', version);
  }

  Future<int> getUpgradeVersion() async {
    final preferences = await _store.value;
    return preferences?.getInt('upgradeVersion') ?? 0;
  }

  Future<void> setUpgradeVersion(int version) async {
    final preferences = await _store.value;
    await preferences?.setInt('upgradeVersion', version);
  }

  Future<void> saveShareState(SharedState shareState) async {
    final preferences = await _store.value;
    await preferences?.setString('sharedState', json.encode(shareState));
  }

  /// The md5 of the config.yaml the Core last accepted, which is also what
  /// the Android service applies when it starts without Flutter.
  Future<String?> getAppliedConfigMd5() async {
    final preferences = await _store.value;
    return preferences?.getString(appliedConfigMd5Key);
  }

  Future<void> saveAppliedConfigMd5(String? md5) async {
    final preferences = await _store.value;
    if (md5 == null) {
      await preferences?.remove(appliedConfigMd5Key);
    } else {
      await preferences?.setString(appliedConfigMd5Key, md5);
    }
  }

  Future<Map<String, Object?>?> getConfigMap() async {
    try {
      final preferences = await _store.value;
      final configString = preferences?.getString(configKey);
      if (configString == null) return null;
      final Map<String, Object?>? configMap = json.decode(configString);
      return configMap;
    } catch (e) {
      commonPrint.log(
        'getConfigMap error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<Map<String, Object?>?> getClashConfigMap() async {
    try {
      final preferences = await _store.value;
      final clashConfigString = preferences?.getString(clashConfigKey);
      if (clashConfigString == null) return null;
      return json.decode(clashConfigString);
    } catch (e) {
      commonPrint.log(
        'getClashConfigMap error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> clearClashConfig() async {
    try {
      final preferences = await _store.value;
      await preferences?.remove(clashConfigKey);
      return;
    } catch (e) {
      commonPrint.log(
        'clearClashConfig error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return;
    }
  }

  Future<Config?> getConfig() async {
    final configMap = await getConfigMap();
    if (configMap == null) {
      return null;
    }
    return Config.fromJson(configMap);
  }

  Future<bool> saveConfig(Config config) async {
    final preferences = await _store.value;
    return preferences?.setString(configKey, json.encode(config)) ?? false;
  }

  Future<String?> subscriptionHwid(
    Profile profile, {
    bool allowedForImport = false,
  }) async {
    final uri = profile.hwidSubscriptionUri;
    if (uri == null) return null;
    return _withHwidStore((store) async {
      if (store == null) return null;
      final policy = _readHwidPolicy(store);
      if (policy['global'] != true &&
          !allowedForImport &&
          _hwidConsents(policy)['${profile.id}'] != _urlDigest(profile.url)) {
        return null;
      }
      var seed = store.getString(_hwidSeedKey);
      if (seed == null) {
        seed = base64.encode(ascii.encode(generateRandomSecret(43)));
        await _saveHwidValue(store, _hwidSeedKey, seed);
      }
      return Hmac(
        sha256,
        base64.decode(seed),
      ).convert(utf8.encode(uri.origin)).toString();
    });
  }

  Future<void> allowSubscriptionHwid(Profile profile) =>
      _setSubscriptionHwid(profile.id, profile.url);

  Future<void> forgetSubscriptionHwid(int profileId) =>
      _setSubscriptionHwid(profileId, null);

  Future<bool> get globalSubscriptionHwidEnabled => _withHwidStore(
    (store) async => store != null && _readHwidPolicy(store)['global'] == true,
  );

  Future<void> setGlobalSubscriptionHwid({
    required bool enabled,
    Iterable<Profile> keepSharing = const [],
  }) => _withHwidStore((store) async {
    if (store == null) throw StateError('Preferences are unavailable');
    final policy = _readHwidPolicy(store);
    if ((policy['global'] == true) == enabled) return;
    await _saveHwidPolicy(store, {
      ...policy,
      'global': enabled,
      if (!enabled)
        'profiles': {
          for (final profile in keepSharing)
            if (profile.hwidSubscriptionUri != null)
              '${profile.id}': _urlDigest(profile.url),
        },
    });
  });

  Future<void> _setSubscriptionHwid(int id, String? url) {
    return _withHwidStore((store) async {
      if (store == null) {
        if (url == null) return;
        throw StateError('Preferences are unavailable');
      }
      final policy = _readHwidPolicy(store);
      final consents = _hwidConsents(policy);
      if (url != null) {
        consents['$id'] = _urlDigest(url);
      } else if (consents.remove('$id') == null) {
        return;
      }
      await _saveHwidPolicy(store, {...policy, 'profiles': consents});
    });
  }

  Future<T> _withHwidStore<T>(Future<T> Function(SharedPreferences?) use) =>
      _hwidQueue.run(() async => use(await _store.value));

  Map<String, Object?> _readHwidPolicy(SharedPreferences store) {
    final saved = store.getString(_hwidConsentKey);
    if (saved == null) return {};
    return decodeOrRestoreDefault(
      'subscription HWID preferences',
      () => json.decode(saved) as Map<String, Object?>,
      () => <String, Object?>{},
    );
  }

  Map<String, Object?> _hwidConsents(Map<String, Object?> policy) {
    final consents = policy['profiles'];
    return consents is Map<String, Object?> ? consents : {};
  }

  Future<void> _saveHwidPolicy(
    SharedPreferences store,
    Map<String, Object?> policy,
  ) => _saveHwidValue(store, _hwidConsentKey, json.encode(policy));

  String _urlDigest(String url) => sha256.convert(utf8.encode(url)).toString();

  Future<void> _saveHwidValue(
    SharedPreferences store,
    String key,
    String value,
  ) async {
    try {
      if (!await store.setString(key, value)) {
        throw StateError('Could not save HWID preferences');
      }
    } catch (_) {
      await store.reload();
      rethrow;
    }
  }

  Future<SystemDnsRecord?> getSystemDnsRecord() async {
    try {
      final sharedPreferencesIns = await _store.value;
      final raw = sharedPreferencesIns?.getString(systemDnsRecordKey);
      if (raw == null) {
        return null;
      }
      return SystemDnsRecord.fromJson(json.decode(raw));
    } catch (e) {
      commonPrint.log(
        'getSystemDnsRecord error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> clearSystemDnsRecord() async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.remove(systemDnsRecordKey);
  }

  Future<BootRecord?> getBootRecord() async {
    try {
      final sharedPreferencesIns = await _store.value;
      final raw = sharedPreferencesIns?.getString(bootRecordKey);
      if (raw == null) {
        return null;
      }
      return BootRecord.fromJson(json.decode(raw));
    } catch (e) {
      commonPrint.log(
        'getBootRecord error ${e.toString()}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<void> saveBootRecord(BootRecord record) async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.setString(bootRecordKey, json.encode(record));
  }

  Future<void> clearPreferences() async {
    final sharedPreferencesIns = await _store.value;
    await sharedPreferencesIns?.clear();
  }
}

final preferences = Preferences();
