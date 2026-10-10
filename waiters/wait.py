#!/usr/bin/env python3
"""
dsh-no-poll waiter (Python, cross-platform, zero third-party dependencies).

WHY THIS EXISTS
    Waiting for a long task should not be the model's job.
        BAD  : the model repeatedly asks "is it done yet?" -- every ask costs a full
               round trip plus context, and the task does not finish any sooner.
        GOOD : a background process waits; when it exits, the host wakes the model.
               Model turns spent waiting = 0.

EXIT CONTRACT -- THREE STATES, NOTHING ELSE
    0  DONE      the system explicitly reported success
    1  FAILED    the system explicitly reported failure,
                 OR the system was unreachable after retries were exhausted
    (no exit)    WAITING -- the process blocks. This is the normal, expected state.

    There is no timeout and no giving up. A task that is queued, slow, or apparently
    stuck is still waited on. Do not kill this process to "check" on the task --
    that is what kills the task.

    FAILED is deliberately STRICT. It is reported only when the upstream system
    itself says the task failed, or when the system cannot be reached at all after
    retries. A slow task, a queued task, or a task missing from history is never
    reported as failed -- it is waited on.

MACHINE-READABLE OUTPUT
    The LAST line on stdout is:  <TAG>\t<detail>
    Progress goes to stderr and can be silenced with --quiet.

USAGE
    wait.py comfyui --prompt-id ID --client-id CID [--host H] [--port P] [--poll]
    wait.py http    --url URL [--until REGEX]
    wait.py file    --path P [--until-match REGEX]
    wait.py probe   --url URL [--expect REGEX]

WHY comfyui NEEDS TWO IDS
    ComfyUI sends execution events DIRECTED at the client that submitted the job
    (see execution.py: server.send_sync("executing", {...}, server.client_id)).
    Connect with a random client id and you get a successful handshake, broadcast
    status messages, and ZERO execution events. Always pass the client_id returned
    when the job was submitted.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import struct
import sys
import time
import urllib.error
import urllib.request

# Force UTF-8 on stdout/stderr. Windows consoles default to a legacy code page and
# would otherwise mangle any non-ASCII detail text.
for _stream in ("stdout", "stderr"):
    try:
        getattr(sys, _stream).reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

DONE, FAILED = 0, 1


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def emit(code, tag, detail="", quiet=False, machine=None):
    """Print the human line to stderr, the machine line to stdout, then exit.

    `machine` overrides what goes on the machine-readable last line. Network errors
    carry OS-localised text (a Chinese Windows reports Chinese), and the last line is
    meant to be parsed -- so callers pass a stable ASCII detail there while the
    localised message stays on stderr for the human.
    """
    if not quiet:
        print(f"  [{tag}] {detail}".rstrip(), file=sys.stderr)
    print(f"{tag}\t{machine if machine is not None else detail}")
    sys.exit(code)


def say(msg, quiet=False):
    if not quiet:
        print(msg, file=sys.stderr, flush=True)


def now():
    return time.monotonic()


# ---------------------------------------------------------------------------
# Minimal WebSocket client
#
# Python's standard library has no WebSocket client. Requiring `pip install
# websockets` would be a real adoption cost for a waiter, so we implement only
# what a waiter needs: handshake, read text frames, close. Handles fragmentation,
# ping/pong and close frames; ignores binary frames.
# ---------------------------------------------------------------------------

class MiniWS:
    def __init__(self, host, port, path, timeout=10.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.sock.sendall(request.encode())

        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed during handshake")
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if "101" not in status:
            raise ConnectionError(f"websocket handshake failed: {status}")

        expected = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        if expected.lower().encode() not in head.lower():
            raise ConnectionError("websocket handshake failed: Sec-WebSocket-Accept mismatch")

        self._buf = rest
        self._frag = bytearray()

    def _read_exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv_text(self):
        """Read one complete text message. Returns None for ignored frames."""
        while True:
            b1, b2 = self._read_exact(2)
            fin = b1 & 0x80
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            payload = self._read_exact(length) if length else b""
            if mask:
                payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))

            if opcode == 0x8:
                raise ConnectionError("peer closed the connection")
            if opcode == 0x9:
                self._send(0xA, payload)
                continue
            if opcode == 0xA:
                continue

            self._frag += payload
            if not fin:
                continue
            message = bytes(self._frag)
            self._frag.clear()
            if opcode == 0x1:
                return message.decode("utf-8", errors="replace")
            continue

    def _send(self, opcode, payload):
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        masked = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def close(self):
        try:
            self._send(0x8, b"")
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def http_json(url, timeout=10.0):
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def http_text(url, timeout=10.0):
    request = urllib.request.Request(url)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


# ---------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------

def cmd_probe(args):
    try:
        body = http_text(args.url, args.timeout or 10)
        ok = re.search(args.expect, body) is not None if args.expect else True
        if ok:
            emit(DONE, "DONE", f"{args.url} ({len(body)} chars)", args.quiet)
        emit(FAILED, "FAILED", f"{args.url} did not match {args.expect}", args.quiet)
    except Exception as exc:
        # The OS message is localised; keep it on stderr and put a stable ASCII
        # detail on the machine-readable last line.
        emit(FAILED, "FAILED", f"unreachable: {type(exc).__name__}: {exc}", args.quiet,
             machine=f"unreachable: {args.url}")


# ---------------------------------------------------------------------------
# http
# ---------------------------------------------------------------------------

def cmd_http(args):
    """Poll a URL until the body matches, or until any response arrives."""
    pattern = re.compile(args.until) if args.until else None
    start = now()
    consecutive_failures = 0

    while True:
        try:
            body = http_text(args.url, args.request_timeout)
            consecutive_failures = 0
            if pattern is None or pattern.search(body):
                emit(DONE, "DONE", f"{args.url} matched after {now() - start:.1f}s", args.quiet)
            say(f"  ... {now() - start:.0f}s, not matched yet")
        except urllib.error.HTTPError as exc:
            # A 404 commonly means "not generated yet" -- a normal state while waiting.
            consecutive_failures = 0
            say(f"  ... {now() - start:.0f}s, HTTP {exc.code}")
        except Exception as exc:
            consecutive_failures += 1
            say(f"  ... {now() - start:.0f}s, request failed ({type(exc).__name__})")
            if consecutive_failures > args.conn_retries:
                emit(FAILED, "FAILED",
                     f"unreachable after {consecutive_failures} attempts: {type(exc).__name__}: {exc}",
                     args.quiet,
                     machine=f"unreachable: {args.url} ({consecutive_failures} attempts)")
        time.sleep(args.interval)


# ---------------------------------------------------------------------------
# file
# ---------------------------------------------------------------------------

def cmd_file(args):
    pattern = re.compile(args.until_match) if args.until_match else None
    start = now()
    while True:
        if os.path.exists(args.path):
            if pattern is None:
                emit(DONE, "DONE", f"{args.path} appeared after {now() - start:.1f}s", args.quiet)
            try:
                with open(args.path, "r", encoding="utf-8", errors="replace") as handle:
                    body = handle.read()
                if pattern.search(body):
                    emit(DONE, "DONE", f"{args.path} matched after {now() - start:.1f}s", args.quiet)
            except Exception:
                pass
        time.sleep(args.interval)


# ---------------------------------------------------------------------------
# comfyui
# ---------------------------------------------------------------------------

def comfy_history(base, prompt_id, timeout):
    """Query history. Returns a THREE-STATE result, which must not be collapsed.

        (True,  entry)  query succeeded and the job is present
        (False, None)   query succeeded and the job is genuinely absent
        (None,  None)   the QUERY ITSELF FAILED (network, server restarting)

    The third case does not mean the job is gone. Treating it as "absent" is how
    a running task gets declared dead -- and that is exactly what this waiter
    must never do.
    """
    try:
        history = http_json(f"{base}/history/{prompt_id}", timeout)
    except Exception:
        return (None, None)
    if isinstance(history, dict) and prompt_id in history:
        return (True, history[prompt_id])
    return (False, None)


def comfy_in_queue(base, prompt_id, timeout):
    """Is the job queued? True means it is definitely still alive.
    Returns True / False / None (None = the queue query itself failed)."""
    try:
        queue = http_json(f"{base}/queue", timeout)
    except Exception:
        return None
    for key in ("queue_running", "queue_pending"):
        for item in (queue.get(key) or []):
            if isinstance(item, (list, tuple)) and len(item) > 1 and item[1] == prompt_id:
                return True
            if isinstance(item, dict) and item.get("prompt_id") == prompt_id:
                return True
    return False


def comfy_entry_outputs(entry, limit=6):
    """Extract (number_of_output_nodes, [filenames]) from a history entry."""
    outputs = entry.get("outputs") or {}
    if not isinstance(outputs, dict):
        return (0, [])
    files = []
    for node_output in outputs.values():
        if not isinstance(node_output, dict):
            continue
        for items in node_output.values():
            if not isinstance(items, list):
                continue
            for item in items:
                if isinstance(item, dict) and item.get("filename"):
                    files.append(str(item["filename"]))
    return (len(outputs), files[:limit] if limit else files)


def comfy_outcome_detail(entry, elapsed, fallback_nodes=None):
    """Compose the DONE detail from an entry already in hand.

    History is the authoritative list of outputs: it names every output node and the
    files each produced. A workflow with several SaveImage nodes is only described
    correctly here -- counting `executed` events gives a number, not the filenames the
    caller actually needs next.
    """
    if not isinstance(entry, dict):
        if fallback_nodes is not None:
            return f"{elapsed}s, {fallback_nodes} output event(s)"
        return f"{elapsed}s"
    count, files = comfy_entry_outputs(entry)
    detail = f"{elapsed}s, {count} output node(s)"
    if files:
        detail += ": " + ", ".join(files)
    return detail


def comfy_judge(entry):
    """Map a history entry to an outcome, or None while it is still running.

    STRICT: FAILED is reported only when ComfyUI itself says so. Anything else
    means keep waiting -- a slow job must never be mistaken for a failed one.
    """
    status = entry.get("status") or {}
    status_str = status.get("status_str")

    if status.get("completed") is True:
        # ComfyUI reports completion. Distinguish an actual error string.
        if status_str and status_str != "success":
            return ("FAILED", FAILED, str(status_str))
        count, files = comfy_entry_outputs(entry)
        detail = f"{count} output node(s)"
        if files:
            detail += ": " + ", ".join(files)
        return ("DONE", DONE, detail)

    # Not completed. Only an explicit error status counts as failure.
    if status_str in ("error", "failed"):
        return ("FAILED", FAILED, str(status_str))

    return None


def comfy_done_detail(base, prompt_id, timeout, elapsed, fallback_nodes=None):
    """Build the DONE detail when we do NOT already hold the history entry."""
    found, entry = comfy_history(base, prompt_id, timeout)
    if not found:
        if fallback_nodes is not None:
            return f"{elapsed}s, {fallback_nodes} output event(s)"
        return f"{elapsed}s"
    return comfy_outcome_detail(entry, elapsed, fallback_nodes)


def comfy_poll(args, base, start, reason):
    """Fallback: poll /history INSIDE THIS PROCESS.

    Still far better than making the model poll -- the model spends zero turns.
    """
    say(f"  (polling /history in-process: {reason})", args.quiet)
    consecutive_query_failures = 0
    while True:
        found, entry = comfy_history(base, args.prompt_id, args.request_timeout)
        if found:
            consecutive_query_failures = 0
            verdict = comfy_judge(entry)
            if verdict:
                tag, code, detail = verdict
                emit(code, tag, f"{detail} (polled, {now() - start:.1f}s)", args.quiet)
        elif found is None:
            # The query failed. This is "could not ask", not "it is gone".
            consecutive_query_failures += 1
            say(f"  ... {now() - start:.0f}s, query failed "
                f"({consecutive_query_failures}/{args.conn_retries + 1})")
            if consecutive_query_failures > args.conn_retries:
                emit(FAILED, "FAILED",
                     f"could not reach {base} after {consecutive_query_failures} attempts "
                     f"(waited {now() - start:.0f}s)", args.quiet,
                     machine=f"unreachable: {base} ({consecutive_query_failures} attempts)")
            time.sleep(args.conn_retry_delay)
            continue
        else:
            # Query succeeded but the job is absent -- check the queue before drawing
            # any conclusion: a queued job has not reached history yet.
            consecutive_query_failures = 0
            in_queue = comfy_in_queue(base, args.prompt_id, args.request_timeout)
            if in_queue is True:
                say(f"  ... {now() - start:.0f}s, still queued")
            elif in_queue is None:
                pass
            else:
                # Absent from both history and queue. Keep waiting: history can be
                # cleared, and this waiter's contract is to wait, not to give up.
                # There is deliberately no "give up" branch -- a task must never be
                # declared dead by this process.
                say(f"  ... {now() - start:.0f}s, not in history or queue (still waiting)")
        time.sleep(args.interval)


def comfy_connect(args):
    """Connect the WebSocket, retrying on failure. Raises after retries are spent."""
    last = None
    for attempt in range(args.conn_retries + 1):
        try:
            return MiniWS(args.host, args.port, f"/ws?clientId={args.client_id}",
                          args.request_timeout)
        except Exception as exc:
            last = exc
            if attempt < args.conn_retries:
                say(f"  connection attempt {attempt + 1}/{args.conn_retries + 1} failed "
                    f"({type(exc).__name__}); retrying in {args.conn_retry_delay:.0f}s")
                time.sleep(args.conn_retry_delay)
    raise last


def cmd_comfyui(args):
    base = f"http://{args.host}:{args.port}"
    start = now()

    # Race guard, not polling. The job can finish between "submitted" and
    # "connected"; without this check a short job is waited on forever.
    found, entry = comfy_history(base, args.prompt_id, args.request_timeout)
    if found:
        verdict = comfy_judge(entry)
        if verdict:
            tag, code, detail = verdict
            emit(code, tag, f"{detail} (finished before we connected, {now() - start:.1f}s)",
                 args.quiet)

    if args.poll or not args.client_id:
        if not args.client_id and not args.quiet:
            say("  note: no --client-id given. ComfyUI directs execution events at the")
            say("        submitting client, so a random id receives none. Polling instead.")
        return comfy_poll(args, base, start, "no client id")

    try:
        ws = comfy_connect(args)
    except Exception as exc:
        return comfy_poll(args, base, start,
                          f"websocket unreachable: {type(exc).__name__}: {exc}")

    say(f"waiting for ComfyUI job {args.prompt_id} (event-driven)")
    say("  (silence is normal. A queued, slow or apparently stuck job is still waited on.)")

    nodes = 0
    try:
        while True:
            try:
                raw = ws.recv_text()
            except socket.timeout:
                continue
            if raw is None:
                continue
            try:
                message = json.loads(raw)
            except Exception:
                continue

            kind = message.get("type")
            data = message.get("data") or {}
            pid = data.get("prompt_id")
            # Some events carry no prompt_id. Only skip when it is present AND different.
            if pid and pid != args.prompt_id:
                continue

            if kind == "execution_start":
                say("   > started")
            elif kind == "progress":
                value, maximum = data.get("value"), data.get("max")
                if value and maximum and value % max(1, maximum // 5) == 0:
                    say(f"   ... {value}/{maximum}")
            elif kind == "executed":
                out = data.get("output") or data.get("outputs") or {}
                nodes += len(out) if isinstance(out, dict) else 0
            elif kind == "executing":
                if data.get("node") is None:
                    ws.close()
                    emit(DONE, "DONE",
                         comfy_done_detail(base, args.prompt_id, args.request_timeout,
                                           f"{now() - start:.1f}", nodes),
                         args.quiet)
            elif kind == "execution_success":
                # ComfyUI's own success verdict -- the exact counterpart of
                # execution_error. Verified to arrive AFTER every `executed` event for a
                # three-output workflow, so treating it as terminal is safe and makes the
                # success path as explicit as the failure path.
                ws.close()
                emit(DONE, "DONE",
                     comfy_done_detail(base, args.prompt_id, args.request_timeout,
                                       f"{now() - start:.1f}", nodes),
                     args.quiet)
            elif kind == "execution_error":
                ws.close()
                message_text = str(data.get("exception_message") or "unspecified error")
                emit(FAILED, "FAILED", message_text, args.quiet)
            elif kind == "execution_interrupted":
                ws.close()
                # An explicit interrupt from ComfyUI is a reported failure.
                emit(FAILED, "FAILED", "execution interrupted", args.quiet)
    except Exception as exc:
        try:
            ws.close()
        except Exception:
            pass
        return comfy_poll(args, base, start, f"event stream ended: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog="wait.py",
        description="dsh-no-poll waiter -- the host wakes the model, the model does not poll.",
        epilog="Exit: 0 DONE, 1 FAILED. Waiting produces no exit at all -- that IS the "
               "point. There is no timeout and no give-up state.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="print only the machine-readable last line")
    sub = parser.add_subparsers(dest="command", required=True)

    def common(sub_parser):
        sub_parser.add_argument("--interval", type=float, default=3.0,
                                help="poll interval in seconds (default 3)")
        sub_parser.add_argument("--request-timeout", type=float, default=10.0,
                                help="per-request timeout in seconds (default 10)")
        sub_parser.add_argument("--conn-retries", type=int, default=2,
                                help="how many times to retry an unreachable system "
                                     "before reporting FAILED (default 2)")
        sub_parser.add_argument("--conn-retry-delay", type=float, default=150.0,
                                help="seconds between connection retries (default 150 = 2.5 min)")
        # Also accepted after the subcommand, not only before it.
        sub_parser.add_argument("-q", "--quiet", action="store_true",
                                default=argparse.SUPPRESS,
                                help="print only the machine-readable last line")

    comfy = sub.add_parser("comfyui", help="wait for a ComfyUI job (event-driven)")
    comfy.add_argument("--prompt-id", required=True, help="prompt_id from the submit call")
    comfy.add_argument("--client-id", default="",
                       help="client_id from the submit call. Required for real events -- "
                            "ComfyUI directs execution events at the submitting client.")
    comfy.add_argument("--host", default="127.0.0.1")
    comfy.add_argument("--port", type=int, default=8188)
    comfy.add_argument("--poll", action="store_true",
                       help="skip the websocket and poll /history instead")
    common(comfy)
    comfy.set_defaults(func=cmd_comfyui)

    http_cmd = sub.add_parser("http", help="poll a URL until it matches")
    http_cmd.add_argument("--url", required=True)
    http_cmd.add_argument("--until", default="",
                          help="regex the body must match; empty = any response counts")
    common(http_cmd)
    http_cmd.set_defaults(func=cmd_http)

    file_cmd = sub.add_parser("file", help="wait for a file to appear or match")
    file_cmd.add_argument("--path", required=True)
    file_cmd.add_argument("--until-match", default="",
                          help="regex the content must match; empty = existence counts")
    common(file_cmd)
    file_cmd.set_defaults(func=cmd_file)

    probe = sub.add_parser("probe", help="one-shot check, does not wait")
    probe.add_argument("--url", required=True)
    probe.add_argument("--expect", default="")
    probe.add_argument("--timeout", type=float, default=10)
    # Accept -q here too: users type it after the subcommand, not just before it.
    probe.add_argument("-q", "--quiet", action="store_true", default=argparse.SUPPRESS,
                       help="print only the machine-readable last line")
    probe.set_defaults(func=cmd_probe)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    for name, default in (("interval", 3.0), ("quiet", False), ("conn_retries", 2),
                          ("conn_retry_delay", 150.0), ("request_timeout", 10.0)):
        if not hasattr(args, name):
            setattr(args, name, default)
    try:
        args.func(args)
    except KeyboardInterrupt:
        # The operator killed this process. That is not a verdict about the task,
        # and it is not a "failure" produced by the system -- but the process has
        # to exit, so report it plainly rather than inventing a task outcome.
        emit(FAILED, "FAILED", "stopped by operator (the task itself was not judged)",
             getattr(args, "quiet", False))
    except Exception as exc:
        emit(FAILED, "FAILED", f"{type(exc).__name__}: {exc}", getattr(args, "quiet", False))


if __name__ == "__main__":
    main()
