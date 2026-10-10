# dsh-no-poll · Manual

**For people using it, and for AI writing code that calls it.**
For the "why", see [README.md](README.md).
Chinese version: [MANUAL.zh-CN.md](MANUAL.zh-CN.md).

---

## 0. Which waiter do I need? (30 seconds)

```
What are you waiting for?
│
├─ A command-line program (ffmpeg / blender -b / a build / a training script)
│    └─ NO waiter from this repo is needed.
│       Start it as a background job (run_in_background in DSH); the host
│       notifies you when it exits.
│
├─ Software that is "submit -> queue -> finish asynchronously"
│  (ComfyUI / render farms / cloud queues)
│    └─ Use a waiter.
│       ├─ Python available        -> waiters/wait.py    (event-driven, preferred)
│       ├─ Windows, no Python      -> waiters/wait.ps1   (event-driven)
│       └─ Only bash               -> waiters/wait.sh    (event-driven too)
│
└─ Your own software
     └─ See examples/add-your-own.md -- an AI can write the adapter for you.
```

**Core principle: the waiter blocks in the background; the model does not wait.**
Turns spent waiting = 0.

---

## 1. Install

### 1.1 Into DSH (so the rule is always active)

```bash
git clone https://github.com/jiuyuesang-art/dsh-no-poll.git
cd dsh-no-poll
```

Then in DSH, say:

> **"Install the plugin bundle `<absolute path to the repo>`"**

Or manually (equivalent):

1. Make the package resolvable by the DSH profile -- put it in `<profile>/node_modules/`, or symlink it there
2. Enable `dsh-no-poll` in DSH's plugin management
3. **Restart DSH**

**Verify**: after restarting, ask the model how it waits for long tasks. It should describe
background jobs and say not to poll.

### 1.2 Waiters only (no plugin)

The waiters are standalone scripts with zero dependencies. Copy them anywhere:

```bash
cp waiters/wait.py /anywhere/
python /anywhere/wait.py comfyui --prompt-id <ID> --client-id <CID>
```

They do not need DSH. But you lose the always-on rule, so you have to remember to use them.

---

## 2. Exit contract -- three states, nothing else

```
0  DONE      the system explicitly reported success
1  FAILED    the system explicitly reported failure,
             OR the system was unreachable after retries were exhausted
(no exit)    WAITING -- the process blocks. This is the normal state.
```

**There is no timeout and no giving up.**
A queued task, a slow task, or one that looks stuck is still waited on.

**FAILED is deliberately strict.** It is reported only when:

- the upstream system itself reports a failure, or
- the system cannot be reached at all after retries (default: 2 retries, 2.5 minutes apart)

It is **never** reported because a task is slow, queued, missing from history,
or because a query failed once.

**Output**

- `stderr`: human-readable progress (`--quiet` / `-Quiet` silences it)
- `stdout` **last line**: machine-readable `TAG<TAB>detail`, e.g. `DONE	137.9s, 1 output node(s)`

```bash
out=$(python waiters/wait.py comfyui --prompt-id "$ID" --client-id "$CID" -q)
code=$?
case $code in
  0) echo "success: ${out#*$'\t'}" ;;
  1) echo "failed: ${out#*$'\t'}" >&2; exit 1 ;;
esac
```

> `code` is 0 or 1. **There is no other case** -- the process only exits when it has
> an actual verdict. While waiting, it does not return at all.

---

## 3. Waiter reference

All three scripts share the same subcommands, argument names (modulo language style),
exit codes and output format.

### 3.1 Common options

| Option | Python | PowerShell | Bash | Default | Meaning |
|---|---|---|---|---|---|
| interval | `--interval` | `-IntervalSeconds` | `--interval` | 3 | seconds between polls |
| request timeout | `--request-timeout` | `-RequestTimeoutSeconds` | `--request-timeout` | 10 | per-request timeout |
| connection retries | `--conn-retries` | `-ConnRetries` | `--conn-retries` | 2 | retries before FAILED |
| retry delay | `--conn-retry-delay` | `-ConnRetryDelaySeconds` | `--conn-retry-delay` | 150 | seconds between retries |
| quiet | `-q`, `--quiet` | `-Quiet` | `-q`, `--quiet` | off | print only the last line |

> These "timeouts" are **per-request network timeouts**. They are not a deadline for
> the task. There is no option anywhere to give up on a task.

### 3.2 `comfyui` -- wait for a ComfyUI job

**Both `prompt_id` and `client_id` are required for real events.**

**Why**: ComfyUI sends execution events **directed** at the submitting client. From its source:

```python
# ComfyUI/execution.py
server.send_sync("executing", {...}, server.client_id)   # third argument = target client
```

| client id you use | broadcast messages (`status`) | execution events (`execution_*`) |
|---|---|---|
| the one from submit | yes | **yes** |
| a random one | yes | **no -- not a single one** |

This is the nastiest failure mode in the whole area: the handshake succeeds, you see
`{"type":"status", ...}`, everything looks healthy, and no execution events ever arrive.
(Observed during development: a job ran for 137 seconds and produced output while the
listener received **zero** execution events. Passing the submitting `client_id` fixed it
immediately.)

Where the ids come from (DSH + ComfyUI MCP):

```
run_workflow(wait=false)  ->  { "prompt_id": "...", "client_id": "..." }
```

| Option | Python | PowerShell | Bash | Default |
|---|---|---|---|---|
| prompt id | `--prompt-id` | `-PromptId` | `--prompt-id` | required |
| client id | `--client-id` | `-ClientId` | `--client-id` | `''` (falls back to polling) |
| host | `--host` | `-HostName` | `--host` | `127.0.0.1` |
| port | `--port` | `-Port` | `--port` | `8188` |
| force polling | `--poll` | `-Poll` | `--poll` | off |

```bash
python waiters/wait.py comfyui --prompt-id abc-123 --client-id def-456
```

```powershell
./waiters/wait.ps1 comfyui -PromptId abc-123 -ClientId def-456
```

```bash
bash waiters/wait.sh comfyui --prompt-id abc-123 --client-id def-456
```

### 3.2b How the Bash waiter does WebSocket

`wait.sh` is event-driven too, with no dependencies at all. It opens a raw TCP connection
through bash's `/dev/tcp` and speaks the WebSocket protocol itself.

Two facts make this practical:

1. **Server-to-client frames are not masked** (RFC 6455), so there is no mask key to strip.
   Only the header and the payload need reading.
2. **`read -u FD` reads one byte at a time from a non-seekable descriptor and therefore
   never over-reads**, and `dd bs=1 count=N <&FD` reads exactly N bytes. Both were verified
   against a live ComfyUI before this was written.

Measured live: `... 5/25 ... 10/25 ... 15/25 ... 20/25 ... 25/25 -> [DONE] 148s`.

**Cost note**: `dd bs=1` runs at roughly 80 KB/s. ComfyUI messages are tiny (`status` ~100 B,
`progress` ~80 B, `executed` 200-2000 B), so a frame costs about 1-25 ms. Irrelevant for a
waiter, and the simplicity is worth it.

**Portability**: the script targets **bash 3.2**, the version macOS still ships. That rules
out `read -N`, `mapfile`, `${var,,}`, associative arrays and namerefs.

**Three bugs found while building this**, all worth knowing if you adapt it:

| Bug | Symptom | Fix |
|---|---|---|
| `exec $FD<>/dev/tcp/...` | `exec: 4: not found` | The fd number must be a **literal**; bash parses `$FD` as a command name |
| `exec 3<>/dev/tcp/... 2>/dev/null` | every later message vanishes | `exec` with no command redirects the **shell**, permanently. Confine it: `{ exec 3<>/dev/tcp/...; } 2>/dev/null` |
| greedy `s/.*"type".../` in sed | events silently dropped; `executed` counted as 0 | A greedy match finds the **last** occurrence, and nested objects reuse key names (`images[].type == "output"`). Use `grep -o ... \| head -n1`, which takes the first |

That last one is subtle: anchoring the regex at the start of the message fixes `type` but
breaks `prompt_id` and `exception_message`, which live inside `data`. Taking the first match
handles both.

When `/dev/tcp` is unavailable (bash built without net redirections), the script falls back
to polling and **says so**.

**What it does internally** (this determines how reliable it is)

1. **Race guard.** Before connecting, it queries `/history/<id>` once. The job can finish
   between "submitted" and "connected"; without this check a short job is waited on
   forever. This is a one-shot check, not polling.
2. **Blocks on the event stream.** Connects to `/ws?clientId=<that id>` and blocks in
   `ReceiveAsync`. It does not ask on a timer -- it waits for the server to push.
3. **Falls back, and says so.** If the WebSocket cannot be reached or the stream breaks,
   it switches to polling `/history` and prints why. The switch is never silent.
4. **Verdicts.** `executing` with `node == null` -> DONE. `execution_error` -> FAILED.
   `execution_interrupted` -> FAILED. Anything else -> keep waiting.

### 3.2c Multiple output nodes, and the explicit success event

A workflow can contain several output nodes (three `SaveImage` nodes, for example).
The observed event order for such a run is:

```
[122.0s] executing         node=9
[122.2s] executed          node=9    output={images: [...]}
[122.2s] executing         node=92
[122.5s] executed          node=92   output={images: [...]}
[122.5s] executing         node=91
[122.8s] executed          node=91   output={images: [...]}
[122.8s] execution_success           <-- ComfyUI's own success verdict
[122.8s] executing         node=NULL <-- end of the whole run
```

Two things follow:

1. **`executing` with `node == null` is sent only after every output node has finished**,
   so waiting on it does wait for all outputs. It is the definitive end marker.
2. **`execution_success` exists** and is the exact counterpart of `execution_error`.
   Both are now terminal for DONE, whichever arrives first. Success is therefore as
   explicit as failure rather than being inferred.

**The waiters report the output filenames, taken from history**, which is the authoritative
record of what a run produced:

```
DONE	3 output node(s): out_A_00001_.png, out_C_00001_.png, out_B_00001_.png
```

The caller learns the filenames from the last line and does not need another tool call to
discover them. The list is capped at six entries.

The Bash waiter reports a **file count** (`3 output file(s)`) rather than a node count,
because counting nodes needs brace matching that grep cannot do. Both statements are
correct; they answer slightly different questions.

### 3.3 `http` -- poll a URL until it matches

For software that only exposes a status endpoint.

| Option | Python | PowerShell | Bash | Default |
|---|---|---|---|---|
| url | `--url` | `-Url` | `--url` | required |
| match | `--until` | `-Until` | `--until` | empty = any response counts |

```bash
python waiters/wait.py http --url http://127.0.0.1:9000/status --until '"state":\s*"done"'
```

> `--until` is a **regex**; escape quoting characters accordingly.

### 3.4 `file` -- wait for a file to appear or match

For software that signals completion by writing a file.

| Option | Python | PowerShell | Bash | Default |
|---|---|---|---|---|
| path | `--path` | `-Path` | `--path` | required |
| match | `--until-match` | `-UntilMatch` | `--until-match` | empty = existence counts |

```bash
python waiters/wait.py file --path ./out/final.png
python waiters/wait.py file --path ./render.log --until-match 'Render complete'
```

> Testing only for existence is risky: some programs create an empty file first and
> write into it afterwards. Prefer `--until-match`, or wait for a `.done` marker.

### 3.5 `probe` -- one-shot check, does not wait

Use it to confirm "is the service up, is the URL right, what does it return".

```bash
python waiters/wait.py probe --url http://127.0.0.1:8188/system_stats
python waiters/wait.py probe --url http://127.0.0.1:8188/system_stats --expect 'comfyui_version'
```

---

## 4. The always-on rule (plugin configuration)

`plugin/no-poll.js` registers a section in the system prompt of **every** session.
It is configured in `cordis.patch.yml`:

```yaml
- id: no-poll
  name: 'dsh-no-poll/plugin/no-poll.js'
  config:
    enabled: true      # false = register nothing at all
    order: 100         # position in the system prompt; lower sorts earlier
    verbose: true      # false = minimal version (326 chars vs 1930)
    sectionName: 'no-poll'
    extraLines: []     # your own lines, appended
```

### Choosing `order`

Reference values from `SECTION_ORDERS` in `@deepseek-ai/dsh-system-prompt`:

| Name | Value | What it is |
|---|---|---|
| `HARNESS_IDENTITY` | `-1000` | harness identity |
| `DEPLOYMENT_PERSONA_PREFIX` | `0` | the persona |
| **default** | **`100`** | right after the persona, read as a behavioural rule |
| `PLAN_POLICY` | `500` | plan policy |
| `TEAM_POLICY` | `600` | team policy |
| `MCP_SERVERS` | `3100` | tool documentation |

`order` **must be a finite number** -- `NaN` or `Infinity` makes `section()` throw.
The plugin falls back to `100` for invalid values.

### Token cost

| Configuration | Size | ~tokens/turn |
|---|---|---|
| `verbose: true` (default) | 1930 chars | **~483** |
| `verbose: false` | 326 chars | ~82 |
| `enabled: false` | 0 | 0 |

**This is paid on every single turn.** If you only occasionally run long tasks, either
set `enabled: false` and mention the pattern when you need it, or move the waiter usage
into your own skill (loaded on demand only).

### `extraLines`

Tell the model about your specific machine, saving it a discovery step:

```yaml
extraLines:
  - 'ComfyUI runs at http://127.0.0.1:8188; wait on it with waiters/wait.py comfyui.'
  - 'Blender is at C:\Program Files\Blender\blender.exe; render with run_in_background -b.'
```

---

## 5. Typical call chains

### A. A five-minute ComfyUI video job

The model's actions -- this is what "do not poll" actually looks like:

```
1. run_workflow(wait=false)  ->  take prompt_id + client_id, return immediately
2. run_in_background: python waiters/wait.py comfyui --prompt-id ... --client-id ...
3. END THE TURN. The model does nothing else.
   ... 138 seconds later ...
4. The host reports the background job finished -> the model wakes up
5. Read the job's last line -> DONE -> continue (collect output, inspect, file it)
```

Step 3 is the point: the model **really stops**, instead of asking differently.

### B. Blender headless render

**No waiter needed** -- just run it in the background:

```
run_in_background: blender -b scene.blend -o //out/frame_ -f 1-250
```

The host notifies the model when the render exits.

### C. Your own software with only a `/status` endpoint

```bash
python waiters/wait.py http --url http://localhost:9000/status --until '"state":"done"'
```

---

## 6. Troubleshooting

### 6.1 "Not a single event arrives"

Check in this order:

1. **Is the WebSocket reachable?**
   ```bash
   python tests/probe-ws.py 12
   ```
   - `handshake OK` plus some `{"type":"status", ...}` -> connectivity is fine, go on
   - `handshake FAILED` -> service not started, wrong port, or a proxy in the way

2. **Is the `client_id` the one from submission?** <- **the most common cause**
   Invent one and you will still receive broadcast `status` messages but **no directed
   `execution_*` events at all**.

3. **Is the job actually executing?**
   ```bash
   curl -s http://127.0.0.1:8188/queue
   ```
   If your id is in `queue_pending` it simply has not started yet -- no events is correct.

4. **Is the entry in `queue_running` one that already produced output?**
   That is a stale phantom entry in ComfyUI and it makes every later job queue forever
   (observed in practice). Clear it:
   ```bash
   curl -X POST http://127.0.0.1:8188/interrupt
   ```

### 6.2 "The waiter returned DONE immediately, but I never saw it run"

The race guard fired: you started waiting after the job had already finished. The last
line says `(finished before we connected, 0.0s)`. **This is correct behaviour**, not a bug.

### 6.3 "It reports FAILED but the job is still running"

It should not. The verdict logic only reports FAILED when ComfyUI itself says
`status_str` is `error`/`failed` or `completed` with a non-success status. If you see
otherwise, capture the payload with `curl -s <host>/history/<id>` and file an issue.

### 6.4 "The model still polls"

1. **Is the plugin installed, and did DSH restart?**
2. **Did `order` collide?** A duplicate section name in the same scope, or a non-finite
   order, throws -- and the plugin is designed to fail silently so it cannot damage a
   session. Change `sectionName` or `order` and try again.
3. **Is something else telling it to poll?** Check your own skills or instructions for a
   rule like "check every 30 seconds". That directly contradicts this one.

### 6.5 "Non-ASCII output looks mangled"

- `wait.py` forces stdout/stderr to UTF-8 and should be fine.
- The last line is plain ASCII tags, so scripted parsing is unaffected regardless.
- If you redirect output to a file, open it as UTF-8.

---

## 7. Behaviour contract (for anyone changing this repo)

These are the rules that must not be broken. They were learned the hard way.

| Contract | Why |
|---|---|
| **Exactly three states: DONE, FAILED, waiting** | A fourth state ("gave up", "timed out") invites the model to interrupt a task that is still running |
| **FAILED only on an explicit upstream verdict** | Guessing failure destroys completed work and triggers pointless resubmits |
| **Unreachable is not the same as absent** | A failed query means "could not ask", never "it is gone" |
| **No give-up path at all** | The contract is to wait; a task must never be declared dead by this process |
| **Last line is machine-readable** | Callers must parse reliably rather than read stderr |
| **Prefer the event stream over polling** | Blocking on a push is cheaper and lower latency than asking on a timer |
| **A race guard is mandatory** | Without it, short jobs are waited on forever -- and only intermittently |
| **A fallback must announce itself** | Silent degradation makes people believe they are still event-driven |
| **Polling inside the process is fine; polling by the model is not** | That is the whole reason this repo exists |

---

## 8. See also

- [README.md](README.md) -- why, and a 60-second start
- [examples/comfyui.md](examples/comfyui.md) -- the event-driven adapter in full
- [examples/blender.md](examples/blender.md) -- the case that needs no waiter
- [examples/add-your-own.md](examples/add-your-own.md) -- adapting your own software
- [MCP SEP-1686 "Tasks"](https://modelcontextprotocol.io/seps/1686-tasks) -- the same problem, at protocol level
