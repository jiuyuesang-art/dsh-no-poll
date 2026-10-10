#!/usr/bin/env python3
"""Dump every WebSocket frame for one ComfyUI job, in order, with timestamps.

Used to verify how a multi-output workflow signals completion: how many `executed`
events arrive, in what order, and relative to the final `executing {node: null}`.

    python tests/dump-frames.py <clientId> <promptId> [seconds]
"""
import importlib.util
import json
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("waitmod", HERE.parent / "waiters" / "wait.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

CLIENT_ID = sys.argv[1]
PROMPT_ID = sys.argv[2]
SECONDS = float(sys.argv[3]) if len(sys.argv) > 3 else 300

WS = MOD.MiniWS("127.0.0.1", 8188, f"/ws?clientId={CLIENT_ID}", 5.0)
print(f"connected  clientId={CLIENT_ID}", file=sys.stderr)
print(f"watching   promptId={PROMPT_ID}", file=sys.stderr)

START = time.monotonic()
EXECUTED = 0
N = 0

while time.monotonic() - START < SECONDS:
    try:
        RAW = WS.recv_text()
    except Exception as EXC:
        print(f"  recv error: {type(EXC).__name__}: {EXC}", file=sys.stderr)
        continue
    if RAW is None:
        continue
    try:
        MSG = json.loads(RAW)
    except Exception:
        continue

    KIND = MSG.get("type")
    DATA = MSG.get("data") or {}
    PID = DATA.get("prompt_id")
    if PID and PID != PROMPT_ID:
        continue

    ELAPSED = time.monotonic() - START
    N += 1

    if KIND == "executed":
        EXECUTED += 1
        NODE = DATA.get("node")
        OUT = DATA.get("output") or DATA.get("outputs") or {}
        KEYS = ",".join(OUT.keys()) if isinstance(OUT, dict) else "?"
        IMGS = []
        if isinstance(OUT, dict):
            for VAL in OUT.values():
                if isinstance(VAL, dict) and isinstance(VAL.get("images"), list):
                    for IM in VAL["images"]:
                        IMGS.append(IM.get("filename"))
        print(f"  [{ELAPSED:6.1f}s] #{N:3d} executed          node={NODE} output_keys=[{KEYS}] files={IMGS}")

    elif KIND == "executing":
        NODE = DATA.get("node")
        if NODE is None:
            print(f"  [{ELAPSED:6.1f}s] #{N:3d} executing         node=NULL  <-- RUN END")
            print(f"  RESUMING: all {EXECUTED} 'executed' event(s) arrived before the end marker")
            break
        print(f"  [{ELAPSED:6.1f}s] #{N:3d} executing         node={NODE}")

    elif KIND == "progress":
        print(f"  [{ELAPSED:6.1f}s] #{N:3d} progress          {DATA.get('value')}/{DATA.get('max')}")

    elif KIND == "execution_start":
        print(f"  [{ELAPSED:6.1f}s] #{N:3d} execution_start")

    elif KIND in ("execution_error", "execution_interrupted"):
        print(f"  [{ELAPSED:6.1f}s] #{N:3d} {KIND}  {DATA.get('exception_message')}")
        break

    elif KIND == "execution_cached":
        print(f"  [{ELAPSED:6.1f}s] #{N:3d} execution_cached  nodes={DATA.get('nodes')}")

    else:
        print(f"  [{ELAPSED:6.1f}s] #{N:3d} {KIND}")

WS.close()
print(f"total frames: {N}, executed events: {EXECUTED}", file=sys.stderr)
