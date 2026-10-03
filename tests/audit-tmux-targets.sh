#!/usr/bin/env zsh
# Kiirja minden PREFIX-ERZEKENY tmux-celt a kodban. Kimenet soronkent:
#   <fajl>:<sor>:<ige>:<cel>
# Ures kimenet = rendben.
#
# ⚠️ MIERT KULON SCRIPT, ES MIERT NEM GREP. A korabbi allitas ez volt:
#     grep -rnE '(has-session|...)[^#]*-t "[^=]' ... | grep -cv 'print '
# A `grep -v 'print '` SOROKAT zart ki, es a legfontosabb nyolc hivas pont olyan
# soron all, ahol a hivas ES egy kiiras egyutt van (`... && { print -r -- ... }`).
# Igy a teszt ugyanazt a vakfoltot osztotta, amit a javitasom — es nyolc cel
# evekig prefix-erzekeny maradhatott volna, kozottuk az `agent_tmux_session`, a
# KOZPONTI feloldo. Az ellenorzes ezert PER-TALALAT nez, nem per-sor.
#
# A ket celtipus kulon szabály:
#   session-cel  -> "=nev"    (has-session, kill-session, list-panes, set-option…)
#   pane-cel     -> "=nev:"   (capture-pane, send-keys, display-message…)
# A `=nev` pane-celkent `can't find pane`-nel bukik — ez tette tonkre egy napra a
# feladat-kezbesitest 2026-10-02-an.
set -u
ROOT="${1:-${${(%):-%x}:A:h:h}}"
SESSION_VERBS=(has-session kill-session list-panes set-option show-option)
PANE_VERBS=(capture-pane send-keys display-message respawn-pane select-pane)
ALL=(${SESSION_VERBS[@]} ${PANE_VERBS[@]})
verbs_re=${(j:|:)ALL}

for f in "$ROOT"/bin/*(N.) "$ROOT"/claude-agent-spawner(N.); do
  [[ -r "$f" ]] || continue
  local -i ln=0
  while IFS= read -r line; do
    ln+=1
    [[ "${line## }" == \#* ]] && continue
    # Minden talalat kulon: a soron levo mas szoveg (pl. egy `print`) NEM ad felmentest.
    print -r -- "$line" | grep -oE "($verbs_re)[^\"]*-t +\"[^\"]+\"" 2>/dev/null \
    | while IFS= read -r hit; do
        verb=${hit%%[^a-z-]*}
        target=${${hit##*-t +}//\"/}
        target=${${hit##*\"}:-}
        target=$(print -r -- "$hit" | sed -E 's/.*-t +"([^"]+)".*/\1/')
        [[ "$target" == "="* ]] || { print -r -- "${f:t}:$ln:$verb:$target"; continue }
        if (( ${PANE_VERBS[(I)$verb]} )) && [[ "$target" != *: ]]; then
          print -r -- "${f:t}:$ln:$verb:$target (pane-cél kettőspont nélkül)"
        fi
      done
  done < "$f"
done
