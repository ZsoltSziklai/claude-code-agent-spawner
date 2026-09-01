#!/bin/zsh
# Kill all agent-* + TERM the ancestor claude --remote-control process.
emulate -L zsh
set -u
source "$(dirname "${(%):-%x}")/_agent-lib.sh"

# --no-parent: csak agent-* kill, parent claude-ot ne TERM-elj
if [[ "${1:-}" == "--no-parent" ]]; then
  NO_PARENT=true
else
  NO_PARENT=false
fi

# SPAWNER_BIN_DIR a _agent-lib.sh-ból jön
COUNT=0
while read -r NAME; do
  [ -z "$NAME" ] && continue
  "$SPAWNER_BIN_DIR/agent-kill-one.sh" "$NAME"
  COUNT=$((COUNT + 1))
done < <(list_running_agents)

# Clear the whole live/ registry — including entries whose tmux session was
# already gone. Otherwise the child watchdog would resurrect them after a
# deliberate kill-all.
rm -f "$CLAUDE_AGENT_LIVE"/*.json 2>/dev/null

echo "all agents killed ($COUNT)"

# Walk process tree upward looking for claude --remote-control (only if !no-parent)
if $NO_PARENT; then
  echo "skipping parent shutdown (--no-parent)"
  exit 0
fi
pid=$$
PARENT_PID=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  pid=$(ps -p $pid -o ppid= 2>/dev/null | tr -d ' ')
  [ -z "$pid" ] && break
  [ "$pid" -le 1 ] && break
  cmd=$(ps -p $pid -o command= 2>/dev/null)
  if echo "$cmd" | grep -qE 'claude.*--remote-control'; then
    PARENT_PID="$pid"
    break
  fi
done

if [ -n "$PARENT_PID" ]; then
  # Az echo a TERM ELŐTT, mert utána a parent claude bezárja a Bash gyermek-tree-t
  # és a /kill-all-exit slash command output-jában a végső echo elveszne.
  echo "shutting down parent pid $PARENT_PID..."
  kill -TERM "$PARENT_PID" 2>/dev/null
  sleep 1
  kill -0 "$PARENT_PID" 2>/dev/null && kill -KILL "$PARENT_PID" 2>/dev/null
else
  echo "no parent claude found — manual /exit needed"
fi
