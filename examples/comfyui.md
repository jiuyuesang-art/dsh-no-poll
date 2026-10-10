# Example: ComfyUI (the event-driven adapter)

**This is the hardest kind of adapter**, because it runs into three traps. Understand it
and every other piece of software becomes easy.

---

## Why ComfyUI is special

```
Ordinary async software:  submit -> poll /status -> done
ComfyUI:                  submit -> EVENTS ARE DIRECTED, so a wrong id means silence
                                  -> and the job can finish before you connect
```

---

## Trap 1: execution events are DIRECTED

From ComfyUI's source, `execution.py`:

```python
server.send_sync("executing", {...}, server.client_id)   # <- third argument
```

That third argument is the target sid, and `server.py` uses it like this:

```python
async def send_json(self, event, data, sid=None):
    ...
    if sid is None:
        for client in self.sockets: ...        # broadcast
    else:
        await self.sockets[sid].send_str(...)  # only to that one client
```

So:

| client id you use | broadcast (`status`) | execution events (`execution_*`) |
|---|---|---|
| the one from submit | yes | **yes** |
| anything else | yes | **not one** |

**What makes this trap nasty**: the handshake succeeds and you see
`{"type":"status", ...}`. Everything looks healthy. You start suspecting your own
WebSocket implementation.

> **Observed during development of this repo**: a job ran for 137 seconds and produced
> output while the listener received **zero** execution events. Switching to the
> submitting `client_id` produced immediate live progress.

**Therefore**: `--client-id` is effectively required. Omitting it degrades to polling,
with a warning.

---

## Trap 2: the job can finish between "submit" and "connect"

```python
# the race window
prompt_id = submit()      # <- the job may already be finished here (short job, cache hit)
ws = connect(client_id)   # <- the events were sent before you connected
```

**Symptom**: short jobs hang the waiter **forever** -- and only intermittently. Long jobs
look fine, which makes it very hard to notice until it bites in production.

**Fix**: query `/history/<id>` once **before** connecting:

```python
found, entry = comfy_history(base, args.prompt_id, args.request_timeout)
if found and comfy_judge(entry):
    tag, code, detail = comfy_judge(entry)
    emit(code, tag, f"{detail} (finished before we connected, {now() - start:.1f}s)")
```

This is **not polling** -- it is a single check. With it, short jobs return the correct
verdict immediately.

---

## Trap 3: the end of a run is `executing` with `node == null`

The event sequence looks roughly like this:

```
execution_start       -> started
execution_cached      -> some nodes were served from cache this run
progress              -> {value, max}
executed              -> a node produced output (field is output / outputs, varies by version)
executing             -> {node: "7"} node 7 is running
executing             -> {node: null}  <- END OF RUN
execution_error       -> failed
execution_interrupted -> interrupted
```

So completion is detected as `type == "executing"` **and** `data.node is None`.

**Also**: the `prompt_id` field may be absent from some events, so the filter must be:

```python
pid = data.get("prompt_id")
if pid and pid != args.prompt_id:   # skip only when present AND different
    continue
```

**Not** `if pid != args.prompt_id: continue` -- that treats `None` as "someone else's
event" and discards it.

---

## A fourth trap that is not yours to fix: phantom queue entries

**Observed in practice**: a job had **already written its output**, yet remained in
`queue_running` indefinitely. Every later job then queued forever, and the waiter saw no
events and eventually looked stuck.

**How to recognise it**:

```bash
curl -s http://127.0.0.1:8188/queue
```

If the entry in `queue_running` has products that already exist on disk, it is a stale
entry.

**Clear it**:

```bash
curl -X POST http://127.0.0.1:8188/interrupt
```

> The adapter **cannot** handle this automatically -- it has no way to tell a phantom from
> a genuinely running job. That is why it lives in the troubleshooting docs (MANUAL.md 6.1).

---

## The full event loop

```python
try:
    ws = connect_with_retries(args)      # retries, then raises
except Exception as exc:
    return comfy_poll(args, base, start, f"websocket unreachable: {exc}")   # announce it

while True:
    try:
        raw = ws.recv_text()             # BLOCKS. Waits for a push, does not ask on a timer.
    except socket.timeout:
        continue                         # quiet period, keep waiting
    message = json.loads(raw)
    kind = message["type"]
    data = message.get("data") or {}
    pid = data.get("prompt_id")
    if pid and pid != args.prompt_id:
        continue                         # another client's job

    if kind == "execution_start":
        say("   > started")
    elif kind == "progress":
        say(f"   ... {data['value']}/{data['max']}")
    elif kind == "executing" and data.get("node") is None:
        ws.close()
        emit(DONE, "DONE", f"{now() - start:.1f}s, {nodes} output node(s)")
    elif kind == "execution_error":
        ws.close()
        emit(FAILED, "FAILED", str(data.get("exception_message")))
    # anything else -> keep waiting. There is no give-up branch.
```

---

## Why not just use `pip install websockets`

To stay dependency-free. A waiter that requires an install step first is measurably
harder to adopt.

Python's standard library has no WebSocket client, so `wait.py` carries a minimal one
(~100 lines): HTTP Upgrade handshake, `Sec-WebSocket-Accept` verification, frame reading
with fragmentation and ping/pong handling.

It does exactly three things: **connect, read text frames, close.** A waiter needs
nothing more.

> If you prefer convenience in your own adapter, using the `websockets` library is fine.
> It is a trade-off: ~100 lines of code versus an installation step.

---

## Measured result

```
waiting for ComfyUI job b2794a88-... (event-driven)
   ... 5/25
   ... 10/25
   ... 15/25
   ... 20/25
   ... 25/25
  [DONE] 137.9s, 1 output node(s)
```

Both the Python and PowerShell implementations were verified against a live ComfyUI 0.37.0.

---

## Calling it

```bash
# Python (cross-platform, event-driven)
python waiters/wait.py comfyui --prompt-id <ID> --client-id <CID>

# PowerShell (Windows, event-driven)
./waiters/wait.ps1 comfyui -PromptId <ID> -ClientId <CID>

# Bash (also event-driven -- pure bash, via /dev/tcp)
bash waiters/wait.sh comfyui --prompt-id <ID>
```

**Where the two ids come from** (DSH + ComfyUI MCP):

```
run_workflow(wait=false)  ->  { "prompt_id": "...", "client_id": "..." }
```
