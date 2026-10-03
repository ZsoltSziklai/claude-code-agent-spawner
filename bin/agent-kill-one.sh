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
# ⚠️ A FORK-FABOL IS KI KELL VENNI. Eddig csak a `close-tree` tette meg, igy a
# `kill-one` (es az erre epulo `kill-tree`) utan a gyerek bent maradt a faban —
# 2026-10-03-an egy eles proba utan pont igy maradt ott egy halott fork. Kesobb egy
# azonos nevu uj agent a REGI szulot orokolne a melysegszamitasban.
fork_tree_forget "$NAME" 2>/dev/null

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
