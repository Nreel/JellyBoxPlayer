import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jplayer/main.dart' show deviceId;
import 'package:jplayer/src/core/audio/stream_target_profile.dart';
import 'package:jplayer/src/data/providers/shared_preferences_provider.dart';
import 'package:jplayer/src/domain/playback/playback_target.dart';
import 'package:jplayer/src/domain/playback/playback_target_provider.dart';
import 'package:jplayer/src/domain/providers/cloud_provider.dart';
import 'package:jplayer/src/domain/providers/system_volume_provider.dart';
import 'package:jplayer/src/providers/player_provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal continuity server so the app provider can be exercised over a real
/// socket without depending on Docker or an external process.
class _FakeServer {
  _FakeServer._(this._server);

  static Future<_FakeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final _sockets = <WebSocket>[];
  final received = <Map<String, dynamic>>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> _handle(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.listen(
      (raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        received.add(message);
        _answer(socket, message);
      },
      onDone: () => _sockets.remove(socket),
    );
  }

  void _answer(WebSocket socket, Map<String, dynamic> message) {
    final payloads = switch (message['type']) {
      'signin' => [
        jsonEncode({
          'type': 'signed_in',
          'account': {
            'serverUrl': url.toString(),
            'login': message['login'],
            'userId': 'user-1',
            'token': 'token-1',
            'serverName': 'Fake',
            'libraryName': 'Default',
            'socketPath': '/ws',
          },
        }),
      ],
      'register' => [
        jsonEncode({
          'type': 'registered',
          'device_id': message['device_id'],
          'session_key': 'user-1:server-1',
        }),
        jsonEncode({
          'type': 'state',
          'doc': <String, dynamic>{},
          'devices': <Map<String, dynamic>>[],
          'active_renderer': null,
        }),
      ],
      _ => const <String>[],
    };
    for (final payload in payloads) {
      // The app may drop the socket while an answer is being written; a relay
      // just loses it, so the fake does the same.
      try {
        socket.add(payload);
      } on Object {
        return;
      }
    }
  }

  Future<void> close() async {
    // Sockets leave the list as they close, so iterate over a snapshot.
    for (final socket in List.of(_sockets)) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}

class _MockAudioPlayer extends Mock implements AudioPlayer {}

class _Target implements PlaybackTarget {
  final _states = StreamController<TargetPlaybackState>.broadcast();

  @override
  PlaybackTargetKind get kind => PlaybackTargetKind.local;

  @override
  String get id => 'local';

  @override
  String get name => 'This device';

  @override
  StreamTargetProfile get streamProfile =>
      StreamTargetProfile.localPlayer(isAndroid: false);

  @override
  bool get supportsLocalFiles => true;

  @override
  TargetPlaybackState get state => TargetPlaybackState.idle;

  @override
  Stream<TargetPlaybackState> get stateStream => _states.stream;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async => _states.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer newContainer() {
    final player = _MockAudioPlayer();
    when(() => player.loopModeStream).thenAnswer((_) => const Stream.empty());
    final container = ProviderContainer(
      overrides: [
        localPlaybackTargetProvider.overrideWithValue(_Target()),
        playerProvider.overrideWithValue(player),
        usesSystemVolumeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('first sign-in after changing the server address succeeds', () async {
    final server = await _FakeServer.start();
    addTearDown(server.close);
    SharedPreferences.setMockInitialValues({
      'conductor_url': server.url.toString(),
    });
    deviceId = 'provider-check-device';
    final container = newContainer();

    await container.read(sharedPreferencesProvider.future);
    final notifier = container.read(cloudProvider.notifier);
    await _waitFor(() => container.read(cloudProvider).isConnected);

    // The preference change notifies the provider, while signIn switches the
    // cloud URL. The two must not close the socket under each other.
    final signedIn = await notifier.signIn(
      address: '${server.url}/',
      login: 'provider-check@example.com',
      password: 'pw',
    );

    expect(signedIn, isTrue);
    expect(container.read(conductorUrlProvider).active, '${server.url}/');
    expect(container.read(cloudProvider).signedIn, isTrue);
    await _waitFor(
      () => server.received.any(
        (message) => message['type'] == 'register',
      ),
    );
  });

  test(
    'a continuity server that only answers on the remote address connects '
    'through it',
    () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = closed.port;
      await closed.close(force: true);
      SharedPreferences.setMockInitialValues({
        'conductor_url': 'http://127.0.0.1:$deadPort',
        'conductor_remote_url': server.url.toString(),
      });
      deviceId = 'provider-check-device';
      final container = newContainer();

      await container.read(sharedPreferencesProvider.future);
      container.read(cloudProvider);

      await _waitFor(() => container.read(cloudProvider).isConnected);

      final addresses = container.read(conductorUrlProvider);
      expect(addresses.active, server.url.toString());
      expect(addresses.home, 'http://127.0.0.1:$deadPort');
      expect(addresses.remote, server.url.toString());
      expect(addresses.down, {'http://127.0.0.1:$deadPort'});
    },
  );
}
