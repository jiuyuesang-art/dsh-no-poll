# Example: Blender (the case that needs NO waiter)

**This file exists to show when NOT to write an adapter.**

---

## The short version

```bash
blender -b scene.blend -o //out/frame_ -f 1-250
```

**Run it in the background. No waiter required.**

```
run_in_background: blender -b scene.blend -o //out/frame_ -f 1-250
        |
     (the model ends its turn and does something else)
        |
   render exits -> the host notifies the model
```

**Blender's lifetime is inside your process tree**, so the host already knows when it
finishes.

---

## Why this beats writing a waiter

| | Command-line program (`blender -b`) | "Submit and queue" (ComfyUI) |
|---|---|---|
| Where the process is | **your child process** | inside someone else's service |
| Completion signal | **exit code** | you must ask, or wait for a push |
| Needs a waiter? | **no** | yes |
| How you learn about failure | non-zero exit | query the status / wait for an error event |

**The only reason a waiter exists**: **you cannot `wait` on something that is not in your
hands.** Blender is in your hands. Do not over-engineer it.

---

## Two ways people use Blender here

### 1. Command-line rendering (headless) -- background it, no waiter

```bash
# whole animation
blender -b scene.blend -o //out/frame_ -F PNG -f 1-250

# a single frame
blender -b scene.blend -o //out/still_ -f 1

# run a script
blender -b scene.blend --python script.py
```

**Key flags**:

| Flag | Meaning |
|---|---|
| `-b` | headless (no window) -- **required for background use** |
| `-o <path>` | output path template |
| `-f <n>` / `-f a-b` | frame / frame range |
| `-F <format>` | output format (`PNG` / `JPEG` / `OPEN_EXR` ...) |
| `-a` | render the animation using the file's own frame range |
| `--python <file>` | run a script |
| `--` | everything after this is passed to the script |

> Without `-b`, Blender tries to open a GUI and will hang on a headless machine.

### 2. Through a Blender MCP (`mcp__blender__*`) -- mostly synchronous

Blender MCP tools generally return synchronously:

| Tool | Duration | Waiter? |
|---|---|---|
| `get_scene_info`, `look`, `execute_blender_code` | seconds | no |
| `search_assets`, `import_asset` | seconds to tens of seconds | no |
| **`generate_3d`** | **1-3 minutes** | see below |
| A render triggered through `execute_blender_code` | **potentially long** | consider it |

**What is special about `generate_3d`**: it takes a `wait_seconds` parameter. If that
elapses it returns a job handle and expects to be called again.

That is the **MCP server implementing its own polling**, not DSH. Three ways to handle it:

```
1. Give it a large enough wait_seconds (say 300) and let one call finish.
   WARNING: this blocks the model's turn -- acceptable only at the 1-3 minute scale.

2. Run an independent headless Blender generation in the background,
   if your generator has a CLI.

3. If the job handle can be queried over some endpoint,
   wait on it with `waiters/wait.py http`.
```

**The deciding question**: **will this block the model for more than about a minute?**
If yes, move it to the background. If no, just call it -- do not build machinery.

> 1-3 minutes is a grey zone. If a single `generate_3d` call gets you the result, calling
> it directly is simpler. If you need twenty of them, that is a batch script plus a
> background job.

---

## Long renders: write one batch script

If you need many frames or many files, **do not create one background job per frame**.
Write a script:

```bash
#!/usr/bin/env bash
# render-all.sh -- all renders in one background job
set -euo pipefail
for f in scenes/*.blend; do
  name=$(basename "$f" .blend)
  echo "[$(date +%T)] rendering $name"
  blender -b "$f" -o "//out/${name}_" -F PNG -f 1-250
  echo "[$(date +%T)] finished $name"
done
echo "ALL_DONE"
```

Then:

```
run_in_background: bash render-all.sh
```

**One job, one wake-up.** The timestamps in the log let you see exactly which step failed,
without interrupting anything.

---

## The takeaway

> **Blender is the representative "command-line" case: it lives in your process tree, so
> the host already knows when it exits.**
>
> **The test is whether the task is in your hands.**
> If it is (`blender -b`, `ffmpeg`, a build, a training script) -- just `run_in_background` it.
> Only if it is not (submit-and-queue services) do you need a waiter.
