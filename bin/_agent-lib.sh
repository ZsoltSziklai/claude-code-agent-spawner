#!/bin/zsh
# _agent-lib.sh — Shared helpers for agent-spawner scripts.
# Source it: source "$(dirname "${(%):-%x}")/_agent-lib.sh"
# All public functions echo to stdout, return 0 on success.

# Config defaults — env-overridable (set in plist or shell)
source "$(dirname "${(%):-%x}")/_models.sh"   # modell-fehérlista, EGY forrás

: ${ROOT_AGENT_NAME:=mac-main}
: ${CLAUDE_AGENT_ROOT:=$HOME/ClaudeProjects}
: ${CLAUDE_AGENT_QUEUE:=$HOME/.claude/agent-queue}
# live/ = registry of agents that SHOULD be running (survives reboot).
# The spawner registers on spawn; kill/close unregister. agent-child-watchdog.sh
# restores anything in here whose tmux session is gone.
: ${CLAUDE_AGENT_LIVE:=$CLAUDE_AGENT_QUEUE/live}
# Log rotation — watchdog.log gains a line every 300s forever, so without this
# it grows without bound (794 KB / 18881 lines by 2026-07-27).
: ${CLAUDE_AGENT_LOG_MAX:=1048576}   # rotate above 1 MiB
: ${CLAUDE_AGENT_LOG_KEEP:=3}        # keep .1 .. .3, drop older

# Script-dir helper — exporting where the bin/ live (this lib's dir).
# Action scripts (agent-kill-*.sh, agent-close-*.sh) source us, then use $SPAWNER_BIN_DIR.
SPAWNER_BIN_DIR="$(dirname "${(%):-%x}" 2>/dev/null)"

# Rotate $1 if it grew past the size cap: f -> f.1 -> f.2 -> ... -> dropped.
# Call once per script run, before the first log line. Always returns 0 so a
# caller running under err_exit is never killed by a rotation no-op.
rotate_log() {
  local f="$1"
  local max="${2:-$CLAUDE_AGENT_LOG_MAX}"
  local keep="${3:-$CLAUDE_AGENT_LOG_KEEP}"
  [[ -n "$f" && -f "$f" ]] || return 0
  local size
  size=$(stat -f %z "$f" 2>/dev/null) || return 0
  [[ "$size" == <-> ]] || return 0
  (( size >= max )) || return 0

  rm -f "$f.$keep" 2>/dev/null
  local i
  for (( i = keep - 1; i >= 1; i-- )); do
    [[ -e "$f.$i" ]] && mv -f "$f.$i" "$f.$((i + 1))" 2>/dev/null
  done
  mv -f "$f" "$f.1" 2>/dev/null
  : > "$f"
  return 0
}

# Most recent done/ spec for a given name. Echoes spec-path or empty.
find_spec() {
  local name="$1"
  if [ -z "$name" ]; then return 1; fi
  # xargs -t multiple paths-szel hívja az ls-t — így a -t rendezés ÖSSZES találatra
  grep -l "\"name\": \"$name\"" "$CLAUDE_AGENT_QUEUE/done"/*.json 2>/dev/null \
    | xargs -r ls -t 2>/dev/null | head -1
}

# Read a JSON field from a spec. $1 = spec-path, $2 = field name. Empty if missing.
read_spec_field() {
  local spec="$1" field="$2"
  if [ -z "$spec" ] || [ ! -f "$spec" ]; then return 1; fi
  jq -r ".${field} // empty" "$spec" 2>/dev/null
}

# --- EGY FORRAS: a spec a parameterek gazdaja ------------------------------
# A `live/<nev>.json` azt mondja meg, MELYIK agentet kell eletben tartani (+ a
# restore_attempts futasideju allapotot). A parametereket (model, effort, ...)
# a `done/` spec adja. 2026-08-11: a ketto elcsuszott — a spec mar
# claude-opus-5 volt, a live/ meg claude-opus-4-8, es az ujrainditas CSENDBEN a
# regi modellel jott vissza. A live/ ertek csak fallback marad, hogy egy
# kitakaritott spec ne tegye ujrainditasra keptelenne az agentet.
# $1=spec-ut (lehet ures) $2=live-bejegyzes $3=mezo $4=default
spec_or_live_field() {
  local spec="$1" entry="$2" f="$3" d="$4" sv="" lv=""
  [ -n "$spec" ] && [ -r "$spec" ] && sv=$(read_spec_field "$spec" "$f" 2>/dev/null)
  [ -r "$entry" ] && lv=$(jq -r --arg f "$f" '.[$f] // empty' "$entry" 2>/dev/null)
  if [ -n "$sv" ] && [ "$sv" != "null" ]; then
    printf '%s\n' "$sv"
    return 0
  fi
  printf '%s\n' "${lv:-$d}"
}

# A spec es a live/ eltereseit sorolja fel, soronkent: "<mezo> live=X spec=Y".
# Nem javit, csak lathatova tesz — a csendes divergencia volt az eredeti hiba.
spec_live_divergences() {            # $1=spec-ut $2=live-bejegyzes
  local spec="$1" entry="$2" f sv lv
  [ -n "$spec" ] && [ -r "$spec" ] && [ -r "$entry" ] || return 0
  for f in cwd worktree model effort permission_mode brief; do
    sv=$(read_spec_field "$spec" "$f" 2>/dev/null)
    lv=$(jq -r --arg f "$f" '.[$f] // empty' "$entry" 2>/dev/null)
    if [ -n "$sv" ] && [ -n "$lv" ] && [ "$sv" != "$lv" ]; then
      printf '%s live=%s spec=%s\n' "$f" "$lv" "$sv"
    fi
  done
  return 0
}

# Echo all running agent names (no `agent-` prefix, no `:` suffix).
list_running_agents() {
  tmux ls 2>/dev/null | grep '^agent-' | sed 's/^agent-//; s/:.*//'
}

# Echo descendants of a parent (incl. parent itself), prefix-match.
list_descendants() {
  local parent="$1"
  list_running_agents | grep -E "^${parent}\$|^${parent}-"
}

# A repó FŐ munkakönyvtára (nem a hívó linked worktree-jéé).
#
# ⚠️ Egy linked worktree-ben a `rev-parse --show-toplevel` ÖNMAGÁT adja vissza.
# Emiatt egy worktree-s agentből forkolva a gyerek worktree-je a szülőébe
# ágyazódott be (mérve 2026-08-07:
# .../worktrees/mac-main-infra/.claude/worktrees/mac-main-infra-dekezet2),
# ahol a gyerek fájljai a szülő munkafájában ülnek — a close-agent merge
# auto-commitja (`git add -A`) be is söpörné őket.
# A `worktree list --porcelain` első sora mindig a FŐ munkakönyvtár.
git_main_toplevel() {
  local cwd="$1" line
  [[ -n "$cwd" ]] || return 1
  line=$(git -C "$cwd" worktree list --porcelain 2>/dev/null | head -1) || return 1
  [[ "$line" == "worktree "* ]] || return 1
  print -r -- "${line#worktree }"
}

# Path of an agent's git worktree, or EMPTY if it has none.
# $1=cwd (a spec cwd-je) $2=worktree flag $3=agent név
#
# A `claude --worktree=<name>` a git TOPLEVEL alá teszi a worktree-t, nem a
# spec cwd-je alá — a kettő eltér, ha a cwd egy alkönyvtár (mérve: a
# mac-main-infra spec cwd-je …/ClaudeProjects/infra, a worktree viszont
# …/ClaudeProjects/.claude/worktrees/mac-main-infra).
#
# ⚠️ SZÁNDÉKOSAN NINCS cwd-fallback. A visszatérési értéket a remove_worktree()
# kapja, ami `rm -rf`-fel végződik; ha worktree hiányában a cwd-re esnénk
# vissza, egy nem-worktree agent lezárása letörölné az agent VALÓDI
# munkakönyvtárát. Nincs worktree → üres string → a hívó nem csinál semmit.
# A spec a cwd-t UGY tarolja, ahogy beirtak — a spawner ugyan kibontja a tildet
# INDITASKOR (`cwd="${cwd/#\~/$HOME}"`), de a spec-fajlba az eredeti marad. A
# kesobbi olvasok (lezaras, watchdog) igy egy literal `~`-val kezdodo utat
# kapnak, ami sehol nem letezik. 2026-08-29: emiatt a `merge`-os lezaras
# "a worktree nincs meg — nincs mit mergelni"-vel ATLEPTE a beolvasztast, es a
# munka a torolt agon maradt volna.
expand_tilde() {                     # $1 = ut -> a `~` kibontva
  local pth="$1"
  print -r -- "${pth/#\~/$HOME}"
}

worktree_path() {
  local cwd worktree="$2" name="$3" top
  cwd=$(expand_tilde "$1")
  [[ "$worktree" == "true" ]] || return 0
  [[ -n "$cwd" && -n "$name" ]] || return 0
  top=$(git_main_toplevel "$cwd") || return 0
  [[ -n "$top" ]] || return 0
  [[ -d "$top/.claude/worktrees/$name" ]] || return 0
  print -r -- "$top/.claude/worktrees/$name"
}

# Remove a worktree + branch + orphan dir. $1=cwd, $2=wt_path, $3=branch.
remove_worktree() {
  local cwd="$1" wt_path="$2" branch="$3"
  if [ -z "$cwd" ] || [ -z "$wt_path" ]; then return 1; fi
  # Alak-ellenőrzés: ez a függvény `rm -rf`-fel végződik, ezért csak valódi
  # worktree-útra szabad mutatnia. Egy rosszul származtatott út (lásd
  # worktree_path) különben egy élő munkakönyvtárat törölne.
  case "$wt_path" in
    */.claude/worktrees/*) ;;
    *) print -u2 "remove_worktree: refusing non-worktree path: $wt_path"; return 1 ;;
  esac
  # ⚠️ A futo claude session ZAROLJA a sajat worktree-jet, es a `--force`
  # ONMAGABAN nem tori at a zarolast — ahhoz elobb `unlock` kell. 2026-08-29-en
  # emiatt a `drop` FELIG sikerult: a konyvtart a lenti `rm -rf` letorolte, de a
  # git-metaadat ES az ag ottmaradt, mert a `git branch -D` `&&`-del volt a
  # bukott `remove` utan fuzve — tehat le sem futott. A fuggveny raadasul mindig
  # 0-val tert vissza, igy a hivo semmit nem vett eszre.
  # Ezert: unlock elore, a lepesek FUGGETLENUL futnak, a vegen `prune`.
  (
    cd "$cwd" || exit 1
    git worktree unlock "$wt_path"        2>/dev/null || true
    git worktree remove --force "$wt_path" 2>/dev/null || true
    [ -n "$branch" ] && git branch -D "$branch" 2>/dev/null || true
    git worktree prune                    2>/dev/null || true
  )
  [ -d "$wt_path" ] && rm -rf "$wt_path"

  # A takaritas EREDMENYET nezzuk, nem a parancsok kilepesi kodjat: ami szamit,
  # az az, hogy ne maradjon se konyvtar, se ag. Igy a hivo eszreveheti, ha a
  # `drop` csak reszben sikerult.
  local rc=0
  if [ -d "$wt_path" ]; then
    print -u2 "remove_worktree: a könyvtár megmaradt: $wt_path"; rc=1
  fi
  if [ -n "$branch" ] && ( cd "$cwd" && git rev-parse --verify --quiet "$branch" >/dev/null 2>&1 ); then
    print -u2 "remove_worktree: az ág megmaradt: $branch"; rc=1
  fi
  return $rc
}

# Kill a tmux session by agent name. Silent if missing.
# Egy agent TENYLEGES tmux-session neve. A gyerekek `agent-<nev>` alatt futnak,
# a parancskozpont viszont ELOTAG NELKUL (`mac-main`) — ez szandekos, es a
# dokumentacio ki is emeli. A hid ezt tobb helyen elrontotta: a `continue_agent`
# fixen `agent-<nev>`-et keresett, a parancskozpontot ezert HALOTTNAK hitte, es
# fel akarta tamasztani. Specje nincs (a start.sh inditja, nem a spawner), tehat
# elbukott ("nincs spec-je: mac-main") — es ha lett volna specje, egy MASODIK
# `--remote-control mac-main` peldanyt inditott volna, ami a TODO.md-ben rogzitett
# 2026-07-27-i incidens szerint elviszi az eredeti bridge-et.
# Merve 2026-08-29: a Cowork elso, mac-main-nek cimzett kerese emiatt bukott el.
#   kiirja a LETEZO session nevet, vagy 1-gyel ter vissza
agent_tmux_session() {               # $1 = agent nev
  local n="$1"
  tmux has-session -t "=agent-$n" 2>/dev/null && { print -r -- "agent-$n"; return 0 }
  tmux has-session -t "=$n"       2>/dev/null && { print -r -- "$n";       return 0 }
  return 1
}

kill_one_tmux() {
  local name="$1"
  if [ -z "$name" ]; then return 1; fi
  tmux kill-session -t "=agent-$name" 2>/dev/null
}

# ---------------------------------------------------------------------------
# live/ registry — restart-survival
# ---------------------------------------------------------------------------

# Register an agent as "should be running". $1 = spec JSON path, $2 = name.
register_agent() {
  local spec="$1" name="$2"
  if [ -z "$spec" ] || [ -z "$name" ] || [ ! -f "$spec" ]; then return 1; fi
  mkdir -p "$CLAUDE_AGENT_LIVE"
  # ⚠️ tmp + mv: a `>` a jq indulasa ELOTT letrehozza/uriti a celfajlt, tehat egy
  # jq-bukas URES registry-bejegyzest hagyott. Az ures bejegyzesen a watchdog
  # set_field-je nemán no-op, a restore_attempts sosem perzisztalodik, es a
  # "max 3 ujrainditas" garancia csendben megszunik: a torott agent 300
  # masodpercenkent orokke ujraindul.
  local tmp="$CLAUDE_AGENT_LIVE/$name.json.tmp.$$"
  if jq --arg name "$name" '. + {name: $name, restore_attempts: 0}' "$spec" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$CLAUDE_AGENT_LIVE/$name.json"
  else
    rm -f "$tmp"; return 1
  fi
}

# Drop an agent from the registry — the watchdog will stop restoring it.
unregister_agent() {
  local name="$1"
  if [ -z "$name" ]; then return 1; fi
  rm -f "$CLAUDE_AGENT_LIVE/$name.json"
}

# A spawnolt sessionok karakterkeszlete. A launchd kornyezeteben NINCS LANG,
# igy a panel C-locale-ben indul: ott minden karakteralapu muvelet BAJTONKENT
# dolgozik, es a tobbajtos UTF-8 (ekezetek) kettevagodik — a terminal-kijeloles
# es a masolas is ezen romlik el. Merve: `LC_ALL=C sed 's/./X/g'` az
# "arvizturo" szora 13 X-et ad 9 helyett.
# en_US.UTF-8 az alapertelmezes, mert a rendezesi sorrend igy joslható marad a
# szkriptekben; a lenyeg az UTF-8 resz, a nyelv izles kerdese.
: ${CLAUDE_AGENT_LANG:=en_US.UTF-8}

# Where the agent's claude process actually runs. Worktree agents live in
# <git-toplevel-of-cwd>/.claude/worktrees/<name>, NOT in the spec cwd.
# $1=cwd $2=worktree(true|false) $3=name
agent_runtime_cwd() {
  local cwd worktree="$2" name="$3" top
  cwd=$(expand_tilde "$1")
  if [[ "$worktree" != "true" ]]; then
    print -r -- "$cwd"
    return 0
  fi
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$top" && -d "$top/.claude/worktrees/$name" ]]; then
    print -r -- "$top/.claude/worktrees/$name"
  else
    print -r -- "$cwd"
  fi
}

# Transcript dir for a cwd — claude escapes both `/` and `.` to `-`.
# A Claude Code projekt-konyvtaranak neve egy cwd-bol. A CLI-t tukrozi (2.1.289):
#     function k(e){ return e.replace(/[^a-zA-Z0-9]/g, "-") }
#     function eI(e){ let n=k(e); if (n.length<=200) return n; return `${n.slice(0,200)}-${hash(e)}` }
# vagyis MINDEN nem-alfanumerikus karakter kotojel — az `_` es az ekezetes betu is.
#
# ⚠️⚠️ 2026-10-06: az elso valtozat csak a `/`-t es a `.`-t csereltee (`sed 's#[/.]#-#g'`).
# A `_KUTATÁS` munkakonyvtaru agentnel ez `…-_KUTATÁS`-t adott, a valodi konyvtar
# pedig `…--KUTAT-S` — a kuldes-ellenorzes rossz helyen kereste az atiratot, es
# HAMIS `PROMPT-LOST`-ot jelentett, mikozben a feladat megerkezett. Sikertelen
# ellenorzes utan a kuldo MASODSZOR is elkuldi a feladatot; ezuttal veletlenul nem
# jutott be.
#
# KARAKTERENKENT, nem bajtonkent: az `Á` EGY kotojel (a JS a UTF-16 kodegysegeket
# cserelI — a BMP-n kivuli karakter, pl. emoji, ezert KETTO). A locale-t a fuggveny
# maga allitja, hogy egy C-locale-u hivo (launchd) se bajtonkent szamoljon.
cc_project_slug() {
  emulate -L zsh
  local LC_ALL=en_US.UTF-8
  local s="$1" out="" c
  local -i i cp
  for (( i = 1; i <= ${#s}; i++ )); do
    c="${s[i]}"; cp=$(( #c ))
    if (( (cp >= 48 && cp <= 57) || (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122) )); then
      out+="$c"
    elif (( cp > 65535 )); then
      out+="--"
    else
      out+="-"
    fi
  done
  print -r -- "$out"
}

transcript_dir() {
  local slug; slug=$(cc_project_slug "$1")
  # 200 karakter felett a CLI csonkol es hash-t fuz hozza, amit nem tudunk
  # kiszamolni — de az elotag egyertelmu, tehat azzal keressuk meg.
  if (( ${#slug} > 200 )); then
    local -a m; m=("$HOME/.claude/projects/${slug[1,200]}-"*(N/))
    if (( ${#m} )); then print -r -- "${m[1]}"; return 0; fi
    print -r -- "$HOME/.claude/projects/${slug[1,200]}"; return 0
  fi
  print -r -- "$HOME/.claude/projects/$slug"
}

# Egy FUTÓ agent pontos session id-ja a saját állapotfájljából.
# A claude minden folyamathoz ír egy ~/.claude/sessions/<pid>.json-t, benne a
# sessionId-val; a pid a tmux pane processze.
#
# Miért nem elég a latest_session_id(cwd): ha egy gyerek worktree NÉLKÜL fut,
# a szülővel közös cwd-n osztozik, tehát közös a transcript-könyvtáruk is — a
# „legfrissebb átirat" ilyenkor a szülőre is a gyerekét adná vissza.
# Nem futó agentre nincs állapotfájl → rc=1, a hívó essen vissza a
# latest_session_id()-ra.
# Egy futó agent állapotfájlja (~/.claude/sessions/<pane-pid>.json), vagy rc=1.
agent_session_file() {
  local name="$1" pane_pid cand sf
  [[ -n "$name" ]] || return 1
  # Kétféle tmux-névkonvenció van: a gyerek agentek `agent-<név>`, a
  # command-center session viszont prefix NÉLKÜL `<név>` (ezért nem éri el a
  # `^agent-` szűrésű kaszkád sem). Mindkettőt meg kell nézni, különben a
  # gyökérből indított fork „a szülő nem fut" hibával bukik.
  for cand in "agent-$name" "$name"; do
    pane_pid=$(tmux list-panes -t "=$cand" -F '#{pane_pid}' 2>/dev/null | head -1)
    [[ -n "$pane_pid" ]] && break
  done
  [[ -n "$pane_pid" ]] || return 1
  sf="$HOME/.claude/sessions/$pane_pid.json"
  [[ -r "$sf" ]] || return 1
  print -r -- "$sf"
}

agent_session_field() {              # $1 = agent név, $2 = mező
  local sf v
  sf=$(agent_session_file "$1") || return 1
  v=$(jq -r --arg f "$2" '.[$f] // empty' "$sf" 2>/dev/null)
  [[ -n "$v" ]] || return 1
  print -r -- "$v"
}

agent_session_id()  { agent_session_field "$1" sessionId }
agent_session_cwd() { agent_session_field "$1" cwd }

# Szerepel-e MINDKET minta a $2 ota irt atiratok valamelyikeben?
# $1 = atirat-konyvtar, $2 = epoch (ettol frissek szamitanak), $3,$4 = a ket minta
# $5 = (opcionalis) EGY konkret atirat-fajl; ha megadva, csak azt nezzuk.
#
# ⚠️⚠️ EZ A FUGGVENY EGY HAMIS-ZOLD MIATT SZULETETT, 2026-10-02.
# Korabban igy allt, a kuldo fuggvenyben:
#     find "$tdir" -name '*.jsonl' -newermt "@$t" -print0 | xargs -0 grep -qlF -- "$frag"
# A macOS (BSD) `xargs` URES bemenetre EL SEM INDITJA a parancsot, es **0-val lep
# ki** — a pipeline kilepesi erteke tehat SIKER. Vagyis ha semmi nem irodott
# (mert a kuldes teljesen elbukott), akkor nem volt friss fajl, a find semmit nem
# adott, es az ellenorzes SIKERT jelentett. Minel kevesebb a bizonyitek, annal
# biztosabb a "megerkezett" — pontosan forditva, mint kellene.
# Igy kapott a `hw-p1-01` keres `spawned` statuszt 6 masodperc alatt, mikozben a
# `send-keys` `can't find pane`-nel elbukott, es az agent tetlenul allt.
# Mostantol: nincs xargs, es URES fajllista = HAMIS, nem igaz.
fresh_transcript_has() {
  local tdir="$1" since="$2" a="$3" b="$4" only="${5-}"
  local -a files
  if [[ -n "$only" ]]; then
    [[ -f "$only" ]] || return 1
    files=("$only")
  else
    [[ -d "$tdir" ]] || return 1
    # ⚠️⚠️ NEM `find -newermt "@<epoch>"`. A macOS `/usr/bin/find` ezt az alakot
    # NEM ERTI: `find: Can't parse date/time: @1790930971` — es **0-val lep ki**,
    # tehat meg egy `|| return 1` sem fogta volna meg. Interaktiv shellben a
    # fejleszto gepen a `find` egy alias (bfs), ami ERTI — a launchd-jobok viszont
    # a /usr/bin/find-ot kapjak. Ezert a kuldes-ellenorzes ELESBEN mindig ures
    # listat kapott, az akkori xargs-lanc pedig abbol SIKERT csinalt: a
    # "`spawned` = a feladat bizonyitottan megerkezett" garancia a launchd alatt
    # nem teljesult. Most zsh-glob + `stat -f %m`, kulso datum-ertelmezes nelkul.
    local -a _all; local _f
    _all=("$tdir"/*.jsonl(N.))
    for _f in $_all; do
      (( $(stat -f %m "$_f" 2>/dev/null || echo 0) >= since )) && files+=("$_f")
    done
  fi
  # ⚠️ URES LISTA = NEM bizonyitek. Ez az egesz fuggveny letenek az oka.
  (( ${#files} )) || return 1
  grep -qlF -- "$a" "${files[@]}" 2>/dev/null || return 1
  grep -qlF -- "$b" "${files[@]}" 2>/dev/null || return 1
  return 0
}

# --- feladat bekuldese egy futo agentbe (darabolva + ellenorizve) ----------
# ⚠️ KET eles hiba tanulsaga egyben, mindketto 2026-08-31:
#  1) DARABOLNI kell. Egy 1796 karakteres promptbol PONTOSAN 774 erkezett meg,
#     szokozepen kezdve — az elso ~1022 karakter (egy 1KB-os bemeneti puffer)
#     elveszett. Se a `send-keys -l`, se a `paste-buffer` nem segit egyben: nem
#     a modszer a baj, hanem a meret. A regresszios C1 haromszor bukott el igy,
#     mert az agent a prompt utolso 12 karakteret kapta feladatnak.
#  2) AZ ATIRATBOL kell ellenorizni, nem a pane-bol. A TUI sortorest tesz a
#     hosszu szovegbe, a pane-grep ezert hamis negativot ad — emiatt kuldtem ki
#     egyszer KETSZER ugyanazt a feladatot.
# $1 = agent nev (prefix nelkul), $2 = szoveg, $3 = a cel cwd-je (az atirathoz)
agent_send_prompt() {
  local name="$1" text="$2" cwd="$3"
  local tmuxb; tmuxb=$(command -v tmux) || return 1
  local sess; sess=$(agent_tmux_session "$name") || return 1
  local flat="${text//$'\n'/ }" pos sent=false tdir w try t0 frag fragend
  # A CLI nevkepzese EGY helyen (transcript_dir) — a sajat masolat itt
  # elcsuszott (csak `/`-t es `.`-t cserelt), lasd cc_project_slug.
  tdir=$(transcript_dir "$cwd")
  # ⚠️ A mintat a LAPOSITOTT szovegbol vesszuk: a beviteli sorba is az megy, a
  # nyers valtozat sortoresei pedig tobbsoros grep-mintat csinalnanak.
  frag="${flat[1,60]}"
  # A szoveg VEGE is minta: enelkul egy kozepen elveszett blokk eszrevetlen marad.
  local fragend="${flat[-60,-1]}"
  # ⚠️⚠️ CSAK A FRISSEN IROTT ATIRATOKAT nezzuk. A projekt-konyvtar a KORABBI
  # korok atiratait is orzi (merve: 14 fajl a ClaudeProjects-temp alatt), a
  # teszt-feladatok szovege pedig korrol korre SZO SZERINT AZONOS. Az elso
  # valtozat ezert egy TEGNAPI atiratra illeszkedett, es sikert jelentett, mikozben
  # a feladat el sem indult — a `spawned` megint hazudott. Az mtime-szures teszi
  # a mintat "ebben a korben erkezett"-te.
  t0=$(date +%s)
  # Az agent SAJAT atirata, ha feloldhato (a futo folyamat allapotfajljabol).
  local own="" _osid
  _osid=$(agent_session_id "$name" 2>/dev/null || true)
  # A sajat atiratot a MUNKAMENET-AZONOSITOVAL keressuk, barmelyik projekt-konyvtar
  # alatt — igy a konyvtarnev kepzesetol egyaltalan nem fugg.
  if [[ -n "$_osid" ]]; then
    local _of
    for _of in "$HOME/.claude/projects"/*/"$_osid.jsonl"(N); do own="$_of"; break; done
  fi
  for try in 1 2; do
    # ⚠️ ELOSZOR TAKARITSUK KI a beviteli sort. Egy korabbi, csonkolt kuldes
    # MARADEKA ott ulhet elkuldetlenul — 2026-08-31-en a CLI-agent sorában
    # tenyleg ott allt a "Fejezd be a kört." (az elozo prompt vege). Ha ra
    # gepelunk, a ket szoveg osszeragad, es ertelmetlen feladat megy be.
    # ⚠️ BLOKKOLO MODAL a kuldes elott. 2026-09-01: egy futo agent sessionjeben
    # KOZBEN ugrott fel a "Teach auto mode about your environment?" ablak, es
    # onnantol minden bekuldott feladat a semmibe ment. Az `auto_dismiss_modals`
    # csak INDULASKOR fut, ezt tehat senki nem vette le.
    # ⚠️ ESC-cel zarjuk, SOHA nem Enterrel: az az ablak a shell-elozmenyek es a
    # tobbi repo atvizsgalasat ajanlja fel — azt a felhasznalo dontse el, nem mi.
    if "$tmuxb" capture-pane -p -t "=$sess:" 2>/dev/null \
         | grep -q 'Teach auto mode about your environment'; then
      "$tmuxb" send-keys -t "=$sess:" Escape 2>/dev/null
      sleep 1
    fi
    "$tmuxb" send-keys -t "=$sess:" C-u 2>/dev/null
    sleep 0.2
    # ⚠️ A send-keys KILEPESI ERTEKET nezzuk. 2026-10-02-ig eldobtuk, es amikor a
    # tmux `can't find pane`-nel elutasitotta a celt, a hiba csak stderr-en
    # latszott — a fuggveny vegigfutott, es (a fenti xargs-lyuk miatt) sikert
    # jelentett. Egy elbukott send-keys utan NINCS mit ellenorizni.
    local _sendfail=false
    pos=1
    while (( pos <= ${#flat} )); do
      # ⚠️ A `--` KOTELEZO. A darabolas kozepen egy blokk KOTOJELLEL kezdodhet
      # (pl. a feladat szovegeben levo `print -r --` reszlet miatt), es a tmux
      # azt KAPCSOLONAK veszi: `command send-keys: unknown flag -r`. A blokk
      # elveszett, a feladat kozepe kiesett — a G6 lepes 2026-09-01-en pontosan
      # ezen bukott el, ES a statusz megis `spawned` lett.
      if ! "$tmuxb" send-keys -t "=$sess:" -l -- "${flat[$pos,$((pos+399))]}"; then
        _sendfail=true; break
      fi
      (( pos += 400 ))
      sleep 0.3
    done
    if $_sendfail; then
      print -u2 "a send-keys elbukott ($sess) — a feladat nem ment be"
      continue
    fi
    sleep 1
    if ! "$tmuxb" send-keys -t "=$sess:" Enter; then
      print -u2 "a lezáró Enter nem ment el ($sess)"
      continue
    fi
    for w in 1 2 3 4 5 6 7 8; do
      sleep 2
      # -newermt: csak a kuldes ota irt atirat szamit.
      # ⚠️ A VEGET IS ellenorizni kell, nem csak az elejet. 2026-09-01: egy
      # blokk kozepen elveszett (a hianyzo `--` miatt), az ELSO 60 karakter
      # viszont rendben megerkezett — az ellenorzes atengedte, a statusz
      # `spawned` lett, es az agent egy CSONKA feladatot kapott.
      # ⚠️ Ha fel tudjuk oldani az agent SAJAT atiratat, CSAK azt nezzuk. A zaro
      # minta az augment_task boilerplate-je, ami kilenc atiratban ott van (merve
      # 2026-10-02) — onmagaban tehat nem kulonbozteti meg a kort, es osztott
      # cwd-n MAS agent atirata is illeszkedhet.
      if fresh_transcript_has "$tdir" "$((t0-2))" "$frag" "$fragend" "$own"; then
        sent=true; break
      fi
    done
    $sent && break
  done
  $sent
}

# --- fork-fa: a szulo->gyerek elek, a MELYSEGKORLAT miatt ------------------
# ⚠️ 2026-08-30: egy `--summary` fork FORK-BOMBAT robbantott. A gyerek a szulo
# beszelgetes-osszefoglalojaban levo runbookot SAJAT feladatlistanak olvasta, es
# ujra forkolt — nemzedekrol nemzedekre. NEGY nemzedek jott letre; a lancot nem
# egy vedelem allitotta meg, hanem veletlen: a nev 64 karakteren elfogyott.
# Ezert kell explicit korlat. A forkoknak nincs `live/` allapotfajljuk (azokat
# szandekosan nem elesztjuk ujra), ezert kell kulon, celzott nyilvantartas.
FORK_TREE="${FORK_TREE:-$CLAUDE_AGENT_QUEUE/fork-tree.json}"

fork_tree_record() {                 # $1 = gyerek, $2 = szulo
  [[ -f "$FORK_TREE" ]] || print '{}' > "$FORK_TREE"
  local t; t=$(jq --arg c "$1" --arg p "$2" '.[$c] = $p' "$FORK_TREE" 2>/dev/null) || return 1
  print -r -- "$t" > "$FORK_TREE"
}

fork_tree_forget() {                 # $1 = agent
  [[ -f "$FORK_TREE" ]] || return 0
  local t; t=$(jq --arg c "$1" 'del(.[$c])' "$FORK_TREE" 2>/dev/null) || return 1
  print -r -- "$t" > "$FORK_TREE"
}

fork_depth() {                       # $1 = agent -> hany fork valasztja a gyokertol
  local cur="$1" d=0 nxt
  [[ -f "$FORK_TREE" ]] || { print 0; return 0 }
  # A 64-es korlat ciklus ellen ved: serult fa eseten se porogjunk vegtelenul.
  while (( d < 64 )); do
    nxt=$(jq -r --arg c "$cur" '.[$c] // empty' "$FORK_TREE" 2>/dev/null)
    [[ -n "$nxt" ]] || break
    (( d++ )); cur="$nxt"
  done
  print -- "$d"
}

# --- melyik atiratot folytassa egy visszaallitott agent? -------------------
# ⚠️ A "cwd legfrissebb atirata" hevisztika KOZOS cwd eseten HAMIS. A spawner
# ures cwd-nel a ClaudeProjects gyokeret adja, ami a command center cwd-je is:
# reboot utan a watchdog a gyereket a command center atiratával indithatja el, a
# start.sh pedig a command centert a gyerekével. Ket session ugyanazon a
# transzkripton — az egyik beszelgetes csendben elarvul, es mindket agent masnak
# hiszi magat. Semmi nem all meg, semmi nem hibazik lathatoan.
#
# Ezert: elsodleges a SAJAT, korabban rogzitett session id (a watchdog irja be,
# amig az agent fut). Hevisztikara csak akkor esunk vissza, ha a cwd NEM osztott.

registry_field() {                   # $1 = nev, $2 = mezo
  local f="$CLAUDE_AGENT_LIVE/$1.json" v
  [[ -r "$f" ]] || return 1
  v=$(jq -r --arg k "$2" '.[$k] // empty' "$f" 2>/dev/null) || return 1
  [[ -n "$v" ]] || return 1
  print -r -- "$v"
}

# Osztozik-e mas NYILVANTARTOTT agent ugyanazon a futasideju cwd-n?
# Egy visszaallitott agent kiserlet-szamlaloja csak akkor nullazodhat, ha az
# agent egy TICKKEL kesobb is fut. A korabbi valtozat kozvetlenul a spawn utan
# nullazott (5 masodperces "meg fut" merce), ezert a "nem eled ujra a
# vegtelensegig" korlat csak az INDULASKOR osszeomlo agentre allt: amelyik egy
# perccel kesobb halt meg ismetlodve, az 300 masodpercenkent orokke ujraindult.
#   $1 = restored_at (epoch; 0 vagy hianyzo = nincs fuggoben levo visszaallitas)
#   $2 = most (epoch)
#   $3 = minimalisan megkovetelt stabil ido masodpercben
# 0 = nullazhato, 1 = meg nem
restore_counter_should_reset() {
  local ra="${1:-0}" now="${2:-0}" min="${3:-120}"
  [[ "$ra"  == <-> ]] || ra=0
  [[ "$now" == <-> ]] || now=0
  [[ "$min" == <-> ]] || min=120
  (( ra == 0 || now - ra >= min ))
}

registry_cwd_shared() {              # $1 = nev, $2 = runtime cwd
  local name="$1" rcwd="$2" f other ocwd owt
  [[ -d "$CLAUDE_AGENT_LIVE" ]] || return 1
  for f in "$CLAUDE_AGENT_LIVE"/*.json(N); do
    other="${f:t:r}"
    [[ "$other" == "$name" ]] && continue
    ocwd=$(jq -r '.cwd // empty' "$f" 2>/dev/null)
    owt=$(jq -r '.worktree // false' "$f" 2>/dev/null)
    [[ -n "$ocwd" ]] || continue
    [[ "$(agent_runtime_cwd "$ocwd" "$owt" "$other")" == "$rcwd" ]] && return 0
  done
  return 1
}

# ⚠️ Az atirat NEM feltetlenul a futasideju cwd-bol szarmaztatott konyvtarban
# van. A worktree-ben futo agent sessionjet a Claude Code a PROJEKT gyokere ala
# filezi, nem a worktree ala. Merve 2026-08-26: a mac-main-proxmox a
# `.claude/worktrees/mac-main-proxmox`-ban fut, az atirata viszont a
# `…-ClaudeProjects-proxmox` konyvtarban van — az elozo valtozat ezert nem
# talalta meg a SAJAT, rogzitett azonositojat sem. A session id UUID, tehat
# globalisan egyedi: keressuk meg ott, ahol van.
transcript_exists() {                # $1 = session id
  [[ -n "$1" ]] || return 1
  local f
  for f in "$HOME/.claude/projects"/*/"$1.jsonl"(N); do return 0; done
  return 1
}

# Sikernel a sid-et adja. Bukasnal az OKOT irja a stderr-re, hogy a naplo ne
# talalgasson — a korabbi valtozat minden bukast "osztott cwd"-nek nevezett,
# akkor is, ha valojaban nem talalt atiratot.
# Egy FUTO agent argv-jebol ujrainditasi argv-t epit, a megadott session-id-vel.
# $1 = a futo folyamat teljes argv-je, $2 = a cel session-id -> a kapcsolok
# soronkent (a hivo olvassa be tombbe).
#
# ⚠️ FEHERLISTA, nem atvetel. Harom dolog, amit az atvetel elrontana, es
# mindharom ott volt eles agentek argv-jeben 2026-10-01-en:
#   --resume <id>    orokolt forknal a SZULO session-idje all ott (a
#                    `mac-main-dsolar-mac` argv-je a parancskozpont atiratat
#                    vitte), tehat az atvetel szerep-atvetelt okozna
#   --fork-session   ujra elagaztatna: minden ujrainditas UJ session-id-t adna,
#                    es a beszelgetes korronkent szettoredezne
#   <pozicionalis>   a kezdo prompt. Resume mellett UJ FORDULOKENT szallna be —
#                    a watchdog resume-aga is pontosan ezert nem fuzi hozza.
# A --worktree is kimarad: a worktree mar letezik, ujra atadva masodikat nyitna.
restart_argv() {
  local argv="$1" sid="$2"
  local -a args clean
  args=(${(z)argv})
  shift args                        # a binaris utvonala
  # ⚠️ HAROM allapot kell, nem kettő. Az elso valtozat egyetlen `want` zaszlot
  # hasznalt, es a `--resume` eseten is azt allitotta be — a kovetkezo korben
  # viszont az "ertek megtartasa" ag futott le, tehat a REGI session-id
  # POZICIONALIS argumentumkent atszivargott, es promptkent szallt volna be.
  # A sajat ellenorzesem nem fogta meg (csak a `--resume` darabszamat es az utolso
  # elemet nezte); a smoke-teszt igen.
  local want=no a
  for a in $args; do
    case "$want" in
      keep) clean+=("$a"); want=no; continue ;;
      skip)                want=no; continue ;;
    esac
    case "$a" in
      --remote-control|--permission-mode|--model|--effort|--append-system-prompt|--disallowed-tools)
        clean+=("$a"); want=keep ;;
      --brief|--chrome)            clean+=("$a") ;;
      --resume)                    want=skip ;;
      --fork-session)              : ;;
      --worktree|--worktree=*)     : ;;
      --*)                         clean+=("$a") ;;
      *)                           : ;;
    esac
  done
  [[ -n "$sid" ]] && clean+=("--resume" "$sid")
  print -rl -- "${clean[@]}"
}

resolve_resume_sid() {               # $1 = nev, $2 = runtime cwd -> sid | ures+rc1
  local name="$1" rcwd="$2" sid
  sid=$(registry_field "$name" last_session_id 2>/dev/null)
  if [[ -n "$sid" ]]; then
    if transcript_exists "$sid"; then print -r -- "$sid"; return 0; fi
    print -u2 "a rögzített session id-hez ($sid) nem található átirat"
    return 1
  fi
  if registry_cwd_shared "$name" "$rcwd"; then
    print -u2 "nincs rögzített session id, és a cwd osztott ($rcwd) — nem találgatok"
    return 1
  fi
  # ⚠️ Ha EGYALTALAN nincs atirat, az nem "ne talalgass", hanem "meg sosem
  # beszelt" — ilyenkor a friss indítás a helyes (az eredeti prompttal). A
  # 2026-08-25-i valtozat ezt is SKIP-re vitte, amivel az atirat nelkul meghalt
  # agent tobbe nem allt vissza. Kulon kilepesi kod, hogy a hivo dontsön.
  sid=$(latest_session_id "$rcwd" 2>/dev/null) || return 2
  print -r -- "$sid"
}

# Newest session id (jsonl basename) for a cwd. Empty + rc=1 if none.
latest_session_id() {
  local rcwd="$1" dir
  dir=$(transcript_dir "$rcwd")
  [[ -d "$dir" ]] || return 1
  local -a files
  files=("$dir"/*.jsonl(N.om))   # zsh: nullglob, regular files, newest first
  (( ${#files} )) || return 1
  print -r -- "${files[1]:t:r}"
}

# Answer the known one-shot startup modals so an UNATTENDED spawn/restore
# doesn't hang on them forever. Logs nothing; caller logs.
# $1 = tmux session name.
auto_dismiss_modals() {
  local sess="$1" pane i
  local resume_mode="${CLAUDE_AGENT_RESUME_MODE:-summary}"
  # ⚠️ EZ A CIKLUS EDDIG AZ ELSO NEM-ILLESZKEDO PANE-NEL FELADTA (`else return 0`),
  # es pont ez tette hasznalhatatlanna a forkot: egy nagy beszelgetest betolto
  # session 5 masodperc utan MEG TART a betoltesnel, tehat a "Resuming the full
  # session" modal meg meg sem jelent. A fuggveny visszatert, a modalt soha senki
  # nem valaszolta meg, es a parancssorban atadott FELADAT SOSEM SUBMITOLODOTT.
  # Igy egyetlen hidon inditott fork sem dolgozott — a folytatasok igen, mert
  # azok send-keys-szel mennek egy mar futo agentbe.
  # Merve 2026-08-29: C1, D1, P1 (a P1 mar `summary` modban — a `--summary` csak
  # a modal VALASZAT valtoztatja, a megjeleneset nem gyorsitja).
  # Most: varunk a modalra, es csak akkor terunk vissza, ha a session KESZEN all.
  local tries="${CLAUDE_AGENT_MODAL_TRIES:-20}"
  [ -z "$sess" ] && return 1
  for i in {1..$tries}; do
    tmux has-session -t "=$sess" 2>/dev/null || return 0
    pane=$(tmux capture-pane -t "=$sess:" -p 2>/dev/null) || return 0
    if [[ "$pane" == *"fullscreen renderer"* ]]; then
      # 2 = "Not now" — never flip the user's renderer behind their back.
      tmux send-keys -t "=$sess:" "2" 2>/dev/null
      sleep 1; tmux send-keys -t "=$sess:" Enter 2>/dev/null; sleep 3; continue
    elif [[ "$pane" == *"Resuming the full session"* ]]; then
      # 1 = resume from summary (recommended), 2 = full as-is.
      if [[ "$resume_mode" == "full" ]]; then
        tmux send-keys -t "=$sess:" "2" 2>/dev/null
      else
        tmux send-keys -t "=$sess:" "1" 2>/dev/null
      fi
      sleep 1; tmux send-keys -t "=$sess:" Enter 2>/dev/null; sleep 3; continue
    elif [[ "$pane" == *"Is this a project you created or one you trust"* \
         || "$pane" == *"Yes, I trust this folder"* ]]; then
      # ⚠️ EZ A PARBESZED MEGOLTE A SAJAT AGENTJEINKET (2026-09-12). A generikus
      # ag barmire Entert nyomott, amin "Enter to confirm" szerepel — a bizalmi
      # ablakon viszont a kijelolt valasz a `❯ No, exit`, tehat az Enter
      # KILEPTETTE a claude-ot.
      #
      # ⚠️ 2026-09-13: eloszor ugy javitottam, hogy MEGALLUNK es visszakerdezunk.
      # Ez TEVES volt es a rendszer lenyegevel ment szembe: a felugyelet nelkuli
      # uzemmod pont arrol szol, hogy az agent magatol vegigcsinalja a munkat, es
      # AZ ENGEDELY a Telegram-jovahagyas. Ha a jovahagyas utan meg egy kerdes
      # megallitja, akkor a kapu nem ket helyen van, hanem ketszer ugyanott.
      #
      # A HATAR viszont marad, csak a helyes helyen: a valasz csak akkor "igen",
      # ha a parbeszedben szereplo munkakonyvtar az ENGEDELYEZETT GYOKEREN BELUL
      # van. A pane-bol olvassuk ki, nem egy atadott valtozobol — igy egy varatlan
      # utvonalra akkor sem irunk ala, ha a hivo tevedne.
      local _root="${CLAUDE_AGENT_ROOT:A}" _ws
      _ws=$(print -r -- "$pane" | sed -n 's/.*Accessing workspace:[[:space:]]*//p' | head -1 | tr -d ' \r')
      [[ -z "$_ws" ]] && _ws=$(print -r -- "$pane" | grep -oE '/Users/[^ ]+' | head -1)
      if [[ -n "$_root" && -n "$_ws" && ( "$_ws" == "$_root" || "$_ws" == "$_root"/* ) ]]; then
        # A kijelolt valasz a `No, exit`; a bizalom a KOVETKEZO sor.
        tmux send-keys -t "=$sess:" Down 2>/dev/null
        sleep 0.5
        tmux send-keys -t "=$sess:" Enter 2>/dev/null
        sleep 3
        continue
      fi
      # A gyokeren KIVULI utvonalra nem irunk ala — az mar nem az, amit jovahagytal.
      return 3
    elif [[ "$pane" == *"Enter to confirm"* ]]; then
      # ⚠️ SZUKITVE. Ez az ag korabban BARMILYEN "Enter to confirm" feliratu
      # ablakra vakon Entert nyomott. Egy ismeretlen parbeszed alapertelmezese
      # lehet romboló (a bizalmi ablake epp a kilepes volt), ezert csak az
      # ISMERT, veszelytelen megerositeseket nyugtazzuk.
      if [[ "$pane" == *"fullscreen"* || "$pane" == *"Chrome"* || "$pane" == *"chrome"* ]]; then
        tmux send-keys -t "=$sess:" Enter 2>/dev/null; sleep 2; continue
      fi
      # Ismeretlen modal: NEM tippelunk. A hivo dontse el, mit kezd vele.
      return 4
    fi
    # Nincs ismert modal. Ha a session mar a beviteli sorat mutatja, keszen
    # vagyunk; kulonben MEG TOLTODIK — varunk, nem adjuk fel.
    [[ "$pane" == *"⏵⏵"* || "$pane" == *"❯"* ]] && return 0
    sleep 3
  done
  return 0
}

