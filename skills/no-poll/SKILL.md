---
name: no-poll
description: Waiting for long-running tasks without polling. Use when a task will take more than about a minute -- rendering, queuing, image/video generation, remote jobs. Covers the event-driven ComfyUI waiter, HTTP and file waiting, the three-state exit contract, and how to write an adapter for your own software. Triggers include waiting for a render, checking whether a queued job finished, long tasks, async jobs, progress.
---

# Long tasks: do not poll

> **The rule itself is already always on** -- the `dsh-no-poll` plugin injects it into
> your system prompt. This skill is the **detail you load when you need it**: parameter
> reference, exit semantics, and how to write an adapter.

## One line

**For anything longer than about a minute, do not repeatedly call tools to ask "is it done
yet?"** Let a background process wait; the host wakes you when it exits.
**Turns spent waiting = 0.**

## First: do you even need a waiter?

```
Command-line program (ffmpeg / blender -b / a build / training)
   -> NO waiter. Just run_in_background it.

"Submit -> queue -> finishes asynchronously" software
(ComfyUI / render farms / cloud queues)
   -> yes, a waiter. The task is not in your process tree, so you cannot wait() on it.
```

**Most cases are the first kind.** Do not build machinery you do not need.

## The three-state contract

```
0  DONE      the system explicitly reported success
1  FAILED    the system explicitly reported failure,
             OR it was unreachable after retries
(no exit)    WAITING -- the process blocks. This is the normal state.
```

**There is no timeout and no give-up path.** A queued or slow or apparently stuck task is
still waited on.

**FAILED is strict**: only an explicit upstream verdict, or total unreachability after
retries. Never from slowness, a queue position, or a single failed query.

The last stdout line is machine-readable: `DONE<TAB>137.9s, 1 output node(s)`.

## The waiters

| Script | Event-driven | Requirement |
|---|---|---|
| `waiters/wait.py` | yes (preferred) | Python 3, no packages |
| `waiters/wait.ps1` | yes | PowerShell 7, uses .NET ClientWebSocket |
| `waiters/wait.sh` | yes (pure bash, /dev/tcp) | bash with /dev/tcp |

Identical subcommands, argument names, exit codes and output format.

```
wait.py comfyui --prompt-id ID --client-id CID [--host H] [--port P] [--poll]
wait.py http    --url URL [--until REGEX]
wait.py file    --path P [--until-match REGEX]
wait.py probe   --url URL [--expect REGEX]
```

## Two traps that matter most

### 1. ComfyUI needs the `client_id` from submission

Its execution events are sent **directed** at the submitting client
(see `execution.py`: `server.send_sync("executing", {...}, server.client_id)`).

With a random id you get a clean handshake and broadcast `status` messages, but
**not one** `execution_*` event. Both ids come from the submit call:

```
run_workflow(wait=false)  ->  { "prompt_id": "...", "client_id": "..." }
```

### 2. Silence is not failure

Do **not** call `job status` / `job cancel`, and do not send an interrupt upstream, just to
check on the task. **That is what kills it.** You will be notified when it ends, whether it
succeeded or failed.

## The standard call sequence

```
1. Submit the task (wait=false), take the id, return immediately
2. run_in_background: <waiter> ...
3. End your turn -- really stop, do not rephrase the question
4. The host wakes you when the job exits. Read the last line and continue.
```

## Troubleshooting

| Symptom | Check first |
|---|---|
| No events at all | `python tests/probe-ws.py 12` for connectivity; then confirm the `client_id` is the one from submission |
| Returns DONE immediately | Normal -- the race guard found the job already finished (the last line says so) |
| Nothing happens for a long time | `curl -s <host>/queue` and see whether it is `running` or `pending`. **Pending means it has not started; no events is correct** |
| Queues forever | If the `queue_running` entry already produced output, it is a stale phantom: `curl -X POST <host>/interrupt` |

## Writing an adapter for your own software

Three questions are enough:

```
1. SUBMIT  How do you start it, and what id comes back?
2. FINISH  Is there an event stream? (yes -> block on it; no -> poll a status endpoint)
3. VERDICT How do you distinguish success / failure / still-running? -> DONE / FAILED / keep waiting
```

**An AI can write it for you** -- see `examples/add-your-own.md`, which has a paste-ready
prompt template and a skeleton.

For full parameter reference, internal behaviour and the behaviour contract, see
`MANUAL.md` in the repository root.
