"""End-to-end protocol and admin API test for the continuity server.

Runs against a live server (default http://127.0.0.1:8000) over real HTTP and
WebSocket connections. Start the server first:

    docker compose up -d
    python test_protocol.py

The test creates its own administrator and users through /api/setup and
/api/users. Against an already configured server it signs in with
CONTINUITY_ADMIN_LOGIN / CONTINUITY_ADMIN_PASSWORD (defaults: admin /
continuity-admin). Exit code 0 means every check passed.
"""

from __future__ import annotations

import http.cookiejar
import json
import os
import sys
import time
import urllib.error
import urllib.request

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect

BASE_URL = "http://127.0.0.1:8000"
WS_URL = "ws://127.0.0.1:8000/ws"

ADMIN_LOGIN = os.environ.get("CONTINUITY_ADMIN_LOGIN", "admin")
ADMIN_PASSWORD = os.environ.get("CONTINUITY_ADMIN_PASSWORD", "continuity-admin")

USERS = {
    "alice": "alice-password",
    "bob": "bob-password",
    "carol": "carol-password",
    "dave": "dave-password",
}

COOKIES = http.cookiejar.CookieJar()
OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(COOKIES))

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    print(f"{'PASS' if condition else 'FAIL'} {message}")
    if not condition:
        failures.append(message)


def recv(conn, timeout: float = 2.0) -> dict:
    return json.loads(conn.recv(timeout=timeout))


def expect(conn, message_type: str, timeout: float = 2.0) -> dict:
    data = recv(conn, timeout)
    check(
        data.get("type") == message_type,
        f"expected {message_type}, got {data.get('type')}",
    )
    return data


def drain(conn, timeout: float = 0.25) -> list[dict]:
    messages: list[dict] = []
    while True:
        try:
            messages.append(recv(conn, timeout))
        except TimeoutError:
            return messages
        except ConnectionClosed:
            return messages


def api(method: str, path: str, payload: dict | None = None) -> tuple[int, dict]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with OPENER.open(request, timeout=10) as response:
            raw = response.read()
            return response.status, json.loads(raw or b"{}")
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {"detail": raw.decode("utf-8", "replace")}
        return error.code, body


def check_admin_page() -> None:
    with urllib.request.urlopen(f"{BASE_URL}/admin", timeout=5) as response:
        body = response.read().decode("utf-8", "replace")
    check(response.status == 200 and "JellyBox Continuity" in body,
          "admin page is served")


def provision() -> dict[str, str]:
    status, setup_body = api("POST", "/api/setup", {
        "login": ADMIN_LOGIN,
        "password": ADMIN_PASSWORD,
        "name": "Administrator",
    })
    if status == 409:
        status, body = api("POST", "/api/login", {
            "login": ADMIN_LOGIN,
            "password": ADMIN_PASSWORD,
        })
        if status != 200:
            raise SystemExit(
                "Server is already configured and the administrator sign-in "
                f"failed ({status}: {body.get('detail', '')}). Set "
                "CONTINUITY_ADMIN_LOGIN / CONTINUITY_ADMIN_PASSWORD."
            )
    elif status != 200:
        raise SystemExit(f"Setup failed: {status} {_detail(setup_body)}")

    status, body = api("GET", "/api/users")
    existing = {user["login"]: user["id"] for user in body.get("users", [])}
    ids: dict[str, str] = {}
    for login, password in USERS.items():
        status, body = api("POST", "/api/users", {
            "login": login,
            "password": password,
            "name": login.title(),
        })
        if status == 200:
            ids[login] = body["user"]["id"]
        elif status == 409 and login in existing:
            ids[login] = existing[login]
            # Tests must be repeatable even if a previous run changed a
            # password or disabled the account.
            patch_status, patch_body = api(
                "PATCH", f"/api/users/{ids[login]}",
                {"password": password, "disabled": False},
            )
            check(patch_status == 200,
                  f"reset test password for {login}: {_detail(patch_body)}")
        else:
            raise SystemExit(f"could not create {login}: {status} {_detail(body)}")
    return ids


def _detail(body: dict) -> str:
    return str(body.get("detail", body))


def sign_in(conn, login: str, password: str) -> dict:
    conn.send(json.dumps({
        "type": "signin",
        "login": login,
        "password": password,
    }))
    return expect(conn, "signed_in")["account"]


def register(conn, device_id: str, token: str, backend_ref: str,
             name: str = "") -> dict:
    conn.send(json.dumps({
        "type": "register",
        "device_id": device_id,
        "name": name or device_id,
        "platform": "test",
        "backend_ref": backend_ref,
        "token": token,
    }))
    expect(conn, "registered")
    return expect(conn, "state")


def playing_doc(**overrides) -> dict:
    doc = {
        "backendRef": "jf1",
        "albumId": "album1",
        "itemIds": ["s1", "s2", "s3"],
        "queuePosition": 1,
        "trackPositionMs": 30000,
        "playing": True,
        "shuffle": False,
        "repeat": "off",
        "volume": 0.7,
        "sourceId": "source1",
    }
    doc.update(overrides)
    return doc


def send_state(conn, doc: dict) -> None:
    conn.send(json.dumps({"type": "state", "doc": doc}))


def main() -> int:
    started = time.time()
    check(api("GET", "/health")[1].get("status") == "ok",
          "health endpoint reports ok")
    check_admin_page()
    ids = provision()
    check(len(ids) == len(USERS), "administrator can create users")

    _, state = api("GET", "/api/state")
    status, _ = api("PATCH", f"/api/users/{state['user']['id']}", {"isAdmin": False})
    check(status == 409, "last administrator cannot be demoted")

    status, _ = api("POST", "/api/users", {
        "login": "alice", "password": "another-password",
    })
    check(status == 409, "duplicate login is rejected")

    status, _ = api("POST", "/api/login", {
        "login": "alice", "password": USERS["alice"],
    })
    check(status == 403, "non-administrators cannot open the admin API")

    a = connect(WS_URL, open_timeout=5)
    bad_login = connect(WS_URL, open_timeout=5)
    bad_login.send(json.dumps({
        "type": "signin", "login": "alice", "password": "wrong-password",
    }))
    error = expect(bad_login, "error")
    check("Invalid login" in str(error.get("message")),
          "wrong password is rejected")
    bad_login.close()

    account = sign_in(a, "alice", USERS["alice"])
    check(bool(account.get("userId")) and bool(account.get("token")),
          "sign-in returns a user id and token")
    check(account.get("login") == "alice", "sign-in returns the login")
    check(account.get("socketPath") == "/ws", "sign-in returns the socket path")

    first = register(a, "A", account["token"], "jf1", "Phone A")
    check(first["active_renderer"] is None, "no renderer after first register")
    check([d["id"] for d in first["devices"]] == ["A"],
          "first device is listed")

    b = connect(WS_URL, open_timeout=5)
    b_account = sign_in(b, "alice", USERS["alice"])
    check(b_account["userId"] == account["userId"],
          "same login maps to the same user id")
    register(b, "B", b_account["token"], "jf1", "Tablet B")
    peer_state = expect(a, "state")
    check({d["id"] for d in peer_state["devices"]} == {"A", "B"},
          "existing peer learns about the new device")

    send_state(a, playing_doc())
    a_state = expect(a, "state")
    b_state = expect(b, "state")
    check(a_state["active_renderer"] == "A", "first playing device is elected")
    check(b_state["active_renderer"] == "A", "peers see the election")
    check(b_state["doc"]["itemIds"] == ["s1", "s2", "s3"],
          "session document is broadcast to peers")

    send_state(b, playing_doc(itemIds=["x1", "x2"], playing=True))
    check(not [m for m in drain(a) if m.get("type") == "state"],
          "non-renderer state updates are ignored")
    check(not drain(b), "non-renderer receives no broadcast for its own state")

    b.send(json.dumps({"type": "command", "command": "pause"}))
    command = expect(a, "command")
    check(command.get("command") == "pause", "command reaches the renderer")

    a.send(json.dumps({"type": "handoff_request", "target_device_id": "B"}))
    pending = expect(a, "handoff_pending")
    handoff = expect(b, "handoff")
    check(pending.get("target_device_id") == "B", "requester sees handoff pending")
    check(handoff.get("from") == "A", "target sees who is handing off")
    check(handoff["doc"]["itemIds"] == ["s1", "s2", "s3"],
          "handoff carries the live queue")

    b.send(json.dumps({"type": "handoff_accept"}))
    a_accepted = expect(a, "handoff_accepted")
    b_accepted = expect(b, "handoff_accepted")
    check(a_accepted["active_renderer"] == "B", "handoff moves the renderer")
    check(b_accepted["active_renderer"] == "B", "target sees itself elected")

    send_state(b, playing_doc(trackPositionMs=31000))
    a_state = expect(a, "state")
    check(a_state["active_renderer"] == "B" and
          a_state["doc"]["trackPositionMs"] == 31000,
          "new renderer's state is broadcast")

    a.send(json.dumps({"type": "command", "command": "seek", "value": 5000}))
    command = expect(b, "command")
    check(command.get("value") == 5000, "commands follow the renderer")

    b.send(json.dumps({"type": "handoff_request", "target_device_id": "A"}))
    expect(b, "handoff_pending")
    expect(a, "handoff")
    a.send(json.dumps({"type": "handoff_reject"}))
    expect(a, "handoff_rejected")
    expect(b, "handoff_rejected")
    check(True, "rejected handoff is broadcast")

    b.send(json.dumps({"type": "handoff_request", "target_device_id": "A"}))
    expect(b, "handoff_pending")
    expect(a, "handoff")
    a.send(json.dumps({"type": "handoff_accept"}))
    expect(a, "handoff_accepted")
    expect(b, "handoff_accepted")

    # A device that asks to take over gets the live session through a handoff.
    b.send(json.dumps({"type": "claim"}))
    claimed = expect(b, "handoff")
    check(claimed["doc"]["itemIds"] == ["s1", "s2", "s3"],
          "claim receives the live session")
    check(not [m for m in drain(a) if m.get("type") == "handoff"],
          "claim does not interrupt the current renderer before acceptance")
    b.send(json.dumps({"type": "handoff_accept"}))
    expect(a, "handoff_accepted")
    expect(b, "handoff_accepted")

    b.send(json.dumps({"type": "state", "doc": {"itemIds": "not-a-list"}}))
    error = expect(b, "error")
    check("itemIds" in str(error.get("message")),
          "malformed session documents are rejected")

    # A second user and a second backend must not see the first session.
    c = connect(WS_URL, open_timeout=5)
    c_account = sign_in(c, "bob", USERS["bob"])
    check(c_account["userId"] != account["userId"],
          "different user gets a different id")
    register(c, "C", c_account["token"], "jf1", "Phone C")
    send_state(c, playing_doc(backendRef="jf1"))
    c_state = expect(c, "state")
    check(c_state["active_renderer"] == "C", "other user's session is separate")
    check(not [m for m in drain(a) if m.get("type") == "state"],
          "first session does not see the second user's broadcasts")
    check(not drain(b), "second device in first session sees nothing")

    d = connect(WS_URL, open_timeout=5)
    d_account = sign_in(d, "alice", USERS["alice"])
    check(d_account["userId"] == account["userId"],
          "same user id for second backend")
    register(d, "D", d_account["token"], "jf2", "Phone D")
    check(not [m for m in drain(a) if m.get("type") == "state"],
          "same user on another backend is a separate session")
    send_state(d, playing_doc(backendRef="jf2"))
    d_state = expect(d, "state")
    check(d_state["active_renderer"] == "D", "second backend elects its own renderer")

    # Re-registering a device from a new socket replaces the old connection.
    a2 = connect(WS_URL, open_timeout=5)
    sign_in(a2, "alice", USERS["alice"])
    register(a2, "A", account["token"], "jf1", "Phone A (reconnected)")
    check(not [m for m in drain(a) if m.get("type") == "state"],
          "replaced socket stops receiving session broadcasts")
    try:
        send_state(a, playing_doc())
    except ConnectionClosed:
        check(True, "replaced socket is closed by the server")
    else:
        check(False, "replaced socket should be closed by the server")
    replacement = [m for m in drain(b) if m.get("type") == "state"]
    check(bool(replacement) and replacement[-1]["active_renderer"] == "B",
          "peers learn about the replacement without losing the renderer")
    send_state(a2, playing_doc())
    check(not drain(a2), "new socket of a non-renderer cannot publish")
    a2.send(json.dumps({"type": "claim"}))
    expect(a2, "handoff")
    a2.send(json.dumps({"type": "handoff_accept"}))
    expect(a2, "handoff_accepted")
    expect(b, "handoff_accepted")
    send_state(a2, playing_doc(trackPositionMs=44000))
    peer_state = expect(b, "state")
    check(peer_state["active_renderer"] == "A" and
          peer_state["doc"]["trackPositionMs"] == 44000,
          "new socket keeps publishing after becoming the renderer")

    # Reconnecting the active renderer must not lose its active status.
    e = connect(WS_URL, open_timeout=5)
    e_account = sign_in(e, "carol", USERS["carol"])
    register(e, "E", e_account["token"], "jf1", "Phone E")
    send_state(e, playing_doc())
    expect(e, "state")
    e2 = connect(WS_URL, open_timeout=5)
    e2_account = sign_in(e2, "carol", USERS["carol"])
    e2_state = register(e2, "E", e2_account["token"], "jf1",
                        "Phone E (reconnected)")
    check(e2_state["active_renderer"] == "E",
          "reconnecting active device keeps active status")
    try:
        e.recv(timeout=2)
    except ConnectionClosed:
        check(True, "old active socket is closed")
    else:
        check(False, "old active socket should be closed")

    # Unregistering the active renderer leaves the session without one.
    a2.send(json.dumps({"type": "unregister"}))
    after_unregister = expect(b, "state")
    check(after_unregister["active_renderer"] is None,
          "unregister clears the active renderer")
    check([d["id"] for d in after_unregister["devices"]] == ["B"],
          "unregister removes the device from the list")

    b.send(json.dumps({"type": "command", "command": "pause"}))
    error = expect(b, "error")
    check("Nothing is playing" in str(error.get("message")),
          "commands fail cleanly without a renderer")

    send_state(b, playing_doc())
    elected = expect(b, "state")
    check(elected["active_renderer"] == "B", "next playing device is elected")

    # Re-registering the same device under another backend must move it out of
    # its old session instead of leaving it listed in both.
    f = connect(WS_URL, open_timeout=5)
    f_account = sign_in(f, "dave", USERS["dave"])
    register(f, "F", f_account["token"], "jf5", "Phone F")
    g = connect(WS_URL, open_timeout=5)
    g_account = sign_in(g, "dave", USERS["dave"])
    register(g, "G", g_account["token"], "jf5", "Tablet G")
    expect(f, "state")
    moved = register(f, "F", f_account["token"], "jf6", "Phone F (other server)")
    check([d["id"] for d in moved["devices"]] == ["F"],
          "switching backend starts a fresh session")
    old_session = expect(g, "state")
    check([d["id"] for d in old_session["devices"]] == ["G"],
          "switching backend removes the device from its old session")

    # Credential manager: a minted token works, a revoked token does not.
    status, body = api("POST", "/api/credentials", {
        "userId": ids["alice"], "label": "Protocol test",
    })
    check(status == 200 and body.get("token", "").startswith("jbc_"),
          "administrator can mint a credential")
    credential_id = body["credential"]["id"]

    h = connect(WS_URL, open_timeout=5)
    register(h, "H", body["token"], "cred-backend", "Credential device")
    h.close()

    check(api("POST", f"/api/credentials/{credential_id}/revoke")[0] == 200,
          "administrator can revoke a credential")
    revoked = connect(WS_URL, open_timeout=5)
    revoked.send(json.dumps({
        "type": "register",
        "device_id": "R",
        "name": "Revoked device",
        "platform": "test",
        "backend_ref": "cred-backend",
        "token": body["token"],
    }))
    signed_out = expect(revoked, "signed_out")
    check("Sign in" in str(signed_out.get("message")),
          "revoked credential cannot register")
    revoked.close()

    status, body = api("GET", "/api/sessions")
    check(status == 200 and isinstance(body.get("sessions"), list),
          "administrator can inspect live sessions")

    for conn in (a, a2, b, c, d, e2, f, g, h):
        try:
            conn.close()
        except Exception:
            pass

    time.sleep(0.4)
    final = api("GET", "/health")[1]
    check(final.get("sessions") == 0 and final.get("devices") == 0,
          "health reports no sessions after every device disconnects")

    elapsed = time.time() - started
    if failures:
        print(f"\n{len(failures)} check(s) failed in {elapsed:.2f}s")
        return 1
    print(f"\nall checks passed in {elapsed:.2f}s")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1:
        BASE_URL = sys.argv[1].rstrip("/")
        WS_URL = BASE_URL.replace("http://", "ws://").replace(
            "https://", "wss://") + "/ws"
    sys.exit(main())
