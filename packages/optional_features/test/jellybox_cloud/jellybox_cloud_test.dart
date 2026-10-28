import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:optional_features/jellybox_cloud.dart';
import 'package:test/test.dart';

/// Minimal in-process stand-in for the continuity server. Speaks the same JSON
/// protocol so the client can be exercised over a real socket.
class FakeContinuityServer {
  FakeContinuityServer._(this._server, this.port);

  static Future<FakeContinuityServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeContinuityServer._(server, server.port);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final int port;
  final received = <Map<String, dynamic>>[];
  final _sockets = <WebSocket>[];

  Uri get url => Uri.parse('http://127.0.0.1:$port');

  Future<void> _handle(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.listen((raw) {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      received.add(message);
      _answer(socket, message);
    });
  }

  void _answer(WebSocket socket, Map<String, dynamic> message) {
    if (message['type'] == 'signin' && message['login'] == 'bad') {
      socket.add(
        jsonEncode({'type': 'error', 'message': 'Invalid login or password.'}),
      );
      return;
    }
    switch (message['type']) {
      case 'signin':
        socket.add(
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
        );
      case 'register':
        socket.add(
          jsonEncode({
            'type': 'registered',
            'device_id': message['device_id'],
            'session_key': 'user-1:server-1',
          }),
        );
        socket.add(jsonEncode({'type': 'state', ...snapshot}));
    }
  }

  /// What the server would broadcast to this client.
  Map<String, dynamic> snapshot = {
    'doc': <String, dynamic>{},
    'devices': <Map<String, dynamic>>[],
    'active_renderer': null,
  };

  void push(Map<String, dynamic> message) {
    final raw = jsonEncode(message);
    for (final socket in _sockets) {
      socket.add(raw);
    }
  }

  void pushState({
    required Map<String, dynamic> doc,
    String? activeRenderer,
    List<Map<String, dynamic>> devices = const [],
  }) {
    push({
      'type': 'state',
      'doc': doc,
      'devices': devices,
      'active_renderer': activeRenderer,
    });
  }

  Iterable<Map<String, dynamic>> ofType(String type) =>
      received.where((message) => message['type'] == type);

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}

class FakeHost implements CloudHost<String> {
  FakeHost({this.deviceId = 'me', this.backend = 'server-1'});

  @override
  final String deviceId;

  final String? backend;

  final calls = <String>[];
  final _playback = StreamController<CloudPlayback?>.broadcast();
  final secrets = <String, String>{};
  CloudPlayback? current;

  @override
  String? get backendRef => backend;

  @override
  String get deviceName => 'Test device';

  @override
  String get platform => 'test';

  @override
  String? get benchUserId => null;

  @override
  CloudPlayback? get playback => current;

  @override
  Stream<CloudPlayback?> get playbackChanges => _playback.stream;

  @override
  Future<List<String>> itemsByIds(List<String> ids) async {
    calls.add('items ${ids.join(',')}');
    return ids;
  }

  @override
  Future<String?> albumById(String id) async {
    calls.add('album $id');
    return id;
  }

  @override
  String placeholderAlbumFor(String song) => song;

  @override
  Future<void> play({
    required List<String> songs,
    required int index,
    required String? album,
    required String? sourceId,
    required Duration position,
    required bool autoPlay,
    required bool shuffle,
  }) async {
    calls.add('play ${songs.join(',')} @$index ${position.inMilliseconds}ms');
  }

  @override
  Future<void> playQueue({
    required List<String> songs,
    required int index,
    required String? album,
    required String? sourceId,
  }) async {
    calls.add('playQueue');
  }

  @override
  Future<bool> enqueue({
    required List<String> songs,
    required bool playNext,
  }) async {
    calls.add('enqueue ${songs.join(',')}${playNext ? ' next' : ''}');
    return true;
  }

  @override
  Future<bool> replaceUpcoming({
    required List<String> songs,
    required String? album,
    required String? sourceId,
  }) async {
    calls.add('replace ${songs.join(',')}');
    return true;
  }

  @override
  Future<void> moveInQueue(int from, int to) async => calls.add('move');

  @override
  Future<void> removeFromQueue(int index) async => calls.add('remove $index');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> skipNext() async => calls.add('next');

  @override
  Future<void> skipPrevious() async => calls.add('previous');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek ${position.inMilliseconds}');

  @override
  Future<void> setShuffle({required bool enabled}) async =>
      calls.add('shuffle $enabled');

  @override
  Future<void> setRepeat(String mode) async => calls.add('repeat $mode');

  @override
  Future<void> setVolume(double level) async => calls.add('volume $level');

  @override
  Future<void> skipTo(int index) async => calls.add('skipTo $index');

  @override
  Future<void> releaseOutput() async => calls.add('release');

  void emit(CloudPlayback? playback) => _playback.add(playback);

  @override
  bool get rendersLocally => true;

  @override
  Future<int?> millisUntilPlaying() async => 0;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  Future<String?> readSecret(String key) async => secrets[key];

  @override
  Future<void> writeSecret(String key, String value) async =>
      secrets[key] = value;

  @override
  Future<void> deleteSecret(String key) async => secrets.remove(key);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late FakeContinuityServer server;
  late FakeHost host;
  late JellyboxCloud<String> cloud;

  setUp(() async {
    server = await FakeContinuityServer.start();
    host = FakeHost();
    cloud = JellyboxCloud<String>(host: host);
  });

  tearDown(() async {
    await cloud.dispose();
    await server.close();
  });

  test('normalizes a bare host:port into an http url', () {
    expect(normalizeContinuityUrl('192.168.1.10:8000'), 'http://192.168.1.10:8000');
    expect(normalizeContinuityUrl(' http://box:8000 '), 'http://box:8000');
    expect(normalizeContinuityUrl(''), defaultContinuityUrl);
  });

  test('starts unavailable and off, then connects', () async {
    expect(cloud.available, isTrue);
    expect(cloud.state.status, ConductorStatus.off);

    await cloud.start(benchUrl: server.url.toString());
    await settle();

    expect(cloud.state.status, ConductorStatus.listening);
    expect(cloud.observing, isTrue);
  });

  test('signs in and registers this device', () async {
    final ok = await cloud.signIn(
      address: '127.0.0.1:${server.port}',
      login: 'me@example.com',
      password: 'secret',
    );
    await settle();

    expect(ok, isTrue);
    expect(cloud.state.account?.userId, 'user-1');
    expect(cloud.state.account?.login, 'me@example.com');

    final register = server.ofType('register').single;
    expect(register['device_id'], 'me');
    expect(register['backend_ref'], 'server-1');
    expect(register['token'], 'token-1');
  });

  test('rejected credentials fail without waiting for the timeout', () async {
    final ok = await cloud.signIn(
      address: '127.0.0.1:${server.port}',
      login: 'bad',
      password: 'secret',
    );
    expect(ok, isFalse);
    expect(cloud.state.account, isNull);
    expect(cloud.state.error, 'Invalid login or password.');
  });

  test('a revoked credential signs the device out', () async {
    await cloud.signIn(
      address: '127.0.0.1:${server.port}',
      login: 'me@example.com',
      password: 'secret',
    );
    await settle();
    expect(cloud.state.account, isNotNull);

    server.push({
      'type': 'signed_out',
      'message': 'Sign in before registering a device.',
    });
    await settle();

    expect(cloud.state.account, isNull);
    expect(cloud.state.error, contains('Sign in'));
    expect(host.secrets, isNot(contains(JellyboxCloud.accountStorageKey)));
  });

  test('persists the account so a restart stays signed in', () async {
    await cloud.signIn(
      address: server.url.toString(),
      login: 'me@example.com',
      password: 'secret',
    );
    await settle();
    expect(host.secrets, contains(JellyboxCloud.accountStorageKey));

    final revived = JellyboxCloud<String>(host: host);
    addTearDown(revived.dispose);
    await revived.start(benchUrl: server.url.toString());
    await settle();

    expect(revived.state.account?.userId, 'user-1');
  });

  test('sign-in fails when the server is unreachable', () async {
    final result = await cloud.signIn(
      address: 'http://127.0.0.1:1',
      login: 'x',
      password: 'y',
    );
    expect(result, isFalse);
    expect(cloud.state.signedIn, isFalse);
    expect(cloud.state.status, ConductorStatus.error);
  });

  test('RemoteSession advances position while playing', () {
    final receivedAt = DateTime(2026, 1, 1, 12);
    final session = RemoteSession(
      doc: const SessionDoc(trackPositionMs: 1000, playing: true, itemIds: ['a']),
      ageMs: 0,
      receivedAt: receivedAt,
    );
    expect(
      session.positionAt(receivedAt.add(const Duration(seconds: 2))),
      const Duration(milliseconds: 3000),
    );
  });

  test('RemoteSession freezes position while paused', () {
    final receivedAt = DateTime(2026, 1, 1, 12);
    final session = RemoteSession(
      doc: const SessionDoc(trackPositionMs: 1000, itemIds: ['a']),
      ageMs: 0,
      receivedAt: receivedAt,
    );
    expect(
      session.positionAt(receivedAt.add(const Duration(seconds: 2))),
      const Duration(milliseconds: 1000),
    );
  });

  group('once another device is the renderer', () {
    Future<void> becomeRemoteRenderer() async {
      await cloud.signIn(
        address: server.url.toString(),
        login: 'me@example.com',
        password: 'secret',
      );
      await settle();
      server.pushState(
        doc: {
          'backendRef': 'server-1',
          'albumId': 'album-1',
          'itemIds': ['s1', 's2'],
          'queuePosition': 0,
          'trackPositionMs': 5000,
          'playing': true,
        },
        activeRenderer: 'phone',
        devices: [
          {'id': 'phone', 'name': 'Phone', 'platform': 'ios', 'isRenderer': true},
          {'id': 'me', 'name': 'Test device', 'platform': 'test'},
        ],
      );
      await settle();
    }

    test('is detected from the broadcast state', () async {
      await becomeRemoteRenderer();

      expect(cloud.hasRemoteRenderer, isTrue);
      expect(cloud.state.remoteRenderer?.id, 'phone');
      expect(cloud.state.remote?.doc.itemIds, ['s1', 's2']);
    });

    test('play is forwarded instead of played locally', () async {
      await becomeRemoteRenderer();
      host.calls.clear();

      final handled = await cloud.playOnRenderer(
        itemIds: ['s1', 's2'],
        index: 1,
        albumId: 'album-1',
      );
      await settle();

      expect(handled, isTrue);
      expect(host.calls, isEmpty);
      final command = server.ofType('command').single;
      expect(command['command'], 'play');
      expect((command['value'] as Map)['index'], 1);
    });

    test('queue edits are forwarded', () async {
      await becomeRemoteRenderer();

      await cloud.moveOnRenderer(0, 1);
      await cloud.removeOnRenderer(1);
      await settle();

      expect(
        server.ofType('command').map((message) => message['command']),
        ['move', 'remove'],
      );
    });

    test('commands from the renderer run on the host', () async {
      await cloud.signIn(
        address: server.url.toString(),
        login: 'me@example.com',
        password: 'secret',
      );
      await settle();
      server.pushState(
        doc: {
          'backendRef': 'server-1',
          'itemIds': ['s1'],
          'playing': true,
        },
        activeRenderer: 'me',
        devices: [
          {'id': 'me', 'name': 'Test device', 'platform': 'test', 'isRenderer': true},
        ],
      );
      await settle();
      host.calls.clear();

      server.push({'type': 'command', 'command': 'pause', 'value': null});
      server.push({'type': 'command', 'command': 'seek', 'value': 90000});
      await settle();

      expect(host.calls, ['pause', 'seek 90000']);
    });

    test('a handoff plays the session here and accepts', () async {
      await becomeRemoteRenderer();
      host.calls.clear();

      server.push({
        'type': 'handoff',
        'from': 'phone',
        'doc': {
          'albumId': 'album-1',
          'itemIds': ['s1', 's2'],
          'queuePosition': 1,
          'trackPositionMs': 42000,
          'playing': true,
        },
      });
      await settle();

      expect(host.calls, contains('play s1,s2 @1 42000ms'));
      expect(server.ofType('handoff_accept'), hasLength(1));
    });

    test('claim asks the server and adopts the session it hands back', () async {
      await becomeRemoteRenderer();

      await cloud.claimHere();
      await settle();

      expect(server.ofType('claim'), hasLength(1));
      // The server answers a claim with the live session.
      server.push({
        'type': 'handoff',
        'from': 'phone',
        'doc': {
          'itemIds': ['s1', 's2'],
          'queuePosition': 0,
          'trackPositionMs': 5000,
          'playing': true,
        },
      });
      await settle();
      expect(server.ofType('handoff_accept'), hasLength(1));
    });

    test('losing the renderer makes this device release its output', () async {
      await cloud.signIn(
        address: server.url.toString(),
        login: 'me@example.com',
        password: 'secret',
      );
      await settle();
      server.pushState(
        doc: {'itemIds': ['s1'], 'playing': true},
        activeRenderer: 'me',
        devices: [
          {'id': 'me', 'name': 'Test device', 'platform': 'test', 'isRenderer': true},
        ],
      );
      await settle();
      host.calls.clear();

      server.pushState(
        doc: {'itemIds': ['s1'], 'playing': true},
        activeRenderer: 'phone',
        devices: [
          {'id': 'phone', 'name': 'Phone', 'platform': 'ios', 'isRenderer': true},
          {'id': 'me', 'name': 'Test device', 'platform': 'test'},
        ],
      );
      await settle();

      expect(host.calls, contains('release'));
    });
  });

  test('a peer cannot make this device publish its own queue', () async {
    await cloud.signIn(
      address: server.url.toString(),
      login: 'me@example.com',
      password: 'secret',
    );
    await settle();
    server.pushState(
      doc: {'itemIds': ['theirs'], 'playing': true},
      activeRenderer: 'phone',
      devices: [
        {'id': 'phone', 'name': 'Phone', 'platform': 'ios', 'isRenderer': true},
        {'id': 'me', 'name': 'Test device', 'platform': 'test'},
      ],
    );
    await settle();
    server.received.clear();

    host.current = const CloudPlayback(
      itemIds: ['mine'],
      index: 0,
      position: Duration.zero,
      playing: true,
    );
    host.emit(host.current);
    await settle();

    expect(server.ofType('state'), isEmpty);
  });

  test('dispose closes the socket and ignores late messages', () async {
    await cloud.signIn(
      address: server.url.toString(),
      login: 'me@example.com',
      password: 'secret',
    );
    await settle();

    await cloud.dispose();
    server.push({'type': 'error', 'message': 'late'});
    await settle();

    expect(cloud.state.error, isNull);
  });
}
