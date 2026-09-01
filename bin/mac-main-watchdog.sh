#!/bin/zsh
# mac-main-watchdog.sh — launchd-driven, 5 percenként fut
# Ha a mac-main claude --remote-control nem fut, újraindítja tmux-ban.
# Kill-switch: ha ~/.claude/agent-queue/watchdog.disabled létezik → exit 0.
emulate -L zsh
set -u

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Always talk to the default tmux server, never inherit a "we are nested"
# $TMUX from a parent — makes a hand-run identical to the launchd run.
unset TMUX

# Config (env-overridable)
: ${ROOT_AGENT_NAME:=mac-main}
: ${CLAUDE_AGENT_QUEUE:=$HOME/.claude/agent-queue}
: ${CLAUDE_AGENT_ROOT:=$HOME/ClaudeProjects}
: ${CLAUDE_AGENT_RESUME:=true}
# A "resume from summary / full as-is" modált az auto_dismiss_modals válaszolja
# meg (különben a launchd-indított session felügyelet nélkül ott állna). A lib
# alapértelmezése `summary`; a command centernél viszont az újraindulás legyen
# LÁTHATATLAN, ne egy sűrített változattal folytatódjon a munka.
# Felülírható: CLAUDE_AGENT_RESUME_MODE=summary egy olcsóbb indításhoz.
: ${CLAUDE_AGENT_RESUME_MODE:=full}

QUEUE_DIR="$CLAUDE_AGENT_QUEUE"
KILL_SWITCH="$QUEUE_DIR/watchdog.disabled"
LOG="$QUEUE_DIR/watchdog.log"
START_SH="${CLAUDE_AGENT_START_SH:-$CLAUDE_AGENT_QUEUE/start.sh}"

# auto_dismiss_modals() — start.sh resumes the previous conversation, so the
# "resume from summary?" prompt can appear on a large session. Nobody is
# attached to a launchd-started session, so it would hang there forever.
source "$(dirname "${(%):-%x}")/_agent-lib.sh"

# Egyszer futásonként — ez a log 5 percenként kap egy sort, örökre.
rotate_log "$LOG"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

if [ -e "$KILL_SWITCH" ]; then
  log "skip (kill-switch present: $KILL_SWITCH)"
  exit 0
fi

# A gyerek-agentek visszaállítása a fő session állapotától FÜGGETLEN — mindkét
# ágon le kell futnia, ezért csak a végén hívjuk, egy helyről.
CHILD_WATCHDOG="$(dirname "${(%):-%x}")/agent-child-watchdog.sh"
sweep_children() {
  [ -x "$CHILD_WATCHDOG" ] && "$CHILD_WATCHDOG"
}

# Fut-e a mac-main?
#
# NEM elég a `ps | grep -- --remote-control <név>`: egy hosszan futó, resume-olt
# session argv-je idővel a kanonikus `claude --resume <id>` formára cserélődik,
# és a --remote-control eltűnik belőle (2026-07-27: két 3.5 órája futó agent
# pontosan így nézett ki, pedig mindkettő --remote-control-lal indult). Mivel a
# start.sh mostantól resume-ol, egy argv-re épülő ellenőrzés előbb-utóbb
# halottnak látna egy ÉLŐ sessiont és újraindítaná — restart-ciklus.
#
# Ezért két független jel, és "fut"-nak számít, ha BÁRMELYIK igent mond. A
# téves "fut" ártalmatlan (a következő kör újranézi), a téves "halott" viszont
# élő sessiont ölne — a bizonytalanságot szándékosan az élet felé billentjük.
main_running() {
  # 1) a saját tmux sessionünk létezik, és a pane processze él
  if tmux has-session -t "$ROOT_AGENT_NAME" 2>/dev/null; then
    local pane_pid
    pane_pid=$(tmux list-panes -t "$ROOT_AGENT_NAME" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [[ -n "$pane_pid" ]] && kill -0 "$pane_pid" 2>/dev/null; then
      return 0
    fi
  fi
  # 2) argv-alapú jel (friss indulásnál ez a megbízható)
  if ps -eo pid,command 2>/dev/null \
     | grep -E "claude .*--remote-control ${ROOT_AGENT_NAME}( |\$)" \
     | grep -v -E 'grep|pgrep|watchdog' | head -1 | grep -q .; then
    return 0
  fi
  return 1
}

if main_running; then
  # ⚠️ Amig fut, rogzitjuk a SAJAT session id-jat. A command center cwd-jen
  # (ClaudeProjects gyoker) gyerek-agentek is osztozhatnak — a spawner ures
  # cwd-nel epp ide teszi oket —, es akkor a "legfrissebb atirat" hevisztika egy
  # GYEREK beszelgeteset adna vissza az ujrainditasnal.
  root_sid=$(agent_session_id "$ROOT_AGENT_NAME" 2>/dev/null || true)
  if [[ -n "$root_sid" ]]; then
    print -r -- "$root_sid" > "$CLAUDE_AGENT_QUEUE/root-session.id.tmp.$$" \
      && mv -f "$CLAUDE_AGENT_QUEUE/root-session.id.tmp.$$" "$CLAUDE_AGENT_QUEUE/root-session.id"
  fi
  log "ok ($ROOT_AGENT_NAME running)"
  sweep_children
  exit 0
fi

log "DOWN — restarting in tmux"

# Ha van orphan tmux session "$ROOT_AGENT_NAME" néven, takarítsuk
if tmux has-session -t "$ROOT_AGENT_NAME" 2>/dev/null; then
  tmux kill-session -t "$ROOT_AGENT_NAME" 2>/dev/null
  log "cleaned orphan tmux session"
fi

# Indítsd tmux-ban.
# tmux NEM adja át a mi környezetünket az új pane-nek (a szervernek saját env-je
# van), ezért minden konfigot a parancs-stringbe kell exportálni. Enélkül egy
# ROOT_AGENT_NAME / CLAUDE_AGENT_RESUME felülírás némán elveszik, a start.sh az
# alapértelmezésekkel fut, és rossz (akár élő) sessiont resume-ol.
start_cmd="export ROOT_AGENT_NAME=${(qq)ROOT_AGENT_NAME}"
start_cmd+=" CLAUDE_AGENT_ROOT=${(qq)CLAUDE_AGENT_ROOT}"
start_cmd+=" CLAUDE_AGENT_QUEUE=${(qq)CLAUDE_AGENT_QUEUE}"
start_cmd+=" CLAUDE_AGENT_RESUME=${(qq)CLAUDE_AGENT_RESUME}"
start_cmd+=" && zsh ${(qq)START_SH}"

if tmux new-session -d -s "$ROOT_AGENT_NAME" -c "$CLAUDE_AGENT_ROOT" "$start_cmd"; then
  log "started in tmux (attach: tmux attach -t $ROOT_AGENT_NAME)"
  sleep 5
  if typeset -f auto_dismiss_modals >/dev/null; then
    auto_dismiss_modals "$ROOT_AGENT_NAME"
  fi
else
  log "ERROR tmux new-session failed"
  sweep_children
  exit 1
fi

sweep_children
