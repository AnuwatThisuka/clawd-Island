#!/usr/bin/env bash
#
# permission-hook.sh — ClawdIsland permission gate.
#
# Wired into Claude Code as a SYNCHRONOUS PreToolUse hook (async: false) for the
# gated tool set only (Bash, Write, Edit, MultiEdit, NotebookEdit, WebFetch, mcp__*).
# Unlike session-hook.sh — a passive observer that always exits 0 immediately — this
# hook BLOCKS: it publishes a permission request for the ClawdIsland app to display,
# then waits for the user to approve or deny it in the notch and relays that decision
# back to Claude Code.
#
# Contract with Claude Code (verified against code.claude.com/docs/en/hooks):
#   - exit 0 + JSON with hookSpecificOutput.permissionDecision = "allow"  -> bypass the
#     normal permission prompt and run the tool.
#   - exit 0 + permissionDecision = "deny"  -> block the tool; reason is shown to Claude.
#   - exit 0 + NO JSON  -> defer to Claude Code's normal permission flow (allowlist /
#     terminal prompt). This is our TIMEOUT FALLBACK: if the app never answers (not
#     running, crashed, quit), we stay silent and the user's usual terminal prompt
#     still appears. The notch is additive, never the sole gate.
#
# Protocol (files under state_dir/../permissions.d/, one pair per request):
#   <id>.request   written here, read by the app  — the pending prompt
#   <id>.decision  written by the app, read here  — {"decision":"allow"|"deny"}
# Both are removed by whichever side finishes the exchange; orphans are pruned by the
# app (a hook that timed out leaves only its .request, aged out after ~2 min).

# Fail OPEN, always. Any error path must fall through to a silent exit 0 so a broken
# hook can never block the user's tools — Claude Code's normal flow takes over.
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || exit 0

support_dir="$HOME/Library/Application Support/ClawdIsland"
req_dir="$support_dir/permissions.d"

payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0

session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
tool_name="$(printf '%s' "$payload"  | jq -r '.tool_name  // empty' 2>/dev/null)"
cwd="$(printf '%s' "$payload"        | jq -r '.cwd        // empty' 2>/dev/null)"

# The one salient argument, same priority order and field names as session-hook.sh, so
# the notch shows the same subtitle it does for live activity (file path / command / …).
detail="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.command // .tool_input.pattern // .tool_input.url // .tool_input.query // empty' 2>/dev/null)"

# Without a tool name there is nothing meaningful to approve; defer to normal flow.
[ -n "$tool_name" ] || exit 0

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$created_at" ] || exit 0

# Unique per request. uuidgen when available, else a PID + nanosecond fallback that is
# still collision-safe across concurrent sessions.
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

# Poll for the app's decision. Claude Code's default hook timeout is 60s, so we cap our
# own wait below that (55s) and leave a margin: if we time out we clean up our request
# and exit 0 silently, handing back to the normal prompt.
waited=0
max_wait=55
poll=0.2
while [ "$(printf '%.0f' "$waited")" -lt "$max_wait" ]; do
  if [ -f "$decision_file" ]; then
    decision="$(jq -r '.decision // empty' "$decision_file" 2>/dev/null)"
    rm -f "$decision_file" "$request_file" 2>/dev/null
    case "$decision" in
      allow)
        jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "Approved from Clawd Island"}}'
        exit 0
        ;;
      deny)
        jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "Denied from Clawd Island"}}'
        exit 0
        ;;
      *)
        # Malformed decision — treat as no answer, fall back to normal flow.
        exit 0
        ;;
    esac
  fi
  sleep "$poll" 2>/dev/null || sleep 1
  waited="$(awk "BEGIN{print $waited + $poll}" 2>/dev/null)"
  [ -n "$waited" ] || waited="$max_wait"   # awk missing -> stop looping, fall back
done

# Timed out: remove our now-stale request and defer to Claude Code's normal prompt.
rm -f "$request_file" 2>/dev/null
exit 0
