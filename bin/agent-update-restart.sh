#!/usr/bin/env zsh
# Frissiti a Claude CLI-t, majd a tmuxban futo agenteket ujrainditja az UJ
# binarisra — a sajat beszelgetesuk folytatasaval.
#
# Miert kell ez kulon script: a "kilepek es majd visszajon" kezi kor harom
# csapdat rejt, es 2026-10-01-en mindharomba belefutottunk.
#
#  1) A FRISSITES SORRENDJE. Ha eloszor ujrainditunk, az UJONNAN indult peldany
#     maga toltti le a kovetkezo verziot, es megint kiirja a "Restart to update"-et
#     — vegtelen kergetes. Merve: 08:32:45 indult 2.1.274-tel, 08:33:01-kor mar a
#     2.1.286 volt a lemezen. Ezert a frissites ELOSZOR fut, egyszer, kozosen.
#
#  2) AZ ARGV RESUME-JA NEM AZ AGENT SAJAT SESSIONJE. Egy orokolt fork argv-jeben
#     a SZULO session-idje all (`mac-main-dsolar-mac` argv: `--resume ed43f571`,
#     ami a parancskozponte; a sajatja `f9e3e120`). Az argv ujrahasznositasa tehat
#     a szulo beszelgetesebe tenne a gyereket — pont az a szerep-atveteli hiba,
#     ami ellen a `resume: none` default szuletett. A sajat id-t a FUTO folyamat
#     allapotfajlja adja (`agent_session_id`), ezert KILLELES ELOTT kell kiolvasni.
#
#  3) AMIT A WATCHDOG NEM TUD VISSZAHOZNI, AZT NEM SZABAD MEGOLNI. A forkoknak
#     nincs `live/` bejegyzese (szandekosan nem elesztjuk ujra oket), a gyoker
#     agent pedig a fo watchdog dolga. Ez a script ezert MAGA inditja ujra
#     mindegyiket, es csak azt oli meg, amire elotte sikerult teljes
#     ujrainditasi parancsot osszeallitania.
#
# Hasznalat:
#   agent-update-restart.sh [--dry-run] [--force] [--include-root] [nev ...]
#
#   --dry-run       csak megmutatja, mit tenne
#   --force         a mar friss agenteket is ujrainditja
#   --include-root  a parancskozpontot is (KULON szakasz, lasd lentebb)
#   nev ...         csak ezeket (prefix nelkuli agent-nev)

set -u
HERE="${${(%):-%x}:A:h}"
source "$HERE/_agent-lib.sh" || { print -u2 "a lib nem toltodott be"; exit 2 }

: ${CLAUDE_BIN:="$HOME/.local/bin/claude"}
: ${ROOT_AGENT_NAME:=mac-main}
: ${STABLE_WAIT:=12}          # ennyi mp utan nezzuk, felallt-e

DRY=false FORCE=false ROOT=false
typeset -a ONLY
while (( $# )); do
  case "$1" in
    --dry-run)      DRY=true ;;
    --force)        FORCE=true ;;
    --include-root) ROOT=true ;;
    -h|--help)      sed -n '2,36p' "${(%):-%x}" | sed 's/^# \?//'; exit 0 ;;
    -*)             print -u2 "ismeretlen kapcsolo: $1"; exit 2 ;;
    *)              ONLY+=("$1") ;;
  esac
  shift
done

TMUX_BIN=$(command -v tmux) || { print -u2 "nincs tmux"; exit 2 }
JQ=$(command -v jq)         || { print -u2 "nincs jq";   exit 2 }

say() { print -r -- "$@" }

# --- 1. A FRISSITES ELOSZOR ------------------------------------------------
# Enelkul minden ujrainditott peldany maga telepiti a kovetkezot, es ujra
# ujrainditast ker (lasd a fejlec 1. pontjat).
before=$(readlink "$CLAUDE_BIN" 2>/dev/null | sed 's|.*/||')
if $DRY; then
  say "[dry-run] frissites kimarad; a jelenlegi verzio: ${before:-?}"
else
  say "frissites…"
  if ! "$CLAUDE_BIN" update >/dev/null 2>&1; then
    say "  ⚠️  a 'claude update' nem futott le; a meglevo binarissal folytatom"
  fi
fi
after=$(readlink "$CLAUDE_BIN" 2>/dev/null | sed 's|.*/||')
binmtime=$(stat -f %m "$CLAUDE_BIN" 2>/dev/null || echo 0)
say "binaris: ${after:-?}${${before:+ (volt: $before)}:-}"
say ""

# --- 2. A FUTO AGENTEK OSSZEGYUJTESE ---------------------------------------
# ⚠️ PONTOS session-lista, nem `has-session`: a `-t <nev>` PREFIXRE is illeszkedik,
# es emiatt latta a watchdog epnek a `…-sziklaizsolthu`-t a `…-dsolar-web` miatt.
typeset -a SESSIONS
SESSIONS=(${(f)"$("$TMUX_BIN" ls -F '#{session_name}' 2>/dev/null)"})

typeset -a PLAN SKIP
for sess in $SESSIONS; do
  # Csak az, amiben valoban Claude CLI fut remote-controllal.
  pane_pid=$("$TMUX_BIN" list-panes -t "=$sess" -F '#{pane_pid}' 2>/dev/null | head -1)
  [[ -n "$pane_pid" ]] || continue
  argv=$(ps -ww -o args= -p "$pane_pid" 2>/dev/null) || continue
  [[ "$argv" == *--remote-control* ]] || continue

  name=${${argv##*--remote-control }%% *}
  [[ -n "$name" ]] || continue

  # --- szures nevre
  if (( ${#ONLY} )); then
    [[ -n "${ONLY[(r)$name]-}" ]] || continue
  fi

  # --- a gyoker agent kulon szakasz (a sajat sessionunket is olhetne)
  if [[ "$name" == "$ROOT_AGENT_NAME" ]]; then
    $ROOT || { SKIP+=("$name|a parancskozpont — --include-root nelkul kimarad"); continue }
  fi

  # --- elavult-e: a folyamat a binaris cserelese ELOTT indult
  started=$(ps -o lstart= -p "$pane_pid" 2>/dev/null | sed 's/^ *//')
  pstart=$(date -j -f '%a %b %d %T %Y' "$started" '+%s' 2>/dev/null || echo 0)
  if (( pstart >= binmtime )) && ! $FORCE; then
    SKIP+=("$name|mar a friss binarissal fut")
    continue
  fi

  # --- a SAJAT session-id, a FUTO folyamat allapotfajljabol (fejlec 2. pont)
  sid=$(agent_session_id "$name" 2>/dev/null || true)
  if [[ -z "$sid" ]]; then
    SKIP+=("$name|nem olvashato ki a sajat session-id — nem talalgatok")
    continue
  fi
  cwd=$(agent_session_cwd "$name" 2>/dev/null || true)
  if [[ -z "$cwd" || ! -d "$cwd" ]]; then
    SKIP+=("$name|nincs hasznalhato cwd (${cwd:-ures})")
    continue
  fi

  PLAN+=("$sess|$name|$pane_pid|$sid|$cwd|$argv")
done

if (( ${#SKIP} )); then
  say "kimarad:"
  for e in $SKIP; do printf "  %-44s %s\n" "${e%%|*}" "${e#*|}"; done
  say ""
fi
if (( ! ${#PLAN} )); then say "nincs ujrainditando agent."; exit 0; fi

# --- 3. UJRAINDITAS --------------------------------------------------------
say "ujrainditas (${#PLAN} agent):"
rc=0
for e in $PLAN; do
  sess=${e%%|*};  rest=${e#*|}
  name=${rest%%|*}; rest=${rest#*|}
  pid=${rest%%|*};  rest=${rest#*|}
  sid=${rest%%|*};  rest=${rest#*|}
  cwd=${rest%%|*};  argv=${rest#*|}

  # A fehérlistás újraépítés a libben él (restart_argv), hogy a teszt a VALÓDI
  # logikát mérje, ne a tesztfájlban álló másolatát.
  typeset -a clean
  clean=(${(f)"$(restart_argv "$argv" "$sid")"})

  cmd="cd ${(qq)cwd} && export CLAUDE_AGENT_NAME=${(qq)name} && ${(qq)CLAUDE_BIN}"
  for a in $clean; do cmd+=" ${(qq)a}"; done

  if $DRY; then
    printf "  %-44s resume=%s\n" "$name" "$sid"
    printf "  %-44s cwd=%s\n" "" "$cwd"
    continue
  fi

  # A `live/` szamlalo nullazasa: a SZANDEKOS ujrainditas nem osszeomlas-hurok.
  entry="$CLAUDE_AGENT_LIVE/$name.json"
  if [[ -f "$entry" ]]; then
    tmp=$(mktemp) && "$JQ" '.restore_attempts = 0 | del(.restored_at)' "$entry" > "$tmp" \
      && mv "$tmp" "$entry"
    # ⚠️ A sajat, most kiolvasott id-t is rogzitjuk: a watchdog korabban
    # prefix-illesztessel irta ide, es igy IDEGEN session-id kerult be.
    tmp=$(mktemp) && "$JQ" --arg s "$sid" '.last_session_id = $s' "$entry" > "$tmp" \
      && mv "$tmp" "$entry"
  fi

  "$TMUX_BIN" kill-session -t "=$sess" 2>/dev/null
  if ! "$TMUX_BIN" new-session -d -s "$sess" "$cmd"; then
    print -u2 "  ✗ $name — a tmux new-session elbukott"; rc=1; continue
  fi
  printf "  %-44s indul (resume=%s)\n" "$name" "${sid[1,8]}…"
done

if $DRY; then say ""; say "[dry-run] semmi nem tortent."; exit 0; fi

# --- 4. ELLENORZES ---------------------------------------------------------
# A spawn visszateresi erteke nem bizonyitek: a pane a parancs kilepesekor is
# letrejon egy pillanatra. Ezert varunk, es UTANA nezunk ra.
say ""
say "ellenorzes ${STABLE_WAIT} mp mulva…"
sleep "$STABLE_WAIT"
for e in $PLAN; do
  sess=${e%%|*}; name=${${e#*|}%%|*}
  if "$TMUX_BIN" ls -F '#{session_name}' 2>/dev/null | grep -qx -- "$sess"; then
    p=$("$TMUX_BIN" list-panes -t "=$sess" -F '#{pane_pid}' 2>/dev/null | head -1)
    v=$("$TMUX_BIN" list-panes -t "=$sess" -F '#{pane_current_command}' 2>/dev/null | head -1)
    now=$(agent_session_id "$name" 2>/dev/null || echo '?')
    printf "  ✅ %-42s verzio=%-9s session=%s\n" "$name" "$v" "${now[1,8]}…"
  else
    printf "  ✗  %-42s NEM all — nezd: tmux capture-pane -p -t '=%s'\n" "$name" "$sess"
    rc=1
  fi
done
exit $rc
