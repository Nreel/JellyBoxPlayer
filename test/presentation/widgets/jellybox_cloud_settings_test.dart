import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/data/providers/shared_preferences_provider.dart';
import 'package:jplayer/src/domain/providers/cloud_provider.dart';
import 'package:jplayer/src/presentation/widgets/jellybox_cloud_settings.dart';
import 'package:mocktail/mocktail.dart';
import 'package:optional_features/jellybox_cloud.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCloudNotifier extends StateNotifier<CloudState>
    with Mock
    implements CloudNotifier {
  _FakeCloudNotifier(super.state);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> pumpSettings(
    WidgetTester tester, [
    Map<String, String> values = const {},
    CloudState cloud = const CloudState(),
  ]) async {
    // The address form opens as a desktop dialog on a wide surface; the 800x600
    // test window would show a bottom sheet whose Save button is off-screen.
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWith((_) => prefs),
          cloudProvider.overrideWith((_) {
            final notifier = _FakeCloudNotifier(cloud);
            when(notifier.signOut).thenAnswer(
              (_) async =>
                  notifier.state = notifier.state.copyWith(clearAccount: true),
            );
            return notifier;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: JellyboxCloudSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  Future<void> save(WidgetTester tester, String address) async {
    await tester.enterText(find.byType(TextField), address);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // The preference write is a future; pumping drains it inside the fake
    // async zone that the widget test runs in.
    await tester.pump();
  }

  testWidgets('- offers a remote address for the continuity server', (
    tester,
  ) async {
    await pumpSettings(tester, {
      'conductor_url': 'http://192.168.1.10:8000',
    });

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('http://192.168.1.10:8000'), findsOneWidget);
    expect(find.text('Add remote address'), findsOneWidget);
    expect(find.text('Remote'), findsNothing);
  });

  testWidgets('- adds a remote address for the continuity server', (
    tester,
  ) async {
    final prefs = await pumpSettings(tester, {
      'conductor_url': 'http://192.168.1.10:8000',
    });

    await tester.tap(find.text('Add remote address'));
    await tester.pumpAndSettle();
    expect(find.text('Remote address'), findsOneWidget);

    await save(tester, 'bench.example.ts.net:8000');

    expect(find.text('Remote'), findsOneWidget);
    expect(find.text('http://bench.example.ts.net:8000'), findsOneWidget);
    expect(find.text('Add remote address'), findsNothing);
    expect(
      prefs.getString('conductor_remote_url'),
      'http://bench.example.ts.net:8000',
    );
  });

  testWidgets('- changes the remote address', (tester) async {
    final prefs = await pumpSettings(tester, {
      'conductor_url': 'http://192.168.1.10:8000',
      'conductor_remote_url': 'http://bench.example.ts.net:8000',
    });

    await tester.tap(find.byTooltip('Change remote address'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'http://bench.example.ts.net:8000',
    );

    await save(tester, 'http://bench2.example.ts.net:8000');

    expect(
      prefs.getString('conductor_remote_url'),
      'http://bench2.example.ts.net:8000',
    );
    expect(find.text('http://bench2.example.ts.net:8000'), findsOneWidget);
  });

  testWidgets('- removes the remote address', (tester) async {
    final prefs = await pumpSettings(tester, {
      'conductor_url': 'http://192.168.1.10:8000',
      'conductor_remote_url': 'http://bench.example.ts.net:8000',
    });

    await tester.tap(find.byTooltip('Remove remote address'));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(find.text('Remote'), findsNothing);
    expect(find.text('Add remote address'), findsOneWidget);
    expect(prefs.getString('conductor_remote_url'), isNull);
  });

  testWidgets('- disconnects inline without opening the manage modal', (
    tester,
  ) async {
    await pumpSettings(tester, const {}, const CloudState(
      account: ContinuityAccount(
        serverUrl: 'http://192.168.1.10:8000',
        login: 'alice',
        userId: 'u1',
        token: 'tok',
      ),
    ));

    expect(find.text('Connected as alice'), findsOneWidget);
    expect(find.byTooltip('Disconnect from Jellybox Cloud'), findsOneWidget);

    await tester.tap(find.byTooltip('Disconnect from Jellybox Cloud'));
    await tester.pumpAndSettle();

    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Connected as alice'), findsNothing);
    expect(find.byTooltip('Disconnect from Jellybox Cloud'), findsNothing);
  });
}
