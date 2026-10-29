import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/src/config/constants.dart';
import 'package:jplayer/src/data/providers/shared_preferences_provider.dart';
import 'package:jplayer/src/domain/providers/cloud_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../provider_container.dart';

const home = 'http://192.168.1.10:8000';
const remote = 'http://bench.example.ts.net:8000';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> containerWith(SharedPreferences prefs) async =>
      createProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWith((_) => prefs)],
      );

  test(
    'first launch seeds the compiled-in default as the home address',
    () async {
      final container = await containerWith(
        await SharedPreferences.getInstance(),
      );

      final addresses = container.read(conductorUrlProvider);
      expect(addresses.home, jellyboxCloudUrl);
      expect(addresses.active, jellyboxCloudUrl);
      expect(addresses.remote, isNull);
    },
  );

  test(
    'adding a remote address normalizes it and keeps home while it answers',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = await containerWith(prefs);

      container.read(conductorUrlProvider.notifier)
        ..setHome('192.168.1.10:8000')
        ..setRemote('bench.example.ts.net:8000');

      final addresses = container.read(conductorUrlProvider);
      expect(addresses.home, home);
      expect(addresses.remote, remote);
      expect(addresses.active, home);
      expect(prefs.getString('conductor_remote_url'), remote);
    },
  );

  test(
    'adding a remote address takes over when home is unreachable',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = await containerWith(prefs);

      container.read(conductorUrlProvider.notifier)
        ..setHome(home)
        ..recordFailure(home)
        ..setRemote(remote);

      final addresses = container.read(conductorUrlProvider);
      expect(addresses.active, remote);
      expect(addresses.down, {home});
    },
  );

  test('removing the remote address drops it and falls back to home', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await containerWith(prefs);

    container.read(conductorUrlProvider.notifier)
      ..setHome(home)
      ..setRemote(remote)
      ..setRemote(null);

    final addresses = container.read(conductorUrlProvider);
    expect(addresses.remote, isNull);
    expect(addresses.active, home);
    expect(prefs.getString('conductor_remote_url'), isNull);
  });

  test(
    'a home address that stops answering hands over to the remote one',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = await containerWith(prefs);

      container.read(conductorUrlProvider.notifier)
        ..setHome(home)
        ..setRemote(remote)
        ..recordFailure(home);

      expect(container.read(conductorUrlProvider).active, remote);

      container.read(conductorUrlProvider.notifier).recordSuccess(home);
      final addresses = container.read(conductorUrlProvider);
      expect(addresses.active, home);
      expect(addresses.down, isEmpty);
    },
  );

  test(
    'a remote-only connection marks the home address unreachable',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final container = await containerWith(prefs);

      container.read(conductorUrlProvider.notifier)
        ..setHome(home)
        ..setRemote(remote)
        ..recordFailure(home)
        ..recordSuccess(remote);

      final addresses = container.read(conductorUrlProvider);
      expect(addresses.active, remote);
      expect(addresses.down, {home});

      container.read(conductorUrlProvider.notifier).clearDown();
      expect(container.read(conductorUrlProvider).active, home);
    },
  );

  test('retries alternate between addresses once both are down', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await containerWith(prefs);

    container.read(conductorUrlProvider.notifier)
      ..setHome(home)
      ..setRemote(remote)
      ..recordFailure(home)
      ..recordFailure(remote)
      ..recordFailure(home);

    // Each failure hands the next attempt to the other address, so a server
    // that comes back on either one is found again.
    expect(container.read(conductorUrlProvider).active, remote);
  });

  test('a server with no remote address keeps the home address', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = await containerWith(prefs);

    container.read(conductorUrlProvider.notifier)
      ..setHome(home)
      ..recordFailure(home);

    final addresses = container.read(conductorUrlProvider);
    expect(addresses.active, home);
    expect(addresses.down, {home});
  });
}
