#!/usr/bin/env bash
#
# permission-hook.sh — ClawdIsland permission gate.
#
# Wired into Claude Code as a `PermissionRequest` hook (matcher "*"). Unlike a PreToolUse
# hook — which fires for EVERY tool call, even allowlisted / auto-approved ones — the
# PermissionRequest event fires ONLY when Claude Code would actually show its permission
# dialog. Gating here therefore mirrors Claude's real prompts one-to-one: the notch asks
# exactly when, and only when, Claude would have asked. (session-hook.sh's PreToolUse hook
# stays a passive observer for live status; the gate lives here.)
#
# This hook BLOCKS: it publishes the request for the ClawdIsland app to display, waits for
# the user's Approve/Deny in the notch, and relays that decision back to Claude Code.
#
# Contract with Claude Code (verified against code.claude.com/docs/en/hooks):
#   exit 0 + {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
#             "decision":{"behavior":"allow"}}}                  -> grant, tool runs
#   exit 0 + {... "decision":{"behavior":"deny","message":...}}  -> block, message shown
#   exit 0 + NO JSON  -> defer to Claude Code's normal permission dialog. This is our
#     fallback for every non-answer: app not running, app quit mid-wait, or a timeout.
#     The notch is an extra approval surface, never the sole gate.
#
# App liveness: a file-based protocol (below) can't fail fast the way a socket connect does,
# so if the app is closed we would otherwise block Claude for the whole timeout. To avoid
# that, the running app re-stamps an `app-heartbeat` file every couple of seconds; we treat a
# missing/stale heartbeat as "app not running" and defer immediately, and also bail mid-wait
# if the heartbeat goes stale (app quit while a request was pending).
#
# Protocol (files under support_dir/permissions.d/, one pair per request):
#   <id>.request   written here, read by the app  — the pending prompt
#   <id>.decision  written by the app, read here  — {"decision":"allow"|"deny"}
# Both are removed by whichever side finishes; orphans are pruned by the app.

# Fail OPEN, always. Any error path falls through to a silent exit 0 so a broken hook can
# never block the user's tools — Claude Code's normal dialog takes over.
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || exit 0

support_dir="$HOME/Library/Application Support/ClawdIsland"
req_dir="$support_dir/permissions.d"
heartbeat="$support_dir/app-heartbeat"

# How stale the app's heartbeat may be before we treat the app as not running. The app
# re-stamps roughly every 2s; 6s tolerates a couple of missed beats without stranding Claude.
heartbeat_max_age=6

# Epoch mtime of a file, or empty if it doesn't exist. macOS stat syntax.
file_mtime() { stat -f %m "$1" 2>/dev/null; }

# True only when the app heartbeat exists and is fresh.
app_is_alive() {
  local m now age
  m="$(file_mtime "$heartbeat")"
  [ -n "$m" ] || return 1
  now="$(date +%s 2>/dev/null)" || return 0   # can't tell -> assume alive, let the wait decide
  age=$(( now - m ))
  [ "$age" -le "$heartbeat_max_age" ]
}

payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0

tool_name="$(printf '%s' "$payload"  | jq -r '.tool_name  // empty' 2>/dev/null)"
[ -n "$tool_name" ] || exit 0

# App not running -> don't even publish a request; defer straight to the normal dialog so the
# user isn't left staring at a terminal prompt while a dead notch never answers.
app_is_alive || exit 0

session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
cwd="$(printf '%s' "$payload"        | jq -r '.cwd        // empty' 2>/dev/null)"

# The one salient argument, same priority order and field names as session-hook.sh, so the
# notch shows the same subtitle it does for live activity (file path / command / …).
detail="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.command // .tool_input.pattern // .tool_input.url // .tool_input.query // empty' 2>/dev/null)"

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$created_at" ] || exit 0

id="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
[ -n "$id" ] || id="$$-$(date +%s)-$RANDOM"

mkdir -p "$req_dir" 2>/dev/null || exit 0

request_file="$req_dir/$id.request"
decision_file="$req_dir/$id.decision"

# Publish the request atomically (temp + mv) so the app never reads a half-written file.
tmp="$request_file.tmp.$$"
jq -n \
  --arg id "$id" \
  --arg sid "$session_id" \
  --arg tool "$tool_name" \
  --arg detail "$detail" \
  --arg cwd "$cwd" \
  --arg ts "$created_at" \
  '{id: $id, tool_name: $tool, created_at: $ts}
     + (if $sid    != "" then {session_id: $sid} else {} end)
     + (if $detail != "" then {detail: $detail}  else {} end)
     + (if $cwd    != "" then {cwd: $cwd}        else {} end)' \
  > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
mv -f "$tmp" "$request_file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }

# Wait for the app's decision. The PermissionRequest hook's default timeout is 600s and the
# installer sets `timeout` explicitly, so we cap our own wait comfortably below that. If we
# time out — or the app quits mid-wait (heartbeat goes stale) — we clean up and defer.
waited=0
max_wait=120
poll=0.2
while [ "$(printf '%.0f' "$waited")" -lt "$max_wait" ]; do
  if [ -f "$decision_file" ]; then
    decision="$(jq -r '.decision // empty' "$decision_file" 2>/dev/null)"
    rm -f "$decision_file" "$request_file" 2>/dev/null
    case "$decision" in
      allow)
        jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}'
        exit 0
        ;;
      deny)
        jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: "Denied from Clawd Island"}}}'
        exit 0
        ;;
      *)
        exit 0   # malformed decision -> treat as no answer, defer.
        ;;
    esac
  fi
  # App quit while we were waiting: stop holding Claude, hand back to the normal dialog.
  app_is_alive || { rm -f "$request_file" 2>/dev/null; exit 0; }
  sleep "$poll" 2>/dev/null || sleep 1
  waited="$(awk "BEGIN{print $waited + $poll}" 2>/dev/null)"
  [ -n "$waited" ] || waited="$max_wait"   # awk missing -> stop looping, fall back
done

# Timed out: remove our now-stale request and defer to Claude Code's normal dialog.
rm -f "$request_file" 2>/dev/null
exit 0
