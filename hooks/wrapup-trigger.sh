#!/usr/bin/env bash
# Emits a systemMessage telling Claude to invoke the wrapup skill.
#
# Triggers:
#   PreCompact   -> always (before context compaction)
#   SessionEnd   -> always (on exit)
#   Remember     -> ONLY when the user typed "/remember wrap" (plain /remember is ignored)
#
# Dedup guard: if a wrapup was already triggered within DEDUP_MINUTES, the trigger
# is suppressed to avoid a duplicate NotebookLM push (e.g. "/remember wrap" followed
# shortly by SessionEnd). Manual /wrapup bypasses this entirely.

set -euo pipefail

EVENT="${1:-Unknown}"
DEDUP_MINUTES=10
STATE_FILE="${HOME}/.claude/wrapup-last-run.txt"

# Read the hook payload from stdin (UserPromptSubmit carries the prompt text)
PAYLOAD="$(cat 2>/dev/null || true)"

# Emit a JSON result. Args: $1 = systemMessage (plain text, no quotes/backslashes)
emit() {
  printf '{"continue": true, "suppressOutput": false, "systemMessage": "%s"}\n' "$1"
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
      MINS=$(( AGE / 60 ))
      emit "A wrapup was already triggered ${MINS} min ago (within the ${DEDUP_MINUTES}-minute dedup window), so this automatic trigger is being skipped to avoid a duplicate NotebookLM push. To force another full wrapup now, run /wrapup manually."
      exit 0
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
    emit "The user ran '/remember wrap'. After the remember skill saves its handoff note, also invoke the wrapup skill (Skill tool, name 'wrapup') to summarize this session, save key memories, and push a session log to the NotebookLM AI Brain notebook. Context is still intact, so do the full wrapup now."
    ;;
  *)
    emit "wrapup-trigger fired with unknown event: ${EVENT}"
    ;;
esac
