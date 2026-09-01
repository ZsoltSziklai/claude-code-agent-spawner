#!/bin/zsh
# agent-child-watchdog.sh — restart-survival for CHILD agents.
#
# mac-main-watchdog.sh only guards the command-center session; every child
# spawned from it died on reboot and stayed dead. This script closes that gap:
# for each agent in the live/ registry whose tmux session is gone, it re-spawns
# it with its ORIGINAL spec parameters and `--resume <newest session id>`, so
# the conversation continues instead of starting over.
#
# Driven by mac-main-watchdog.sh (launchd, every 300s + RunAtLoad).
#
# Kill-switches: ~/.claude/agent-queue/watchdog.disabled (global)
#                ~/.claude/agent-queue/child-watchdog.disabled (children only)
emulate -L zsh
setopt nullglob
set -u

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Remote Control needs the full-scope claude.ai login; an inference-only
# CLAUDE_CODE_OAUTH_TOKEN inherited from launchd silently disables it.
unset CLAUDE_CODE_OAUTH_TOKEN

source "$(dirname "${(%):-%x}")/_agent-lib.sh"

LOG="$CLAUDE_AGENT_QUEUE/watchdog.log"
KILL_SWITCH="$CLAUDE_AGENT_QUEUE/watchdog.disabled"
CHILD_KILL_SWITCH="$CLAUDE_AGENT_QUEUE/child-watchdog.disabled"
MAX_ATTEMPTS="${CLAUDE_AGENT_MAX_RESTORE:-3}"
# Mennyi ideig kell futnia egy visszaallitott agentnek, hogy a kiserlet-szamlalo
# nullazodjon. A tick 300s, tehat a kovetkezo korben teljesul — de a spawn utani
# 5 masodperces "meg fut" merceben nem.
MIN_STABLE="${CLAUDE_AGENT_MIN_STABLE:-120}"
# Visszaállításkor is TELJES átvétel: egy crash vagy reboot utáni helyreállás
# legyen láthatatlan, ne folytatódjon a munka egy sűrített változatból. Ezt a
# modált az auto_dismiss_modals válaszolja meg (a lib alapértelmezése summary).
# Felülírható: CLAUDE_AGENT_RESUME_MODE=summary olcsóbb helyreállításhoz.
: ${CLAUDE_AGENT_RESUME_MODE:=full}

rotate_log "$LOG"

log() { printf '%s [child] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

if [[ -e "$KILL_SWITCH" || -e "$CHILD_KILL_SWITCH" ]]; then
  exit 0
fi

# NEVER name this variable TMUX — tmux reads $TMUX from the environment to find
# the server socket. If TMUX is already exported (i.e. we run from inside tmux),
# assigning it clobbers the real socket triple and every tmux call fails with
# "Socket operation on non-socket". Unset it too, so we always talk to the
# default server instead of thinking we are nested.
unset TMUX
JQ=$(command -v jq 2>/dev/null || true)
TMUX_BIN=$(command -v tmux 2>/dev/null || true)
CLAUDE=$(command -v claude 2>/dev/null || true)
if [[ -z "$JQ" || -z "$TMUX_BIN" || -z "$CLAUDE" ]]; then
  log "ERROR missing tool (jq=$JQ tmux=$TMUX_BIN claude=$CLAUDE)"
  exit 1
fi

mkdir -p "$CLAUDE_AGENT_LIVE"

# Persist a field back into the registry entry (atomic rename).
set_field() {
  local entry="$1" expr="$2" tmp
  tmp="${entry}.tmp.$$"
  if "$JQ" "$expr" "$entry" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$entry"
  else
    rm -f "$tmp"
  fi
}

for entry in "$CLAUDE_AGENT_LIVE"/*.json; do
  name="${entry:t:r}"
  sess="agent-$name"

  attempts=$("$JQ" -r '.restore_attempts // 0' "$entry" 2>/dev/null)
  [[ "$attempts" == <-> ]] || attempts=0

  if "$TMUX_BIN" has-session -t "$sess" 2>/dev/null; then
    # Healthy — de a szamlalot CSAK akkor nullazzuk, ha a visszaallitas ota
    # eltelt MIN_STABLE masodperc. Korabban a nullazas kozvetlenul a spawn utan
    # tortent, ezert a korlat csak az INDULASKOR osszeomlo agentet fogta meg:
    # amelyik egy perccel kesobb halt meg ismetlodve, az orokke ujraindult.
    if (( attempts > 0 )); then
      restored_at=$("$JQ" -r '.restored_at // 0' "$entry" 2>/dev/null)
      if restore_counter_should_reset "$restored_at" "$(date -u +%s)" "$MIN_STABLE"; then
        set_field "$entry" '.restore_attempts = 0 | del(.restored_at)'
      fi
    fi
    # ⚠️ AMIG FUT, rogzitjuk a SAJAT session id-jat. Ez az egyetlen pillanat,
    # amikor biztosan tudjuk, melyik atirat az ove (a folyamat allapotfajljabol);
    # holt agentnel mar csak talalgatni lehetne, es kozos cwd-nel a talalgatas
    # MAS AGENT beszelgeteset adna vissza.
    live_sid=$(agent_session_id "$name" 2>/dev/null || true)
    if [[ -n "$live_sid" && "$live_sid" != "$(registry_field "$name" last_session_id 2>/dev/null)" ]]; then
      set_field "$entry" ".last_session_id = \"$live_sid\""
    fi
    continue
  fi

  if (( attempts >= MAX_ATTEMPTS )); then
    # Bounded retries: a permanently broken agent must not respawn forever.
    continue
  fi

  # EGY FORRAS: a parameterek a specbol jonnek; a live/ csak fallback (es a
  # restore_attempts gazdaja). A ket hely elcsuszasa csendes volt — most eloszor
  # naplozzuk, aztan a spec nyer.
  spec=$(find_spec "$name" 2>/dev/null)
  while IFS= read -r diverg; do
    [[ -n "$diverg" ]] && log "DIVERG $name $diverg — a spec nyer"
  done < <(spec_live_divergences "$spec" "$entry")

  cwd=$(spec_or_live_field      "$spec" "$entry" cwd             "")
  worktree=$(spec_or_live_field "$spec" "$entry" worktree        false)
  model=$(spec_or_live_field    "$spec" "$entry" model           opus)
  effort=$(spec_or_live_field   "$spec" "$entry" effort          high)
  pm=$(spec_or_live_field       "$spec" "$entry" permission_mode auto)
  brief=$(spec_or_live_field    "$spec" "$entry" brief           true)
  # A prompt futasideju: resume-nal amugy sem fuzzuk hozza, marad a live/-ban.
  prompt=$("$JQ" -r '.prompt // empty'       "$entry")

  if [[ -z "$cwd" ]]; then
    log "SKIP $name (no cwd in registry entry)"
    continue
  fi

  rcwd=$(agent_runtime_cwd "$cwd" "$worktree" "$name")
  if [[ ! -d "$rcwd" ]]; then
    log "SKIP $name (cwd gone: $rcwd)"
    continue
  fi

  # A sajat, korabban rogzitett atirat. Ha nincs, es a cwd OSZTOTT, inkabb nem
  # inditjuk ujra: rossz beszelgetes folytatasa rosszabb, mint a kimarado restore.
  sid=$(resolve_resume_sid "$name" "$rcwd" 2>"$CLAUDE_AGENT_QUEUE/.resume-why.$$"); sid_rc=$?
  why=$(<"$CLAUDE_AGENT_QUEUE/.resume-why.$$" 2>/dev/null); rm -f "$CLAUDE_AGENT_QUEUE/.resume-why.$$"
  if (( sid_rc == 2 )); then
    # Nincs atirat: az agent meg sosem beszelt -> friss indítás az eredeti prompttal.
    sid=""
    log "FRESH $name — nincs átirat, friss indítás"
  elif (( sid_rc != 0 )); then
    log "SKIP $name — ${why:-ismeretlen ok}"
    log "     kézzel: tmux new-session -s ${sess} -c ${rcwd} 'claude --remote-control ${name} --resume <id>'"
    continue
  fi

  cmd_args=("--remote-control" "$name"
            "--permission-mode" "$pm"
            "--model" "$model"
            "--effort" "$effort")
  [[ "$brief" == "true" ]] && cmd_args+=("--brief")
  cmd_args+=("--chrome")

  if [[ -n "$sid" ]]; then
    # Resume — do NOT append the original prompt, it would land as a new turn.
    cmd_args+=("--resume" "$sid")
    mode="resume=$sid"
  else
    mode="fresh"
  fi

  # NOTE: no --worktree= flag on restore. The worktree already exists; we cd
  # straight into it. Passing it again would try to create a second one.
  shell_cmd="cd ${(qq)rcwd} && export LANG=${(qq)${CLAUDE_AGENT_LANG:-en_US.UTF-8}} && export CLAUDE_AGENT_NAME=${(qq)name} && ${(qq)CLAUDE}"
  for arg in "${cmd_args[@]}"; do
    shell_cmd+=" ${(qq)arg}"
  done
  [[ -z "$sid" && -n "$prompt" ]] && shell_cmd+=" ${(qq)prompt}"

  # Count the attempt BEFORE spawning, so a crash-loop stays bounded even if
  # this script is killed mid-restore.
  set_field "$entry" ".restore_attempts = $((attempts + 1))"

  log "DOWN $name — restoring ($mode, cwd=$rcwd, attempt $((attempts + 1))/$MAX_ATTEMPTS)"

  if ! "$TMUX_BIN" new-session -d -s "$sess" "$shell_cmd"; then
    log "ERROR $name tmux new-session failed"
    continue
  fi

  sleep 5
  if ! "$TMUX_BIN" has-session -t "$sess" 2>/dev/null; then
    log "ERROR $name exited within 5s (check flags / auth)"
    continue
  fi

  # Unattended startup modals (chrome confirm, fullscreen renderer, resume mode)
  auto_dismiss_modals "$sess"

  # NEM nullazzuk itt: a "sikeres" spawn merceje 5 masodperc, es egy perccel
  # kesobb osszeomlo agent igy hatartalanul ujraindulhatna. A nullazas a
  # KOVETKEZO tick "meg mindig fut" agara kerult (lasd fent, MIN_STABLE).
  set_field "$entry" ".restored_at = $(date -u +%s)"
  log "RESTORED $name ($mode) — attach: tmux attach -t $sess"
done
