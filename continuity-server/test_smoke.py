"""End-to-end smoke test for the continuity server.

Starts uvicorn on a free port and drives real WebSocket clients through the
protocol the app speaks: sign-in, register, active-renderer election, remote
commands, claim, and handoff.

    python test_smoke.py
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import sys
import tempfile
from typing import Any, Dict, List

import uvicorn
import websockets

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# Keep the test's accounts out of a real deployment's database.
os.environ["CONTINUITY_DB"] = os.path.join(
    tempfile.mkdtemp(prefix="continuity-smoke-"), "smoke.db"
)

import main as server_main  # noqa: E402

SIGN_IN_LOGIN = "tester"
SIGN_IN_PASSWORD = "correct-horse-battery"
TOKEN = ""


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


class Client:
    def __init__(self, ws: Any, device_id: str) -> None:
        self.ws = ws
        self.device_id = device_id
        self.inbox: List[Dict[str, Any]] = []
        self._reader = asyncio.create_task(self._read())

    async def _read(self) -> None:
        try:
            async for raw in self.ws:
                self.inbox.append(json.loads(raw))
        except Exception:
            pass

    async def send(self, **message: Any) -> None:
        await self.ws.send(json.dumps(message))

    async def next_of(self, msg_type: str, timeout: float = 5.0) -> Dict[str, Any]:
        async def wait() -> Dict[str, Any]:
            while True:
                for index, message in enumerate(self.inbox):
                    if message.get("type") == msg_type:
                        return self.inbox.pop(index)
                await asyncio.sleep(0.01)

        return await asyncio.wait_for(wait(), timeout)

    def drain(self) -> None:
        self.inbox.clear()

    async def close(self) -> None:
        await self.ws.close()
        self._reader.cancel()


async def connect(
    port: int, device_id: str, name: str, backend: str
) -> tuple[Client, Dict[str, Any]]:
    ws = await websockets.connect(f"ws://127.0.0.1:{port}/ws")
    client = Client(ws, device_id)
    await client.send(
        type="register",
        device_id=device_id,
        name=name,
        platform="test",
        backend_ref=backend,
        token=TOKEN,
    )
    await client.next_of("registered")
    state = await client.next_of("state")
    return client, state


def check(condition: bool, label: str) -> None:
    if not condition:
        raise AssertionError(label)
    print(f"  ok  {label}")


async def run(port: int) -> None:
    global TOKEN

    print("sign-in")
    server_main.store.create_first_admin(SIGN_IN_LOGIN, SIGN_IN_PASSWORD, "Tester")
    ws = await websockets.connect(f"ws://127.0.0.1:{port}/ws")
    signer = Client(ws, "signer")
    await signer.send(type="signin", address="x", login=SIGN_IN_LOGIN, password="wrong")
    error = await signer.next_of("error")
    check("Invalid login" in error["message"], "wrong password is rejected")
    await signer.send(
        type="signin", address="x", login=SIGN_IN_LOGIN, password=SIGN_IN_PASSWORD
    )
    account = (await signer.next_of("signed_in"))["account"]
    check(account["login"] == SIGN_IN_LOGIN, "server returns the login")
    check(account["userId"], "server issues a user id")
    check(account["token"], "server issues a token")
    check(account["socketPath"] == "/ws", "account points at the ws endpoint")
    TOKEN = account["token"]
    await signer.close()

    print("registration")
    unauth = await websockets.connect(f"ws://127.0.0.1:{port}/ws")
    unauth_client = Client(unauth, "unauth")
    await unauth_client.send(
        type="register", device_id="unauth", name="Unauth", platform="test",
        backend_ref="server-1", token="jbc_bogus",
    )
    signed_out = await unauth_client.next_of("signed_out")
    check("Sign in" in signed_out["message"], "invalid token is rejected")
    await unauth_client.close()

    phone, seen = await connect(port, "phone", "Phone", "server-1")
    desktop, _ = await connect(port, "desktop", "Desktop", "server-1")
    seen = await phone.next_of("state")
    check(
        {d["id"] for d in seen["devices"]} == {"phone", "desktop"},
        "peers learn about each other",
    )
    check(seen["active_renderer"] is None, "no renderer before anyone plays")

    print("renderer election")
    doc = {
        "backendRef": "server-1",
        "albumId": "album-1",
        "itemIds": ["s1", "s2", "s3"],
        "queuePosition": 1,
        "trackPositionMs": 42000,
        "playing": True,
        "shuffle": False,
        "repeat": "off",
        "volume": 0.5,
        "sourceId": "album-1",
    }
    await phone.send(type="state", doc=doc)
    state = await desktop.next_of("state")
    check(state["active_renderer"] == "phone", "playing device becomes renderer")
    check(state["doc"]["itemIds"] == ["s1", "s2", "s3"], "doc reaches the peer")
    check(state["doc"]["trackPositionMs"] == 42000, "position is relayed")

    print("state fan-out is coalesced")
    server_main.STATE_BROADCAST_INTERVAL_MS = 400
    phone.drain()
    desktop.drain()
    for position_ms in (1000, 2000, 3000):
        await phone.send(type="state", doc={**doc, "trackPositionMs": position_ms})
    await asyncio.sleep(0.1)
    check(
        not any(m.get("type") == "state" for m in desktop.inbox),
        "ticks inside the interval are folded",
    )
    await asyncio.sleep(0.5)
    folded = [m for m in desktop.inbox if m.get("type") == "state"]
    check(len(folded) == 1, "one trailing broadcast carries the ticks")
    check(folded[0]["doc"]["trackPositionMs"] == 3000, "the newest position wins")
    server_main.STATE_BROADCAST_INTERVAL_MS = 250

    print("non-renderer state is ignored")
    await desktop.send(type="state", doc={**doc, "itemIds": ["bogus"]})
    await asyncio.sleep(0.2)
    check(
        not any(m.get("doc", {}).get("itemIds") == ["bogus"] for m in phone.inbox),
        "a peer cannot overwrite the renderer's queue",
    )

    print("remote commands")
    await desktop.send(type="command", command="pause", value=None)
    command = await phone.next_of("command")
    check(command["command"] == "pause", "command reaches the renderer")
    await desktop.send(type="command", command="seek", value=90000)
    command = await phone.next_of("command")
    check(command["value"] == 90000, "command payload is preserved")

    print("claim")
    phone.drain()
    desktop.drain()
    await desktop.send(type="claim")
    claimed = await desktop.next_of("handoff")
    check(
        claimed["doc"]["itemIds"] == ["s1", "s2", "s3"],
        "claim receives the live session",
    )
    check(
        not any(m.get("type") == "state" for m in phone.inbox),
        "claim does not change the renderer before acceptance",
    )
    await desktop.send(type="handoff_accept")
    accepted = await phone.next_of("handoff_accepted")
    check(accepted["active_renderer"] == "desktop", "claim moves the renderer")
    await desktop.send(
        type="state",
        doc={**doc, "itemIds": ["d1"], "queuePosition": 0, "playing": False},
    )
    after = await phone.next_of("state")
    check(after["doc"]["itemIds"] == ["d1"], "new renderer's state is broadcast")

    print("handoff")
    phone.drain()
    desktop.drain()
    await phone.send(type="handoff_request", target_device_id="desktop")
    pending = await phone.next_of("handoff_pending")
    check(pending["target_device_id"] == "desktop", "source sees it is pending")
    handoff = await desktop.next_of("handoff")
    check(handoff["from"] == "phone", "target learns who is handing off")
    check(handoff["doc"]["itemIds"] == ["d1"], "target receives the queue")
    await desktop.send(type="handoff_accept")
    accepted = await phone.next_of("handoff_accepted")
    check(accepted["target_device_id"] == "desktop", "handoff is accepted")
    check(accepted["active_renderer"] == "desktop", "target becomes the renderer")

    print("handoff to an unknown device is rejected")
    await phone.send(type="handoff_request", target_device_id="ghost")
    rejected = await phone.next_of("handoff_rejected")
    check(rejected["target_device_id"] == "ghost", "unknown target is rejected")

    print("sessions are isolated by backend")
    other, other_state = await connect(port, "laptop", "Laptop", "server-2")
    check(
        other_state["active_renderer"] is None,
        "a different server starts with no renderer",
    )

    print("disconnect")
    phone.drain()
    await desktop.close()
    gone = await phone.next_of("state")
    check("desktop" not in {d["id"] for d in gone["devices"]}, "device is removed")
    check(gone["active_renderer"] is None, "renderer is cleared on disconnect")
    await phone.close()
    await other.close()

    print("re-register from a new socket replaces the stale one")
    first, _ = await connect(port, "phone", "Phone", "server-1")
    second, _ = await connect(port, "phone", "Phone", "server-1")
    check(second.device_id == "phone", "device reconnected")
    await first.close()
    await asyncio.sleep(0.2)
    second.drain()
    await second.send(type="state", doc={**doc, "playing": True})
    state = await second.next_of("state", timeout=2)
    check(state["active_renderer"] == "phone", "new socket still works")
    await second.close()


async def main() -> int:
    port = free_port()
    config = uvicorn.Config(
        "main:app",
        host="127.0.0.1",
        port=port,
        log_level="warning",
        ws="websockets",
    )
    server = uvicorn.Server(config)
    sys.path.insert(0, HERE)
    task = asyncio.create_task(server.serve())
    while not server.started:
        if task.done():
            print("server failed to start", file=sys.stderr)
            return 1
        await asyncio.sleep(0.02)

    try:
        await run(port)
    finally:
        server.should_exit = True
        await task

    print("\nall continuity checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
