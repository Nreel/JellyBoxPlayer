import 'dart:async';

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jplayer/src/config/constants.dart';
import 'package:jplayer/src/data/cloud/cloud_host_adapter.dart';
import 'package:jplayer/src/data/providers/providers.dart';
import 'package:jplayer/src/domain/models/models.dart';
import 'package:jplayer/src/domain/playback/play_request.dart';
import 'package:jplayer/src/domain/providers/current_user_provider.dart';
import 'package:jplayer/src/domain/providers/playback_provider.dart';
import 'package:jplayer/src/providers/accounts_provider.dart';
import 'package:jplayer/src/providers/current_server_id_provider.dart';
import 'package:optional_features/jellybox_cloud.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The continuity server has the same two-address model as the media server:
/// [home] is the LAN address the user owns, [remote] a second address for the
/// same server (Tailscale, WireGuard, reverse proxy). [active] is the address
/// the app currently reaches the server through; it fails over to [remote]
/// when [home] stops answering and back when [home] answers again.
@immutable
class ConductorAddresses {
  const ConductorAddresses({
    this.home = '',
    this.remote,
    this.active = '',
    this.down = const {},
  });

  final String home;
  final String? remote;
  final String active;
  final Set<String> down;

  List<String> get candidates => [
    if (home.isNotEmpty) home,
    if (remote != null && remote!.isNotEmpty) remote!,
  ];

  ConductorAddresses copyWith({
    String? home,
    String? Function()? remote,
    String? active,
    Set<String>? down,
  }) => ConductorAddresses(
    home: home ?? this.home,
    remote: remote == null ? this.remote : remote(),
    active: active ?? this.active,
    down: down ?? this.down,
  );

  @override
  bool operator ==(Object other) =>
      other is ConductorAddresses &&
      other.home == home &&
      other.remote == remote &&
      other.active == active &&
      other.down == down;

  @override
  int get hashCode => Object.hash(home, remote, active, down);
}

/// Home address seeded from [jellyboxCloudUrl] on first launch; both
/// addresses stay editable in every build because the user owns the server.
const conductorUrlStorageKey = 'conductor_url';
const conductorRemoteUrlStorageKey = 'conductor_remote_url';

final conductorUrlProvider =
    StateNotifierProvider<ConductorUrlNotifier, ConductorAddresses>((ref) {
      return ConductorUrlNotifier(
        ref.watch(sharedPreferencesProvider).valueOrNull,
      );
    });

class ConductorUrlNotifier extends StateNotifier<ConductorAddresses> {
  ConductorUrlNotifier(this._prefs)
    : super(
        ConductorAddresses(
          home: _home(_prefs),
          remote: _nullableStored(_prefs, conductorRemoteUrlStorageKey),
          active: _home(_prefs),
        ),
      );

  final SharedPreferences? _prefs;

  static String _home(SharedPreferences? prefs) {
    final stored = _stored(prefs, conductorUrlStorageKey);
    return stored.isEmpty ? jellyboxCloudUrl : stored;
  }

  static String _stored(SharedPreferences? prefs, String key) =>
      prefs?.getString(key)?.trim() ?? '';

  static String? _nullableStored(SharedPreferences? prefs, String key) {
    final value = _stored(prefs, key);
    return value.isEmpty ? null : value;
  }

  /// Points the continuity server at a new home address.
  void setHome(String value) {
    final next = value.trim().isEmpty ? '' : normalizeContinuityUrl(value);
    if (next == state.home) return;
    final remote = state.remote;
    final addresses = state.copyWith(home: next, down: const {});
    state = addresses.copyWith(
      active: next.isNotEmpty ? next : (remote ?? jellyboxCloudUrl),
    );
    _write(conductorUrlStorageKey, next);
  }

  /// Adds (or removes) the second address for the same continuity server. The
  /// home address stays in use while it answers; the new address takes over
  /// only when home has already been seen unreachable.
  void setRemote(String? value) {
    final next = value == null || value.trim().isEmpty
        ? null
        : normalizeContinuityUrl(value);
    if (next == state.remote) return;
    final down = {...state.down};
    if (next == null) {
      down.remove(state.remote ?? '');
      state = state.copyWith(
        remote: () => null,
        down: down,
        active: state.home.isEmpty ? jellyboxCloudUrl : state.home,
      );
    } else {
      down.remove(next);
      final homeDown = down.contains(state.home);
      state = state.copyWith(
        remote: () => next,
        down: down,
        active: homeDown ? next : state.home,
      );
    }
    _write(conductorRemoteUrlStorageKey, next ?? '');
  }

  /// Called when a connection attempt to [url] failed: the other address takes
  /// over. When both have been seen down the retry alternates between them, so
  /// a server that comes back on either address is found again.
  void recordFailure(String url) {
    final down = {...state.down, url};
    final others = state.candidates.where((c) => c != url).toList();
    if (others.isEmpty) {
      state = state.copyWith(down: down);
      return;
    }
    final next =
        others.firstWhereOrNull((c) => !down.contains(c)) ?? others.first;
    state = state.copyWith(down: down, active: next);
  }

  /// Called when a connection to [url] succeeded: the home address wins again,
  /// and a remote-only success marks home unreachable.
  void recordSuccess(String url) {
    if (url == state.home) {
      state = state.copyWith(down: const {}, active: url);
      return;
    }
    if (url == state.remote && state.home.isNotEmpty) {
      state = state.copyWith(down: {...state.down, state.home});
    }
  }

  /// Forget what was unreachable, e.g. after a network interface change; the
  /// home address is tried first again.
  void clearDown() {
    final home = state.home;
    state = state.copyWith(
      down: const {},
      active: home.isNotEmpty ? home : (state.remote ?? jellyboxCloudUrl),
    );
  }

  void _write(String key, String value) {
    final prefs = _prefs;
    if (prefs == null) return;
    if (value.isEmpty) {
      unawaited(prefs.remove(key));
    } else {
      unawaited(prefs.setString(key, value));
    }
  }
}

final cloudProvider = StateNotifierProvider<CloudNotifier, CloudState>((ref) {
  final notifier = CloudNotifier(ref);
  ref.onDispose(notifier.shutdown);
  return notifier;
});

class CloudNotifier extends StateNotifier<CloudState> {
  CloudNotifier(this._ref) : super(const CloudState()) {
    cloudLog = debugPrint;

    _host = CloudHostAdapter(_ref);
    _cloud = JellyboxCloud<LibraryItem>(host: _host);
    _states = _cloud.states.listen((next) {
      state = next;
      _trackOutcome(next);
    });

    _ref
      ..listen(conductorUrlProvider, (_, _) {
        // [signIn] updates the addresses and the cloud URL together. Letting
        // refresh also react would close the socket mid-sign-in and make the
        // first attempt against a new server fail.
        if (!_signingIn) unawaited(_refresh());
      })
      ..listen(currentUserProvider, (_, next) {
        if (next == null && _ref.read(accountsProvider).isEmpty) {
          _cloud.forgetAccount();
        }
        unawaited(_refresh());
      });

    _watchNetwork();
    _remote = _RemotePlayback(_cloud);
    _playback = _ref.read(playbackProvider.notifier)..remote = _remote;

    unawaited(_cloud.start(benchUrl: _benchUrl()));
  }

  final Ref _ref;

  late final CloudHostAdapter _host;
  late final JellyboxCloud<LibraryItem> _cloud;
  late final _RemotePlayback _remote;
  late final PlaybackNotifier _playback;
  late final StreamSubscription<CloudState> _states;
  StreamSubscription<List<ConnectivityResult>>? _network;
  AppLifecycleListener? _lifecycle;
  bool _signingIn = false;
  DateTime? _lastFailureAt;

  /// Gap between failovers so a server down on both addresses retries at the
  /// cloud reconnect cadence instead of hammering each address back to back.
  static const _failoverGap = Duration(seconds: 2);

  bool get available => _cloud.available;

  /// Signs in through every address of the continuity server, home first, so
  /// a device away from home still connects through the remote address.
  Future<bool> signIn({
    required String address,
    required String login,
    required String password,
  }) async {
    _signingIn = true;
    final notifier = _ref.read(conductorUrlProvider.notifier)..setHome(address);
    try {
      for (final url in notifier.state.candidates) {
        final connected = await _cloud.signIn(
          address: url,
          login: login,
          password: password,
        );
        if (connected) {
          notifier.recordSuccess(url);
          return true;
        }
        notifier.recordFailure(url);
      }
      return false;
    } finally {
      _signingIn = false;
    }
  }

  Future<void> signOut() => _cloud.signOut();

  Future<bool> handoffTo(String deviceId) => _cloud.handoffTo(deviceId);

  bool? sameBackend(ConductorDevice device) => _cloud.sameBackend(device);

  Future<void> sendCommand(PlayerCommand command, {Object? value}) =>
      _cloud.sendCommand(command, value: value);

  Future<bool> claimHere() => _cloud.claimHere();

  Future<void> shutdown() async {
    _lifecycle?.dispose();
    if (_playback.remote == _remote) _playback.remote = null;
    await _network?.cancel();
    await _states.cancel();
    await _cloud.dispose();
    _host.dispose();
  }

  void _watchNetwork() {
    try {
      _network = Connectivity().onConnectivityChanged.listen(
        (results) {
          if (results.every((r) => r == ConnectivityResult.none)) return;
          // A new interface can make a previously unreachable address answer,
          // so forget what was down and try the home address first again.
          _ref.read(conductorUrlProvider.notifier).clearDown();
          unawaited(_refresh());
        },
        onError: (Object error) =>
            debugPrint('[conductor] network events unavailable: $error'),
      );
    } on Object catch (error) {
      debugPrint('[conductor] network events unavailable: $error');
    }

    try {
      _lifecycle = AppLifecycleListener(
        onResume: () {
          _ref.read(conductorUrlProvider.notifier).clearDown();
          unawaited(_refresh());
        },
      );
    } on Object catch (error) {
      debugPrint('[conductor] lifecycle events unavailable: $error');
    }
  }

  /// Routes the cloud socket to whichever address of the continuity server is
  /// answering: a failed connection hands over to the other address, a
  /// successful one puts the home address back in front.
  void _trackOutcome(CloudState next) {
    final active = _ref.read(conductorUrlProvider).active;
    if (active.isEmpty) return;
    final status = next.status;
    if (status == ConductorStatus.listening ||
        status == ConductorStatus.rendering) {
      _ref.read(conductorUrlProvider.notifier).recordSuccess(active);
    } else if (status == ConductorStatus.error) {
      _failover(active);
    }
  }

  void _failover(String url) {
    final now = DateTime.now();
    final last = _lastFailureAt;
    if (last != null && now.difference(last) < _failoverGap) return;
    _lastFailureAt = now;
    debugPrint('[conductor] $url did not answer, trying the other address');
    _ref.read(conductorUrlProvider.notifier).recordFailure(url);
  }

  Future<void> _refresh() => _cloud.refresh(benchUrl: _benchUrl());

  String? _benchUrl() {
    final url = _ref.read(conductorUrlProvider).active.trim();
    return url.isEmpty ? null : url;
  }
}

/// Forwards playback intents to the device that owns the session.
///
/// Every method declines (`false`) unless another device is actually the
/// renderer, so `PlaybackNotifier` falls back to playing locally. Without that
/// gate a local play would be forwarded back into the local player.
class _RemotePlayback implements RemotePlayback {
  _RemotePlayback(this._cloud);

  final JellyboxCloud<LibraryItem> _cloud;

  bool get _elsewhere => _cloud.hasRemoteRenderer;

  @override
  Future<bool> play(PlayRequest request) async {
    if (!_elsewhere) return false;
    return _cloud.playOnRenderer(
      itemIds: request.itemIds,
      index: request.index,
      albumId: request.album.id,
      sourceId: request.sourceId,
    );
  }

  @override
  Future<bool> enqueue(List<LibraryItem> songs, {required bool playNext}) {
    if (!_elsewhere) return Future.value(false);
    return _cloud.enqueueOnRenderer(
      itemIds: [for (final song in songs) song.id],
      playNext: playNext,
    );
  }

  @override
  Future<bool> replaceUpcoming(
    List<LibraryItem> songs,
    LibraryItem album, {
    String? sourceId,
  }) {
    if (!_elsewhere) return Future.value(false);
    return _cloud.replaceUpcomingOnRenderer(
      itemIds: [for (final song in songs) song.id],
      albumId: album.id,
      sourceId: sourceId,
    );
  }

  @override
  Future<bool> move(int from, int to) async =>
      _elsewhere && await _cloud.moveOnRenderer(from, to);

  @override
  Future<bool> remove(int index) async =>
      _elsewhere && await _cloud.removeOnRenderer(index);
}

/// Whether this build ships continuity. It stays true while the server is
/// unreachable, otherwise the settings section that lets the user fix the
/// server address would disappear exactly when it is needed.
final cloudAvailableProvider = Provider<bool>(
  (ref) => ref.watch(cloudProvider.notifier).available,
);

final remoteSessionOursProvider = Provider<bool>((ref) {
  final queueRef = ref.watch(
    cloudProvider.select((state) => state.remote?.doc.backendRef),
  );
  final ours = ref.watch(currentServerIdProvider);
  return queueRef == null || ours == null || queueRef == ours;
});

final remoteRendererProvider = Provider<ConductorDevice?>((ref) {
  if (!ref.watch(remoteSessionOursProvider)) return null;
  final state = ref.watch(cloudProvider);
  final hasQueue = !(state.remote?.doc.isEmpty ?? true);
  return hasQueue ? state.remoteRenderer : null;
});

final remoteSessionProvider = Provider<RemoteSession?>(
  (ref) => ref.watch(remoteRendererProvider) == null
      ? null
      : ref.watch(cloudProvider.select((state) => state.remote)),
);

final playingElsewhereProvider = Provider<bool>(
  (ref) => ref.watch(remoteRendererProvider) != null,
);

final remoteQueueProvider = FutureProvider<List<LibraryItem>>((ref) async {
  final key = ref.watch(
    remoteSessionProvider.select((remote) => remote?.doc.itemIds.join(',')),
  );
  if (key == null || key.isEmpty) return const [];

  final ids = key.split(',');
  final items = await ref.read(mediaServerClientProvider).getItemsByIds(ids);
  final byId = {for (final item in items) item.id: item};
  return [
    for (final id in ids)
      byId[id] ??
          LibraryItem(id: id, name: 'Unavailable track', kind: ItemKind.song),
  ];
});

final remoteNowPlayingProvider = Provider<LibraryItem?>((ref) {
  final itemId = ref.watch(
    remoteSessionProvider.select((remote) => remote?.doc.currentItemId),
  );
  if (itemId == null) return null;
  final queue = ref.watch(remoteQueueProvider).valueOrNull ?? const [];
  for (final item in queue) {
    if (item.id == itemId) return item;
  }
  return null;
});

final AutoDisposeStreamProvider<int> _remoteTickProvider =
    StreamProvider.autoDispose<int>((ref) {
      final playing = ref.watch(
        remoteSessionProvider.select((remote) => remote?.doc.playing ?? false),
      );
      if (!playing) return Stream.value(0);
      return Stream.periodic(const Duration(milliseconds: 250), (tick) => tick);
    });

final AutoDisposeProvider<Duration> remotePositionProvider =
    Provider.autoDispose<Duration>((ref) {
      ref.watch(_remoteTickProvider);
      final remote = ref.watch(remoteSessionProvider);
      if (remote == null) return Duration.zero;
      return remote.positionAt(DateTime.now());
    });
