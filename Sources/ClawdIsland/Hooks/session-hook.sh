#!/usr/bin/env bash
#
# session-hook.sh — ClawdIsland real-time session observer.
#
# Wired into Claude Code as an async hook for SessionStart, PreToolUse and Stop.
# Reads the hook payload from stdin, distils it into a tiny per-session state file
# that the ClawdIsland app polls, and gets out of the way.
#
# Contract: this script is a passive OBSERVER, never a gate. It must never block,
# never slow Claude Code down, and never return a non-zero status — every path,
# including every failure, ends in `exit 0`. If anything goes wrong we would rather
# lose a state update than interfere with the user's session.
#
# State file: ~/Library/Application Support/ClawdIsland/state.d/<session_id>.json
#   {
#     "session_id": "<id>",
#     "status":     "idle" | "running",
#     "tool_name":  "<tool>"   // present only while running
#     "updated_at": "<ISO8601 UTC>"   // stamped on EVERY write; the app treats a
#                                     // session as alive based on this field
#   }

# Fail silently, always. No `set -e`: a mid-script error must not skip the exit 0.
# Belt-and-braces trap so an unexpected signal still leaves Claude Code untouched.
trap 'exit 0' EXIT

# jq is required to parse the payload and to emit valid JSON. If it is missing we
# simply do nothing — the app just won't get live status, which is harmless.
command -v jq >/dev/null 2>&1 || exit 0

state_dir="$HOME/Library/Application Support/ClawdIsland/state.d"

# Slurp the hook payload from stdin. Guard against no stdin / empty input.
payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0

# Pull the fields we care about. `// empty` keeps missing keys as empty strings
# rather than the literal "null". A malformed payload yields empty vars and we bail.
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
tool_name="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"

# Without a session id there is nowhere to write and nothing to identify. Bail.
[ -n "$session_id" ] || exit 0

# Decide status from the event. Anything unexpected is treated as idle so we never
# leave a stale "running" marker lingering from an event we didn't model.
case "$event" in
  PreToolUse) status="running" ;;
  SessionStart|Stop) status="idle" ;;
  *) status="idle" ;;
esac

# Current wall-clock time in ISO8601 UTC, re-stamped on every single write. The app
# uses this to decide whether a session is still alive, so it must always be "now".
updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$updated_at" ] || exit 0

# Ensure the state directory exists (harmless if it already does).
mkdir -p "$state_dir" 2>/dev/null || exit 0

target="$state_dir/$session_id.json"
# Write to a temp file first, then move into place, so a poller never reads a
# half-written file. The PID keeps concurrent sessions from clobbering each other.
tmp="$target.tmp.$$"

# Build the JSON with jq so quoting/escaping is always correct. tool_name is only
# included while running (idle carries no tool). If the build fails, clean up and bail.
if [ "$status" = "running" ] && [ -n "$tool_name" ]; then
  jq -n \
    --arg sid "$session_id" \
    --arg status "$status" \
    --arg tool "$tool_name" \
    --arg ts "$updated_at" \
    '{session_id: $sid, status: $status, tool_name: $tool, updated_at: $ts}' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
else
  jq -n \
    --arg sid "$session_id" \
    --arg status "$status" \
    --arg ts "$updated_at" \
    '{session_id: $sid, status: $status, updated_at: $ts}' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }
fi

mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
