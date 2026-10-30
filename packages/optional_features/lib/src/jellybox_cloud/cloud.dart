import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:optional_features/src/jellybox_cloud/host.dart';
import 'package:optional_features/src/jellybox_cloud/log.dart';
import 'package:optional_features/src/jellybox_cloud/models.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Default local continuity server. Override with [JellyboxCloud.start]'s
/// `benchUrl` or by changing the app's conductor URL preference.
const String defaultContinuityUrl = 'http://localhost:8000';

/// Accepts `host:port`, `http://host:port` or a full WebSocket URL and returns
/// an HTTP base URL. A bare `host:port` would otherwise parse as an opaque URI.
String normalizeContinuityUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return defaultContinuityUrl;
  if (value.contains('://')) return value;
  return 'http://$value';
}

@immutable
class RemoteSession {
  const RemoteSession({
    required this.doc,
    required this.ageMs,
    required this.receivedAt,
  });

  final SessionDoc doc;
  final int ageMs;
  final DateTime receivedAt;

  Duration positionAt(DateTime now) {
    final base = Duration(milliseconds: doc.trackPositionMs);
    if (!doc.playing) return base;
    return base + now.difference(receivedAt);
  }
}

@immutable
class CloudState {
  const CloudState({
    this.status = ConductorStatus.off,
    this.devices = const [],
    this.remote,
    this.account,
    this.busy = false,
    this.lastHandoffMs,
    this.error,
    this.handingOffTo,
  });

  final ConductorStatus status;
  final List<ConductorDevice> devices;
  final RemoteSession? remote;
  final ContinuityAccount? account;
  final bool busy;
  final int? lastHandoffMs;
  final String? error;
  final String? handingOffTo;

  bool get signedIn => account != null;

  bool get isConnected =>
      status == ConductorStatus.listening ||
      status == ConductorStatus.rendering;

  List<ConductorDevice> get targets => devices.where((d) => !d.isSelf).toList();

  ConductorDevice? get remoteRenderer {
    for (final device in devices) {
      if (device.isRenderer && !device.isSelf) return device;
    }
    return null;
  }

  CloudState copyWith({
    ConductorStatus? status,
    List<ConductorDevice>? devices,
    RemoteSession? remote,
    bool clearRemote = false,
    ContinuityAccount? account,
    bool clearAccount = false,
    bool? busy,
    int? lastHandoffMs,
    String? error,
    bool clearError = false,
    String? handingOffTo,
    bool clearHandingOffTo = false,
  }) {
    return CloudState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      remote: clearRemote ? null : (remote ?? this.remote),
      account: clearAccount ? null : (account ?? this.account),
      busy: busy ?? this.busy,
      lastHandoffMs: lastHandoffMs ?? this.lastHandoffMs,
      error: clearError ? null : (error ?? this.error),
      handingOffTo: clearHandingOffTo
          ? null
          : (handingOffTo ?? this.handingOffTo),
    );
  }
}

class JellyboxCloud<S> {
  JellyboxCloud({required CloudHost<S> host}) : _host = host;

  static const accountStorageKey = 'continuity_account';

  static const _handoffTimeout = Duration(seconds: 15);
  // Reconnection backs off exponentially: a server that is restarting, or an
  // account whose token was revoked, must not be hammered every few seconds.
  static const _reconnectBaseDelay = Duration(seconds: 5);
  static const _reconnectMaxDelay = Duration(seconds: 30);
  // Playback ticks arrive several times a second and only move the position;
  // peers need the newest doc, so publishes are folded into one per interval.
  static const _publishMinInterval = Duration(milliseconds: 250);

  final CloudHost<S> _host;
  final _stateController = StreamController<CloudState>.broadcast();
  CloudState _state = const CloudState();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  StreamSubscription<CloudPlayback?>? _playbackSubscription;
  Completer<bool>? _signInCompleter;
  Timer? _reconnectTimer;
  Timer? _handoffTimer;
  Duration _reconnectDelay = _reconnectBaseDelay;
  Timer? _publishTimer;
  CloudPlayback? _pendingPublish;
  String? _lastPublishSig;
  DateTime? _lastPublishAt;
  ContinuityAccount? _account;
  String? _serverUrl;
  bool _observing = false;
  bool _disposed = false;

  /// Serializes connect/disconnect so a URL change and a sign-in cannot race.
  Future<void> _connectLock = Future<void>.value();

  /// Set while this device applies a remote command. The host then drives local
  /// playback, which must not be forwarded back to the cloud.
  bool _applyingRemote = false;

  /// Whether this build implements continuity at all. The app hides every
  /// continuity entry point when it is false, so it stays true regardless of
  /// whether the server is reachable right now.
  bool get available => true;
  CloudState get state => _state;
  Stream<CloudState> get states => _stateController.stream;
  bool get observing => _observing;

  /// True when another device is the elected renderer for our library. The app
  /// forwards playback intents to the cloud only while this holds.
  bool get hasRemoteRenderer {
    if (_applyingRemote) return false;
    if (_rendersHere) return false;
    final remote = _state.remote;
    if (remote == null || remote.doc.isEmpty) return false;
    if (_state.remoteRenderer == null) return false;
    final mine = _host.backendRef;
    final theirs = remote.doc.backendRef;
    return mine == null || theirs == null || mine == theirs;
  }

  /// True when the server elected this device as the renderer.
  bool get _rendersHere => _state.status == ConductorStatus.rendering;

  /// True when another connected device is the elected renderer.
  bool get _hasOtherRenderer =>
      !_rendersHere && _state.remoteRenderer != null;

  /// Whether this device should publish its playback state. The first device to
  /// report playing becomes the renderer; a device that merely watches another
  /// renderer must stay silent so it cannot overwrite the queue.
  bool get _shouldPublish => _channel != null && !_hasOtherRenderer;

  void _setState(CloudState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<void> start({String? benchUrl}) async {
    _serverUrl ??= normalizeContinuityUrl(benchUrl ?? defaultContinuityUrl);
    await _loadAccount();
    if (_channel == null) await _connect(_serverUrl!);
  }

  Future<void> refresh({String? benchUrl}) async {
    final url = benchUrl == null ? null : normalizeContinuityUrl(benchUrl);
    if (url != null && url != _serverUrl) {
      _serverUrl = url;
      await _disconnect();
      await _connect(url);
      return;
    }
    if (_channel == null) {
      if (_serverUrl == null) return;
      await _connect(_serverUrl!);
      return;
    }
    // Already connected: re-register so a user/server switch moves this device
    // into the right session instead of leaving it behind in the old one.
    if (_account != null) _register();
  }

  Future<void> networkChanged() async {
    if (_channel != null) return;
    if (_serverUrl == null) return;
    await _connect(_serverUrl!);
  }

  Future<void> _connect(String baseUrl) {
    final next = _connectLock.then((_) => _connectNow(baseUrl));
    _connectLock = next.catchError((Object _) {});
    return next;
  }

  Future<void> _connectNow(String baseUrl) async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setState(
      _state.copyWith(status: ConductorStatus.connecting, clearError: true),
    );
    try {
      final httpUri = Uri.parse(normalizeContinuityUrl(baseUrl));
      final wsUri = httpUri.replace(
        scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
        path: (httpUri.path.isEmpty || httpUri.path == '/')
            ? '/ws'
            : httpUri.path,
      );
      final channel = WebSocketChannel.connect(wsUri);
      _channel = channel;
      await channel.ready;
      if (_disposed || !identical(_channel, channel)) {
        unawaited(channel.sink.close());
        return;
      }
      _channelSubscription = channel.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      _observing = true;
      _setState(_state.copyWith(status: ConductorStatus.listening));
      if (_account != null) _register();
    } on Object catch (error) {
      _channel = null;
      _observing = false;
      _setState(
        _state.copyWith(
          status: ConductorStatus.error,
          error: error.toString(),
        ),
      );
      _signInCompleter?.complete(false);
      _signInCompleter = null;
      _scheduleReconnect();
    }
  }

  Future<void> _disconnect() {
    final next = _connectLock.then((_) => _disconnectNow());
    _connectLock = next.catchError((Object _) {});
    return next;
  }

  Future<void> _disconnectNow() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _publishTimer?.cancel();
    _publishTimer = null;
    _pendingPublish = null;
    _observing = false;
    final channel = _channel;
    _channel = null;
    final subscription = _channelSubscription;
    _channelSubscription = null;
    _signInCompleter?.complete(false);
    _signInCompleter = null;
    await subscription?.cancel();
    await channel?.sink.close();
  }

  Future<bool> signIn({
    required String address,
    required String login,
    required String password,
  }) async {
    final next = normalizeContinuityUrl(address);
    final previous = _serverUrl;
    _serverUrl = next;
    if (_channel == null) {
      await _connect(next);
    } else if (previous != next) {
      // The user pointed the app at another server; the old socket would
      // otherwise swallow the sign-in and keep this device in the old session.
      await _disconnect();
      await _connect(next);
    }
    if (_channel == null) return false;

    final completer = Completer<bool>();
    _signInCompleter?.complete(false);
    _signInCompleter = completer;
    _send({
      'type': 'signin',
      'address': _serverUrl,
      'login': login,
      'password': password,
    });
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _signInCompleter = null;
        return false;
      },
    );
  }

  Future<void> signOut() async {
    _account = null;
    _observing = false;
    await _playbackSubscription?.cancel();
    _playbackSubscription = null;
    await _disconnect();
    await _clearAccount();
    _setState(const CloudState());
  }

  void forgetAccount() {
    if (_account == null) return;
    _account = null;
    unawaited(_clearAccount());
    if (_channel != null) _send({'type': 'unregister'});
    _setState(_state.copyWith(clearAccount: true));
  }

  Future<bool> handoffTo(String deviceId) async {
    if (_channel == null) return false;
    _handoffTimer?.cancel();
    _handoffTimer = Timer(_handoffTimeout, () {
      if (_state.handingOffTo != deviceId) return;
      _setState(
        _state.copyWith(
          clearHandingOffTo: true,
          busy: false,
          error: 'The other device did not answer.',
        ),
      );
    });
    _setState(_state.copyWith(handingOffTo: deviceId, busy: true));
    _send({'type': 'handoff_request', 'target_device_id': deviceId});
    return true;
  }

  bool? sameBackend(ConductorDevice device) {
    final backend = _host.backendRef;
    if (backend == null || device.backend == null) return null;
    return backend == device.backend;
  }

  Future<void> sendCommand(PlayerCommand command, {Object? value}) async {
    _send({'type': 'command', 'command': command.wire, 'value': value});
  }

  /// Asks the renderer to start a queue. Local playback stays local: the app
  /// only calls these while another device owns the session.
  Future<bool> playOnRenderer({
    required List<String> itemIds,
    required int index,
    String? albumId,
    String? sourceId,
  }) async => _command(PlayerCommand.play.wire, {
    'itemIds': itemIds,
    'index': index,
    'albumId': albumId,
    'sourceId': sourceId,
  });

  Future<bool> enqueueOnRenderer({
    required List<String> itemIds,
    required bool playNext,
  }) async => _command('enqueue', {
    'itemIds': itemIds,
    'playNext': playNext,
  });

  Future<bool> replaceUpcomingOnRenderer({
    required List<String> itemIds,
    String? albumId,
    String? sourceId,
  }) async => _command('replace_upcoming', {
    'itemIds': itemIds,
    'albumId': albumId,
    'sourceId': sourceId,
  });

  Future<bool> moveOnRenderer(int from, int to) async =>
      _command('move', {'from': from, 'to': to});

  Future<bool> removeOnRenderer(int index) async =>
      _command('remove', {'index': index});

  bool _command(String command, Object? value) {
    if (_channel == null) return false;
    _send({'type': 'command', 'command': command, 'value': value});
    return true;
  }

  /// Takes renderer status for this device, stealing it from whoever has it.
  ///
  /// The server answers with a `handoff` carrying the live session, so the
  /// queue and position survive the takeover even when this device had nothing
  /// queued. [claimHere] therefore only asks; the switch happens when the
  /// handoff lands.
  Future<bool> claimHere() async {
    if (_channel == null) return false;
    _handoffTimer?.cancel();
    _handoffTimer = null;
    _send({'type': 'claim'});
    return true;
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _handoffTimer?.cancel();
    _signInCompleter?.complete(false);
    _signInCompleter = null;
    await _playbackSubscription?.cancel();
    _playbackSubscription = null;
    await _disconnect();
    _observing = false;
    await _stateController.close();
  }

  void _send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(message));
    } on Object catch (error) {
      cloudLog('[continuity] send failed: $error');
    }
  }

  void _onMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      switch (data['type']) {
        case 'signed_in':
          _handleSignedIn(data['account'] as Map<String, dynamic>);
        case 'registered':
          _handleRegistered();
        case 'state':
          _handleState(data);
        case 'command':
          unawaited(_handleCommand(data));
        case 'handoff':
          unawaited(_handleHandoff(data));
        case 'handoff_pending':
          _setState(
            _state.copyWith(
              handingOffTo: data['target_device_id'] as String?,
              busy: true,
            ),
          );
        case 'handoff_accepted':
          _handleHandoffAccepted(data);
        case 'handoff_rejected':
          _handoffTimer?.cancel();
          _handoffTimer = null;
          _setState(_state.copyWith(clearHandingOffTo: true, busy: false));
        case 'signed_out':
          _handleSignedOut(data['message'] as String?);
        case 'error':
          _signInCompleter?.complete(false);
          _signInCompleter = null;
          _setState(
            _state.copyWith(
              error: data['message'] as String?,
              busy: false,
            ),
          );
      }
    } on Object catch (error) {
      _setState(_state.copyWith(error: error.toString()));
    }
  }

  void _handleSignedOut(String? message) {
    _account = null;
    unawaited(_clearAccount());
    _setState(
      CloudState(error: message ?? 'This device is no longer signed in.'),
    );
    unawaited(_disconnect());
  }

  void _handleSignedIn(Map<String, dynamic> accountData) {
    _account = ContinuityAccount(
      serverUrl: accountData['serverUrl'] as String? ?? _serverUrl ?? '',
      login: accountData['login'] as String? ?? '',
      userId: accountData['userId'] as String,
      token: accountData['token'] as String? ?? '',
      serverName: accountData['serverName'] as String?,
      libraryName: accountData['libraryName'] as String?,
      socketPath: accountData['socketPath'] as String? ?? '/ws',
    );
    unawaited(_saveAccount(_account!));
    _setState(_state.copyWith(account: _account, clearError: true));
    _register();
    _signInCompleter?.complete(true);
    _signInCompleter = null;
  }

  void _register() {
    _send({
      'type': 'register',
      'device_id': _host.deviceId,
      'name': _host.deviceName,
      'platform': _host.platform,
      'backend_ref': _host.backendRef,
      'token': _account?.token ?? '',
    });
  }

  void _handleRegistered() {
    // A live connection ends the backoff; a dropped one starts it again.
    _reconnectDelay = _reconnectBaseDelay;
    _setState(
      _state.copyWith(status: ConductorStatus.listening, clearError: true),
    );
    _startObservingPlayback();
    _sendCurrentState();
  }

  void _startObservingPlayback() {
    unawaited(_playbackSubscription?.cancel());
    _playbackSubscription = _host.playbackChanges.listen((playback) {
      if (playback == null) return;
      _publishPlayback(playback);
    });
  }

  Map<String, dynamic> _playbackToDoc(CloudPlayback playback) => {
    'backendRef': _host.backendRef,
    'albumId': playback.albumId,
    'itemIds': playback.itemIds,
    'queuePosition': playback.index,
    'trackPositionMs': playback.position.inMilliseconds,
    'playing': playback.playing,
    'shuffle': playback.shuffle,
    'repeat': playback.repeat,
    'volume': playback.volume,
    'sourceId': playback.sourceId,
  };

  /// Publishes playback state, folding rapid position ticks into one trailing
  /// send. Shape changes (queue, mode, volume) go out immediately.
  void _publishPlayback(CloudPlayback playback) {
    if (!_shouldPublish) return;
    final sig = _publishSignature(playback);
    final now = DateTime.now();
    final since = _lastPublishAt == null ? null : now.difference(_lastPublishAt!);
    if (sig != _lastPublishSig || since == null || since >= _publishMinInterval) {
      _publishTimer?.cancel();
      _publishTimer = null;
      _pendingPublish = null;
      _lastPublishSig = sig;
      _lastPublishAt = now;
      _send({'type': 'state', 'doc': _playbackToDoc(playback)});
      return;
    }
    _pendingPublish = playback;
    _publishTimer ??= Timer(_publishMinInterval - since, _flushPendingPublish);
  }

  void _flushPendingPublish() {
    _publishTimer = null;
    final playback = _pendingPublish;
    _pendingPublish = null;
    if (playback == null || !_shouldPublish) return;
    _lastPublishSig = _publishSignature(playback);
    _lastPublishAt = DateTime.now();
    _send({'type': 'state', 'doc': _playbackToDoc(playback)});
  }

  /// Everything but the playback position: only a tick may be folded, so a
  /// queue, mode, or volume change never waits for the throttle.
  String _publishSignature(CloudPlayback playback) => [
    _host.backendRef,
    playback.albumId,
    playback.itemIds.length,
    playback.index,
    playback.playing,
    playback.shuffle,
    playback.repeat,
    playback.volume,
  ].join('|');

  void _sendCurrentState() {
    if (!_shouldPublish) return;
    final playback = _host.playback;
    if (playback == null) return;
    _publishTimer?.cancel();
    _publishTimer = null;
    _pendingPublish = null;
    _lastPublishSig = _publishSignature(playback);
    _lastPublishAt = DateTime.now();
    _send({'type': 'state', 'doc': _playbackToDoc(playback)});
  }

  void _handleState(Map<String, dynamic> data) => _applySnapshot(data);

  /// Adopts a server snapshot and reacts to losing or gaining the renderer
  /// seat. [clearHandoff] also ends a pending handoff UI state.
  void _applySnapshot(
    Map<String, dynamic> data, {
    bool clearHandoff = false,
  }) {
    final doc = _parseDoc(data['doc'] as Map<String, dynamic>? ?? const {});
    final devices = _parseDevices(data['devices'] as List<dynamic>? ?? const []);
    final activeRenderer = data['active_renderer'] as String?;
    final isActive = activeRenderer == _host.deviceId;
    final wasActive = _rendersHere;
    _setState(
      _state.copyWith(
        status: isActive
            ? ConductorStatus.rendering
            : ConductorStatus.listening,
        devices: devices,
        remote: doc.isEmpty
            ? null
            : RemoteSession(doc: doc, ageMs: 0, receivedAt: DateTime.now()),
        clearRemote: doc.isEmpty,
        clearError: true,
        busy: clearHandoff ? false : null,
        clearHandingOffTo: clearHandoff,
      ),
    );
    if (isActive && !wasActive) {
      _startObservingPlayback();
      _sendCurrentState();
    } else if (!isActive && wasActive) {
      unawaited(_host.releaseOutput());
    }
  }

  SessionDoc _parseDoc(Map<String, dynamic> data) => SessionDoc(
    backendRef: data['backendRef'] as String?,
    albumId: data['albumId'] as String?,
    itemIds: (data['itemIds'] as List<dynamic>? ?? const []).cast<String>(),
    queuePosition: data['queuePosition'] as int? ?? 0,
    trackPositionMs: data['trackPositionMs'] as int? ?? 0,
    playing: data['playing'] as bool? ?? false,
    shuffle: data['shuffle'] as bool? ?? false,
    repeat: data['repeat'] as String? ?? 'off',
    volume: (data['volume'] as num?)?.toDouble() ?? 1,
    sourceId: data['sourceId'] as String?,
  );

  List<ConductorDevice> _parseDevices(List<dynamic> list) => [
    for (final raw in list)
      if (raw is Map<String, dynamic>)
        ConductorDevice(
          id: raw['id'] as String,
          name: raw['name'] as String? ?? raw['id'] as String,
          platform: raw['platform'] as String? ?? 'unknown',
          backend: raw['backend'] as String?,
          isRenderer: raw['isRenderer'] as bool? ?? false,
          isSelf: raw['id'] == _host.deviceId,
          isOnline: raw['isOnline'] as bool? ?? true,
        ),
  ];

  Future<void> _handleHandoff(Map<String, dynamic> data) async {
    final doc = _parseDoc(data['doc'] as Map<String, dynamic>? ?? const {});
    if (doc.isEmpty) {
      _send({'type': 'handoff_reject'});
      return;
    }
    _applyingRemote = true;
    try {
      final songs = await _host.itemsByIds(doc.itemIds);
      final album = doc.albumId != null
          ? await _host.albumById(doc.albumId!)
          : null;
      await _host.play(
        songs: songs,
        index: doc.queuePosition,
        album: album,
        sourceId: doc.sourceId,
        position: Duration(milliseconds: doc.trackPositionMs),
        autoPlay: doc.playing,
        shuffle: doc.shuffle,
      );
      _send({'type': 'handoff_accept'});
    } on Object catch (error) {
      _send({'type': 'handoff_reject'});
      _setState(_state.copyWith(error: error.toString()));
    } finally {
      _applyingRemote = false;
    }
  }

  void _handleHandoffAccepted(Map<String, dynamic> data) {
    _handoffTimer?.cancel();
    _handoffTimer = null;
    // The broadcast carries the same snapshot as a state update, so the new
    // active renderer and device flags land without waiting for another push.
    _applySnapshot(data, clearHandoff: true);
  }

  Future<void> _handleCommand(Map<String, dynamic> data) async {
    if (!_rendersHere) return;
    final value = data['value'];
    _applyingRemote = true;
    try {
      switch (data['command']) {
        case 'play':
          if (value is Map<String, dynamic>) {
            final ids = (value['itemIds'] as List<dynamic>? ?? const [])
                .cast<String>();
            final songs = await _host.itemsByIds(ids);
            final album = value['albumId'] != null
                ? await _host.albumById(value['albumId'] as String)
                : null;
            await _host.play(
              songs: songs,
              index: value['index'] as int? ?? 0,
              album: album,
              sourceId: value['sourceId'] as String?,
              position: Duration.zero,
              autoPlay: true,
              shuffle: false,
            );
          } else {
            await _host.resume();
          }
        case 'pause':
          await _host.pause();
        case 'next':
          await _host.skipNext();
        case 'previous':
          await _host.skipPrevious();
        case 'seek':
          if (value is num) {
            await _host.seek(Duration(milliseconds: value.toInt()));
          }
        case 'shuffle':
          if (value is bool) await _host.setShuffle(enabled: value);
        case 'repeat':
          if (value is String) await _host.setRepeat(value);
        case 'volume':
          if (value is num) await _host.setVolume(value.toDouble());
        case 'skip_to':
          if (value is num) await _host.skipTo(value.toInt());
        case 'enqueue':
          if (value is Map<String, dynamic>) {
            final ids = (value['itemIds'] as List<dynamic>? ?? const [])
                .cast<String>();
            final songs = await _host.itemsByIds(ids);
            await _host.enqueue(
              songs: songs,
              playNext: value['playNext'] as bool? ?? false,
            );
          }
        case 'replace_upcoming':
          if (value is Map<String, dynamic>) {
            final ids = (value['itemIds'] as List<dynamic>? ?? const [])
                .cast<String>();
            final songs = await _host.itemsByIds(ids);
            final album = value['albumId'] != null
                ? await _host.albumById(value['albumId'] as String)
                : null;
            await _host.replaceUpcoming(
              songs: songs,
              album: album,
              sourceId: value['sourceId'] as String?,
            );
          }
        case 'move':
          if (value is Map<String, dynamic>) {
            await _host.moveInQueue(
              value['from'] as int? ?? 0,
              value['to'] as int? ?? 0,
            );
          }
        case 'remove':
          if (value is Map<String, dynamic>) {
            await _host.removeFromQueue(value['index'] as int? ?? 0);
          }
      }
    } on Object catch (error) {
      _setState(_state.copyWith(error: error.toString()));
    } finally {
      _applyingRemote = false;
    }
  }

  void _onError(Object error) {
    _observing = false;
    _setState(
      _state.copyWith(
        status: ConductorStatus.error,
        error: error.toString(),
      ),
    );
    unawaited(_afterDrop());
  }

  void _onDone() {
    _observing = false;
    _setState(_state.copyWith(status: ConductorStatus.off));
    unawaited(_afterDrop());
  }

  Future<void> _afterDrop() async {
    await _disconnect();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _account == null || _serverUrl == null) return;
    if (_reconnectTimer != null) return;
    _reconnectTimer = Timer(_reconnectDelay, () {
      _reconnectTimer = null;
      if (_disposed || _channel != null) return;
      unawaited(_connect(_serverUrl!));
    });
    _reconnectDelay = Duration(
      milliseconds: (_reconnectDelay.inMilliseconds * 2).clamp(
        _reconnectBaseDelay.inMilliseconds,
        _reconnectMaxDelay.inMilliseconds,
      ),
    );
  }

  Future<void> _loadAccount() async {
    if (_account != null) return;
    try {
      final raw = await _host.readSecret(accountStorageKey);
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _account = ContinuityAccount(
        serverUrl: data['serverUrl'] as String? ?? '',
        login: data['login'] as String? ?? '',
        userId: data['userId'] as String,
        token: data['token'] as String? ?? '',
        serverName: data['serverName'] as String?,
        libraryName: data['libraryName'] as String?,
        socketPath: data['socketPath'] as String? ?? '/ws',
      );
      _setState(_state.copyWith(account: _account));
    } on Object catch (error) {
      cloudLog('[continuity] could not restore account: $error');
    }
  }

  Future<void> _saveAccount(ContinuityAccount account) async {
    try {
      await _host.writeSecret(
        accountStorageKey,
        jsonEncode({
          'serverUrl': account.serverUrl,
          'login': account.login,
          'userId': account.userId,
          'token': account.token,
          'serverName': account.serverName,
          'libraryName': account.libraryName,
          'socketPath': account.socketPath,
        }),
      );
    } on Object catch (error) {
      cloudLog('[continuity] could not persist account: $error');
    }
  }

  Future<void> _clearAccount() async {
    try {
      await _host.deleteSecret(accountStorageKey);
    } on Object catch (error) {
      cloudLog('[continuity] could not clear account: $error');
    }
  }
}
