import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/general.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/preferences.dart';
import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';
import 'package:prism_ui/prism_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    container.read(viewSizeProvider.notifier).value = const Size(1000, 3000);
  });

  tearDown(() => container.dispose());

  Future<void> pumpGeneralView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: GeneralView()),
      ),
    );
    await tester.pumpAndSettle();
  }

  PatchClashConfig config() => container.read(patchClashConfigProvider);

  for (final choice in [true, false, null]) {
    testWidgets('switching off global HWID honors the answer $choice', (
      tester,
    ) async {
      await mockPreferences();
      final allowed = Profile.normal(url: 'https://example.com/allowed');
      final other = Profile.normal(url: 'https://example.com/other');
      final http = Profile.normal(url: 'http://example.com/legacy');
      final future = Profile.normal(url: 'https://example.com/future');
      container.read(profilesProvider.notifier)
        ..put(allowed)
        ..put(other)
        ..put(http);
      await preferences.allowSubscriptionHwid(allowed);
      await pumpGeneralView(tester);
      final l = currentAppLocalizations;

      await tester.tap(find.text(l.globalHwid));
      await tester.pumpAndSettle();
      expect(await preferences.globalSubscriptionHwidEnabled, isTrue);
      expect(await preferences.subscriptionHwid(http), isNull);

      await tester.tap(find.text(l.globalHwid));
      await tester.pumpAndSettle();
      expect(find.text(l.disableGlobalHwidMessage(2)), findsOneWidget);
      final yes = find.text(l.yes);
      final no = find.text(l.no);
      expect(tester.getCenter(no).dx, greaterThan(tester.getCenter(yes).dx));
      if (choice == null) {
        Navigator.of(tester.element(yes)).pop();
      } else {
        await tester.tap(choice ? yes : no);
      }
      await tester.pumpAndSettle();

      await preferences.rebind();
      expect(await preferences.globalSubscriptionHwidEnabled, choice == null);
      final currentExpectation = choice == true ? isNull : isNotNull;
      expect(await preferences.subscriptionHwid(allowed), currentExpectation);
      expect(await preferences.subscriptionHwid(other), currentExpectation);
      expect(
        await preferences.subscriptionHwid(future),
        choice == null ? isNotNull : isNull,
      );
    });
  }

  testWidgets(
    'global HWID switches off without a prompt if no profile uses it',
    (tester) async {
      await mockPreferences();
      await preferences.setGlobalSubscriptionHwid(enabled: true);
      await pumpGeneralView(tester);
      final l = currentAppLocalizations;

      await tester.tap(find.text(l.globalHwid));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(await preferences.globalSubscriptionHwidEnabled, isFalse);
    },
  );

  testWidgets('lists no override until one is added', (tester) async {
    await pumpGeneralView(tester);
    final l = currentAppLocalizations;

    expect(find.text(l.tcpConcurrent), findsNothing);
    expect(find.text(l.testUrl), findsNothing);
    expect(find.textContaining(l.generalOverrideDesc), findsOneWidget);

    await tester.tap(find.text(l.addOverrideEntry));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.tcpConcurrent));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    expect(config().generalOverrideKeys, {GeneralOverrideKey.tcpConcurrent});
    expect(config().tcpConcurrent, defaultClashConfig.tcpConcurrent);
    expect(find.text(l.tcpConcurrent), findsOneWidget);
  });

  testWidgets('removing an override resets its value', (tester) async {
    container
        .read(patchClashConfigProvider.notifier)
        .update(
          (state) => state.copyWith(
            ipv6: true,
            generalOverrideKeys: {GeneralOverrideKey.ipv6},
          ),
        );
    await pumpGeneralView(tester);
    final l = currentAppLocalizations;
    expect(find.text('IPv6'), findsOneWidget);
    expect(find.textContaining(l.ipv6Desc), findsOneWidget);

    await tester.tap(find.byTooltip(l.remove));
    await tester.pumpAndSettle();

    expect(config().generalOverrideKeys, isEmpty);
    expect(config().ipv6, defaultClashConfig.ipv6);
    expect(find.text('IPv6'), findsNothing);
  });

  testWidgets('the test URL takes only a URL', (tester) async {
    container
        .read(patchClashConfigProvider.notifier)
        .update(
          (state) =>
              state.copyWith(generalOverrideKeys: {GeneralOverrideKey.testUrl}),
        );
    await pumpGeneralView(tester);
    final l = currentAppLocalizations;

    await tester.tap(find.text(l.testUrl));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not a url');
    await tester.tap(find.text(l.submit));
    await tester.pumpAndSettle();
    expect(find.text(l.urlTip(l.testUrl)), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'https://probe.test/204');
    await tester.tap(find.text(l.submit));
    await tester.pumpAndSettle();
    expect(config().testUrl, 'https://probe.test/204');
  });
}
