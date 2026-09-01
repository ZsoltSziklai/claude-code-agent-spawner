#!/bin/zsh
# Single-target kill: tmux + worktree drop if spec.worktree=true
emulate -L zsh
set -u
source "$(dirname "${(%):-%x}")/_agent-lib.sh"

NAME="${1:?usage: $0 <NAME>}"
NAME="${NAME#agent-}"

# Unregister FIRST — otherwise the child watchdog could restore it in the
# window between the tmux kill and the registry cleanup.
unregister_agent "$NAME"

kill_one_tmux "$NAME"

SPEC=$(find_spec "$NAME")
if [ -n "$SPEC" ]; then
  WT=$(read_spec_field "$SPEC" worktree)
  CWD=$(read_spec_field "$SPEC" cwd)
  # A worktree a git toplevel alatt van, NEM a spec cwd-je alatt — a
  # worktree_path() oldja fel, és üreset ad, ha nincs worktree.
  WT_PATH=$(worktree_path "$CWD" "$WT" "$NAME")
  if [ -n "$WT_PATH" ]; then
    remove_worktree "$CWD" "$WT_PATH" "worktree-$NAME"
  fi
fi
echo "killed: $NAME"
