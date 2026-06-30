#!/usr/bin/env bash
# Emits a systemMessage telling Claude to invoke the wrapup skill
# before context compaction or at session end.

set -euo pipefail

EVENT="${1:-Unknown}"

# Drain stdin (hook payload) so the pipe doesn't break — we don't need its contents
cat > /dev/null 2>&1 || true

case "$EVENT" in
  PreCompact)
    MSG="Context compaction is about to run. Before compacting, invoke the wrapup skill (Skill tool, name 'wrapup') to summarize this session, save memories, and push a session log to the NotebookLM AI Brain notebook. Keep it concise — the user wants the summary saved before context is compressed."
    ;;
  SessionEnd)
    MSG="The session is ending (exiting Claude Code). If meaningful work happened this session, invoke the wrapup skill now to save memories and push a session summary to NotebookLM. Skip if the session was trivial."
    ;;
  Clear)
    MSG="The user typed /clear to reset the conversation. Before the context is cleared, invoke the wrapup skill (Skill tool, name 'wrapup') to summarize what happened this session, save any key memories, and push a session log to the NotebookLM AI Brain notebook."
    ;;
  *)
    MSG="wrapup-trigger fired with unknown event: $EVENT"
    ;;
esac

# Messages above contain no double-quotes or backslashes, so safe to embed directly.
printf '{"continue": true, "suppressOutput": false, "systemMessage": "%s"}\n' "$MSG"
