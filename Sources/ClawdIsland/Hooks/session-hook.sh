#!/usr/bin/env bash
#
# session-hook.sh — ClawdIsland real-time session observer.
#
# Wired into Claude Code as an async hook for SessionStart, PreToolUse, PostToolUse
# and Stop. Reads the hook payload from stdin, distils it into a tiny per-session
# state file that the ClawdIsland app polls, and gets out of the way.
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
#     "started_at": "<ISO8601 UTC>"   // when THIS tool run began; set on PreToolUse,
#                                     // preserved by the PostToolUse heartbeat. Drives
#                                     // the elapsed-time UI, so it must NOT be re-stamped
#                                     // to "now" on every event the way updated_at is.
#     "updated_at": "<ISO8601 UTC>"   // stamped on EVERY write; the app treats a
#                                     // session as alive based on this field
#   }
#
# Why PostToolUse: PreToolUse fires once, at the start of a tool. Claude Code exposes
# NO progress/heartbeat event mid-tool (verified against code.claude.com/docs/en/hooks),
# so a single long call (e.g. `sleep 20`) sends nothing between start and finish.
# PostToolUse re-stamps updated_at when the tool completes, which keeps a *sequence* of
# tools continuously live; the single-long-tool gap is covered by the app's liveWithin
# window being sized generously. See SessionActivityFeed.swift.

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

# Decide status from the event. Both tool events mean "running"; PostToolUse doubles as
# a heartbeat that keeps a multi-tool turn continuously live. Anything unexpected is
# treated as idle so we never leave a stale "running" marker from an event we didn't model.
case "$event" in
  PreToolUse|PostToolUse) status="running" ;;
  SessionStart|Stop) status="idle" ;;
  *) status="idle" ;;
esac

# Current wall-clock time in ISO8601 UTC, re-stamped on every single write. The app
# uses this to decide whether a session is still alive, so it must always be "now".
updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -n "$updated_at" ] || exit 0

target="$state_dir/$session_id.json"

# started_at marks when the current tool run began, and — unlike updated_at — must NOT
# be reset to "now" on every write, or the elapsed-time UI would never advance.
#   PreToolUse  → a fresh run starts: stamp started_at = now.
#   PostToolUse → heartbeat for the same run: carry the existing started_at forward.
#                 Fall back to now only if the prior file is missing/partial.
# Idle events carry no started_at.
started_at=""
if [ "$status" = "running" ]; then
  if [ "$event" = "PreToolUse" ]; then
    started_at="$updated_at"
  else
    [ -f "$target" ] && started_at="$(jq -r '.started_at // empty' "$target" 2>/dev/null)"
    [ -n "$started_at" ] || started_at="$updated_at"
  fi
fi

# Ensure the state directory exists (harmless if it already does).
mkdir -p "$state_dir" 2>/dev/null || exit 0

# Write to a temp file first, then move into place, so a poller never reads a
# half-written file. The PID keeps concurrent sessions from clobbering each other.
tmp="$target.tmp.$$"

# Build the JSON with jq so quoting/escaping is always correct. tool_name and started_at
# are only included while running (idle carries neither). Each optional field is added
# only when non-empty. If the build fails, clean up and bail.
if [ "$status" = "running" ]; then
  jq -n \
    --arg sid "$session_id" \
    --arg status "$status" \
    --arg tool "$tool_name" \
    --arg started "$started_at" \
    --arg ts "$updated_at" \
    '{session_id: $sid, status: $status}
       + (if $tool    != "" then {tool_name: $tool}     else {} end)
       + (if $started != "" then {started_at: $started} else {} end)
       + {updated_at: $ts}' \
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
