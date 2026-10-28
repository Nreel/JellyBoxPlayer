# Continuity Feature — Implementation Report

## Objective

Replace the closed-source, remote Jellybox Cloud continuity backend with a
self-hosted, Dockerized service that runs on a local IP. No HTTPS, no domains,
no external account required.

## What was built

### 1. Local continuity server (`continuity-server/`)

A small FastAPI application that relays playback state and handoff requests
between JellyBox clients over a single WebSocket.

| File | Purpose |
|---|---|
| `main.py` | WebSocket protocol, in-memory session state, active-renderer election, handoff relay, admin HTTP API |
| `store.py` | SQLite users, scrypt password hashes, signed credential tokens, admin sessions |
| `requirements.txt` | `fastapi==0.115.6`, `uvicorn[standard]==0.34.0` |
| `Dockerfile` | Python 3.12-slim, exposes port 8000 |
| `docker-compose.yml` | Single `continuity` service, port `8000:8000`, restart unless-stopped |
| `README.md` | Run instructions and protocol table |

**Key behavior**

- Sessions are scoped by `user_id:backend_ref`, so different users or Jellyfin
  servers never share state.
- Re-registering a device under another user or backend moves it out of the old
  session and broadcasts the removal there.
- A device becomes the active renderer when it reports `playing: true` and no
  active renderer exists yet.
- Only the active renderer's state is broadcast to peers.
- Handoff: source requests `handoff_request` → server sends `handoff` to target
  → target accepts/rejects → server updates active renderer and broadcasts the
  result. A device can also `claim` the live session without a second device
  asking first.
- State is in memory; restarting the container resets sessions (acceptable for
  local use).

### 2. Client implementation (`packages/optional_features`)

The open-repo stub was replaced with a working WebSocket client that speaks the
same protocol.

| File | Change |
|---|---|
| `lib/src/jellybox_cloud/cloud.dart` | Full `JellyboxCloud` implementation: connect, sign in, push state, receive commands, handoff |
| `lib/src/jellybox_cloud/models.dart` | Added `SessionDoc.sourceId` |
| `pubspec.yaml` | Added `web_socket_channel: ^3.0.3` |
| `test/jellybox_cloud/jellybox_cloud_test.dart` | Updated tests for the working client |
| `lib/src/config/constants.dart` | Default `jellyboxCloudUrl` now `http://localhost:8000` |

**Client behavior**

- Connects to `ws://<host>:8000/ws` derived from the configured conductor URL.
  The URL preference is honored in every build, not only debug builds, and the
  compiled-in `CONTINUITY_URL` only seeds the first launch.
- `signIn` sends credentials over the socket and stores the returned
  `ContinuityAccount`.
- Sends `state` whenever the active renderer's playback changes.
- Executes incoming commands (`play`, `pause`, `seek`, `skip_to`, `enqueue`,
  `replace_upcoming`, `move`, `remove`, etc.) against the `CloudHost`.
- On `handoff`, resolves item/album IDs, calls `CloudHost.play(...)` at the
  saved position, and accepts.
- On losing active-renderer status, calls `CloudHost.releaseOutput()`.
- Changing the server address in the connect form updates the preference and
  the cloud URL as one operation. The preference listener no longer races the
  sign-in by closing the socket mid-handshake, so the first attempt against a
  new address succeeds.
- `CloudState.copyWith` and `RemoteSession.positionAt` now support live position
  tracking.

## How to run

```bash
cd continuity-server
docker compose up --build -d
```

Server listens on `http://0.0.0.0:8000`; WebSocket endpoint is
`ws://<host>:8000/ws`.

### Point the app at it

- In any build, open the continuity settings and set **Continuity server** to
  `http://<host-ip>:8000` (use `http://localhost:8000` when the app runs on the
  same machine).
- The compiled-in `jellyboxCloudUrl` only seeds the first launch. To change the
  default for a build, pass
  `--dart-define=CONTINUITY_URL=http://<host-ip>:8000`.

### Build the app

```bash
cd packages/optional_features && dart pub get
cd ../.. && flutter pub get
```

## Verification

| Check | Result |
|---|---|
| `test_smoke.py` (sign-in, register A/B, election, commands, claim, handoff, disconnect, stale socket) | **Passed** (exit 0) |
| `test_protocol.py` against the Docker container (isolated sessions, session switch, reconnects, malformed docs) | **Passed** (exit 0) |
| `docker compose up --build -d` + `/health` | **Passed**; container reports `healthy` |
| `packages/optional_features` `dart test` | **Passed** (45 tests) |
| App provider sign-in regression test (`cloud_provider_test`) | **Passed** (1 test) |
| App continuity tests (`output_controller_test`, `playback_handoff_test`) | **Passed** (9 tests) |
| Continuity-related app suite (provider, playback, volume, picker) | **Passed** (71 tests) |
| `flutter analyze` | No diagnostics in the continuity files; repository has unrelated pre-existing warnings |
| Full `flutter test` | 1630 passed; 22 failures, all pre-existing/environmental: 21 download tests fail on Windows temp-file locks (`PathAccessException`, even with `--concurrency=1`) and one Discord IPC live test needs a running Discord client. No continuity test failed. |

The smoke test exercises the real server process over a real WebSocket
connection. The protocol test runs against the real Docker image and verifies
active-renderer election, handoff accept/reject, claim, session isolation by
user/backend, session switching, reconnect replacement, and health cleanup.

## Limitations and notes

- Playback session state is in memory and is lost when the container restarts.
  Accounts and credentials are persisted in SQLite (`CONTINUITY_DB`).
- The protocol assumes one active renderer per `(user_id, backend_ref)` session.
- Accounts and credentials live in SQLite and are managed from `/admin`.
  Sign-in validates a login and scrypt-hashed password; `register` requires a
  valid credential token. Devices sign in with a login, not an email. The
  server still speaks plain HTTP, so keep it on a trusted LAN or put it behind
  TLS.
- The default URL is `http://localhost:8000`. For access from another device on
  the LAN, set the URL in the app (every build) or compile in
  `--dart-define=CONTINUITY_URL=http://<host-ip>:8000`.
- The full app suite still has environmental failures outside continuity: the
  download tests cannot delete temp directories held open on Windows, and the
  Discord IPC live test needs Discord running.

## Files added or changed

```
continuity-server/main.py
continuity-server/store.py
continuity-server/requirements.txt
continuity-server/Dockerfile
continuity-server/docker-compose.yml
continuity-server/README.md
continuity-server/.gitignore
continuity-server/.dockerignore
continuity-server/test_smoke.py
continuity-server/test_protocol.py
packages/optional_features/pubspec.yaml
packages/optional_features/lib/src/jellybox_cloud/cloud.dart
packages/optional_features/lib/src/jellybox_cloud/models.dart
packages/optional_features/test/jellybox_cloud/jellybox_cloud_test.dart
lib/src/config/constants.dart
lib/src/data/cloud/cloud_host_adapter.dart
lib/src/domain/playback/output_controller.dart
lib/src/domain/providers/cloud_provider.dart
lib/src/presentation/widgets/jellybox_cloud_connect_form.dart
test/domain/playback/output_controller_test.dart
test/domain/providers/cloud_provider_test.dart
```

No commits or pushes were made.
