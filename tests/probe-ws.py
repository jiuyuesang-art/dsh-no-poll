#!/usr/bin/env python3
"""WebSocket connectivity probe for dsh-no-poll.

Isolates the two reasons a waiter can see no events:

  1. The WebSocket handshake or frame parsing is broken.
  2. The handshake works but the job is not actually executing (queued behind
     another job, or never started).

This script answers only (1). It connects, prints every raw message it receives
for N seconds, and exits.

    python tests/probe-ws.py [seconds] [clientId]

Exit codes:
    0  messages arrived -- connectivity is fine
    3  connected but no messages arrived
    4  the handshake failed -- the service is not reachable / not listening

A healthy run prints a `{"type":"status", ...}` message. Note that `status` is
BROADCAST, so receiving it proves connectivity only -- it does NOT prove that
execution events (which are directed at the submitting client id) will arrive.
"""
import importlib.util
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("waitmod", HERE.parent / "waiters" / "wait.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 12
CLIENT_ID = sys.argv[2] if len(sys.argv) > 2 else f"probe-{int(time.time())}"

print(f"connecting to /ws?clientId={CLIENT_ID}", file=sys.stderr)
try:
    WS = MODULE.MiniWS("127.0.0.1", 8188, f"/ws?clientId={CLIENT_ID}", 5.0)
    print("handshake OK", file=sys.stderr)
except Exception as exc:
    print(f"handshake FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
    raise SystemExit(4)

COUNT = 0
DEADLINE = time.monotonic() + SECONDS
while time.monotonic() < DEADLINE:
    try:
        RAW = WS.recv_text()
    except Exception as exc:
        print(f"receive error: {type(exc).__name__}: {exc}", file=sys.stderr)
        continue
    if RAW is None:
        continue
    COUNT += 1
    PREVIEW = RAW if len(RAW) < 230 else RAW[:230] + "..."
    print(f"  [{COUNT}] {PREVIEW}", file=sys.stderr)

WS.close()
print(f"received {COUNT} message(s)", file=sys.stderr)
raise SystemExit(0 if COUNT else 3)
