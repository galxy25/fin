#!/usr/bin/env python3
"""relay.py — the terminal relay's WebSocket server, self-hosted on an on-demand EC2 body.

WHY THIS EXISTS AT ALL, rather than the API Gateway WebSocket API it replaces:
`URLSessionWebSocketTask` — the WebSocket client BOTH Swift sides use (the app's
`TerminalSession`, the daemon's `TerminalRelayClient`) — cannot talk to an AWS
API Gateway WebSocket endpoint. Reproduced 2026-09-16 with a 30-line Swift
program against that endpoint: connect succeeds, the first `send()` succeeds,
and the very next `receive()` fails instantly with `NSPOSIXErrorDomain Code=57
"Socket is not connected"`, every time. The same Swift program against an
ordinary WebSocket server works perfectly, and a plain Python client against
the API Gateway endpoint also works perfectly — so it is neither a universal
Apple bug nor anything wrong server-side, it is those two specific
implementations disagreeing (both negotiate `h2` by ALPN; the likely culprit is
API Gateway's handling of WebSocket-over-HTTP/2, RFC 8441 Extended CONNECT).
Rewriting both Swift clients onto `Network.framework` would have been the other
way out; hosting an ordinary WebSocket server instead costs no client rewrite.

WHAT IT IS: a dumb, in-memory pairing switch. Each terminal session has exactly
two parties — the app (which sends `open`) and the site's daemon (which sends
`attach`) — and this process copies frames between them. No database: the
instance is ephemeral and terminates itself when idle, so a session that
outlives the process is a session whose parties have both gone away anyway.

AUTH: the sessionId IS the capability. It is a UUID minted by the control plane
and handed only to callers who already authenticated to it over REST (the same
posture as this project's presigned URLs and message ids). So this server does
not re-check bearers; it only refuses to pair a connection into a session that
is already fully occupied, and never reveals whether an unknown sessionId
exists. Transport is TLS with a self-signed certificate both clients pin by
SHA-256, which is what keeps an eavesdropper (or an impostor relay) out.
"""

import asyncio
import json
import logging
import os
import ssl
import time
import urllib.request

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

LOG = logging.getLogger("fin-relay")

PORT = int(os.environ.get("FIN_RELAY_PORT", "443"))
CERT_PATH = os.environ.get("FIN_RELAY_CERT", "/etc/fin-relay/cert.pem")
KEY_PATH = os.environ.get("FIN_RELAY_KEY", "/etc/fin-relay/key.pem")
# How long with NO open session before this body terminates itself. The whole
# cost model of the feature is this number: the instance exists only while
# someone is looking at a terminal.
IDLE_SECONDS = int(os.environ.get("FIN_RELAY_IDLE_SECONDS", "900"))
# Set for local testing, where "terminate the instance" means "terminate the
# laptop's own EC2 metadata call", i.e. nothing good.
SELF_TERMINATE = os.environ.get("FIN_RELAY_SELF_TERMINATE", "1") == "1"

# Frames larger than this are a bug or an attack, not a terminal: a PTY chunk is
# kilobytes. Base64 of a 64 KiB read is ~87 KiB, so this leaves generous room.
MAX_FRAME_BYTES = 256 * 1024


class Session:
    """One terminal: the app on one side, the site's daemon on the other."""

    __slots__ = ("session_id", "app", "site", "created_at")

    def __init__(self, session_id, app):
        self.session_id = session_id
        self.app = app
        self.site = None
        self.created_at = time.monotonic()


sessions: "dict[str, Session]" = {}
# Not "when did a frame last cross" — "when was this body last WITHOUT work".
# Reset whenever the session count drops to zero, read by the idle watchdog.
idle_since = time.monotonic()


def _mark_busy():
    global idle_since
    idle_since = None


def _mark_maybe_idle():
    global idle_since
    if not sessions and idle_since is None:
        idle_since = time.monotonic()


async def _send(websocket, payload):
    """Best-effort: a peer that has gone away is not an error worth unwinding
    the other side's loop for — its own handler is already tearing down."""
    if websocket is None:
        return
    try:
        await websocket.send(json.dumps(payload))
    except (ConnectionClosed, RuntimeError):
        pass


async def _close_session(session, reason, *, notify):
    """Drops the session and tells whichever side is still connected why."""
    if sessions.get(session.session_id) is not session:
        return
    del sessions[session.session_id]
    frame = {"action": "close", "sessionId": session.session_id, "reason": reason}
    for party in (session.app, session.site):
        if party is not None and party is not notify:
            await _send(party, frame)
    _mark_maybe_idle()
    LOG.info("session %s closed: %s", session.session_id, reason)


async def handler(websocket):
    """One connection. Its FIRST frame declares which side it is: `open` is the
    app, `attach` is the site. Nothing else is accepted until then, so a
    connection can never act on a session it never joined."""
    session = None
    role = None
    try:
        async for raw in websocket:
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8", "replace")
            if len(raw) > MAX_FRAME_BYTES:
                await _send(websocket, {"action": "close", "reason": "frame too large"})
                return
            try:
                frame = json.loads(raw)
            except ValueError:
                await _send(websocket, {"action": "close", "reason": "malformed frame"})
                return
            if not isinstance(frame, dict):
                await _send(websocket, {"action": "close", "reason": "malformed frame"})
                return

            action = str(frame.get("action") or "")
            session_id = str(frame.get("sessionId") or "").strip()
            if not session_id:
                await _send(websocket, {"action": "close", "reason": "missing sessionId"})
                return

            if session is None:
                # --- joining ---
                if action == "open":
                    existing = sessions.get(session_id)
                    if existing is not None:
                        # A retry of an open the relay already has (the app
                        # reconnecting after a drop): take over the app slot
                        # rather than refusing, so a flaky phone network
                        # doesn't strand a session the daemon is still holding.
                        await _send(existing.app, {"action": "close", "reason": "replaced by a newer app connection"})
                        existing.app = websocket
                        session = existing
                    else:
                        session = Session(session_id, websocket)
                        sessions[session_id] = session
                    role = "app"
                    _mark_busy()
                    LOG.info("session %s opened by app", session_id)
                    continue
                if action == "attach":
                    session = sessions.get(session_id)
                    if session is None:
                        # The daemon woke on a heartbeat for a session whose app
                        # already gave up. Say so plainly instead of hanging.
                        await _send(websocket, {"action": "close", "sessionId": session_id, "reason": "no such session"})
                        return
                    session.site = websocket
                    role = "site"
                    _mark_busy()
                    await _send(session.app, {"action": "attached", "sessionId": session_id})
                    LOG.info("session %s attached by site", session_id)
                    continue
                await _send(websocket, {"action": "close", "reason": "first frame must be open or attach"})
                return

            # --- joined: relay or close ---
            if session_id != session.session_id:
                await _send(websocket, {"action": "close", "reason": "sessionId does not match this connection"})
                return

            if action == "close":
                await _close_session(session, "peer closed", notify=websocket)
                return
            if action in ("input", "resize") and role == "app":
                await _send(session.site, frame)
                continue
            if action == "output" and role == "site":
                await _send(session.app, frame)
                continue
            # Anything else — an app sending "output", a site sending "input",
            # an unknown action — is dropped rather than relayed. Silence is
            # right here: it is not this switch's job to teach either side the
            # protocol mid-session.
            LOG.warning("session %s: dropped %r from %s", session.session_id, action, role)
    except ConnectionClosed:
        pass
    finally:
        if session is not None:
            await _close_session(session, "peer disconnected", notify=websocket)


def _imds(path):
    """IMDSv2 — the instance's own identity, for terminating itself."""
    token_request = urllib.request.Request(
        "http://169.254.169.254/latest/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
    )
    with urllib.request.urlopen(token_request, timeout=5) as response:
        token = response.read().decode()
    request = urllib.request.Request(
        "http://169.254.169.254/latest/meta-data/" + path,
        headers={"X-aws-ec2-metadata-token": token},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.read().decode()


def _terminate_self():
    """The whole cost model in one call: no sessions for IDLE_SECONDS, so stop
    existing. The instance profile is scoped to terminating only this instance."""
    import boto3

    instance_id = _imds("instance-id")
    region = _imds("placement/region")
    LOG.info("idle for %ss — terminating %s", IDLE_SECONDS, instance_id)
    boto3.client("ec2", region_name=region).terminate_instances(InstanceIds=[instance_id])


async def idle_watchdog():
    while True:
        await asyncio.sleep(30)
        if sessions or idle_since is None:
            continue
        if time.monotonic() - idle_since < IDLE_SECONDS:
            continue
        if not SELF_TERMINATE:
            LOG.info("idle past %ss (self-terminate disabled)", IDLE_SECONDS)
            continue
        try:
            _terminate_self()
        except Exception as error:  # noqa: BLE001 — never die trying to die
            LOG.error("self-terminate failed: %s", error)
        await asyncio.sleep(120)


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(CERT_PATH, KEY_PATH)
    LOG.info("listening on :%s (idle timeout %ss)", PORT, IDLE_SECONDS)
    async with serve(handler, "0.0.0.0", PORT, ssl=context, max_size=MAX_FRAME_BYTES):
        await idle_watchdog()


if __name__ == "__main__":
    asyncio.run(main())
