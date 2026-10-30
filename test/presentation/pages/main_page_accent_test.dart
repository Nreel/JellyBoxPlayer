import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jplayer/generated/l10n.dart';
import 'package:jplayer/main.dart';
import 'package:jplayer/src/data/providers/shared_preferences_provider.dart';
import 'package:jplayer/src/presentation/pages/main_page.dart';
import 'package:jplayer/src/presentation/themes/themes.dart';
import 'package:jplayer/src/presentation/widgets/custom_navigation_rail.dart';
import 'package:jplayer/src/providers/connectivity_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../provider_container.dart';

class _FakeConn extends StateNotifier<bool>
    with Mock
    implements ConnectivityNotifier {
  _FakeConn(bool state) : super(state);
}

GoRouter _shellRouter() => GoRouter(
  initialLocation: '/home',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigator) => MainPage(shell: navigator),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (_, _) => const Scaffold(body: Text('home')),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/browse',
              builder: (_, _) => const Scaffold(body: Text('browse')),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/downloads',
              builder: (_, _) => const Scaffold(body: Text('downloads')),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, _) => const Scaffold(body: Text('settings')),
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  setUp(() {
    deviceId = 'test-device';
    appInfo = PackageInfo(
      appName: 'JellyBox',
      packageName: 'app.jellybox',
      version: '0.0.0',
      buildNumber: '1',
    );
  });

  Future<void> pumpMainPage(WidgetTester tester, ThemeData theme) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: createProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((_) => prefs),
            connectivityProvider.overrideWith((_) => _FakeConn(true)),
          ],
        ),
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: const [
            DefaultWidgetsLocalizations.delegate,
            DefaultMaterialLocalizations.delegate,
            S.delegate,
          ],
          supportedLocales: S.delegate.supportedLocales,
          routerConfig: _shellRouter(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<Color?> railPills(WidgetTester tester) {
    final buttons = find.descendant(
      of: find.byType(CustomNavigationRail),
      matching: find.byType(TextButton),
    );
    return [
      for (final candidate in buttons.evaluate().take(4))
        (candidate.widget as TextButton).style?.backgroundColor
            ?.resolve(const <WidgetState>{}),
    ];
  }

  testWidgets('selected sidebar pill follows the accent hue', (tester) async {
    const teal = Color(0xFF2ECDB0);
    await pumpMainPage(tester, Themes.withAccent(teal));

    // Rail order: Home (selected), Browse, Downloads, Settings (trailing).
    final pills = railPills(tester);
    expect(
      pills.first,
      Themes.tone(teal, saturation: 0.69, value: 0.2),
    );
    expect(pills, isNot(contains(const Color(0xFF341010))));

    // BottomPlayer's artwork-scheme extraction schedules 5s fallback timers;
    // drain them so the widget tree tears down cleanly.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('default accent keeps the original maroon pill', (
    tester,
  ) async {
    await pumpMainPage(tester, Themes.withAccent(Themes.defaultAccent));

    final pills = railPills(tester);
    final pill = pills.first;
    expect(pill, isNotNull);
    // Derived from the red accent: same hue and darkness as the previously
    // hardcoded 0xFF341010.
    final hsv = HSVColor.fromColor(pill!);
    expect(hsv.hue, closeTo(HSVColor.fromColor(Themes.defaultAccent).hue, 2));
    expect(hsv.value, closeTo(0.2, 0.03));
    expect(hsv.saturation, closeTo(0.69, 0.03));

    await tester.pump(const Duration(seconds: 6));
  });
}
