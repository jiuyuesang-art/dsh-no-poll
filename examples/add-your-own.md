# Adapting your own software

**The real value of this repo is not the three scripts -- it is the pattern.**
Adding an adapter for your own software usually means answering three questions.

---

## The three questions

```
1. SUBMIT  How do you start the task, and what id comes back?
2. FINISH  Is there an event stream?
             yes -> block on it (best)
             no  -> poll a status endpoint (acceptable)
3. VERDICT How do you tell success / failure / still-running apart?
             -> map to DONE / FAILED / (keep waiting)
```

**First check whether you can skip it entirely.**
If the software is a **command-line program**, you do not need an adapter at all --
`run_in_background` it and you are done. Only "submit -> queue -> finish asynchronously"
software needs a waiter, because the task is not in your process tree.

---

## Let an AI write it for you

Paste this, with the angle-bracket parts filled in:

````text
I need a dsh-no-poll waiter adapter for <software name>.

How its interface works:
- Submit a task: <how? HTTP endpoint / MCP tool / CLI? what does it return?>
- What the task id looks like: <e.g. a UUID>
- Completion signal: <is there a WebSocket / SSE / event stream? what URL?
                      what event names? if not, is there a status endpoint to poll?>
- What success / failure / still-running each look like: <give examples>

Write it following the existing dsh-no-poll conventions:
1. Reuse the structure of waiters/wait.py (same subcommand style, same emit() output)
2. Exit codes must be exactly 0 DONE / 1 FAILED -- and NO exit while waiting
3. The last stdout line must be machine-readable: `TAG\t detail`
4. Include a race guard: query the current state once BEFORE connecting to the event
   stream, because the task may finish between submit and connect
5. If the event stream cannot be reached or breaks, fall back to polling AND SAY SO
   (never degrade silently)
6. FAILED must be strict: only when the upstream system explicitly reports failure,
   or when it is completely unreachable after retries. Never guess failure from
   slowness, a queue position, or a single failed query.
7. No timeouts and no give-up path anywhere
8. Show me how to test it -- especially how to produce a genuine FAILED case

Reference implementations: examples/comfyui.md (event-driven) and
examples/blender.md (command-line, needs no waiter).
````

---

## Adapter skeleton

```python
def cmd_yoursoft(args):
    base = f"http://{args.host}:{args.port}"
    start = now()

    # 1. Race guard -- not polling, a single check.
    #    The task may finish between "submitted" and "connected"; without this the
    #    waiter can block forever on a task that is already done.
    state = probe_status(base, args.job_id)
    if state is not None:
        verdict = judge(state)
        if verdict:
            emit(verdict[1], verdict[0], f"{verdict[2]} (finished before we connected)")

    # 2. Event stream -> block on it
    if has_event_stream and not args.poll:
        ws = connect_with_retries(args)          # raises after retries are spent
        while True:
            event = json.loads(ws.recv_text())   # blocks; waits for the server to push
            kind = event.get("type")
            if kind == "finished":
                emit(DONE, "DONE", f"{now() - start:.1f}s")
            elif kind == "failed":
                emit(FAILED, "FAILED", str(event.get("error")))
            # anything else -> keep waiting

    # 3. No event stream -> poll INSIDE THIS PROCESS
    return poll_loop(args, base, start)


def poll_loop(args, base, start):
    query_failures = 0
    while True:
        state = probe_status(base, args.job_id)   # returns None when the QUERY failed
        if state is None:
            query_failures += 1
            if query_failures > args.conn_retries:
                emit(FAILED, "FAILED", f"could not reach {base}")
            time.sleep(args.conn_retry_delay)
            continue
        query_failures = 0
        verdict = judge(state)
        if verdict:
            emit(verdict[1], verdict[0], verdict[2])
        time.sleep(args.interval)                 # no exit: still waiting


def judge(state):
    """Map the software's state to an outcome, or None while it is still running.

    This function is the heart of an adapter. It must keep three cases apart:

        still running -> None
        succeeded     -> ("DONE",   0, "...")
        failed        -> ("FAILED", 1, "...")

    FAILED must be STRICT. Only return it when the upstream system actually says so.
    """
    if state.get("state") == "running":
        return None
    if state.get("state") == "done":
        return ("DONE", 0, f"{state.get('outputs', 0)} output(s)")
    if state.get("state") == "error":
        return ("FAILED", 1, str(state.get("message") or "unspecified error"))
    return None
```

---

## Four contracts you must not break

| Contract | Why |
|---|---|
| **Exactly three states** | A timeout or give-up state invites the model to interrupt a running task |
| **FAILED only on an explicit verdict** | Guessing failure destroys completed work and causes pointless resubmits |
| **A failed query is not an absent task** | "I could not ask" and "it is gone" are different facts; conflating them kills running jobs |
| **A race guard is mandatory** | Without it, short tasks hang the waiter forever -- and only intermittently, which is the worst kind of bug |

---

## How to test your adapter

**Do not test only the happy path.** All outcomes must be reproducible:

```bash
# DONE -- run a normal task
python waiters/wait.py yoursoft --job-id <id>

# FAILED (upstream verdict) -- deliberately submit a task that will fail
python waiters/wait.py yoursoft --job-id <an-id-that-fails>

# FAILED (unreachable) -- point it at a port nobody listens on
python waiters/wait.py yoursoft --job-id <id> --port 1 --conn-retries 1 --conn-retry-delay 2

# WAITING -- use a bad id against a live service; it must NOT exit
python waiters/wait.py yoursoft --job-id does-not-exist
```

**Verify the exit code:**

```bash
python waiters/wait.py yoursoft --job-id "$ID" -q; echo "exit=$?"
```

**Verify the race guard**: run a task to completion, then wait on its id. It should return
`DONE ... (finished before we connected)` **immediately**, not hang.

That last one is the easiest to skip and the only defence against the "short tasks hang
forever" bug.

---

## And remember: you may not need an adapter at all

Ask first: **is this a command-line program?**

```
blender -b scene.blend -f 1-250     -> run_in_background it
ffmpeg -i in.mp4 out.mp4            -> run_in_background it
python train.py                     -> run_in_background it
```

Their lifetime is inside your process tree, so the host already knows when they exit.
Writing a waiter for them is **extra work for nothing**.

Only "submit it somewhere else and it finishes later" software needs a waiter -- because
**you cannot `wait` on something that is not in your hands.**
