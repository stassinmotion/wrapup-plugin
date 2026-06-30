#!/usr/bin/env bash
# Emits an instruction telling Claude to invoke the wrapup skill.
#
# Triggers:
#   PreCompact   -> always (before context compaction)
#   SessionEnd   -> always (on exit)
#   Remember     -> ONLY when the user typed "/remember wrap" (plain /remember is ignored)
#
# Output: uses hookSpecificOutput.additionalContext (the mechanism that actually
# injects an actionable instruction into Claude's context). systemMessage alone is
# only shown to the user and does NOT make Claude act — that was the original bug.
#
# Dedup guard: if a wrapup was already triggered within DEDUP_MINUTES, the trigger
# is suppressed to avoid a duplicate NotebookLM push. Manual /wrapup bypasses this.

set -euo pipefail

EVENT="${1:-Unknown}"
DEDUP_MINUTES=10
STATE_FILE="${HOME}/.claude/wrapup-last-run.txt"

# Map our internal event name to the real Claude Code hook event name.
case "$EVENT" in
  Remember)   HOOK_EVENT="UserPromptSubmit" ;;
  PreCompact) HOOK_EVENT="PreCompact" ;;
  SessionEnd) HOOK_EVENT="SessionEnd" ;;
  *)          HOOK_EVENT="UserPromptSubmit" ;;
esac

# Read the hook payload from stdin (UserPromptSubmit carries the prompt text)
PAYLOAD="$(cat 2>/dev/null || true)"

# Emit an instruction Claude will act on. $1 = message text.
emit() {
  python3 -c '
import json, sys
event, msg = sys.argv[1], sys.argv[2]
print(json.dumps({
    "continue": True,
    "hookSpecificOutput": {"hookEventName": event, "additionalContext": msg},
    "systemMessage": msg,
}))' "$HOOK_EVENT" "$1"
}

# Let the prompt through silently without nagging Claude, then stop.
skip() {
  printf '{"continue": true, "suppressOutput": true}\n'
  exit 0
}

# --- Remember event: only proceed when the user explicitly asked to "wrap" ---
if [ "$EVENT" = "Remember" ]; then
  PROMPT="$(printf '%s' "$PAYLOAD" | python3 -c 'import sys,json
try:
    d = json.load(sys.stdin)
    print(d.get("prompt") or d.get("user_prompt") or "")
except Exception:
    print("")' 2>/dev/null || true)"
  # Require "/remember wrap" (case-insensitive). Plain /remember is a quiet handoff.
  if ! printf '%s' "$PROMPT" | grep -qiE '^/remember[[:space:]]+wrap'; then
    skip
  fi
fi

# --- Dedup guard: skip if we triggered a wrapup within DEDUP_MINUTES ---
NOW="$(date +%s)"
if [ -f "$STATE_FILE" ]; then
  LAST="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
  if printf '%s' "$LAST" | grep -qE '^[0-9]+$'; then
    AGE=$(( NOW - LAST ))
    if [ "$AGE" -lt $(( DEDUP_MINUTES * 60 )) ]; then
      skip
    fi
  fi
fi

# --- Record this trigger time for the dedup guard ---
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
printf '%s\n' "$NOW" > "$STATE_FILE" 2>/dev/null || true

case "$EVENT" in
  PreCompact)
    emit "Context compaction is about to run. Before compacting, invoke the wrapup skill (Skill tool, name 'wrapup') to summarize this session, save memories, and push a session log to the NotebookLM AI Brain notebook. Keep it concise — the user wants the summary saved before context is compressed."
    ;;
  SessionEnd)
    emit "The session is ending (exiting Claude Code). If meaningful work happened this session, invoke the wrapup skill now to save memories and push a session summary to NotebookLM. Skip if the session was trivial."
    ;;
  Remember)
    emit "The user ran '/remember wrap'. After the remember skill saves its handoff note, also invoke the wrapup skill (Skill tool, name 'wrapup') NOW to summarize this session, save key memories, and push a session log to the NotebookLM AI Brain notebook. Context is still intact, so do the full wrapup."
    ;;
  *)
    emit "wrapup-trigger fired with unknown event: ${EVENT}"
    ;;
esac
