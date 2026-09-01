#!/bin/zsh
# Cascade kill: NAME + descendants (agent-NAME-* pattern).
emulate -L zsh
set -u
source "$(dirname "${(%):-%x}")/_agent-lib.sh"

# ⚠️ A nev VALIDALASA kotelezo, mielott grep-mintaba kerul (list_descendants).
# Enelkul egy `.*` argumentum — elgepeles vagy egy slash parancsot ertelmezo
# modell hibaja — MINDEN futo agentre kiterjesztene a kaszkadot: a hibas bemenet
# nem megallitana, hanem hatokort tagitana. A spawner es a hid mar validal, a
# kaszkad-parancsok eddig nem.
PARENT="${1:?usage: $0 <NAME>}"
[[ "$PARENT" =~ '^[a-zA-Z0-9_-]{3,64}$' ]] || {
  print -u2 "érvénytelen agent-név: $PARENT (megengedett: [a-zA-Z0-9_-]{3,64})"; exit 2 }
PARENT="${PARENT#agent-}"

# DIR provided by _agent-lib.sh as SPAWNER_BIN_DIR
# Use process substitution — pipe puts the loop in a subshell, losing COUNT.
COUNT=0
while read -r NAME; do
  [ -z "$NAME" ] && continue
  "$SPAWNER_BIN_DIR/agent-kill-one.sh" "$NAME"
  COUNT=$((COUNT + 1))
done < <(list_descendants "$PARENT")
echo "tree killed: $PARENT ($COUNT agent)"
