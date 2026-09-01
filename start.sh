#!/bin/zsh
# start.sh - launch the command-center Remote Control session.
# A help bannert a system promptba tesszük, az első user üzenet csak egy rövid
# "szia" — így nem duplikálódik a chat-ben a hosszú prompt.

# Config (env-overridable)
: ${ROOT_AGENT_NAME:=mac-main}
: ${CLAUDE_AGENT_ROOT:=$HOME/ClaudeProjects}
: ${CLAUDE_AGENT_QUEUE:=$HOME/.claude/agent-queue}
# Resume the previous command-center conversation instead of starting a fresh
# one. Without this every restart splits the history into a new transcript.
# Set CLAUDE_AGENT_RESUME=false for a deliberately clean start.
: ${CLAUDE_AGENT_RESUME:=true}

# latest_session_id() lives in the shared lib; installed next to us in bin/,
# or one level down when run straight from the repo.
for _lib in "$CLAUDE_AGENT_QUEUE/bin/_agent-lib.sh" "${0:A:h}/bin/_agent-lib.sh"; do
  if [[ -r "$_lib" ]]; then source "$_lib"; break; fi
done

# Export CLAUDE_AGENT_NAME so /new-agent inside main knows the parent name
# → child sessions get "${ROOT_AGENT_NAME}-<name>" prefix (parent-aware naming).
# UTF-8: launchd alol NINCS LANG, es a C-locale bajtonként vagja a tobbajtos
# karaktereket — az ekezetek a terminal-kijeloleskor/masolaskor romlanak el.
export LANG="${CLAUDE_AGENT_LANG:-en_US.UTF-8}"
export CLAUDE_AGENT_NAME="$ROOT_AGENT_NAME"

# Explicit cwd — különben a launchd-spawned context "/" cwd-vel indít,
# ami workspace trust dialogot vált ki és blokkolja a Remote Control bridge-t.
# ⚠️ Az ELLENORZES nem elhagyhato: ha a cd elbukik (torolt vagy at nem csatolt
# konyvtar), a szkript "/" cwd-vel futna tovabb — pontosan azt a hibat okozva,
# ami ellen ez a sor vedeni hivatott. Inkabb alljunk meg hangosan.
cd "$CLAUDE_AGENT_ROOT" || {
  print -u2 "start.sh: nem sikerult belepni ide: $CLAUDE_AGENT_ROOT"
  exit 1
}

# Guard: soha ne induljon második példány ugyanazon a néven. Mivel lentebb a
# cwd LEGFRISSEBB átiratát resume-oljuk, egy párhuzamos indítás két claude
# folyamatot kötne UGYANARRA a transcript-fájlra.
if ps -eo command 2>/dev/null \
   | grep -E "claude .*--remote-control ${ROOT_AGENT_NAME}( |\$)" \
   | grep -qv -E 'grep|watchdog'; then
  print -u2 "start.sh: '${ROOT_AGENT_NAME}' mar fut — nem inditok masodik peldanyt."
  exit 1
fi

SYSTEM_PROMPT="Te vagy a ${ROOT_AGENT_NAME} command-center Remote Control session. Ha a felhasználó első üzenete egyszerű köszönés (\"szia\", \"hello\", \"hi\", \"start\", üres), válaszolj PONTOSAN ezzel a banner-szöveggel, semmi mást, semmi körítést, semmi kommentárt:

${ROOT_AGENT_NAME} · command center

/new-agent
új háttér session

/close-agent
lezárás — merge vagy drop

/kill-agent
azonnali kill

/kill-all-exit
mindet kill + kilépés

/fork
ez a session elágaztatása

bármi más: nekem szólj

Ezután várd a következő utasítást. Ne kezdj el dolgozni, ne kérdezz vissza, ne hívj toolt."

args=(
  --remote-control "$ROOT_AGENT_NAME"
  --brief
  --permission-mode auto
  --model opus
  --effort high
  # Claude in Chrome: a spawnolt agentek eddig is megkaptak (a spawner explicit
  # átadja), a command center viszont nem — így pl. a claude-vault
  # bejelentkezés-folyamata (javascript_tool a lapon) innen nem volt futtatható.
  --chrome
  --append-system-prompt "$SYSTEM_PROMPT"
)

# Resume the newest transcript for this cwd, if there is one. On resume we pass
# NO prompt — a positional prompt would land as a fresh user turn (and would
# re-trigger the banner). First ever start has nothing to resume, so it falls
# back to the greeting that produces the banner.
# ⚠️ ELOSZOR a sajat, korabban rogzitett atirat (a watchdog irja, amig futunk).
# A "cwd legfrissebb atirata" hevisztika csak tartalek: ezen a cwd-n gyerek
# agentek is osztozhatnak (a spawner ures cwd-nel ide teszi oket), es akkor a
# hevisztika EGY GYEREK beszelgeteset folytatna — a sajat elozmeny pedig
# csendben elarvulna.
SID=""
if [[ "$CLAUDE_AGENT_RESUME" == "true" ]]; then
  ROOT_SID_FILE="$CLAUDE_AGENT_QUEUE/root-session.id"
  if [[ -r "$ROOT_SID_FILE" ]]; then
    SID=$(<"$ROOT_SID_FILE")
    if [[ -n "$SID" ]] && typeset -f transcript_dir >/dev/null; then
      [[ -f "$(transcript_dir "$CLAUDE_AGENT_ROOT")/$SID.jsonl" ]] || SID=""
    fi
  fi
  if [[ -z "$SID" ]] && typeset -f latest_session_id >/dev/null; then
    SID=$(latest_session_id "$CLAUDE_AGENT_ROOT" 2>/dev/null) || SID=""
  fi
fi

if [[ -n "$SID" ]]; then
  exec claude "${args[@]}" --resume "$SID"
else
  exec claude "${args[@]}" 'szia'
fi
