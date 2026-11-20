import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
  Completer<void>? _hwidWrite;

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
    final uri = profile.url.webUri;
    if (profile.type != ProfileType.url ||
        uri == null ||
        uri.scheme != 'https') {
      return null;
    }
    return _withHwidStore((store) async {
      if (store == null ||
          !allowedForImport &&
              _hwidConsents(store)['${profile.id}'] !=
                  _urlDigest(profile.url)) {
        return null;
      }
      var seed = store.getString(_hwidSeedKey);
      if (seed == null) {
        final random = Random.secure();
        seed = base64.encode(List.generate(32, (_) => random.nextInt(256)));
        await _saveHwidValue(store, _hwidSeedKey, seed);
      }
      return Hmac(
        sha256,
        base64.decode(seed),
      ).convert(utf8.encode(uri.origin)).toString();
    });
  }

  Future<void> allowSubscriptionHwid(Profile profile) {
    return _withHwidStore((store) async {
      if (store == null) throw StateError('Preferences are unavailable');
      final consents = _hwidConsents(store);
      consents['${profile.id}'] = _urlDigest(profile.url);
      await _saveHwidConsents(store, consents);
    });
  }

  Future<void> forgetSubscriptionHwid(int profileId) {
    return _withHwidStore((store) async {
      if (store == null) return;
      final consents = _hwidConsents(store);
      if (consents.remove('$profileId') != null) {
        await _saveHwidConsents(store, consents);
      }
    });
  }

  Future<T> _withHwidStore<T>(
    Future<T> Function(SharedPreferences?) use,
  ) async {
    final previous = _hwidWrite;
    final done = _hwidWrite = Completer<void>();
    try {
      await previous?.future;
      return await use(await _store.value);
    } finally {
      if (identical(_hwidWrite, done)) _hwidWrite = null;
      done.complete();
    }
  }

  Map<String, String> _hwidConsents(SharedPreferences store) {
    final saved = store.getString(_hwidConsentKey);
    if (saved == null) return {};
    try {
      final policy = json.decode(saved) as Map<String, dynamic>;
      return Map<String, String>.from(policy['profiles'] as Map);
    } on FormatException {
      return {};
    } on TypeError {
      return {};
    }
  }

  Future<void> _saveHwidConsents(
    SharedPreferences store,
    Map<String, String> consents,
  ) {
    return _saveHwidValue(
      store,
      _hwidConsentKey,
      json.encode({'profiles': consents}),
    );
  }

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
