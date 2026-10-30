# Local Continuity Server

Replaces the closed-source Jellybox Cloud continuity backend with a small
WebSocket relay that runs on your LAN. No HTTPS, no domain, no external account.

It also ships a small admin web UI for the accounts and credentials that
JellyBox devices sign in with. Accounts live in SQLite, so users, passwords and
revoked tokens survive a restart.

## Run

```bash
cd continuity-server
docker compose up --build -d
```

The server listens on `http://0.0.0.0:8000`; the WebSocket endpoint is
`ws://<host>:8000/ws` and the admin UI is at `http://<host>:8000/admin`.

Open the admin UI on first run and create the first administrator. The account
database is stored in the `continuity-data` Docker volume; deleting the volume
resets the server.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CONTINUITY_DB` | `continuity.db` next to `main.py` | SQLite file for users and credentials |
| `CONTINUITY_SESSION_TTL` | `43200` | Admin web session lifetime in seconds |
| `CONTINUITY_COOKIE_SECURE` | off | Set to `1` when serving the UI over HTTPS |
| `CONTINUITY_STATE_INTERVAL_MS` | `250` | Shortest spacing between state broadcasts to peers |

State fan-out is the server's main CPU cost: each published queue is serialised
once and sent to every peer in the session. Publishes that arrive closer than
`CONTINUITY_STATE_INTERVAL_MS` are folded into one trailing broadcast, so a
device ticking every playback change cannot fan a large queue out several times
a second; peers lag the renderer by at most that interval. The app publishes at
most one state per 250 ms, sends queue changes immediately, and reconnects with
exponential backoff (5 s up to 30 s). `docker-compose.yml` caps the container at
1.5 CPUs so a busy relay cannot starve the host.

## Users and credentials

Open `http://<host>:8000/admin` and sign in as an administrator.

- **Users** are JellyBox identities identified by a **login** (not an email) and
  a password. Passwords are hashed with scrypt and are never stored or shown.
- **Credentials** are bearer tokens for devices. The server mints one reusable
  `App sign-in` credential per user when the app signs in with a password, and
  the admin UI can mint additional labelled tokens. Tokens are shown once when
  created; revoking or deleting one disconnects the devices using it.
- Disabling or deleting a user drops its live relay sessions immediately.
- The last active administrator cannot be deleted, demoted or disabled.

## Point the app at it

The app reads the continuity URL from the `conductor_url` preference in every
build. Set it to `http://<host-ip>:8000` (or `http://localhost:8000` when the
app runs on the same machine) from the Continuity server settings, then sign in
with a login and password created in the admin UI.

The same settings section also accepts a second address for the server in the
`conductor_remote_url` preference (Tailscale, WireGuard or reverse proxy). The
app keeps using the home address while it answers and switches to the remote
one when it does not, so a device away from the LAN still connects.

The first launch seeds that preference from `jellyboxCloudUrl` in
`lib/src/config/constants.dart`, which reads `CONTINUITY_URL` at compile time:

```bash
flutter build apk --dart-define=CONTINUITY_URL=http://192.168.1.10:8000
```

If the define is omitted it defaults to `http://localhost:8000`.

## Protocol

All messages are JSON over the single WebSocket at `/ws`. Devices authenticate
with a login and password, then send the returned token when registering and
reconnecting.

| Direction | Type | Purpose |
|---|---|---|
| C→S | `signin` | Exchange `login`/`password` for a credential token |
| S→C | `signed_in` | Return account (`login`, `userId`, `token`) |
| C→S | `register` | Announce device id, name, platform, backend and `token` |
| S→C | `registered` | Confirm registration |
| C→S | `unregister` | Leave the current session without closing the socket |
| C→S | `state` | Push current `SessionDoc` |
| S→C | `state` | Broadcast `SessionDoc`, device list and active renderer |
| C→S | `claim` | Ask to take over the live session on this device |
| C→S | `command` | Send a player command to the active renderer |
| S→C | `command` | Deliver a player command |
| C→S | `handoff_request` | Ask to take over playback on another device |
| S→C | `handoff` | Ask the target device to accept playback |
| S→C | `handoff_pending` | Tell the requester the target was asked |
| C→S | `handoff_accept` / `handoff_reject` | Answer a handoff request |
| S→C | `handoff_accepted` / `handoff_rejected` | Broadcast the result |
| S→C | `signed_out` | The token is missing, revoked or belongs to a disabled user |
| S→C | `error` | Report a rejected or invalid message |

`register` requires a valid token; the server derives the user id from it
instead of trusting the client. Sessions are scoped by `user_id` and
`backend_ref`, so different users or Jellyfin servers do not see each other's
playback. Session state is still in memory and is lost when the server
restarts.

## Admin API

The web UI uses these JSON endpoints; they require the admin session cookie.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/state` | Setup and sign-in status |
| `POST` | `/api/setup` | Create the first administrator |
| `POST` | `/api/login` / `/api/logout` | Admin session |
| `GET` / `POST` | `/api/users` | List or create users |
| `PATCH` / `DELETE` | `/api/users/{id}` | Update or delete a user |
| `GET` / `POST` | `/api/credentials` | List or mint credentials |
| `POST` | `/api/credentials/{id}/revoke` | Revoke a token |
| `DELETE` | `/api/credentials/{id}` | Delete a token |
| `GET` | `/api/sessions` | Live relay sessions and devices |

## Tests

```bash
python test_smoke.py       # in-process server, WebSocket protocol only
python test_protocol.py    # real HTTP + WebSocket against a running server
```

`test_protocol.py` creates its own administrator and test users. Against an
already configured server, set `CONTINUITY_ADMIN_LOGIN` and
`CONTINUITY_ADMIN_PASSWORD` (defaults: `admin` / `continuity-admin`).

## Security notes

This server is intended for a trusted LAN. It speaks plain HTTP, so the admin
cookie and passwords are not protected against a network eavesdropper; put it
behind TLS if it is reachable by anyone else. Passwords are hashed with scrypt,
tokens are HMAC-signed and stored as references rather than secrets, and the
admin API only accepts JSON requests with the session cookie.
