"""Local JellyBox continuity server.

WebSocket relay that mirrors playback state and handoff requests between
JellyBox clients on the same LAN, plus a small admin web UI that manages the
accounts and credentials those clients sign in with.

Protocol (JSON over WebSocket at /ws):

Client -> Server
  {"type": "signin", "login": str, "password": str}
  {"type": "register", "device_id": str, "name": str, "platform": str,
   "backend_ref": str|null, "token": str}
  {"type": "unregister"}
  {"type": "state", "doc": SessionDoc}
  {"type": "command", "command": str, "value": any}
  {"type": "claim"}
  {"type": "handoff_request", "target_device_id": str}
  {"type": "handoff_accept"}
  {"type": "handoff_reject"}

Server -> Client
  {"type": "signed_in", "account": ContinuityAccount}
  {"type": "registered", "device_id": str, "session_key": str}
  {"type": "state", "doc": SessionDoc, "devices": [Device], "active_renderer": str|null}
  {"type": "command", "command": str, "value": any}
  {"type": "handoff", "from": str, "doc": SessionDoc}
  {"type": "handoff_pending", "target_device_id": str}
  {"type": "handoff_accepted", "target_device_id": str, "doc": SessionDoc,
   "devices": [Device], "active_renderer": str|null}
  {"type": "handoff_rejected", "target_device_id": str}
  {"type": "error", "message": str}

Admin HTTP API (session cookie, JSON bodies):
  GET    /admin                       web UI
  GET    /api/state                   setup/authentication status
  POST   /api/setup                   create the first administrator
  POST   /api/login                   {"login", "password"}
  POST   /api/logout
  GET    /api/users
  POST   /api/users                   {"login", "password", "name", "isAdmin"}
  PATCH  /api/users/{id}              {"login"?, "name"?, "password"?, "isAdmin"?, "disabled"?}
  DELETE /api/users/{id}
  GET    /api/credentials[?userId=]
  POST   /api/credentials             {"userId", "label"}
  POST   /api/credentials/{id}/revoke
  DELETE /api/credentials/{id}
  GET    /api/sessions                live sessions and connected devices
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from fastapi import Depends, FastAPI, HTTPException, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, Field

from store import (
    SESSION_COOKIE,
    NotFound,
    SessionTokens,
    Store,
    StoreError,
    ValidationError,
)

DB_PATH = os.environ.get("CONTINUITY_DB", str(Path(__file__).with_name("continuity.db")))
SESSION_TTL_SECONDS = int(os.environ.get("CONTINUITY_SESSION_TTL", 12 * 60 * 60))
COOKIE_SECURE = os.environ.get("CONTINUITY_COOKIE_SECURE", "").lower() in {"1", "true", "yes"}

# State fan-out is the server's dominant CPU cost: every published doc is
# re-encoded and sent to each peer. A playback tick only moves trackPositionMs,
# so broadcasts are coalesced to one per interval and the newest doc always
# wins. Peers never lag behind the renderer by more than this interval.
STATE_BROADCAST_INTERVAL_MS = int(
    os.environ.get("CONTINUITY_STATE_INTERVAL_MS", 250)
)

app = FastAPI(title="Local JellyBox Continuity Server")
store = Store(DB_PATH)
tokens = SessionTokens(store.secret, SESSION_TTL_SECONDS)


class SessionDoc(BaseModel):
    backendRef: Optional[str] = None
    albumId: Optional[str] = None
    itemIds: List[str] = Field(default_factory=list)
    queuePosition: int = 0
    trackPositionMs: int = 0
    playing: bool = False
    shuffle: bool = False
    repeat: str = "off"
    volume: float = 1.0
    sourceId: Optional[str] = None

    @property
    def is_empty(self) -> bool:
        return not self.itemIds

    @classmethod
    def from_wire(cls, raw: Any) -> "SessionDoc":
        """Build a doc from a wire payload without validating every field.

        A queue can hold tens of thousands of item ids, and a device publishes
        on every playback tick; validating the whole model per tick costs more
        than relaying it. Malformed payloads still raise, so the handler can
        answer with an error instead of broadcasting garbage.
        """
        if not isinstance(raw, dict):
            raise ValueError("doc must be an object")
        item_ids = raw.get("itemIds") or []
        if not isinstance(item_ids, list):
            raise ValueError("doc.itemIds must be a list")
        volume = raw.get("volume")
        # item_ids is reused as-is: json already produced the list, and copying
        # tens of thousands of ids per tick is pure waste.
        return cls.model_construct(
            backendRef=raw.get("backendRef"),
            albumId=raw.get("albumId"),
            itemIds=item_ids,
            queuePosition=int(raw.get("queuePosition") or 0),
            trackPositionMs=int(raw.get("trackPositionMs") or 0),
            playing=bool(raw.get("playing")),
            shuffle=bool(raw.get("shuffle")),
            repeat=str(raw.get("repeat") or "off"),
            volume=1.0 if volume is None else float(volume),
            sourceId=raw.get("sourceId"),
        )


class DeviceInfo(BaseModel):
    id: str
    name: str
    platform: str
    backend: Optional[str] = None
    user_id: str
    isRenderer: bool = False
    isOnline: bool = True


class SessionState:
    def __init__(self) -> None:
        self.doc = SessionDoc()
        self.devices: Dict[str, DeviceInfo] = {}
        self.active_renderer: Optional[str] = None
        self.connections: Dict[str, WebSocket] = {}
        self.pending_handoff: Optional[Dict[str, str]] = None
        # Coalescing bookkeeping for state broadcasts (see publish_state).
        self.last_state_ms = 0.0
        self.flush_task: Optional[asyncio.Task] = None

    def device_list(self) -> List[Dict[str, Any]]:
        result = []
        for dev in self.devices.values():
            data = dev.model_dump()
            data["isRenderer"] = dev.id == self.active_renderer
            result.append(data)
        return result

    def snapshot(self) -> Dict[str, Any]:
        return {
            "doc": self.doc.model_dump(),
            "devices": self.device_list(),
            "active_renderer": self.active_renderer,
        }

    def remove_device(self, device_id: str) -> None:
        self.connections.pop(device_id, None)
        self.devices.pop(device_id, None)
        if self.active_renderer == device_id:
            self.active_renderer = None
        if self.pending_handoff and device_id in self.pending_handoff.values():
            self.pending_handoff = None


sessions: Dict[str, SessionState] = {}

# websocket -> credential id. Used to close sockets promptly when an
# administrator revokes the credential they signed in with. Keyed by the socket
# itself: id(websocket) can be reused after a socket is garbage-collected, and
# a recycled id would close an unrelated connection.
active_credentials: Dict[WebSocket, str] = {}


async def send(ws: WebSocket, message: Dict[str, Any]) -> bool:
    try:
        await ws.send_text(json.dumps(message))
        return True
    except Exception:
        return False


async def broadcast(
    session_key: str,
    message: Dict[str, Any],
    exclude: Optional[str] = None,
) -> None:
    """Send one message to every peer in a session.

    The payload is encoded once and reused, so a large queue costs one
    serialisation no matter how many devices are listening.
    """
    state = sessions.get(session_key)
    if not state:
        return
    targets = [
        (device_id, ws)
        for device_id, ws in list(state.connections.items())
        if device_id != exclude
    ]
    if not targets:
        return
    payload = json.dumps(message)
    for device_id, ws in targets:
        try:
            await ws.send_text(payload)
        except Exception:
            state.remove_device(device_id)


async def broadcast_state(session_key: str, exclude: Optional[str] = None) -> None:
    """Broadcast the session snapshot immediately (device list / handoff)."""
    state = sessions.get(session_key)
    if not state:
        return
    state.last_state_ms = time.monotonic()
    await broadcast(session_key, {"type": "state", **state.snapshot()}, exclude)


async def publish_state(session_key: str, exclude: Optional[str] = None) -> None:
    """Broadcast the session snapshot, coalescing rapid publishes.

    Publishes closer together than STATE_BROADCAST_INTERVAL_MS are folded into
    one trailing broadcast, so a device ticking every playback change cannot
    fan a full queue out to every peer several times per second.
    """
    state = sessions.get(session_key)
    if not state:
        return
    now = time.monotonic()
    elapsed_ms = (now - state.last_state_ms) * 1000
    if elapsed_ms >= STATE_BROADCAST_INTERVAL_MS:
        state.last_state_ms = now
        await broadcast_state(session_key, exclude)
        return
    if state.flush_task is None:
        state.flush_task = asyncio.create_task(
            _flush_state(
                session_key,
                (STATE_BROADCAST_INTERVAL_MS - elapsed_ms) / 1000,
                exclude,
            )
        )


async def _flush_state(
    session_key: str, delay: float, exclude: Optional[str]
) -> None:
    await asyncio.sleep(delay)
    state = sessions.get(session_key)
    if state is None:
        return
    state.flush_task = None
    await broadcast_state(session_key, exclude)


def _forget_session(session_key: str, state: SessionState) -> None:
    """Drop a session and cancel any broadcast it still has queued."""
    if state.flush_task is not None:
        state.flush_task.cancel()
        state.flush_task = None
    sessions.pop(session_key, None)


@app.get("/health")
async def health() -> Dict[str, Any]:
    return {
        "status": "ok",
        "users": store.count_users(),
        "sessions": len(sessions),
        "devices": sum(len(s.devices) for s in sessions.values()),
    }


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await websocket.accept()
    device_id: Optional[str] = None
    session_key: Optional[str] = None
    host = websocket.headers.get("host", "localhost:8000")
    server_url = f"http://{host}"

    try:
        while True:
            data = await websocket.receive_json()
            msg_type = data.get("type")

            if msg_type == "signin":
                login = str(data.get("login") or "").strip()
                password = str(data.get("password") or "")
                # scrypt costs tens of milliseconds; run it in a worker thread
                # so a sign-in cannot stall the relay.
                user = await asyncio.to_thread(
                    store.authenticate_password, login, password
                )
                if user is None or user["disabled"]:
                    await send(
                        websocket,
                        {"type": "error", "message": "Invalid login or password."},
                    )
                    continue
                _, token = await asyncio.to_thread(store.ensure_app_credential, user["id"])
                await send(
                    websocket,
                    {
                        "type": "signed_in",
                        "account": {
                            "serverUrl": server_url,
                            "login": user["login"],
                            "userId": user["id"],
                            "token": token,
                            "serverName": "Local Continuity",
                            "libraryName": "Default",
                            "socketPath": "/ws",
                        },
                    },
                )

            elif msg_type == "register":
                new_device_id = str(data.get("device_id") or "")
                if not new_device_id:
                    await send(
                        websocket,
                        {"type": "error", "message": "register needs a device_id"},
                    )
                    continue
                token = str(data.get("token") or "")
                user = store.user_for_token(token)
                if user is None:
                    await send(
                        websocket,
                        {
                            "type": "signed_out",
                            "message": "Sign in before registering a device.",
                        },
                    )
                    continue
                credential_id = store.credential_id_for_token(token)
                if credential_id is not None:
                    active_credentials[websocket] = credential_id
                user_id = user["id"]
                backend_ref = data.get("backend_ref")
                new_session_key = (
                    f"{user_id}:{backend_ref}" if backend_ref else user_id
                )
                if device_id is not None and (
                    device_id != new_device_id or session_key != new_session_key
                ):
                    # Same socket re-registering under another identity or
                    # session. Leaving it in the old one would keep a device
                    # listed and receiving broadcasts after the app switched
                    # user or Jellyfin server.
                    old = sessions.get(session_key or "")
                    if old:
                        old.remove_device(device_id)
                        if old.devices:
                            await broadcast_state(session_key or "")
                        else:
                            _forget_session(session_key or "", old)
                device_id = new_device_id
                session_key = new_session_key

                state = sessions.setdefault(session_key, SessionState())
                stale = state.connections.get(device_id)
                was_active = state.active_renderer == device_id
                if stale is not None and stale is not websocket:
                    # Device reconnected from a new socket; drop the stale one so
                    # it can neither publish state nor stay listed as a peer.
                    state.remove_device(device_id)
                state.devices[device_id] = DeviceInfo(
                    id=device_id,
                    name=str(data.get("name") or device_id),
                    platform=str(data.get("platform") or "unknown"),
                    backend=backend_ref,
                    user_id=user_id,
                )
                state.connections[device_id] = websocket
                if was_active:
                    # The same device came back on a new socket; it keeps the
                    # renderer seat instead of leaving the session headless.
                    state.active_renderer = device_id
                if stale is not None and stale is not websocket:
                    try:
                        await stale.close(code=1000, reason="replaced")
                    except Exception:
                        pass

                await send(
                    websocket,
                    {
                        "type": "registered",
                        "device_id": device_id,
                        "session_key": session_key,
                    },
                )
                # One snapshot for every socket in the session: the registering
                # device needs its peers, and the peers need this device.
                await broadcast_state(session_key)

            elif msg_type == "unregister":
                if session_key and session_key in sessions:
                    state = sessions[session_key]
                    state.remove_device(device_id or "")
                    if state.devices:
                        await broadcast_state(session_key)
                    else:
                        _forget_session(session_key, state)
                device_id = None
                session_key = None

            elif msg_type == "state":
                if not session_key or session_key not in sessions or not device_id:
                    continue
                state = sessions[session_key]
                try:
                    doc = SessionDoc.from_wire(data.get("doc", {}))
                except Exception as exc:
                    await send(websocket, {"type": "error", "message": str(exc)})
                    continue
                if state.active_renderer is None:
                    state.doc = doc
                    if doc.playing:
                        state.active_renderer = device_id
                    # Election lands immediately; later publishes are coalesced.
                    await broadcast_state(session_key)
                elif state.active_renderer == device_id:
                    state.doc = doc
                    # Playback ticks only move trackPositionMs; fan them out at
                    # most once per interval, so peers lag at most that long.
                    await publish_state(session_key, exclude=device_id)

            elif msg_type == "claim":
                if not session_key or session_key not in sessions or not device_id:
                    continue
                state = sessions[session_key]
                if state.doc.is_empty:
                    # Nothing to carry over; the claimer's own queue becomes
                    # the session when it publishes its state.
                    state.active_renderer = device_id
                    state.pending_handoff = None
                    await broadcast_state(session_key)
                    continue
                # There is a live session: hand it to the claimer so its queue
                # and position are not lost, exactly like a normal handoff.
                state.pending_handoff = {
                    "from": state.active_renderer or device_id,
                    "to": device_id,
                }
                await send(
                    websocket,
                    {
                        "type": "handoff",
                        "from": state.active_renderer or device_id,
                        "doc": state.doc.model_dump(),
                    },
                )

            elif msg_type == "command":
                if not session_key or session_key not in sessions or not device_id:
                    continue
                state = sessions[session_key]
                target = state.active_renderer
                if not target:
                    await send(
                        websocket,
                        {"type": "error", "message": "Nothing is playing right now."},
                    )
                    continue
                if target == device_id:
                    continue
                ws = state.connections.get(target)
                if ws is None:
                    await send(
                        websocket,
                        {"type": "error", "message": "That device is offline."},
                    )
                    continue
                await send(
                    ws,
                    {
                        "type": "command",
                        "command": data.get("command"),
                        "value": data.get("value"),
                    },
                )

            elif msg_type == "handoff_request":
                if not session_key or session_key not in sessions or not device_id:
                    continue
                state = sessions[session_key]
                target = data.get("target_device_id")
                ws = state.connections.get(target) if target else None
                if not target or target == device_id or ws is None:
                    await send(
                        websocket,
                        {
                            "type": "handoff_rejected",
                            "target_device_id": target,
                            "message": "That device is not connected.",
                        },
                    )
                    continue
                state.pending_handoff = {"from": device_id, "to": target}
                await send(
                    ws,
                    {
                        "type": "handoff",
                        "from": device_id,
                        "doc": state.doc.model_dump(),
                    },
                )
                await send(
                    websocket,
                    {"type": "handoff_pending", "target_device_id": target},
                )

            elif msg_type == "handoff_accept":
                if not session_key or session_key not in sessions or not device_id:
                    continue
                state = sessions[session_key]
                pending = state.pending_handoff
                if pending and pending.get("to") == device_id:
                    state.active_renderer = device_id
                    state.pending_handoff = None
                    await broadcast(
                        session_key,
                        {
                            "type": "handoff_accepted",
                            "target_device_id": device_id,
                            **state.snapshot(),
                        },
                    )
                else:
                    await send(
                        websocket,
                        {"type": "error", "message": "No handoff is waiting for this device."},
                    )

            elif msg_type == "handoff_reject":
                if not session_key or session_key not in sessions or not device_id:
                    continue
                state = sessions[session_key]
                pending = state.pending_handoff
                if pending and pending.get("to") == device_id:
                    state.pending_handoff = None
                    await broadcast(
                        session_key,
                        {
                            "type": "handoff_rejected",
                            "target_device_id": device_id,
                        },
                    )

    except WebSocketDisconnect:
        pass
    except Exception as exc:
        await send(websocket, {"type": "error", "message": str(exc)})
    finally:
        active_credentials.pop(websocket, None)
        if session_key and session_key in sessions:
            state = sessions[session_key]
            # A newer socket may already have replaced this one.
            if state.connections.get(device_id or "") is websocket:
                state.remove_device(device_id or "")
                if state.devices:
                    await broadcast_state(session_key)
                else:
                    _forget_session(session_key, state)


# ---------------------------------------------------------------------------
# Admin API
# ---------------------------------------------------------------------------


class SetupRequest(BaseModel):
    login: str
    password: str
    name: str = ""


class LoginRequest(BaseModel):
    login: str
    password: str


class UserCreateRequest(BaseModel):
    login: str
    password: str
    name: str = ""
    isAdmin: bool = False


class UserUpdateRequest(BaseModel):
    login: Optional[str] = None
    name: Optional[str] = None
    password: Optional[str] = None
    isAdmin: Optional[bool] = None
    disabled: Optional[bool] = None


class CredentialCreateRequest(BaseModel):
    userId: str
    label: str = ""


_login_attempts: Dict[str, Tuple[int, float]] = {}
LOGIN_ATTEMPT_LIMIT = 10
LOGIN_ATTEMPT_WINDOW = 300.0


def _client_key(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _throttled(request: Request) -> bool:
    key = _client_key(request)
    count, reset_at = _login_attempts.get(key, (0, 0.0))
    now = time.monotonic()
    if reset_at <= now:
        return False
    return count >= LOGIN_ATTEMPT_LIMIT


def _record_attempt(request: Request, success: bool) -> None:
    key = _client_key(request)
    now = time.monotonic()
    if success:
        _login_attempts.pop(key, None)
        return
    count, reset_at = _login_attempts.get(key, (0, 0.0))
    if reset_at <= now:
        count, reset_at = 0, now + LOGIN_ATTEMPT_WINDOW
    _login_attempts[key] = (count + 1, reset_at)


def _set_cookie(response: Response, user_id: str) -> None:
    response.set_cookie(
        SESSION_COOKIE,
        tokens.issue(user_id),
        max_age=SESSION_TTL_SECONDS,
        httponly=True,
        samesite="strict",
        secure=COOKIE_SECURE,
        path="/",
    )


def _admin_user(request: Request) -> Dict[str, Any]:
    user_id = tokens.verify(request.cookies.get(SESSION_COOKIE))
    if user_id is None:
        raise HTTPException(status_code=401, detail="Sign in to continue.")
    user = store.get_user(user_id)
    if user is None or user["disabled"] or not user["is_admin"]:
        raise HTTPException(status_code=401, detail="Sign in to continue.")
    return user


def _error(exc: StoreError) -> HTTPException:
    status = 404 if isinstance(exc, NotFound) else 409
    if isinstance(exc, ValidationError):
        status = 400
    return HTTPException(status_code=status, detail=str(exc))


@app.get("/", include_in_schema=False)
async def index() -> RedirectResponse:
    return RedirectResponse(url="/admin")


@app.get("/admin", response_class=HTMLResponse, include_in_schema=False)
async def admin_page() -> HTMLResponse:
    return HTMLResponse(ADMIN_HTML)


@app.get("/api/state")
async def api_state(request: Request) -> Dict[str, Any]:
    needs_setup = not store.has_admin()
    user_id = tokens.verify(request.cookies.get(SESSION_COOKIE))
    user = store.get_user(user_id) if user_id else None
    authenticated = bool(user and user["is_admin"] and not user["disabled"])
    return {
        "needsSetup": needs_setup,
        "authenticated": authenticated,
        "user": user if authenticated else None,
    }


@app.post("/api/setup")
async def api_setup(request: Request, body: SetupRequest, response: Response) -> Dict[str, Any]:
    if store.has_admin():
        raise HTTPException(status_code=409, detail="Setup has already been completed.")
    try:
        user = await asyncio.to_thread(
            store.create_first_admin, body.login, body.password, body.name
        )
    except StoreError as exc:
        raise _error(exc) from exc
    _set_cookie(response, user["id"])
    return {"user": user}


@app.post("/api/login")
async def api_login(request: Request, body: LoginRequest, response: Response) -> Dict[str, Any]:
    if _throttled(request):
        raise HTTPException(
            status_code=429, detail="Too many attempts. Try again in a few minutes."
        )
    user = await asyncio.to_thread(store.authenticate_password, body.login, body.password)
    if user is None or user["disabled"]:
        _record_attempt(request, False)
        raise HTTPException(status_code=401, detail="Invalid login or password.")
    if not user["is_admin"]:
        _record_attempt(request, False)
        raise HTTPException(status_code=403, detail="This account is not an administrator.")
    _record_attempt(request, True)
    _set_cookie(response, user["id"])
    return {"user": user}


@app.post("/api/logout")
async def api_logout(response: Response) -> Dict[str, bool]:
    response.delete_cookie(SESSION_COOKIE, path="/")
    return {"ok": True}


@app.get("/api/users")
async def api_users(_: Dict[str, Any] = Depends(_admin_user)) -> Dict[str, Any]:
    return {"users": store.list_users()}


@app.post("/api/users")
async def api_create_user(
    body: UserCreateRequest, _: Dict[str, Any] = Depends(_admin_user)
) -> Dict[str, Any]:
    try:
        user = await asyncio.to_thread(
            store.create_user, body.login, body.password, body.name, body.isAdmin
        )
    except StoreError as exc:
        raise _error(exc) from exc
    return {"user": user}


@app.patch("/api/users/{user_id}")
async def api_update_user(
    user_id: str,
    body: UserUpdateRequest,
    admin: Dict[str, Any] = Depends(_admin_user),
) -> Dict[str, Any]:
    try:
        user = await asyncio.to_thread(
            store.update_user,
            user_id,
            login=body.login,
            name=body.name,
            password=body.password,
            is_admin=body.isAdmin,
            disabled=body.disabled,
        )
    except StoreError as exc:
        raise _error(exc) from exc
    if body.password is not None or body.disabled is True:
        _drop_user_sessions(user_id)
    return {"user": user, "self": admin["id"] == user_id}


@app.delete("/api/users/{user_id}")
async def api_delete_user(
    user_id: str, admin: Dict[str, Any] = Depends(_admin_user)
) -> Dict[str, Any]:
    if admin["id"] == user_id:
        raise HTTPException(status_code=409, detail="You cannot delete your own account.")
    try:
        store.delete_user(user_id)
    except StoreError as exc:
        raise _error(exc) from exc
    _drop_user_sessions(user_id)
    return {"ok": True}


@app.get("/api/credentials")
async def api_credentials(
    user_id: Optional[str] = None, _: Dict[str, Any] = Depends(_admin_user)
) -> Dict[str, Any]:
    return {"credentials": store.list_credentials(user_id)}


@app.post("/api/credentials")
async def api_create_credential(
    body: CredentialCreateRequest, _: Dict[str, Any] = Depends(_admin_user)
) -> Dict[str, Any]:
    try:
        credential, token = store.create_credential(body.userId, body.label)
    except StoreError as exc:
        raise _error(exc) from exc
    # The token is only ever returned here; the database stores a signature.
    return {"credential": credential, "token": token}


@app.post("/api/credentials/{credential_id}/revoke")
async def api_revoke_credential(
    credential_id: str, _: Dict[str, Any] = Depends(_admin_user)
) -> Dict[str, Any]:
    try:
        credential = store.revoke_credential(credential_id)
    except StoreError as exc:
        raise _error(exc) from exc
    _drop_credential_sessions(credential_id)
    return {"credential": credential}


@app.delete("/api/credentials/{credential_id}")
async def api_delete_credential(
    credential_id: str, _: Dict[str, Any] = Depends(_admin_user)
) -> Dict[str, Any]:
    try:
        store.delete_credential(credential_id)
    except StoreError as exc:
        raise _error(exc) from exc
    _drop_credential_sessions(credential_id)
    return {"ok": True}


@app.get("/api/sessions")
async def api_sessions(_: Dict[str, Any] = Depends(_admin_user)) -> Dict[str, Any]:
    logins = {user["id"]: user["login"] for user in store.list_users()}
    result = []
    for key, state in sessions.items():
        user_id, _, backend = key.partition(":")
        result.append(
            {
                "key": key,
                "userId": user_id,
                "login": logins.get(user_id, user_id),
                "backend": backend or None,
                "activeRenderer": state.active_renderer,
                "devices": state.device_list(),
                "doc": state.doc.model_dump(),
            }
        )
    return {"sessions": result}


def _drop_user_sessions(user_id: str) -> None:
    for key in [k for k in sessions if k == user_id or k.startswith(f"{user_id}:")]:
        state = sessions.get(key)
        if state is None:
            continue
        _forget_session(key, state)
        for ws in list(state.connections.values()):
            _close_soon(ws, "account removed")


def _drop_credential_sessions(credential_id: str) -> None:
    """Close sockets that registered with a revoked or deleted credential."""
    for ws, owner in list(active_credentials.items()):
        if owner == credential_id:
            active_credentials.pop(ws, None)
            _close_soon(ws, "credential revoked")


def _close_soon(ws: WebSocket, reason: str) -> None:
    async def close() -> None:
        try:
            await ws.close(code=1008, reason=reason)
        except Exception:
            pass

    try:
        asyncio.get_running_loop().create_task(close())
    except RuntimeError:
        pass


ADMIN_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>JellyBox Continuity</title>
<style>
  :root { color-scheme: dark light; --bg:#101114; --panel:#17181d; --line:#2a2c34;
          --fg:#e8e8ea; --muted:#9a9da8; --accent:#7c8cff; --danger:#ff6b6b; --ok:#5ad19a; }
  @media (prefers-color-scheme: light) {
    :root { --bg:#f6f6f8; --panel:#fff; --line:#e2e3e8; --fg:#1a1b1f; --muted:#666a75;
            --accent:#4c5bd4; --danger:#c33; --ok:#178a52; }
  }
  * { box-sizing: border-box; }
  body { margin:0; font:15px/1.45 system-ui, sans-serif; background:var(--bg); color:var(--fg); }
  header { display:flex; align-items:center; gap:12px; padding:16px 24px; border-bottom:1px solid var(--line); }
  header h1 { font-size:17px; margin:0; font-weight:600; }
  header .who { margin-left:auto; color:var(--muted); font-size:13px; }
  main { max-width:1080px; margin:0 auto; padding:24px; display:grid; gap:20px; }
  section { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:18px; }
  section h2 { margin:0 0 4px; font-size:14px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
  .hint { color:var(--muted); font-size:13px; margin:0 0 14px; }
  table { width:100%; border-collapse:collapse; font-size:14px; }
  th, td { text-align:left; padding:8px 6px; border-bottom:1px solid var(--line); vertical-align:middle; }
  th { color:var(--muted); font-weight:500; font-size:12px; text-transform:uppercase; letter-spacing:.05em; }
  code, .mono { font-family:ui-monospace, monospace; font-size:12.5px; }
  input[type=text], input[type=password], input[type=search] {
    width:100%; padding:8px 10px; border-radius:7px; border:1px solid var(--line);
    background:var(--bg); color:var(--fg); font:inherit; }
  label { display:block; font-size:12px; color:var(--muted); margin:0 0 4px; }
  .row { display:flex; gap:10px; flex-wrap:wrap; align-items:flex-end; }
  .row > div { flex:1 1 160px; }
  button { font:inherit; padding:8px 14px; border-radius:7px; border:1px solid var(--line);
           background:var(--bg); color:var(--fg); cursor:pointer; }
  button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
  button.danger { color:var(--danger); border-color:var(--danger); }
  button:disabled { opacity:.5; cursor:default; }
  .tag { display:inline-block; padding:1px 7px; border-radius:99px; font-size:11.5px;
         border:1px solid var(--line); color:var(--muted); }
  .tag.ok { color:var(--ok); border-color:var(--ok); }
  .tag.bad { color:var(--danger); border-color:var(--danger); }
  .token { display:flex; gap:8px; align-items:center; margin-top:12px; padding:10px;
           border:1px dashed var(--accent); border-radius:8px; word-break:break-all; }
  .error { color:var(--danger); font-size:13px; min-height:18px; margin-top:8px; }
  .muted { color:var(--muted); }
  .cards { display:grid; gap:10px; grid-template-columns:repeat(auto-fill, minmax(260px, 1fr)); }
  .card { border:1px solid var(--line); border-radius:8px; padding:12px; font-size:13px; }
  .card b { display:block; font-size:14px; margin-bottom:4px; }
  .hidden { display:none !important; }
</style>
</head>
<body>
<header>
  <h1>JellyBox Continuity</h1>
  <span class="who" id="who"></span>
  <button id="logout" class="hidden">Sign out</button>
</header>
<main>
  <section id="setup" class="hidden">
    <h2>Create administrator</h2>
    <p class="hint">This server has no accounts yet. The first account manages users and credentials.</p>
    <div class="row">
      <div><label for="setup-login">Login</label><input id="setup-login" type="text" autocomplete="username"></div>
      <div><label for="setup-name">Display name (optional)</label><input id="setup-name" type="text"></div>
      <div><label for="setup-password">Password</label><input id="setup-password" type="password" autocomplete="new-password"></div>
      <div style="flex:0 0 auto"><button class="primary" id="setup-submit">Create</button></div>
    </div>
    <div class="error" id="setup-error"></div>
  </section>

  <section id="login" class="hidden">
    <h2>Sign in</h2>
    <p class="hint">Administrator access to users and credentials.</p>
    <div class="row">
      <div><label for="login-login">Login</label><input id="login-login" type="text" autocomplete="username"></div>
      <div><label for="login-password">Password</label><input id="login-password" type="password" autocomplete="current-password"></div>
      <div style="flex:0 0 auto"><button class="primary" id="login-submit">Sign in</button></div>
    </div>
    <div class="error" id="login-error"></div>
  </section>

  <section id="app" class="hidden">
    <h2>Users</h2>
    <p class="hint">Each user is one JellyBox identity. Devices sign in with a login and password; the password is never stored.</p>
    <table>
      <thead><tr><th>Login</th><th>Name</th><th>Role</th><th>Credentials</th><th></th></tr></thead>
      <tbody id="users"></tbody>
    </table>
    <div class="row" style="margin-top:14px">
      <div><label for="user-login">Login</label><input id="user-login" type="text" autocomplete="off"></div>
      <div><label for="user-name">Display name</label><input id="user-name" type="text"></div>
      <div><label for="user-password">Password</label><input id="user-password" type="password" autocomplete="new-password"></div>
      <div style="flex:0 0 auto"><label>&nbsp;</label><label class="muted"><input id="user-admin" type="checkbox"> Admin</label></div>
      <div style="flex:0 0 auto"><button class="primary" id="user-submit">Add user</button></div>
    </div>
    <div class="error" id="users-error"></div>
  </section>

  <section id="credentials" class="hidden">
    <h2>Credentials</h2>
    <p class="hint">Tokens are shown once when created. Revoke one to disconnect the devices using it.</p>
    <table>
      <thead><tr><th>Label</th><th>User</th><th>Kind</th><th>Prefix</th><th>Last used</th><th>State</th><th></th></tr></thead>
      <tbody id="cred-list"></tbody>
    </table>
    <div class="row" style="margin-top:14px">
      <div><label for="cred-user">User</label><select id="cred-user" style="width:100%;padding:8px 10px;border-radius:7px;border:1px solid var(--line);background:var(--bg);color:var(--fg)"></select></div>
      <div><label for="cred-label">Label</label><input id="cred-label" type="text" placeholder="Living room TV"></div>
      <div style="flex:0 0 auto"><button class="primary" id="cred-submit">Create token</button></div>
    </div>
    <div class="token hidden" id="cred-token"></div>
    <div class="error" id="cred-error"></div>
  </section>

  <section id="live" class="hidden">
    <h2>Live sessions</h2>
    <p class="hint">Devices currently connected to the relay, per user and library.</p>
    <div class="cards" id="sessions"></div>
  </section>
</main>
<script>
const $ = (id) => document.getElementById(id);
let state = { users: [], credentials: [] };

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });
  let body = null;
  try { body = await response.json(); } catch (_) { body = null; }
  if (!response.ok) {
    const message = (body && (body.detail || body.message)) || `Request failed (${response.status})`;
    throw new Error(message);
  }
  return body;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function show(section) {
  for (const id of ['setup', 'login', 'app', 'credentials', 'live']) {
    $(id).classList.toggle('hidden', id !== section);
  }
}

async function boot() {
  const info = await api('/api/state');
  if (info.needsSetup) { show('setup'); return; }
  if (!info.authenticated) { show('login'); return; }
  $('who').textContent = `Signed in as ${info.user.login}`;
  $('logout').classList.remove('hidden');
  show('app');
  $('credentials').classList.remove('hidden');
  $('live').classList.remove('hidden');
  await refresh();
}

async function refresh() {
  const [users, credentials, sessions] = await Promise.all([
    api('/api/users'), api('/api/credentials'), api('/api/sessions'),
  ]);
  state.users = users.users;
  state.credentials = credentials.credentials;
  renderUsers();
  renderCredentials();
  renderSessions(sessions.sessions);
}

function renderUsers() {
  const rows = state.users.map((user) => `
    <tr>
      <td class="mono">${escapeHtml(user.login)}</td>
      <td>${escapeHtml(user.name || '')}</td>
      <td>${user.is_admin ? '<span class="tag ok">admin</span>' : '<span class="tag">user</span>'}
          ${user.disabled ? '<span class="tag bad">disabled</span>' : ''}</td>
      <td>${user.active_credential_count} active / ${user.credential_count}</td>
      <td style="text-align:right;white-space:nowrap">
        <button data-action="password" data-id="${user.id}">Password</button>
        <button data-action="toggle" data-id="${user.id}" data-disabled="${user.disabled ? 0 : 1}">${user.disabled ? 'Enable' : 'Disable'}</button>
        <button class="danger" data-action="delete" data-id="${user.id}">Delete</button>
      </td>
    </tr>`).join('');
  $('users').innerHTML = rows || '<tr><td colspan="5" class="muted">No users yet.</td></tr>';

  $('cred-user').innerHTML = state.users
    .map((user) => `<option value="${user.id}">${escapeHtml(user.login)}</option>`)
    .join('');
}

function renderCredentials() {
  const rows = state.credentials.map((credential) => `
    <tr>
      <td>${escapeHtml(credential.label)}</td>
      <td class="mono">${escapeHtml(credential.user_login)}</td>
      <td>${credential.kind === 'app' ? 'App sign-in' : 'API'}</td>
      <td class="mono">${escapeHtml(credential.prefix)}…</td>
      <td class="muted">${credential.last_used_at ? escapeHtml(credential.last_used_at.replace('T', ' ')) : 'never'}</td>
      <td>${credential.revoked ? '<span class="tag bad">revoked</span>' : '<span class="tag ok">active</span>'}</td>
      <td style="text-align:right;white-space:nowrap">
        ${credential.revoked ? '' : `<button data-cred="revoke" data-id="${credential.id}">Revoke</button>`}
        <button class="danger" data-cred="delete" data-id="${credential.id}">Delete</button>
      </td>
    </tr>`).join('');
  $('cred-list').innerHTML = rows || '<tr><td colspan="7" class="muted">No credentials yet.</td></tr>';
}

function renderSessions(list) {
  if (!list.length) {
    $('sessions').innerHTML = '<p class="muted">No devices are connected.</p>';
    return;
  }
  $('sessions').innerHTML = list.map((session) => `
    <div class="card">
      <b>${escapeHtml(session.login)}</b>
      <div class="muted">${session.backend ? `Library ${escapeHtml(session.backend)}` : 'No library'}</div>
      <div style="margin-top:8px">
        ${session.devices.map((device) => `
          <div>${escapeHtml(device.name)} <span class="tag">${escapeHtml(device.platform)}</span>
          ${device.isRenderer ? '<span class="tag ok">playing</span>' : ''}</div>`).join('')}
      </div>
    </div>`).join('');
}

async function guard(fn, errorId) {
  $(errorId).textContent = '';
  try { await fn(); } catch (error) { $(errorId).textContent = error.message; }
}

$('setup-submit').addEventListener('click', () => guard(async () => {
  await api('/api/setup', { method: 'POST', body: JSON.stringify({
    login: $('setup-login').value, password: $('setup-password').value,
    name: $('setup-name').value,
  })});
  location.reload();
}, 'setup-error'));

$('login-submit').addEventListener('click', () => guard(async () => {
  await api('/api/login', { method: 'POST', body: JSON.stringify({
    login: $('login-login').value, password: $('login-password').value,
  })});
  location.reload();
}, 'login-error'));

$('logout').addEventListener('click', () => guard(async () => {
  await api('/api/logout', { method: 'POST' });
  location.reload();
}, 'login-error'));

$('user-submit').addEventListener('click', () => guard(async () => {
  await api('/api/users', { method: 'POST', body: JSON.stringify({
    login: $('user-login').value, name: $('user-name').value,
    password: $('user-password').value, isAdmin: $('user-admin').checked,
  })});
  $('user-login').value = $('user-name').value = $('user-password').value = '';
  $('user-admin').checked = false;
  await refresh();
}, 'users-error'));

$('users').addEventListener('click', (event) => guard(async () => {
  const button = event.target.closest('button');
  if (!button) return;
  const id = button.dataset.id;
  if (button.dataset.action === 'delete') {
    if (!confirm('Delete this user and every credential it owns?')) return;
    await api(`/api/users/${id}`, { method: 'DELETE' });
  } else if (button.dataset.action === 'toggle') {
    await api(`/api/users/${id}`, { method: 'PATCH', body: JSON.stringify({
      disabled: button.dataset.disabled === '1',
    })});
  } else if (button.dataset.action === 'password') {
    const password = prompt('New password (at least 8 characters)');
    if (!password) return;
    await api(`/api/users/${id}`, { method: 'PATCH', body: JSON.stringify({ password })});
  }
  await refresh();
}, 'users-error'));

$('cred-submit').addEventListener('click', () => guard(async () => {
  const result = await api('/api/credentials', { method: 'POST', body: JSON.stringify({
    userId: $('cred-user').value, label: $('cred-label').value,
  })});
  $('cred-label').value = '';
  $('cred-token').classList.remove('hidden');
  $('cred-token').innerHTML = `<span class="mono" id="token-value">${escapeHtml(result.token)}</span>
    <button id="copy-token">Copy</button>`;
  $('copy-token').addEventListener('click', () => navigator.clipboard.writeText(result.token));
  await refresh();
}, 'cred-error'));

$('cred-list').addEventListener('click', (event) => guard(async () => {
  const button = event.target.closest('button');
  if (!button) return;
  const id = button.dataset.id;
  if (button.dataset.cred === 'revoke') {
    await api(`/api/credentials/${id}/revoke`, { method: 'POST' });
  } else if (confirm('Delete this credential permanently?')) {
    await api(`/api/credentials/${id}`, { method: 'DELETE' });
  }
  await refresh();
}, 'cred-error'));

boot().catch((error) => { $('login-error').textContent = error.message; show('login'); });
</script>
</body>
</html>
"""
