#!/usr/bin/env bash
# dsh-no-poll waiter (Bash, POSIX-first, no third-party dependencies).
#
# WHY THIS EXISTS
#     Waiting for a long task should not be the model's job.
#         BAD  : the model repeatedly asks "is it done yet?" -- every ask costs a
#                full round trip plus context, and the task does not finish sooner.
#         GOOD : a background process waits; when it exits, the host wakes the
#                model. Model turns spent waiting = 0.
#
# EXIT CONTRACT -- THREE STATES, NOTHING ELSE
#     0  DONE      the system explicitly reported success
#     1  FAILED    the system explicitly reported failure,
#                  OR the system was unreachable after retries were exhausted
#     (no exit)    WAITING -- the process blocks. This is the normal state.
#
#     There is no timeout and no giving up. FAILED is deliberately STRICT: only an
#     explicit verdict from the upstream system, or total unreachability.
#
# WEBSOCKET IN PURE BASH -- YES, IT WORKS
#     Bash can open a raw TCP connection through /dev/tcp and speak the WebSocket
#     protocol itself, so the comfyui subcommand here IS event-driven. Two facts make
#     this practical:
#
#       1. Server-to-client frames are NOT masked (RFC 6455), so there is no mask key
#          to strip -- only the header and the payload need reading.
#       2. `read -u FD` reads one byte at a time from a non-seekable descriptor and
#          therefore never over-reads; `dd bs=1 count=N <&FD` reads exactly N bytes.
#          Both were verified against a live ComfyUI before this was written.
#
#     Cost note: `dd bs=1` runs at roughly 80 KB/s. ComfyUI messages are tiny
#     (status ~100 B, progress ~80 B, executed ~200-2000 B), so a frame costs about
#     1-25 ms. That is irrelevant for a waiter, and the simplicity is worth it.
#
#     If /dev/tcp is unavailable (bash built without net redirections, or the fd cannot
#     be opened) this falls back to polling /history and SAYS SO.
#
# Portability: written for bash 3.2 (the version macOS still ships). That rules out
# `read -N`, `mapfile`, `${var,,}`, associative arrays and namerefs.
#
# OUTPUT
#     Progress goes to stderr. The LAST line on stdout is: <TAG><TAB><detail>
set -u

EXIT_DONE=0
EXIT_FAILED=1

QUIET=0
COMMAND=""
INTERVAL=3
REQ_TIMEOUT=10
CONN_RETRIES=2
CONN_RETRY_DELAY=150

URL=""
UNTIL=""
FILE_PATH=""
UNTIL_MATCH=""
PROMPT_ID=""
CLIENT_ID=""
HOST="127.0.0.1"
PORT="8188"
FORCE_POLL=0


usage() {
  cat <<'EOF'
dsh-no-poll waiter (Bash)

Usage:
  wait.sh comfyui --prompt-id ID --client-id CID [--host H] [--port P] [--poll]
  wait.sh http    --url URL [--until REGEX]
  wait.sh file    --path P [--until-match REGEX]
  wait.sh probe   --url URL [--expect REGEX]

Common:
  --interval SEC            poll interval (default 3)
  --request-timeout SEC     per-request timeout (default 10)
  --conn-retries N          retries before reporting FAILED (default 2)
  --conn-retry-delay SEC    seconds between retries (default 150 = 2.5 min)
  -q, --quiet               print only the machine-readable last line

Exit: 0 DONE, 1 FAILED. Waiting produces no exit at all -- that IS the point.

The comfyui subcommand uses a real WebSocket (pure bash, via /dev/tcp) when a
--client-id is supplied, and falls back to polling /history otherwise.
EOF
}

finish() { # code tag detail [machine_detail]
  local code="$1" tag="$2" detail="${3:-}" machine="${4:-}"
  if [ "$QUIET" -eq 0 ]; then printf '  [%s] %s\n' "$tag" "$detail" >&2; fi
  if [ -n "$machine" ]; then printf '%s\t%s\n' "$tag" "$machine"
  else printf '%s\t%s\n' "$tag" "$detail"; fi
  exit "$code"
}

say() { if [ "$QUIET" -eq 0 ]; then printf '%s\n' "$*" >&2; fi; return 0; }

[ $# -eq 0 ] && { usage; exit "$EXIT_FAILED"; }
case "$1" in -h|--help) usage; exit 0 ;; esac
COMMAND="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)         INTERVAL="${2:-3}"; shift 2 ;;
    --request-timeout)  REQ_TIMEOUT="${2:-10}"; shift 2 ;;
    --conn-retries)     CONN_RETRIES="${2:-2}"; shift 2 ;;
    --conn-retry-delay) CONN_RETRY_DELAY="${2:-150}"; shift 2 ;;
    -q|--quiet)         QUIET=1; shift ;;
    --url)              URL="${2:-}"; shift 2 ;;
    --until)            UNTIL="${2:-}"; shift 2 ;;
    --expect)           UNTIL="${2:-}"; shift 2 ;;
    --path)             FILE_PATH="${2:-}"; shift 2 ;;
    --until-match)      UNTIL_MATCH="${2:-}"; shift 2 ;;
    --prompt-id)        PROMPT_ID="${2:-}"; shift 2 ;;
    --client-id)        CLIENT_ID="${2:-}"; shift 2 ;;
    --host)             HOST="${2:-}"; shift 2 ;;
    --port)             PORT="${2:-}"; shift 2 ;;
    --poll)             FORCE_POLL=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) finish "$EXIT_FAILED" FAILED "unknown argument: $1" ;;
  esac
done

http_get() { # url -> body on stdout; non-zero means the request failed
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time "$REQ_TIMEOUT" "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - --timeout="$REQ_TIMEOUT" "$1" 2>/dev/null
  else
    return 127
  fi
}

START=$(date +%s)
elapsed() { echo $(( $(date +%s) - START )); }

# ---------------------------------------------------------------------------
# Minimal WebSocket client over /dev/tcp
#
# Only what a waiter needs: connect, handshake, read text frames. Written for
# bash 3.2, so: fixed fd, no read -N, no mapfile.
# ---------------------------------------------------------------------------

# Reads exactly N bytes from the socket and echoes them raw.
ws_read_raw() { dd bs=1 count="$1" <&3 2>/dev/null; }

# Reads exactly N bytes and echoes them as space-separated unsigned decimals.
ws_read_dec() { dd bs=1 count="$1" <&3 2>/dev/null | od -An -tu1 | tr -s ' ' | sed 's/^ //; s/ $//'; }

ws_connect() { # host port path -> 0 on success
  # Two hard-won details here:
  #   1. The file descriptor must be a LITERAL number. xec $FD<>/dev/tcp/... is
  #      parsed as the command $FD, which fails with xec: 4: not found.
  #   2. The stderr redirect must be confined to a brace group. xec ... 2>/dev/null`n  #      has no command argument, so it redirects the SHELL's stderr permanently and
  #      every later message -- including our own diagnostics -- is swallowed.
  if ! { exec 3<>/dev/tcp/"$1"/"$2"; } 2>/dev/null; then
    return 1
  fi

  local key
  if command -v base64 >/dev/null 2>&1; then
    key=$(head -c 16 /dev/urandom | base64 | tr -d '\n')
  else
    # Deterministic fallback: the key only has to be unique, not secret, for a
    # local waiter. Still 16 bytes, still base64.
    key=$(printf 'dsh-no-poll-%s-%s' "$$" "$(date +%s)" | base64 | tr -d '\n' | cut -c1-24)
  fi

  printf 'GET %s HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' \
    "$3" "$1" "$2" "$key" >&3

  local status
  if ! IFS= read -r -t "$REQ_TIMEOUT" -u 3 status; then
    exec 3<&-
    return 1
  fi
  case "$status" in
    *101*) : ;;
    *) exec 3<&-; return 1 ;;
  esac

  # Drain the remaining response headers. `read -u` is byte-at-a-time here, so the
  # first frame already sitting in the socket buffer is left untouched.
  local line
  while IFS= read -r -t "$REQ_TIMEOUT" -u 3 line; do
    line=${line%$'\r'}
    [ -z "$line" ] && break
  done
  return 0
}

# Reads one complete (possibly fragmented) text message.
# Sets WS_OPCODE and WS_PAYLOAD. Returns 1 when the connection ended.
ws_read_message() {
  WS_OPCODE=""
  WS_PAYLOAD=""
  local assembling=0
  local buffer=""

  while :; do
    local b1 b2
    set -- $(ws_read_dec 2)
    if [ $# -lt 2 ]; then return 1; fi
    b1=$1; b2=$2

    local fin=$(( b1 & 0x80 ))
    local opcode=$(( b1 & 0x0f ))
    local masked=$(( b2 & 0x80 ))
    local len=$(( b2 & 0x7f ))

    if [ "$len" -eq 126 ]; then
      set -- $(ws_read_dec 2)
      [ $# -lt 2 ] && return 1
      len=$(( $1 * 256 + $2 ))
    elif [ "$len" -eq 127 ]; then
      set -- $(ws_read_dec 8)
      [ $# -lt 8 ] && return 1
      # 64-bit lengths never occur for these messages; stay well inside shell integers
      # by refusing anything beyond the low 32 bits rather than overflowing.
      len=$(( $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 ))
    fi

    if [ "$masked" -ne 0 ]; then
      # RFC 6455 forbids masked server frames. If one arrives anyway, consume the key
      # and continue rather than losing stream alignment.
      ws_read_raw 4 >/dev/null
    fi

    local payload
    payload=$(ws_read_raw "$len")

    case "$opcode" in
      8) return 1 ;;                                 # close
      9|10) continue ;;                              # ping/pong: ignore, keep reading
      1)                                               # text
        buffer="$buffer$payload"
        if [ "$fin" -ne 0 ]; then WS_OPCODE=1; WS_PAYLOAD="$buffer"; return 0; fi
        assembling=1
        ;;
      0)                                               # continuation
        [ "$assembling" -eq 1 ] || return 1
        buffer="$buffer$payload"
        if [ "$fin" -ne 0 ]; then WS_OPCODE=1; WS_PAYLOAD="$buffer"; return 0; fi
        ;;
      *) continue ;;                                   # binary: ignore
    esac
  done
}

# Flat JSON field extraction. No jq -- it is frequently absent, and these payloads
# are flat enough for a tolerant regex.
#
# Implementation note: `grep -o` plus `head -n1` takes the FIRST occurrence, which is
# what "non-greedy" means here and what sed's BRE cannot express. Two traps this avoids:
#
#   1. A greedy `s/.*"key".../` in sed matches the LAST occurrence. Nested objects reuse
#      these key names -- an `executed` message carries
#          {"type": "executed", "data": {"output": {"images": [{"type": "output"}]}}}
#      so a greedy match reports the type as "output" and the event is silently dropped.
#   2. Anchoring the pattern at the start of the message fixes (1) for `type`, but breaks
#      every key that is not first -- `prompt_id` and `exception_message` live inside
#      "data" and would match nothing at all.
#
# Taking the first match handles both: `type` is first in every ComfyUI message, and the
# nested keys are simply the first occurrence of that name.
json_str() { # json key -> value on stdout (empty when absent)
  printf '%s' "$1" \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n1 \
    | sed 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

# Every output filename in a history body, one per line.
#
# History is the authoritative record of what a run produced, and it is the only place
# that names the files. For a workflow with several SaveImage nodes this is what the
# caller actually needs next -- counting events would give a number and nothing else.
#
# Note: this counts FILES. Counting output *nodes* would need brace matching, which grep
# cannot do; the Python and PowerShell waiters report the node count as well. Both
# statements are correct, they just answer slightly different questions.
comfy_files() { # history body -> one filename per line
  printf '%s' "$1" \
    | grep -o '"filename"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"$/\1/'
}

# DONE detail built from a history body already in hand.
comfy_detail_from() { # history_body elapsed -> detail
  local files count
  files="$(comfy_files "$1" | head -n6 | tr '\n' '|' | sed 's/|$//; s/|/, /g')"
  count="$(comfy_files "$1" | wc -l | tr -d ' ')"
  if [ -z "$files" ]; then printf '%ss, 0 output file(s)' "$2"
  else printf '%ss, %s output file(s): %s' "$2" "$count" "$files"; fi
}

# DONE detail built from history. Falls back to the event count when history is unreadable.
comfy_done_detail() { # elapsed fallback_node_events -> detail
  local body
  body="$(http_get "$BASE/history/$PROMPT_ID")"
  if [ -z "$body" ]; then
    if [ -n "${2:-}" ]; then printf '%ss, %s output event(s)' "$1" "$2"
    else printf '%ss' "$1"; fi
    return
  fi
  comfy_detail_from "$body" "$1"
}

# ---------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------
if [ "$COMMAND" = "probe" ]; then
  [ -z "$URL" ] && finish "$EXIT_FAILED" FAILED "probe requires --url"
  body="$(http_get "$URL")" || finish "$EXIT_FAILED" FAILED "unreachable: $URL" "unreachable: $URL"
  if [ -z "$UNTIL" ]; then finish "$EXIT_DONE" DONE "$URL (${#body} chars)"; fi
  if printf '%s' "$body" | grep -Eq -- "$UNTIL"; then
    finish "$EXIT_DONE" DONE "$URL matched"
  fi
  finish "$EXIT_FAILED" FAILED "$URL did not match $UNTIL"
fi

# ---------------------------------------------------------------------------
# http
# ---------------------------------------------------------------------------
if [ "$COMMAND" = "http" ]; then
  [ -z "$URL" ] && finish "$EXIT_FAILED" FAILED "http requires --url"
  FAILURES=0
  while :; do
    body="$(http_get "$URL")"
    if [ -n "$body" ]; then
      FAILURES=0
      if [ -z "$UNTIL" ] || printf '%s' "$body" | grep -Eq -- "$UNTIL"; then
        finish "$EXIT_DONE" DONE "$URL matched after $(elapsed)s"
      fi
      say "  ... $(elapsed)s, not matched yet"
    else
      FAILURES=$((FAILURES + 1))
      say "  ... $(elapsed)s, request failed ($FAILURES/$((CONN_RETRIES + 1)))"
      if [ "$FAILURES" -gt "$CONN_RETRIES" ]; then
        finish "$EXIT_FAILED" FAILED "unreachable after $FAILURES attempts" "unreachable: $URL ($FAILURES attempts)"
      fi
      sleep "$CONN_RETRY_DELAY"
      continue
    fi
    sleep "$INTERVAL"
  done
fi

# ---------------------------------------------------------------------------
# file
# ---------------------------------------------------------------------------
if [ "$COMMAND" = "file" ]; then
  [ -z "$FILE_PATH" ] && finish "$EXIT_FAILED" FAILED "file requires --path"
  while :; do
    if [ -e "$FILE_PATH" ]; then
      if [ -z "$UNTIL_MATCH" ]; then
        finish "$EXIT_DONE" DONE "$FILE_PATH appeared after $(elapsed)s"
      fi
      if grep -Eq -- "$UNTIL_MATCH" "$FILE_PATH" 2>/dev/null; then
        finish "$EXIT_DONE" DONE "$FILE_PATH matched after $(elapsed)s"
      fi
    fi
    sleep "$INTERVAL"
  done
fi

# ---------------------------------------------------------------------------
# comfyui
# ---------------------------------------------------------------------------
[ "$COMMAND" = "comfyui" ] || finish "$EXIT_FAILED" FAILED "unknown command: $COMMAND"
[ -z "$PROMPT_ID" ] && finish "$EXIT_FAILED" FAILED "comfyui requires --prompt-id"

BASE="http://${HOST}:${PORT}"

# Polling fallback. Reads the SAME three-state distinction as the websocket path:
# a failed query ("could not ask") must never be mistaken for an absent job.
comfy_poll() {
  say "  (polling /history in-process: $1)"
  local query_failures=0 body code
  while :; do
    body="$(http_get "$BASE/history/$PROMPT_ID")"
    code=$?
    if [ "$code" -ne 0 ] || [ -z "$body" ]; then
      query_failures=$((query_failures + 1))
      say "  ... $(elapsed)s, query failed ($query_failures/$((CONN_RETRIES + 1)))"
      if [ "$query_failures" -gt "$CONN_RETRIES" ]; then
        finish "$EXIT_FAILED" FAILED "could not reach $BASE after $query_failures attempts (waited $(elapsed)s)" \
          "unreachable: $BASE ($query_failures attempts)"
      fi
      sleep "$CONN_RETRY_DELAY"
      continue
    fi
    query_failures=0

    if printf '%s' "$body" | grep -q "\"$PROMPT_ID\""; then
      if printf '%s' "$body" | grep -Eq '"status_str"[[:space:]]*:[[:space:]]*"(error|failed)"'; then
        finish "$EXIT_FAILED" FAILED "execution failed"
      fi
      if printf '%s' "$body" | grep -Eq '"completed"[[:space:]]*:[[:space:]]*true'; then
        finish "$EXIT_DONE" DONE "$(comfy_detail_from "$body" "$(elapsed)") (polled)"
      fi
      say "  ... $(elapsed)s, still running"
    else
      # Absent from history. Check the queue, then keep waiting. There is
      # deliberately no give-up branch: this waiter's contract is to wait.
      if http_get "$BASE/queue" | grep -q "\"$PROMPT_ID\""; then
        say "  ... $(elapsed)s, still queued"
      else
        say "  ... $(elapsed)s, not in history or queue (still waiting)"
      fi
    fi
    sleep "$INTERVAL"
  done
}

# Race guard. Not polling: a single check, because the job can finish between
# "submitted" and "connected", and without this a short job is waited on forever.
guarded() {
  local entry
  entry="$(http_get "$BASE/history/$PROMPT_ID")"
  [ -z "$entry" ] && return 0
  printf '%s' "$entry" | grep -q "\"$PROMPT_ID\"" || return 0
  if printf '%s' "$entry" | grep -Eq '"status_str"[[:space:]]*:[[:space:]]*"(error|failed)"'; then
    finish "$EXIT_FAILED" FAILED "execution failed (reported before we connected)"
  fi
  if printf '%s' "$entry" | grep -Eq '"completed"[[:space:]]*:[[:space:]]*true'; then
    finish "$EXIT_DONE" DONE "$(comfy_detail_from "$entry" "$(elapsed)") (finished before we connected)"
  fi
  return 0
}

if [ "$FORCE_POLL" -eq 0 ] && [ -n "$CLIENT_ID" ]; then
  guarded

  attempt=0
  connected=0
  while [ "$attempt" -le "$CONN_RETRIES" ]; do
    attempt=$((attempt + 1))
    if ws_connect "$HOST" "$PORT" "/ws?clientId=$CLIENT_ID"; then
      connected=1
      break
    fi
    say "  websocket connect attempt $attempt/$((CONN_RETRIES + 1)) failed"
    [ "$attempt" -le "$CONN_RETRIES" ] && sleep "$CONN_RETRY_DELAY"
  done

  if [ "$connected" -eq 0 ]; then
    comfy_poll "websocket unreachable after $attempt attempts"
  fi

  say "waiting for ComfyUI job $PROMPT_ID (event-driven, pure-bash websocket)"
  say "  (silence is normal. A queued, slow or apparently stuck job is still waited on.)"

  nodes=0
  while ws_read_message; do
    msg="$WS_PAYLOAD"
    mtype="$(json_str "$msg" type)"
    [ -z "$mtype" ] && continue

    mpid="$(json_str "$msg" prompt_id)"
    # Some events carry no prompt_id; only skip when it is present AND different.
    if [ -n "$mpid" ] && [ "$mpid" != "$PROMPT_ID" ]; then continue; fi

    case "$mtype" in
      execution_start)
        say "   > started"
        ;;
      progress)
        val="$(printf '%s' "$msg" | grep -o '"value"[[:space:]]*:[[:space:]]*[0-9]*' | head -n1 | grep -o '[0-9]*$')"
        mx="$(printf '%s' "$msg" | grep -o '"max"[[:space:]]*:[[:space:]]*[0-9]*' | head -n1 | grep -o '[0-9]*$')"
        if [ -n "$val" ] && [ -n "$mx" ] && [ "$mx" -gt 0 ]; then
          step=$(( mx / 5 )); [ "$step" -lt 1 ] && step=1
          if [ $(( val % step )) -eq 0 ]; then say "   ... $val/$mx"; fi
        fi
        ;;
      executed)
        nodes=$((nodes + 1))
        ;;
      executing)
        # node == null marks the end of the run. Every `executed` event has already
        # arrived by this point, so this is the definitive "all outputs are done".
        if printf '%s' "$msg" | grep -Eq '"node"[[:space:]]*:[[:space:]]*null'; then
          exec 3<&-
          finish "$EXIT_DONE" DONE "$(comfy_done_detail "$(elapsed)" "$nodes")"
        fi
        ;;
      execution_success)
        # ComfyUI's own success verdict -- the exact counterpart of execution_error.
        # Verified to arrive AFTER every `executed` event for a three-output workflow,
        # so treating it as terminal is safe and makes success as explicit as failure.
        exec 3<&-
        finish "$EXIT_DONE" DONE "$(comfy_done_detail "$(elapsed)" "$nodes")"
        ;;
      execution_error)
        detail="$(json_str "$msg" exception_message)"
        [ -z "$detail" ] && detail="unspecified error"
        exec 3<&-
        finish "$EXIT_FAILED" FAILED "$detail" "execution failed"
        ;;
      execution_interrupted)
        exec 3<&-
        finish "$EXIT_FAILED" FAILED "execution interrupted"
        ;;
    esac
  done

  exec 3<&- 2>/dev/null
  comfy_poll "event stream ended"
fi

if [ -z "$CLIENT_ID" ]; then
  say "  note: no --client-id given. ComfyUI directs execution events at the"
  say "        submitting client, so a random id receives none. Polling instead."
fi
comfy_poll "polling requested"
