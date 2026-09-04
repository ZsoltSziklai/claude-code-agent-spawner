#!/bin/zsh
# _bridge-lib.sh — közös réteg a Desktop-hídhoz (relay + poller).
# Source-old: source "$(dirname "${(%):-%x}")/_bridge-lib.sh"

: ${CLAUDE_AGENT_ROOT:=$HOME/ClaudeProjects}
: ${CLAUDE_AGENT_QUEUE:=$HOME/.claude/agent-queue}
: ${BRIDGE_DIR:=$CLAUDE_AGENT_ROOT/bridge}
: ${BRIDGE_CONFIG:=$CLAUDE_AGENT_QUEUE/bridge-allow.json}
# A token SOHA nem env-ben és nem parancssorban utazik. Fallback-tárhely:
: ${BRIDGE_TOKEN_FILE:=$CLAUDE_AGENT_QUEUE/telegram-approve.token}
# Elsődleges tárhely a macOS Keychain — ugyanaz a mechanizmus, amit a
# claude-vault használ a mesterkulcsához. A 0600-as fájl csak fallback.
: ${BRIDGE_TOKEN_KC_SERVICE:=claude-bridge-telegram}
: ${BRIDGE_STATE:=$CLAUDE_AGENT_QUEUE/bridge-state.json}
: ${BRIDGE_LOG:=$CLAUDE_AGENT_QUEUE/bridge.log}

# A konyvtar 69 helyen csupasz `jq`-t hiv (a PATH-ot a belepesi pontok allitjak
# be: bridge-relay.sh / bridge-poller.sh). Ha a jq megsincs a PATH-on, minden
# hivas ures stringet ad, es a hid CSENDBEN rosszul viselkedik: minden keres
# ismeretlen modu, minden allowlist-tag hianyzik. Alljunk meg hangosan.
if ! command -v jq >/dev/null 2>&1; then
  print -u2 "_bridge-lib.sh: jq nincs a PATH-on ($PATH) — a híd nem tud működni"
  return 1 2>/dev/null || exit 1
fi

# ⚠️ A curl-időkorlát MARADJON a poller launchd-intervalluma (StartInterval,
# ma 30 mp) alatt, érezhető tartalékkal. 2026-08-11-ig 25 mp volt: egy
# beragadt lekérdezés után 5 mp maradt a következő indításig, tehát a két
# példány gyakorlatilag összeért. Mérve: 5 db `curl: (28) Operation timed out
# after 25s` a bridge.stderr.log-ban (2026-08-09 és 08-10 hajnalán).
: ${BRIDGE_HTTP_MAX_TIME:=28}
# Külön connect-timeout: halott hálózaton a kapcsolatépítés ne egye meg a
# teljes keretet — így a lekérdezés 10 mp-en belül elbukik és újrapróbálható.
: ${BRIDGE_HTTP_CONNECT_TIMEOUT:=10}

# LONG POLLING. A `getUpdates` ennyi masodpercig varhat egy esemenyre, es amint
# megjon, AZONNAL visszater. Enelkul (`timeout=0`) a gombnyomasrol csak a
# kovetkezo 30 mp-es tickkor ertesultunk — a felhasznalo joggal hitte, hogy nem
# tortent semmi, es UJRA NYOMOTT. 2026-08-30: ket `rv:` callback egy masodpercen
# belul, es a masodik, uresbe futo valasz eltorolt egy dokumentalo uzenetet.
# A gombot NEM tudjuk a nyomas pillanataban levenni (a nyomasrol is csak
# pollozaskor ertesulunk), a VARAKOZAST viszont le tudjuk vinni ~1 mp-re.
#
# ⚠️ MARADJON a curl `--max-time` ALATT, kulonben a curl vagja el a kapcsolatot,
# mielott a Telegram valaszolna — es minden kor egy hamis timeout lenne.
# ⚠️ 2026-09-04: a 15 mp NEM VOLT ELEG. A poller 30 mp-enkent indul, tehat
# koronkent ~15 mp HOLTIDO maradt, amikor a gombnyomas egyszeruen allt a sorban.
# Merve a naplobol: 32 ismetelt gombnyomas, MEDIAN 33 masodperces idokozzel —
# ez nem remego ujj, hanem "megnyomtam, nem tortent semmi, ujra megnyomtam".
# A `napelem-sema2`-nel a felhasznalo 35 masodpercig nem kapott semmilyen
# visszajelzest. A 25 mp-es varakozas a 30 mp-es ciklusban gyakorlatilag
# folyamatos figyelest ad: a holtido ~2-5 mp-re csokken.
: ${BRIDGE_POLL_TIMEOUT:=25}
if (( BRIDGE_POLL_TIMEOUT >= BRIDGE_HTTP_MAX_TIME )); then
  BRIDGE_POLL_TIMEOUT=$(( BRIDGE_HTTP_MAX_TIME > 5 ? BRIDGE_HTTP_MAX_TIME - 5 : 0 ))
fi

REQ_DIR="$BRIDGE_DIR/requests"
RES_DIR="$BRIDGE_DIR/results"
ARCHIVE_DIR="$BRIDGE_DIR/archive"

blog() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$BRIDGE_LOG" }

# --- config ---------------------------------------------------------------
# Hiányzó config = zárt kapu: inkább ne induljon semmi, mint hogy mindent
# engedjünk.
bridge_cfg() {                       # $1 = jq path, $2 = default
  local q="$1" d="${2-}"
  [[ -r "$BRIDGE_CONFIG" ]] || { print -r -- "$d"; return 0 }
  local v; v=$(jq -r "$q // empty" "$BRIDGE_CONFIG" 2>/dev/null)
  print -r -- "${v:-$d}"
}

bridge_allowed_parent() {            # $1 = parent név
  [[ -r "$BRIDGE_CONFIG" ]] || return 1
  jq -e --arg p "$1" '.parents | index($p) != null' "$BRIDGE_CONFIG" >/dev/null 2>&1
}

# --- Telegram -------------------------------------------------------------
# A token az URL-ben van, ezért a curl a URL-t a STDIN-ről kapja (--config -),
# nem argumentumként: így nem jelenik meg a `ps` kimenetében.
# A token forrása sorrendben: Keychain, majd a 0600-as fájl.
# ⚠️ id -un, nem $USER: launchd alatt a USER nincs beállítva.
bridge_token() {
  local t
  t=$(security find-generic-password -a "$(id -un)" -s "$BRIDGE_TOKEN_KC_SERVICE" -w 2>/dev/null)
  t="${t//[$'\n\r\t ']/}"
  # Alak-ellenorzes: a Telegram bot-token `<szamok>:<karakterek>` alaku. Ami nem
  # ilyen, azt NEM tokennek tekintjuk -- igy egy helykitolto ertek (amit a
  # felhasznalo majd felulir) nem tori el a hidat, hanem a fallbackre esunk.
  [[ "$t" == <->:?* ]] || t=""
  if [[ -z "$t" && -r "$BRIDGE_TOKEN_FILE" ]]; then
    t=$(<"$BRIDGE_TOKEN_FILE")
    t="${t//[$'\n\r\t ']/}"
    [[ "$t" == <->:?* ]] || t=""
  fi
  [[ -n "$t" ]] || return 1
  print -r -- "$t"
}

tg_ready() { bridge_token >/dev/null 2>&1 }

tg_call() {                          # $1 = method, többi = curl argumentumok
  local method="$1"; shift
  local token
  token=$(bridge_token) || {
    blog "ERROR nincs token (Keychain: $BRIDGE_TOKEN_KC_SERVICE, fájl: $BRIDGE_TOKEN_FILE)"; return 1
  }
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$method" \
    | curl -sS --connect-timeout "$BRIDGE_HTTP_CONNECT_TIMEOUT" \
           --max-time "$BRIDGE_HTTP_MAX_TIME" --config - "$@"
}

tg_chat_id() { bridge_cfg '.user_id' }

# ⚠️ A szövegben VALÓDI újsor legyen, ne "%0A": a --data-urlencode mindent
# kódol, így a kézzel írt %0A a telefonon szó szerint jelenne meg.
tg_send_message() {                  # $1 = szöveg, $2 = reply_markup JSON (opc.)
  local text="$1" markup="${2-}"
  local -a args
  args=(-d "chat_id=$(tg_chat_id)" --data-urlencode "text=$text" -d "parse_mode=HTML")
  [[ -n "$markup" ]] && args+=(--data-urlencode "reply_markup=$markup")
  tg_call sendMessage "${args[@]}"
}

# ⚠️ Explicit MIME-típus és charset KELL: enélkül a Telegram nem tudja, hogy a
# csatolmány UTF-8, és a beépített előnézetben az ékezetes karakterek
# elromlanak. A fájl maga végig helyes UTF-8 (ellenőrizve), csak a
# megjelenítés találgat.
tg_send_document() {                 # $1 = fájl, $2 = caption
  tg_call sendDocument \
    -F "chat_id=$(tg_chat_id)" \
    -F "document=@$1;type=text/plain; charset=utf-8" \
    -F "caption=$2" \
    -F "parse_mode=HTML"
}

tg_answer_callback() {               # $1 = callback id, $2 = rövid szöveg
  tg_call answerCallbackQuery -d "callback_query_id=$1" --data-urlencode "text=$2"
}

# A gombos uzenet ATIRASA a vegleges allapotra. A reply_markup ELHAGYASA veszi
# le a gombokat — enelkul a chatben orokre kattinthatonak latszanak.
# 2026-08-13: egy 36 oraja LEJART keresre harom Elutasitas-nyomas erkezett,
# mert a gombok ott maradtak; a rendszer helyesen visszautasitotta, de csak egy
# felugro buborekkal, amit konnyu nem eszrevenni.
# CSAK a gombokat veszi le, a szoveget MEGHAGYJA. 2026-08-30: egy uresbe futo
# visszavonas (dupla gombnyomas) `editMessageText`-tel atirta azt az uzenetet,
# amelyik egy SIKERES auto-inditast dokumentalt — a felhasznalonak ugy tunt, hogy
# a B4 lepes "eltunt". Egy no-op valasz nem torolhet el egy elvegzett muvelet
# nyomat; a gombot viszont le kell venni, hogy ne lehessen ujra ranyomni.
tg_clear_markup() {                  # $1 = message_id
  local mid="$1"
  [[ -n "$mid" ]] || return 1
  tg_call editMessageReplyMarkup -d "chat_id=$(tg_chat_id)" -d "message_id=$mid" \
    | jq -e '.ok == true' >/dev/null 2>&1
}

tg_edit_message() {                  # $1 = message_id, $2 = uj szoveg
  local mid="$1" text="$2"
  [[ -n "$mid" ]] || return 1
  tg_call editMessageText -d "chat_id=$(tg_chat_id)" -d "message_id=$mid" \
    -d "parse_mode=HTML" --data-urlencode "text=$text" \
    | jq -e '.ok == true' >/dev/null 2>&1
}

# A gombos uzenet azonositoja a keres id-je ala. Csak a LEJARATHOZ kell: ott
# nincs gombnyomas, amibol kiolvashatnank. A gombnyomasos agak a callback
# sajat `.message.message_id`-jat hasznaljak, igy a valtozas elotti uzenetek is
# rendbe tehetok.
# --- kozos allapot-zar -----------------------------------------------------
# A bridge-state.json-t es a bridge-spawned.json-t KET folyamat is
# olvassa-modositja-irja: a relay (WatchPaths-trigger) es a poller (30 mp-es
# utem). A tmp+mv csere folyamaton BELUL atomi, a ket ciklus kozott viszont
# nincs kizaras — ezert egy frissites elveszhet.
#
# A legrosszabb eset nem elmeleti: a poller torol egy felhatalmazast (rv: gomb),
# a felhasznalo megkapja a "Visszavonva." visszajelzest, kozben a relay egy epp
# beeso keresnel a TORLES ELOTTI allapotbol dolgozik, es visszairasaval
# FELTAMASZTJA a torolt felhatalmazast — a tovabbi folytatasok gombnyomas nelkul
# indulnanak, mikozben a felhasznalo azt hiszi, visszavonta.
#
# macOS-en nincs flock(1), ezert atomi mkdir-lock. Reentrans (a melyseget
# szamoljuk), hogy egy zart szakaszbol hivott masik zart fuggveny ne akadjon be.
: ${BRIDGE_LOCK_DIR:=$CLAUDE_AGENT_QUEUE/bridge-state.lock}
: ${BRIDGE_LOCK_WAIT:=10}
: ${BRIDGE_LOCK_ORPHAN_SEC:=120}
typeset -g _BRIDGE_LOCK_DEPTH=0

state_lock() {
  (( _BRIDGE_LOCK_DEPTH++ > 0 )) && return 0
  local i lpid
  for (( i = 0; i < BRIDGE_LOCK_WAIT * 20; i++ )); do
    if mkdir "$BRIDGE_LOCK_DIR" 2>/dev/null; then
      print -r -- "$$" > "$BRIDGE_LOCK_DIR/pid" 2>/dev/null
      return 0
    fi
    lpid=$(cat "$BRIDGE_LOCK_DIR/pid" 2>/dev/null)
    if [[ -n "$lpid" ]] && ! kill -0 "$lpid" 2>/dev/null; then
      blog "WARN elárvult állapot-lock eltávolítva (pid=$lpid)"
      rm -rf "$BRIDGE_LOCK_DIR"
      continue
    fi
    # ⚠️ PID NELKULI zar: ha a folyamat a `mkdir` es a pid kiirasa KOZOTT halt
    # meg, a feltoro ag sosem fogott (ures pid), es a zar ORAKRA-OROKRE bent
    # ragadt — minden allapot-modositas csendben kimaradt volna. Kor alapjan
    # bontjuk; a hataridonek nagyobbnak kell lennie, mint egy normal zart szakasz.
    if [[ -z "$lpid" ]]; then
      local lage
      lage=$(( $(date -u +%s) - $(stat -f %m "$BRIDGE_LOCK_DIR" 2>/dev/null || print 0) ))
      if (( lage > BRIDGE_LOCK_ORPHAN_SEC )); then
        blog "WARN pid nélküli állapot-lock eltávolítva (${lage}s)"
        rm -rf "$BRIDGE_LOCK_DIR"
        continue
      fi
    fi
    sleep 0.05
  done
  _BRIDGE_LOCK_DEPTH=0
  blog "ERROR az állapot-lock ${BRIDGE_LOCK_WAIT}s alatt nem szerezhető meg — a módosítás kimarad"
  return 1
}
state_unlock() {
  (( --_BRIDGE_LOCK_DEPTH > 0 )) && return 0
  _BRIDGE_LOCK_DEPTH=0
  rm -rf "$BRIDGE_LOCK_DIR"
}

# Olvasas-modositas-iras EGY lepesben, zar alatt. $1 = fajl, tobbi = jq argumentum.
state_edit() {
  local f="$1"; shift
  state_lock || return 1
  local tmp="$f.tmp.$$" rc=0
  [[ -r "$f" ]] || print '{}' > "$f"
  if jq "$@" "$f" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$f"; else rm -f "$tmp"; rc=1; fi
  state_unlock
  return $rc
}

bridge_remember_msg() {              # $1 = keres id, $2 = message_id
  state_edit "$BRIDGE_STATE" --arg id "$1" --argjson m "$2" \
    '.messages = ((.messages // {}) | .[$id] = $m)'
}
bridge_msg_id() {                    # $1 = keres id -> message_id vagy ures
  [[ -r "$BRIDGE_STATE" ]] || return 0
  jq -r --arg id "$1" '(.messages // {})[$id] // empty' "$BRIDGE_STATE" 2>/dev/null
}
bridge_forget_msg() {                # $1 = keres id
  [[ -r "$BRIDGE_STATE" ]] || return 0
  state_edit "$BRIDGE_STATE" --arg id "$1" \
    'if .messages then .messages |= del(.[$id]) else . end'
}

# --- idokorlatos allando jovahagyas ("felhatalmazas") ----------------------
# Egy KONKRET agentre szol: amig el, az arra erkezo `continue` es `reconnect`
# keresek gombnyomas nelkul indulnak. Uj fork es `close` SOHA nem esik bele —
# a fork uj munkat kezd, a close pedig kaszkadol es visszafordithatatlan.
# A lejarat EPOCH-ban tarolva (nem szovegkent), es HASZNALATKOR ellenorizve,
# igy nem kell kulon takarito ahhoz, hogy a lejart felhatalmazas ne fogjon.
bridge_grant_set() {                 # $1 = agent, $2 = masodperc, $3 = keres id
  local until; until=$(( $(date -u +%s) + $2 ))
  state_edit "$BRIDGE_STATE" --arg a "$1" --argjson u "$until" --arg r "$3" \
    '.grants = ((.grants // {}) | .[$a] = {until:$u, req:$r, scope:"continue+reconnect"})' || return 1
  print -r -- "$until"
}

bridge_grant_until() {               # $1 = agent -> lejarat epoch, ha MEG el
  [[ -r "$BRIDGE_STATE" ]] || return 1
  local u; u=$(jq -r --arg a "$1" '(.grants // {})[$a].until // empty' "$BRIDGE_STATE" 2>/dev/null)
  [[ -n "$u" ]] || return 1
  (( u > $(date -u +%s) )) || return 1
  print -r -- "$u"
}
bridge_grant_active() { bridge_grant_until "$1" >/dev/null 2>&1 }

# A visszavono gomb a KERES id-jet viszi, nem az agentnevet: a callback_data
# 64 bajt, az agentnev viszont 64 karakterig ervenyes (rv: + 64 = 67 > 64),
# a keres-id pedig legfeljebb 48 (rv: + 48 = 51). Merve 2026-08-15.
bridge_grant_revoke_by_req() {       # $1 = keres id -> kiirja az erintett agentet
  [[ -r "$BRIDGE_STATE" ]] || return 1
  # ⚠️ OLVAS, majd IR: a zarat a ketto KORE kell tartani, kulonben a ketto kozott
  # beekelodo iras alol kicsuszik az allapot.
  state_lock || return 1
  local a tmp="$BRIDGE_STATE.tmp.$$"
  a=$(jq -r --arg r "$1" '(.grants // {}) | to_entries[] | select(.value.req == $r) | .key' \
       "$BRIDGE_STATE" 2>/dev/null | head -1)
  if [[ -z "$a" ]]; then state_unlock; return 1; fi
  if jq --arg a "$a" 'if .grants then .grants |= del(.[$a]) else . end' \
       "$BRIDGE_STATE" > "$tmp"; then mv -f "$tmp" "$BRIDGE_STATE"
  else rm -f "$tmp"; state_unlock; return 1; fi
  state_unlock
  print -r -- "$a"
}

# ⚠️ 2026-09-01: a lezaras kivezette az agentet a `bridge-spawned`-bol es a
# fork-fabol, de a FELHATALMAZAS bent maradt. Egy lezart agentre szolo grant
# nem tud tuzelni (nem letezik a session), de ugyanaz a "koszos allapot"
# osztaly, ami korabban mar egyszer hamis kepet adott a nyilvantartasrol.
bridge_grant_revoke_by_agent() {     # $1 = agent
  [[ -r "$BRIDGE_STATE" ]] || return 1
  state_lock || return 1
  local tmp="$BRIDGE_STATE.tmp.$$"
  if jq --arg a "$1" 'if .grants then .grants |= del(.[$a]) else . end' \
       "$BRIDGE_STATE" > "$tmp"; then mv -f "$tmp" "$BRIDGE_STATE"
  else rm -f "$tmp"; state_unlock; return 1; fi
  state_unlock
}

bridge_grant_prune() {
  [[ -r "$BRIDGE_STATE" ]] || return 0
  local now; now=$(date -u +%s)
  state_edit "$BRIDGE_STATE" --argjson n "$now" \
    'if .grants then .grants |= with_entries(select(.value.until > $n)) else . end'
}

bridge_grant_human() {               # $1 = epoch -> helyi ido, olvashatoan
  date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || print -r -- "$1"
}

# --- beragadt agent eszlelese ----------------------------------------------
# 2026-08-22: egy hid-agent kerdessel fejezte be a kort, es vart egy valaszra,
# amit senki nem adhatott meg — a munka felkeszen ult a lemezen. A megelozes
# (utasitas + AskUserQuestion tiltas) LLM-fuggo, ezert kell melle eszleles.
#
# "Beragadt" = a hid inditotta, TETLEN mar N perce, es a hozza tartozo keresre
# meg nincs jelentes (sem publikalva, sem a munkakonyvtaraban).
: ${BRIDGE_STALL_MIN:=15}

# Emberi idotartam: a "14016 perce tetlen" olvashatatlan (elesben pont ez jott ki).
bridge_dur_human() {                 # $1 = percek
  local m="$1"
  if   (( m >= 2880 )); then print -r -- "$(( m / 1440 )) napja"
  elif (( m >= 1440 )); then print -r -- "egy napja"
  elif (( m >= 120  )); then print -r -- "$(( m / 60 )) órája"
  elif (( m >= 60   )); then print -r -- "egy órája"
  else print -r -- "${m} perce"; fi
}

# --- beragadas-nemitas -------------------------------------------------------
# Van, amirol a felhasznalo TUDJA, hogy szandekosan all (parkolt agent, vagy epp
# a parancskozpont ket kor kozott). Ilyenkor a riasztas zaj. A `🔕` gomb
# idokorlatosan elnemitja EZT AZ AGENTET — nem a rendszert, es nem orokre:
# lejarat utan magatol visszaall, tehat egy valodi beragadas nem marad rejtve.
bridge_stall_mute_set() {            # $1 = agent, $2 = masodperc -> lejarat epoch
  local until; until=$(( $(date -u +%s) + $2 ))
  state_edit "$BRIDGE_STATE" --arg a "$1" --argjson u "$until" \
    '.stall_mute = ((.stall_mute // {}) | .[$a] = $u)' || return 1
  print -r -- "$until"
}

bridge_stall_muted() {               # $1 = agent -> 0, ha MEG el a nemitas
  local u now
  u=$(jq -r --arg a "$1" '(.stall_mute // {})[$a] // empty' "$BRIDGE_STATE" 2>/dev/null)
  [[ "$u" == <-> ]] || return 1
  now=$(date -u +%s)
  (( u > now )) || { 
    # Lejart -> opportunista takaritas, hogy ne gyuljon.
    state_edit "$BRIDGE_STATE" --arg a "$1" \
      'if .stall_mute then .stall_mute |= del(.[$a]) else . end' 2>/dev/null
    return 1
  }
  print -r -- "$u"
}

bridge_stall_marked() {              # $1 = agent -> a mar jelzett keres id-je
  [[ -r "$BRIDGE_STATE" ]] || return 0
  jq -r --arg a "$1" '(.stalled // {})[$a] // empty' "$BRIDGE_STATE" 2>/dev/null
}
bridge_stall_mark() {                # $1 = agent, $2 = keres id
  state_edit "$BRIDGE_STATE" --arg a "$1" --arg r "$2" \
    '.stalled = ((.stalled // {}) | .[$a] = $r)'
}

# Emlekezteto BEKULDESE a beragadt agent sessionjebe. Ugyanaz a minta, mint a
# folytatasnal: EGY sorba osszevonva, mert a tmux send-keys minden ujsort
# ENTERKENT kuld, es a tobbsoros szoveg felkesz promptot submitolna.
bridge_nudge_agent() {               # $1 = agent nev, $2 = keres id (opc.)
  local sess msg fname
  fname=$([[ -n "${2-}" ]] && bridge_result_name "$2" || print -r -- "$BRIDGE_RESULT_BASENAME")
  source "$(dirname "${(%):-%x}")/_agent-lib.sh"
  sess=$(agent_tmux_session "$1") || { print -u2 "nem fut: $1"; return 1 }
  msg="EMLÉKEZTETŐ a hídtól: ebben a sessionben nincs kihez visszakérdezned, a válaszodat senki nem olvassa. Ha döntésre vársz, írd a kérdést, a lehetőségeket és a javaslatodat a ${fname} fájlba a munkakönyvtárad gyökerében, majd fejezd be a kört — a küldő új folytatás-kéréssel válaszol. Ha van ésszerű alapértelmezés, döntsd el magad és a jelentésben mondd el, mit választottál."
  tmux send-keys -t "$sess" -l "${msg//$'\n'/ }" || return 1
  sleep 1
  tmux send-keys -t "$sess" Enter || return 1
}

bridge_detect_stalled() {
  [[ -r "$BRIDGE_SPAWNED" ]] || return 0
  local mins now name id st upd idle spec rcwd mk
  mins=$(bridge_cfg '.stall_minutes' "$BRIDGE_STALL_MIN")
  now=$(date -u +%s)
  for name in ${(f)"$(jq -r 'keys[]' "$BRIDGE_SPAWNED" 2>/dev/null)"}; do
    [[ -n "$name" ]] || continue
    # ⚠️ A PARANCSKOZPONT SOHA nem "beragadt hid-agent". 2026-09-03: a gyoker
    # agent egy 2026-08-29-i, reg halott keres-id-vel bent maradt a
    # nyilvantartasban, a beragadas-figyelo tetlennek latta, es NUDGE-olta — az
    # emlekezteto szovegevel egyutt, ami azt allitja, hogy "nincs kihez
    # visszakerdezned". A parancskozpontnal ez pont forditva igaz: ott UL a
    # felhasznalo. Az uzenet a beszelgeteset szakitja felbe, es olyan
    # jelentes-fajl irasara szolitja fel, aminek nincs cimzettje.
    # A gyokeret a watchdog kezeli, nem a hid — ugyanaz a hatar, mint a
    # `continue_agent` feltamasztas-tilalmanal.
    if [[ "$name" == "${ROOT_AGENT_NAME:-mac-main}" ]]; then
      continue
    fi
    id=$(jq -r --arg n "$name" '.[$n].request // empty' "$BRIDGE_SPAWNED" 2>/dev/null)
    [[ "$id" =~ '^[A-Za-z0-9._-]{1,48}$' ]] || continue

    # Erre a keresre MAR VALASZOLT? Ezt ALLAPOTBOL nezzuk: a jelentes-fajl
    # archivalhato vagy kitakarithato, es akkor egy REGEN lezarult kor ujra
    # "beragadtnak" latszana — 2026-08-30-an pontosan ez tortent a mac-main-nel.
    [[ "$(jq -r --arg n "$name" '.[$n].answered // empty' "$BRIDGE_SPAWNED" 2>/dev/null)" == "$id" ]] && continue
    # Fallback a regi korokre, amikhez meg nincs `answered` jelzes.
    [[ -s "$RES_DIR/$id.md" ]] && continue
    # A meg NEM publikalt jelentes is szamit (a poller 30 mp-enkent emeli at).
    spec=$(find_spec "$name" 2>/dev/null)
    if [[ -n "$spec" ]]; then
      rcwd=$(agent_runtime_cwd "$(read_spec_field "$spec" cwd)" \
                               "$(read_spec_field "$spec" worktree)" "$name")
      # Barmelyik meg nem publikalt jelentes szamit (keresenkenti nevek!).
      # ⚠️ `L+0` = csak a NEM URES fajl. A bridge_publish_results is `-s`-re
      # szur, tehat egy 0 bajtos jelentest sosem emelne at — ha itt a puszta
      # letezese elnyomna a riasztast, az agent OROKRE nemakent ragadna be.
      local pend; pend=("$rcwd"/.bridge-result*.md(N.L+0))
      (( ${#pend} )) && continue
    fi

    # Elnemitva? A felhasznalo kimondta, hogy errol az agentrol most nem ker
    # ertesitest (`🔕` gomb). Idokorlatos, tehat magatol visszaall.
    bridge_stall_muted "$name" >/dev/null && continue

    # Nem fut -> nem ez a dolgunk (azt a gc/reconnect kezeli).
    st=$(agent_session_field "$name" status 2>/dev/null) || continue
    [[ "$st" == "idle" ]] || continue
    upd=$(agent_session_field "$name" statusUpdatedAt 2>/dev/null) || continue
    idle=$(( (now - upd / 1000) / 60 ))          # statusUpdatedAt ezredmasodpercben
    (( idle >= mins )) || continue

    # Keresenkent EGYSZER szolunk, kulonben 30 mp-enkent ismetelnenk.
    [[ "$(bridge_stall_marked "$name")" == "$id" ]] && continue
    bridge_stall_mark "$name" "$id"
    blog "STALLED $name (keres: $id, tetlen: $(bridge_dur_human "$idle"))"
    tg_ready || continue
    mk=$(jq -nc --arg r "$id" \
      '{inline_keyboard:[[{text:"🔔 Emlékeztetem",callback_data:("nu:" + $r)}],
                         [{text:"🔕 8 óra",callback_data:("s8:" + $r)},
                          {text:"🔕 1 nap",callback_data:("sd:" + $r)},
                          {text:"🔕 1 hét",callback_data:("sw:" + $r)}]]}')
    tg_send_message "⏳ <b>Egy agent tétlenül áll, jelentés nélkül</b>"$'\n'"agent: <code>$name</code>"$'\n'"kérés: <code>$id</code>"$'\n'"$(bridge_dur_human "$idle") tétlen, és még nincs jelentése. Elképzelhető, hogy kérdéssel fejezte be a kört — arra viszont itt nincs kitől választ kapnia."$'\n'"Csatlakozás: <code>$(attach_hint "$name")</code>" "$mk" >/dev/null 2>&1
  done
}

# --- állapot --------------------------------------------------------------
# A getUpdates offsetjét perzisztálni KELL, különben újrafeldolgozás.
state_get() { local k="$1"; [[ -r "$BRIDGE_STATE" ]] || { print 0; return }; jq -r --arg k "$k" '.[$k] // 0' "$BRIDGE_STATE" }
state_set() {
  state_edit "$BRIDGE_STATE" --arg k "$1" --argjson v "$2" '.[$k] = $v'
}

# ⚠️ A HIANYZO es a SERULT statuszt kulon kell kezelni. A regi valtozat a jq
# bukasat is a `|| print "new"` agra ejtette, tehat egy felbeszakadt irassal
# serult statuszfajl UJ keresnek latszott: a relay ujra jovahagyast kert, es egy
# gombnyomassal masodszor is lefutott egy mar vegrehajtott keres.
req_status() {                       # $1 = id
  local f="$REQ_DIR/$1.status" v
  [[ -e "$f" ]] || { print "new"; return 0 }          # tenylegesen uj
  v=$(jq -r '.status // empty' "$f" 2>/dev/null) || { print "corrupt"; return 0 }
  [[ -n "$v" ]] || { print "corrupt"; return 0 }
  print -r -- "$v"
}

# ⚠️ tmp + mv, NEM kozvetlen `>`: az atiranyitas a jq indulasa ELOTT truncate-el,
# tehat egy jq-bukas vagy egy felbeszakadt iras ures/csonka statuszfajlt hagy —
# azt pedig a req_status korabban "new"-nak olvasta (ujravegrehajtas).
set_status() {                       # $1 = id, $2 = status, $3 = üzenet
  local tmp="$REQ_DIR/$1.status.tmp.$$"
  if jq -n --arg s "$2" --arg m "${3-}" --arg t "$(date -u +%FT%TZ)" \
    '{status:$s, message:$m, updated_at:$t}' > "$tmp"; then
    mv -f "$tmp" "$REQ_DIR/$1.status"
  else
    rm -f "$tmp"; blog "ERROR set_status $1 -> $2 sikertelen (a statusz valtozatlan)"
  fi
  blog "STATUS $1 -> $2 ${3-}"
}

# --- a hid altal INDITOTT agentek nyilvantartasa ---------------------------
# Ez adja a lezaras hatarat: a Desktop csak a sajat maga utan takarithat.
# A whitelistazott GYOKEREK sosem kerulnek ide -- azokat lezarni annyi lenne,
# mint a napi munkakornyezetet kinyirni (a kaszkad nevszerinti leszarmazottakra
# megy, tehat a mac-main lezarasa a -infra es a -web agentet is
# elvinne).
: ${BRIDGE_SPAWNED:=$CLAUDE_AGENT_QUEUE/bridge-spawned.json}
# A hid-agent a SAJAT munkakonyvtaraba irja a jelentest, mert a sandbox CSAK
# oda enged irni (mert 2026-08-11: a `bridge/results/`-be iras `operation not
# permitted`-tel bukott, es a shell-script CSENDBEN ment tovabb -> a Desktop
# orokke varhatott volna egy soha meg nem szuleto fajlra).
: ${BRIDGE_RESULT_BASENAME:=.bridge-result.md}
# ⚠️ KERESENKENTI fajlnev. A fix nev postalada 1 fereohellyel: ha az agent ket
# kort fut, mielott a publikalo (30 mp) elvinne az elsot, a MASODIK FELULIRJA —
# az elso jelentes nyomtalanul elvesz. Ennel is alattomosabb: ha a nyilvantartas
# kozben a kovetkezo keresre lepett, az elso jelentes a MASODIK keres id-je alatt
# publikalodik. Merve 2026-08-26, egy Desktop-agent jelezte.
# A regi nevet tovabbra is elfogadjuk (visszafele kompatibilitas).
bridge_result_name() { print -r -- ".bridge-result-${1}.md" }
# Ennyi masodpercig NEM nyulunk egy frissen irt fajlhoz: ne vegyuk el iras kozben.
: ${BRIDGE_RESULT_SETTLE_SEC:=3}

bridge_register_spawned() {          # $1 = agent nev, $2 = keres id
  state_edit "$BRIDGE_SPAWNED" --arg n "$1" --arg r "$2" --arg t "$(date -u +%FT%TZ)" \
    '.[$n] = {request:$r, at:$t}'
  blog "REGISTERED-SPAWNED $1 (kérés: $2)"
}

bridge_is_spawned() {                # $1 = agent nev
  [[ -r "$BRIDGE_SPAWNED" ]] || return 1
  jq -e --arg n "$1" 'has($n)' "$BRIDGE_SPAWNED" >/dev/null 2>&1
}

bridge_unregister_spawned() {        # $1 = agent nev
  [[ -r "$BRIDGE_SPAWNED" ]] || return 0
  state_edit "$BRIDGE_SPAWNED" --arg n "$1" 'del(.[$n])'
}

# --- takaritas: nyilvantartott, de nem futo agentek ------------------------
# Ha egy agentet KEZZEL zarnak le (`exit` a tmuxban, `tmux kill-session`), az NEM
# megy at a close-tree-n: a worktree, az ag es a nyilvantartas-bejegyzes
# takaritatlanul marad (merve 2026-08-08, mac-main-dcred-store-...).
#
# ⚠️ Turelmi ido kell: egy agent atmenetileg is lehet "nem futo" (ujraindulas,
# reconnect kozben). Csak azt takaritjuk, ami mar egy ideje halott.
# ⚠️ Es csak az URESET: ha a worktree-ben munka van, JELEZZUK, nem toroljuk.
: ${BRIDGE_GC_GRACE_MIN:=15}

bridge_gc_spawned() {
  [[ -r "$BRIDGE_SPAWNED" ]] || return 0
  local now n since age spec cwd wt rt wtp top base commits dirty
  now=$(date -u +%s)
  for n in ${(f)"$(jq -r 'keys[]?' "$BRIDGE_SPAWNED" 2>/dev/null)"}; do
    [[ -n "$n" ]] || continue
    if tmux has-session -t "agent-$n" 2>/dev/null || tmux has-session -t "$n" 2>/dev/null; then
      # Fut -> a halott-ota belyeg torlodik.
      state_edit "$BRIDGE_SPAWNED" --arg k "$n" \
        'if .[$k].not_running_since then .[$k] |= del(.not_running_since) else . end'
      continue
    fi
    since=$(jq -r --arg k "$n" '.[$k].not_running_since // empty' "$BRIDGE_SPAWNED" 2>/dev/null)
    if [[ -z "$since" ]]; then
      state_edit "$BRIDGE_SPAWNED" --arg k "$n" --arg t "$(date -u +%FT%TZ)" \
        '.[$k].not_running_since = $t'
      blog "GC $n nem fut — türelmi idő indul"
      continue
    fi
    age=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$since" +%s 2>/dev/null) || continue
    (( (now - age) / 60 >= BRIDGE_GC_GRACE_MIN )) || continue

    spec=$(find_spec "$n"); [[ -n "$spec" ]] || { bridge_unregister_spawned "$n"; blog "GC $n kivezetve (nincs spec)"; continue }
    cwd=$(read_spec_field "$spec" cwd); wt=$(read_spec_field "$spec" worktree)
    wtp=$(worktree_path "$cwd" "$wt" "$n")
    if [[ -z "$wtp" ]]; then
      bridge_unregister_spawned "$n"; blog "GC $n kivezetve (nincs worktree, nincs mit takaritani)"; continue
    fi
    top=$(git_main_toplevel "$cwd") || { blog "GC $n: nem oldható fel a toplevel"; continue }
    base=$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null); [[ -n "$base" ]] || base=main
    # ⚠️ A git HIBAJA NEM "ures worktree". Serult repo, kezi `git worktree prune`
    # utani torott back-pointer vagy zarolt index eseten mindket parancs ures
    # kimenettel bukik — a regi kod ezt commits=0 / dirty=0-nak olvasta, es a
    # munkat tartalmazo worktree-t URESKENT torolte volna (remove_worktree =
    # `worktree remove --force` + `branch -D` + `rm -rf`). Ugyanez az or all a
    # close-tree-ben is (agent-close-tree.sh), a GC-bol hianyzott.
    commits=$(git -C "$top" rev-list --count "$base..worktree-$n" 2>/dev/null) \
      || { blog "GC $n KIHAGYVA — a rev-list hibara futott (sérült repó?); nem takarítok, mert nem tudom, üres-e"; continue }
    [[ "$commits" == <-> ]] \
      || { blog "GC $n KIHAGYVA — a rev-list nem számot adott: ${commits:-<üres>}"; continue }
    dirty=$(git -C "$wtp" status --porcelain 2>/dev/null) \
      || { blog "GC $n KIHAGYVA — a git status hibára futott a worktree-ben: $wtp"; continue }
    dirty=$(print -r -- "$dirty" | grep -c . )
    if (( commits == 0 && dirty == 0 )); then
      remove_worktree "$cwd" "$wtp" "worktree-$n"
      bridge_unregister_spawned "$n"
      blog "GC $n takarítva (üres worktree + ág törölve, kivezetve)"
    else
      blog "GC $n MEGTARTVA — munka van benne ($commits commit, $dirty módosítás)"
    fi
  done
}

# --- felderites: mit lat a Desktop --------------------------------------
# A Desktop nem tudhatja fejbol, mely agentek leteznek -- egy hardcode-olt lista
# az elso valtozasnal elavul, es a keres csak egy elutasitast kap, amibol nem
# derul ki, mi az ervenyes. Ezert a Mac IRJA KI az aktualis allapotot a csatolt
# mappaba; a fajl az egyetlen csatorna itt is.
bridge_write_agents() {
  local out="$BRIDGE_DIR/agents.json" tmp="$BRIDGE_DIR/agents.json.tmp.$$"
  [[ -d "$BRIDGE_DIR" ]] || return 0
  local running_check
  source "$(dirname "${(%):-%x}")/_agent-lib.sh"
  running_check() {                  # $1 = nev -> "true"/"false"
    # ⚠️ Ez a lista hirdeti a Desktopnak, mi erheto el. Ha ELTER attol, ahogy a
    # `continue_agent` keresi a sessiont, a hid olyan celt kinal, amit nem tud
    # kiszolgalni — pontosan ez tortent a `mac-main`-nel 2026-08-29-en.
    if agent_tmux_session "$1" >/dev/null; then print true; else print false; fi
  }
  {
    print -n '{"updated_at":"'"$(date -u +%FT%TZ)"'","parents":['
    local first=1 p r about
    for p in ${(f)"$(jq -r '.parents[]?' "$BRIDGE_CONFIG" 2>/dev/null)"}; do
      [[ -n "$p" ]] || continue
      (( first )) || print -n ','; first=0
      r=$(running_check "$p")
      about=$(jq -r --arg n "$p" '.about[$n] // ""' "$BRIDGE_CONFIG" 2>/dev/null)
      jq -nc --arg n "$p" --argjson run "$r" --arg a "$about" '{name:$n, running:$run, about:$a}' | tr -d '\n'
    done
    print -n '],"spawned":['
    first=1
    local n
    for n in ${(f)"$(jq -r 'keys[]?' "$BRIDGE_SPAWNED" 2>/dev/null)"}; do
      [[ -n "$n" ]] || continue
      (( first )) || print -n ','; first=0
      r=$(running_check "$n")
      jq -nc --arg n "$n" --argjson run "$r" \
        --arg req "$(jq -r --arg k "$n" '.[$k].request // ""' "$BRIDGE_SPAWNED" 2>/dev/null)" \
        --arg at "$(jq -r --arg k "$n" '.[$k].at // ""' "$BRIDGE_SPAWNED" 2>/dev/null)" \
        --arg nrs "$(jq -r --arg k "$n" '.[$k].not_running_since // ""' "$BRIDGE_SPAWNED" 2>/dev/null)" \
        '{name:$n, running:$run, request:$req, since:$at}
         + (if $nrs != "" then {not_running_since:$nrs} else {} end)' | tr -d '\n'
    done
    print -n ']}'
  } > "$tmp" 2>/dev/null
  jq -e . "$tmp" >/dev/null 2>&1 && mv "$tmp" "$out" || rm -f "$tmp"
}

# --- kérés-validálás ------------------------------------------------------
# Visszaadja a normalizált kérést JSON-ként, vagy hibaüzenettel bukik.
validate_request() {                 # $1 = kérés-fájl
  local f="$1" parent agent task cwd model effort worktree root mode target ok pp action code ctx tr wtnote eff
  jq -e . "$f" >/dev/null 2>&1 || { print -u2 "érvénytelen JSON"; return 1 }

  parent=$(jq -r '.parent // empty' "$f")
  agent=$(jq -r '.agent // empty' "$f")
  task=$(jq -r '.task // empty' "$f")
  action=$(jq -r '.action // "run"' "$f")

  # --- UJRACSATLAKOZTATAS: nem destruktiv, de sessiont indit ujra ----------
  if [[ "$action" == "reconnect" ]]; then
    [[ -n "$agent" ]] || { print -u2 "a reconnect-hez agent kell"; return 1 }
    [[ "$agent" =~ '^[a-zA-Z0-9_-]{3,64}$' ]] || { print -u2 "érvénytelen agent-név: $agent"; return 1 }
    bridge_is_spawned "$agent" || {
      print -u2 "ezt az agentet nem a híd indította: $agent (a gyökereket a watchdog kezeli)"; return 1 }
    jq -n --arg a "$agent" '{mode:"reconnect", target:$a, agent:$a}'
    return 0
  fi

  # --- LEZARAS: kulon, szukebb hataru ag -----------------------------------
  if [[ "$action" == "close" ]]; then
    [[ -n "$agent" ]] || { print -u2 "a lezáráshoz agent kell (melyiket zárjam le)"; return 1 }
    [[ "$agent" =~ '^[a-zA-Z0-9_-]{3,64}$' ]] || { print -u2 "érvénytelen agent-név: $agent"; return 1 }
    # ⚠️ A hatar: csak amit a hid maga inditott. A gyokerek strukturalisan
    # kimaradnak, mert oda sosem regisztralunk.
    bridge_is_spawned "$agent" || {
      print -u2 "ezt az agentet nem a híd indította, ezért innen nem zárható le: $agent"; return 1 }
    code=$(jq -r '.code // "nowt"' "$f")
    case "$code" in merge|drop|nowt) ;; *) print -u2 "érvénytelen code: $code (merge|drop|nowt)"; return 1;; esac
    ctx=$(jq -r '.context // "keep"' "$f")
    case "$ctx" in merge|keep) ;; *) print -u2 "érvénytelen context: $ctx (merge|keep)"; return 1;; esac
    tr=$(jq -r '.transcript // "keep"' "$f")
    case "$tr" in keep|delete) ;; *) print -u2 "érvénytelen transcript: $tr (keep|delete)"; return 1;; esac
    jq -n --arg a "$agent" --arg c "$code" --arg x "$ctx" --arg t "$tr" \
      '{mode:"close", target:$a, agent:$a, code:$c, context:$x, transcript:$t}'
    return 0
  fi

  [[ -n "$task" ]] || { print -u2 "üres task"; return 1 }
  # BAJT, nem karakter — ugyanaz, mint a spawnerben: a `${#task}` karaktert
  # szamol, tehat ekezetes szoveggel a "8 KB" 16 KB is lehetett volna.
  (( $(printf %s "$task" | wc -c) <= 8192 )) || { print -u2 "a task túl hosszú (>8KB)"; return 1 }

  # `parent` = UJ fork belole; `agent` = FOLYTATAS a mar letezo sessionben.
  # A ketto kizarja egymast.
  if [[ -n "$parent" && -n "$agent" ]]; then
    print -u2 "parent ÉS agent egyszerre — az egyik kell, nem mindkettő"; return 1
  fi
  if [[ -z "$parent" && -z "$agent" ]]; then
    print -u2 "hiányzik: adj meg parent-et (új fork) vagy agent-et (folytatás)"; return 1
  fi

  if [[ -n "$agent" ]]; then
    mode=continue; target="$agent"
    [[ "$agent" =~ '^[a-zA-Z0-9_-]{3,64}$' ]] || { print -u2 "érvénytelen agent-név: $agent"; return 1 }
    # Csak whitelistazott gyokerbol SZARMAZO agentet szabad megszolitani --
    # igy a hatar ugyanaz marad, mint az uj forkoknal.
    ok=false
    for pp in ${(f)"$(jq -r '.parents[]?' "$BRIDGE_CONFIG" 2>/dev/null)"}; do
      [[ "$agent" == "$pp" || "$agent" == "$pp-"* ]] && { ok=true; break }
    done
    $ok || { print -u2 "az agent nem whitelistázott gyökérből származik: $agent"; return 1 }
  else
    mode=fork; target="$parent"
    bridge_allowed_parent "$parent" || { print -u2 "a parent nincs a whitelistán: $parent"; return 1 }
  fi

  root=$(bridge_cfg '.cwd_root' "${CLAUDE_AGENT_ROOT:A}")
  cwd=$(jq -r '.cwd // empty' "$f")
  if [[ -n "$cwd" ]]; then
    [[ "$cwd" == /* ]] || cwd="$root/$cwd"
    cwd="${cwd:A}"
    [[ "$cwd" == "$root" || "$cwd" == "$root"/* ]] \
      || { print -u2 "a cwd az engedélyezett gyökéren kívül: $cwd"; return 1 }
  fi

  # A default a varazsloeval EGYEZZEN (new-agent.md 4a-bis) — kulonben ugyanaz
  # a "nem adtam meg modellt" ket kulonbozo modellt jelentene a ket uton.
  # ALIAS, nem rogzitett azonosito: a CLI sugoja szerint az alias mindig A
  # LEGFRISSEBB modellt jelenti, tehat verziovaltaskor nem avul el.
  model=$(jq -r '.model // "opus"' "$f")
  case "$model" in
    # ⚠️ A harom validator (spawner, hid, fork-agent) LISTAJANAK EGYEZNIE KELL.
    # 2026-08-26: csak a spawner kapta meg a Claude 5 csaladot, igy egy hid-keres
    # vagy /fork a TENYLEGESEN hasznalt `claude-opus-5`-tel elutasitasra kerult.
    opus|sonnet|haiku|fable) ;;
    claude-opus-4-7|claude-opus-4-8|'claude-opus-4-7[1m]'|'claude-opus-4-8[1m]') ;;
    claude-opus-5|claude-sonnet-5|claude-fable-5|claude-haiku-4-5|'claude-opus-5[1m]'|'claude-sonnet-5[1m]') ;;
    *) print -u2 "érvénytelen model: $model"; return 1;;
  esac
  effort=$(jq -r '.effort // "high"' "$f")
  case "$effort" in low|medium|high|xhigh|max) ;; *) print -u2 "érvénytelen effort: $effort"; return 1;; esac
  # ALAPERTELMEZES: worktree. Az izolacio a jobb default -- a gyerek sajat agon
  # dolgozik, ami mergelheto vagy eldobhato. Csak akkor kell elhagyni, ha a
  # feladat a szulo NEM COMMITOLT munkajara epul: a friss worktree a HEAD-rol
  # keszul, tehat a szulo modositasait es uj fajljait NEM tartalmazza.
  wtnote=""
  if jq -e 'has("worktree")' "$f" >/dev/null 2>&1; then
    worktree=$(jq -r 'if .worktree == true then "true" else "false" end' "$f")
  else
    worktree=true
    # De: a --worktree git repot igenyel. Ha a cwd nem az, csendben visszaesunk
    # (ugyanaz a minta, amit a /new-agent 4.5 lepese hasznal), es megmondjuk.
    local eff="$cwd"
    if [[ -z "$eff" ]] && typeset -f agent_session_cwd >/dev/null; then
      eff=$(agent_session_cwd "$target" 2>/dev/null) || eff=""
    fi
    if [[ -n "$eff" ]] && ! git -C "$eff" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      worktree=false
      wtnote="a cwd nem git repó, ezért worktree nélkül indul"
    fi
  fi

  # A permission mode MOST MAR johet a keresbol: a hid celja epp az, hogy teljes
  # erteku CLI agentet lehessen inditani rola. A hatart nem itt huzzuk meg, hanem
  # a VEGREHAJTASNAL — a `bypassPermissions` csak kifejezett Telegram-gombnyomas
  # utan ervenyesul (lasd spawn_from_request).
  # ⚠️ A LISTA EGYEZZEN a spawnereval es a fork-agentevel.
    # ⚠️ ALAPERTELMEZES: `none` — FRISS session (2026-08-31). Korabban `full` volt.
    # Az orokles KETSZER bizonyitottan a szulo SZEREPET adta at a gyereknek a sajat
    # feladata helyett (714 soros orokolt atirat, a feladat a 703. sorban), es a
    # vedekezo rendszer-prompt nem volt eleg ellene. Aki kontextust akar adni,
    # kerje kifejezetten: `summary` (tomoritett, gyorsabb) vagy `full` (teljes
    # beszelgetes; nagy szulonel percekig tarto elso kor — 2026-08-29-en emiatt
    # maradt nema ket teszt-agent).
  rs=$(jq -r '.resume // "none"' "$f")
  case "$rs" in
    # `none` = FRISS session, orokolt beszelgetes nelkul. 2026-08-31: egy fork
    # gyereke a szulo 700 soros kontextusat orokolve a szulo SZEREPET folytatta
    # a sajat feladata helyett — a feladat a 703. sorban allt. Onallo munkahoz
    # ez a biztonsagos valasztas.
    full|summary|none) ;;
    *) print -u2 "érvénytelen resume: $rs (full|summary|none)"; return 1;;
  esac
  pp=$(jq -r '.permission_mode // "auto"' "$f")
  case "$pp" in
    auto|acceptEdits|plan|dontAsk|manual|bypassPermissions) ;;
    *) print -u2 "érvénytelen permission_mode: $pp"; return 1;;
  esac
  jq -n --arg p "$parent" --arg a "$agent" --arg mo "$mode" --arg tg "$target" \
        --arg t "$task" --arg c "$cwd" --arg wn "$wtnote" \
        --arg m "$model" --arg e "$effort" --argjson w "$worktree" --arg pm "$pp" --arg rs "$rs" \
    '{mode:$mo, target:$tg, parent:$p, agent:$a, task:$t, cwd:$c, model:$m,
      effort:$e, worktree:$w, worktree_note:$wn, permission_mode:$pm, resume:$rs}'
}

# --- a kért agent tényleges elindítása -------------------------------------
# A relay/poller nem Claude sessionből fut, tehát nincs CLAUDE_CODE_SESSION_ID.
# A szülő élő session id-ját az agent_session_id() oldja fel a folyamat saját
# állapotfájljából — ezért kellett az az 1. fázisban.
# Az eredmeny visszairasa: a Desktop VM-bol nincs halozat es nincs
# agent-to-agent messaging -- a mountolt lemez az egyetlen visszaut. Ezt NEM
# bizzuk arra, hogy a kero beleirja a feladatszovegbe: a hid maga fuzi hozza.
# (A Telegram-osszefoglaloba szandekosan NEM kerul bele -- ott azt lasd, amit a
# kero akar, ne a vizvezetéket.) Mindket mod hasznalja: uj fork es folytatas is.
augment_task() {                     # $1 = id, $2 = eredeti task
  local id="$1" t="$2"
  t+=$'\n\n---\n'"Ezt a feladatot a Desktop-hídon keresztül kaptad. Amikor kész vagy, az eredményt írd ide:"
  t+=$'\n'"  a SAJÁT munkakönyvtárad gyökerébe, \`$(bridge_result_name "$id")\` néven"
  t+=$'\n'"  (a fájlnévben a kérés azonosítója van — NE írd felül egy korábbi kör jelentését)"
  t+=$'\n'"A Mac ezt magától publikálja a küldőnek (30 mp-en belül); neked nem kell máshova másolnod."
  t+=$'\n'"⚠️ A $RES_DIR/ könyvtárba KÖZVETLENÜL ne írj: a sandboxod csak a saját munkakönyvtáradba"
  t+=$'\n'"enged írni, és egy blokkolt átirányítás NEM állítja meg a scriptet — azt hinnéd, kész vagy."
  t+=$'\n'"Rövid, önmagában érthető összefoglaló legyen — aki a feladatot küldte, NEM látja a beszélgetésedet."
  t+=$'\n\n'"⛔️ NEM KÉRDEZHETSZ VISSZA EBBEN A SESSIONBEN."
  t+=$'\n'"Ezt a feladatot nem ember adta, hanem egy másik agent a hídon át. A te"
  t+=$'\n'"beszélgetésedet SENKI nem olvassa: a session-ödben feltett kérdés örökre"
  t+=$'\n'"megválaszolatlan marad, a munka pedig félbe. Ne fejezd be úgy a kört, hogy"
  t+=$'\n'"választ vársz, és ne használd az AskUserQuestion eszközt."
  t+=$'\n'"Ha DÖNTÉS kell (pl. két megoldás közül kellene választani):"
  t+=$'\n'"  1. írd le a $(bridge_result_name "$id") fájlba, hogy mi a kérdés, milyen lehetőségek"
  t+=$'\n'"     vannak, mi a különbségük, és melyiket javaslod — pontosan, mert a döntő"
  t+=$'\n'"     fél nem látja, amit te látsz;"
  t+=$'\n'"  2. fejezd be a kört. A küldő elolvassa, dönt, és egy ÚJ folytatás-kéréssel"
  t+=$'\n'"     válaszol — így a döntés is átmegy a jóváhagyási kapun."
  t+=$'\n'"Ha viszont a kérdés részletkérdés, és van ésszerű alapértelmezés: DÖNTSD EL"
  t+=$'\n'"MAGAD, csináld meg, és a jelentésben mondd el, mit választottál és miért."
  # ⚠️ EZ A ZARO MONDAT KORABBAN ONMAGAT UTOTTE: "Kerdesre csak akkor menj
  # vissza, ha..." — vagyis megengedte azt, amit a blokk eleje TILT, es ami itt
  # fizikailag lehetetlen (senki nem olvassa a sessiont). Aki az utolso mondatot
  # koveti, pont abba a hibaba fut, ami ellen az egesz szoveg keszult: megall
  # egy valaszra, ami sosem jon. A kiveteles eset nem MASIK csatorna, csak
  # annyi, hogy olyankor ne donts magad — de a kerdes akkor is a JELENTESBE megy.
  t+=$'\n'"Magadtól akkor NE dönts, ha a döntés visszafordíthatatlan, vagy ha olyan"
  t+=$'\n'"információ kell, ami nálad nincs meg — ilyenkor a fenti módon, a JELENTÉSBEN"
  t+=$'\n'"kérdezz, és úgy fejezd be a kört. A sessionben feltett kérdéssel soha ne állj"
  t+=$'\n'"meg: arra itt nincs kitől választ kapnod."
  print -r -- "$t"
}

# A jelentes atemelese az agent munkakonyvtarabol a Desktop altal olvasott
# helyre. Idempotens: publikalas utan a forrast torli, igy nem publikal ujra.
# Atomi csere (tmp + mv), hogy a Desktop sose lasson felig kiirt fajlt.
bridge_publish_results() {
  [[ -r "$BRIDGE_SPAWNED" ]] || return 0
  local name cur spec c w rcwd f base fid dst claim now mt orph
  now=$(date -u +%s)
  # Arva atmeneti fajl: ha a folyamat a ket `mv` KOZOTT halt meg, a jelentes itt
  # ragad. Nem toroljuk (tartalom!), de jelezzuk, mert magatol semmi nem viszi el.
  for orph in "$RES_DIR"/.incoming.*(N); do
    blog "WARN árva jelentés-töredék a results-ban: ${orph:t} — nézd meg kézzel"
  done
  for name in ${(f)"$(jq -r 'keys[]' "$BRIDGE_SPAWNED" 2>/dev/null)"}; do
    [[ -n "$name" ]] || continue
    cur=$(jq -r --arg n "$name" '.[$n].request // empty' "$BRIDGE_SPAWNED" 2>/dev/null)
    spec=$(find_spec "$name" 2>/dev/null)
    if [[ -n "$spec" ]]; then
      c=$(read_spec_field "$spec" cwd)
      w=$(read_spec_field "$spec" worktree)
      rcwd=$(agent_runtime_cwd "$c" "$w" "$name")
    elif [[ "$name" == "${ROOT_AGENT_NAME:-mac-main}" ]]; then
      # A GYOKER agentnek NINCS specje: a start.sh inditja, nem a spawner. Eddig
      # ezert a jelentese SOSEM publikalodott — a hid ki tudta kezbesiteni neki a
      # folytatast, de a valasza nem jutott vissza a kuldohoz: a kor a VISSZAUTON
      # tort el, csendben. 2026-08-29, a T1 regresszios teszt talalta meg.
      # A gyoker a queue gyokerkonyvtaraban fut, worktree nelkul.
      rcwd="${CLAUDE_AGENT_ROOT:A}"
    else
      continue
    fi
    [[ -d "$rcwd" ]] || continue
    mkdir -p "$RES_DIR"
    # Egy korben AZ OSSZES varakozo jelentest atvesszuk, nem csak egyet.
    for f in "$rcwd"/.bridge-result*.md(N); do
      [[ -s "$f" ]] || continue                    # ures vagy epp most keletkezett
      # Ne vegyuk el IRAS KOZBEN: a frissen modositott fajl varjon egy kort.
      mt=$(stat -f %m "$f" 2>/dev/null) || continue
      (( now - mt >= BRIDGE_RESULT_SETTLE_SEC )) || continue

      base="${f:t}"
      fid="${base#.bridge-result-}"; fid="${fid%.md}"
      # A regi, fix nev (`.bridge-result.md`) a nyilvantartas AKTUALIS keresehez
      # tartozik — ez a visszafele kompatibilitas ara, es egyben a regi hiba
      # forrasa; az uj, keresenkenti nevnel a fajl maga hordozza az id-t.
      [[ "$base" == "$BRIDGE_RESULT_BASENAME" ]] && fid="$cur"
      if [[ ! "$fid" =~ '^[A-Za-z0-9._-]{1,48}$' ]]; then
        blog "WARN publikálatlan jelentés (nincs érvényes kérés-id): $f"
        continue
      fi

      # ⚠️ ELOSZOR ELVESSZUK (atomi mv), csak AZUTAN tesszuk a helyere. A regi
      # sorrend (cp -> mv -> rm) torolhetett egy KOZBEN irt uj jelentest.
      claim="$RES_DIR/.incoming.$$.$RANDOM"
      mv -f "$f" "$claim" 2>/dev/null || { blog "WARN nem sikerült átvenni: $f"; continue }
      dst="$RES_DIR/$fid.md"
      if mv -f "$claim" "$dst"; then
        blog "RESULT-PUBLISHED $fid <- $name"
        # A LEZARULT kort ALLAPOTBAN rogzitjuk, nem a fajl letezesebol
        # kovetkeztetjuk. A beragadas-figyelo eddig azt nezte, van-e
        # `results/<id>.md` — ha azt barki archivalta vagy kitakaritotta, egy
        # REGEN befejezett kor ujra "beragadtnak" latszott. 2026-08-30: a
        # mac-main-re jott ilyen hamis riasztas egy 4 oraval korabban lezarult
        # korre, mert a teszt-fajlokat kitakaritottuk.
        state_edit "$BRIDGE_SPAWNED" --arg k "$name" --arg r "$fid" \
          '.[$k].answered = $r'
      else
        rm -f "$claim"; blog "WARN eredmény-publikálás sikertelen: $fid"
      fi
    done
  done
}

# A statusz-uzenetbe a KESZ csatlakozasi parancs kerul, ne csak az agent neve.
# A tmux session neve `agent-<nev>` (a `mac-main` az egyetlen kivetel, az prefix
# nelkul fut) -- ezt fejben hozzatenni konnyu elrontani.
attach_hint() {                      # $1 = agent nev
  local n="$1"
  # Ures nev -> semmi. Kulonben csonka parancsot adnank ("tmux attach -t agent-"),
  # ami rosszabb, mint semmit nem mondani.
  [[ -n "$n" ]] || return 1
  if tmux has-session -t "agent-$n" 2>/dev/null; then print -r -- "tmux attach -t agent-$n"
  elif tmux has-session -t "$n" 2>/dev/null; then print -r -- "tmux attach -t $n"
  else print -r -- "tmux attach -t agent-$n"; fi
}

# LEZARAS: a meglevo close-tree-t hivja, majd kiveszi a nyilvantartasbol.
close_agent_request() {              # $1 = id, $2 = normalizált kérés JSON
  local name code ctx trm out spec cwd wt rt tdir tsid excl tdel_refused crc
  name=$(print -r -- "$2" | jq -r '.target')
  code=$(print -r -- "$2" | jq -r '.code')
  ctx=$(print -r -- "$2"  | jq -r '.context')
  trm=$(print -r -- "$2"  | jq -r '.transcript // "keep"')
  bridge_is_spawned "$name" || { print -u2 "időközben már nem a híd nyilvántartásában van: $name"; return 1 }

  # ⚠️ Az atirat celpontjat MOST kell feloldani: a lezaras utan a folyamat es a
  # worktree eltunik, es a futasideju cwd mar nem lenne visszakereheto.
  if [[ "$trm" == "delete" ]]; then
    spec=$(find_spec "$name")
    if [[ -n "$spec" ]]; then
      cwd=$(read_spec_field "$spec" cwd); wt=$(read_spec_field "$spec" worktree)
      rt=$(agent_runtime_cwd "$cwd" "$wt" "$name")
      tdir=$(transcript_dir "$rt")
      # ⚠️ A konyvtar CSAK akkor a sajatja, ha sajat worktree-ben fut. Kozos
      # cwd eseten (worktree nelkuli fork) ugyanaz a konyvtar a SZULO
      # atiratait is tartalmazza -- ott csak a sajat fajljat szabad torolni.
      excl=0
      [[ "$rt" == */.claude/worktrees/"$name" ]] && excl=1

      # A session-id feloldasa. A sorrend NEM kozombos: ez a fuggveny egyetlen
      # visszafordithatatlan lepese egy `rm -f`, es a rossz id egy MASIK session
      # (jellemzoen a szulo vagy a command center) atiratat torolne.
      #   1. a hid altal FUTAS KOZBEN rogzitett sajat id — ez a megbizhato forras;
      #   2. az elo sessionbol olvasott id, ha meg fut;
      #   3. a "cwd legfrissebb atirata" heurisztika — KIZAROLAG akkor, ha a cwd
      #      nem osztott. A sajat kodbazisunk mondja ki (_agent-lib.sh:270-278),
      #      hogy kozos cwd-nel ez HAMIS; a resume-utrol epp ezert szamuztuk.
      # Ha egyik sem ad biztosat es a cwd osztott, INKABB NEM TORLUNK.
      tsid=$(jq -r --arg n "$name" '.[$n].session_id // empty' "$BRIDGE_SPAWNED" 2>/dev/null)
      [[ -n "$tsid" ]] && ! transcript_exists "$tsid" && tsid=""
      [[ -z "$tsid" ]] && tsid=$(agent_session_id "$name" 2>/dev/null) || true
      if [[ -z "$tsid" ]]; then
        if (( excl == 1 )) || ! bridge_cwd_shared "$name" "$rt"; then
          tsid=$(latest_session_id "$rt" 2>/dev/null) || tsid=""
        else
          tsid=""; tdel_refused=1
          blog "TRANSCRIPT-DELETE-REFUSED $name (osztott cwd: $rt, nincs rögzített session id)"
        fi
      fi
    fi
  fi
  out=$("$(dirname "${(%):-%x}")/agent-close-tree.sh" "$name" "$code" "$ctx" 2>&1); crc=$?
  # A 3 NEM altalanos hiba: a lezaras megtortent, csak a merge futott
  # konfliktusra. Ezt ATENGEDJUK — kulonben a run_request dedikalt, beszedes
  # `failed` uzenete holt kod, es a nyilvantartas-takaritas (lentebb) sem fut
  # le, tehat a mar lezart agentekre a GC orokke "MEGTARTVA"-t naplozna.
  if (( crc != 0 && crc != 3 )); then print -r -- "$out"; return 1; fi
  # A kaszkad a leszarmazottakat is lezarta -> azok is kikerulnek.
  local n
  for n in ${(f)"$(jq -r 'keys[]' "$BRIDGE_SPAWNED" 2>/dev/null)"}; do
    [[ "$n" == "$name" || "$n" == "$name-"* ]] && bridge_unregister_spawned "$n"
  done
  # --- atirat torlese, a fenti feloldas alapjan ---
  if [[ "$trm" == "delete" ]]; then
    # ⚠️ Meg kell varni, hogy a folyamat TENYLEG kilepjen. A tmux-kill utan a
    # haldoklo claude meg kiirja a konyvelo rekordjait (ai-title, bridge-session,
    # last-prompt...), es ha kozben torlunk, ujra letrehozza a fajlt egy 800
    # bajtos vazkent -- merve 2026-08-07.
    local w=0
    while tmux has-session -t "agent-$name" 2>/dev/null && (( w < 10 )); do sleep 1; w=$((w+1)); done
    sleep 3
    if (( ${excl:-0} == 1 )) && [[ -n "$tdir" && "$tdir" == *"/projects/"*worktrees* ]]; then
      rm -rf "$tdir" && print "átirat törölve (saját worktree-könyvtár): ${tdir:t}"
      blog "TRANSCRIPT-DELETED dir $tdir ($name)"
    elif [[ -n "$tdir" && -n "$tsid" && -f "$tdir/$tsid.jsonl" ]]; then
      rm -f "$tdir/$tsid.jsonl" && print "átirat törölve (közös könyvtár, csak a saját fájl): $tsid"
      blog "TRANSCRIPT-DELETED file $tdir/$tsid.jsonl ($name)"
    elif (( ${tdel_refused:-0} == 1 )); then
      print "átiratot NEM töröltem: a cwd osztott ($rt), és nincs rögzített session id — találgatva a szülő átiratát törölhetném"
    else
      print "átiratot nem találtam, nem törlődött semmi"
    fi
    # Masodik kor: ha a kilepo folyamat idokozben ujra letrehozta a vazat,
    # takaritsuk el azt is.
    if [[ -n "$tdir" && -n "$tsid" && -f "$tdir/$tsid.jsonl" ]]; then
      sleep 2
      rm -f "$tdir/$tsid.jsonl" && blog "TRANSCRIPT-DELETED (2. kör, kilépéskori váz) $tdir/$tsid.jsonl"
    fi
    [[ -n "$tdir" && -d "$tdir" ]] && rmdir "$tdir" 2>/dev/null   # ha teljesen kiurult
  fi

  print -r -- "$out"
  # A konfliktus-kodot TOVABB kell adni: a fuggveny addig a `print` 0-javal tert
  # vissza, ezert a run_request KONFLIKTUS-aga sosem futott le.
  return ${crc:-0}
}

# A kerés vegrehajtasa: uj fork, folytatas vagy lezaras, a mode szerint.
execute_request() {                  # $1 = id, $2 = normalizált kérés JSON
  local mode; mode=$(print -r -- "$2" | jq -r '.mode // "fork"')
  case "$mode" in
    continue)  continue_agent "$1" "$2" ;;
    close)     close_agent_request "$1" "$2" ;;
    reconnect) reconnect_agent "$1" "$2" ;;
    *)        spawn_from_request "$1" "$2" ;;
  esac
}

# Vegrehajtas + statuszkiras EGY helyen. Harom hivo van (relay audit-ag, relay
# auto-inditas felhatalmazasbol, poller jovahagyas); a `nm` kinyereset haromszor
# leirva elobb-utobb elcsuszna. A hivo a kimenetet a BRIDGE_LAST_OUT-bol, a
# letrejott/megszolitott agent nevet a BRIDGE_LAST_NAME-bol veszi (utobbi kell a
# fork utani felhatalmazashoz is, mert a nev csak vegrehajtas UTAN derul ki).
typeset -g BRIDGE_LAST_OUT="" BRIDGE_LAST_NAME=""
run_request() {                      # $1 = id, $2 = normalizált kérés JSON
  local id="$1" req="$2" out rc
  out=$(execute_request "$id" "$req" 2>&1); rc=$?
  BRIDGE_LAST_OUT="$out"
  BRIDGE_LAST_NAME=$(print -r -- "$out" \
    | sed -n 's/^fork kész: //p;s/^folytatás elküldve: //p;s/^újracsatlakoztatva: //p' \
    | head -1 | sed 's/  *|.*//')
  # A close-tree 3-mal lep ki, ha a lezaras megtortent, de a merge konfliktusra
  # futott. Ez NEM `spawned`: a Desktop kulonben ugy tudna, hogy a munka beolvadt.
  if (( rc == 3 )) && [[ "$out" == *KONFLIKTUS* ]]; then
    set_status "$id" failed "merge-konfliktus: a session lezárva, az ág megmaradt — $(print -r -- "$out" | grep -m1 'KONFLIKTUS')"
    return $rc
  fi
  if (( rc == 0 )); then
    # ⚠️ A lezaras kimenete tobbsoros: elobb a merge-lepesek (behuzva), aztan az
    # agtorles, es csak a vegen az osszegzes. A `head -1` ezert a behuzott
    # "  merge: ..." sort vitte a statuszba, amibol a kuldo nem latta, MI tortent
    # az agenttel. Az osszegzo sort keressuk elobb.
    local _msg
    _msg=$(print -r -- "$out" | grep -m1 '^tree closed:') \
      || _msg=$(print -r -- "$out" | grep -m1 '^closed:') \
      || _msg=$(print -r -- "$out" | head -1)
    set_status "$id" spawned "${_msg}$([[ -n "$BRIDGE_LAST_NAME" ]] && print -n "  |  $(attach_hint "$BRIDGE_LAST_NAME")")"
  else
    set_status "$id" failed "$(print -r -- "$out" | tail -1)"
  fi
  return $rc
}

# FOLYTATAS: uzenet egy mar letezo agentnek, ugyanabban a sessionben.
# Ha fut -> bekuldjuk a tmux-ba. Ha nem fut -> eloszor resume-oljuk a sajat
# sessionjet (a done/ spec cwd-jebol es a legfrissebb atiratbol), azutan kuldunk.
# Egy agent sajat sessionjenek ujrainditasa --resume-mal. Ket helyrol hivjuk:
# a folytatas (ha nem fut) es a reconnect (ha fut, de leszakadt a bridge-e).
# ⚠️ A hid-agentek NINCSENEK a live/ nyilvantartasban (szandekosan: a watchdog
# ne tamassza fel oket). Ezert a sajat session-id-juket ITT rogzitjuk, amig
# futnak — kulonben a feltamasztasnak csak a "cwd legfrissebb atirata"
# hevisztika maradna, amirol a sajat kodbazisunk mondja ki, hogy kozos cwd-nel
# HAMIS (lasd _agent-lib.sh). Merve 2026-08-26 (masodik audit).
bridge_record_session() {            # $1 = agent nev
  local sid old
  sid=$(agent_session_id "$1" 2>/dev/null) || return 1
  [[ -n "$sid" ]] || return 1
  old=$(jq -r --arg n "$1" '.[$n].session_id // empty' "$BRIDGE_SPAWNED" 2>/dev/null)
  [[ "$sid" == "$old" ]] && return 0
  state_edit "$BRIDGE_SPAWNED" --arg n "$1" --arg s "$sid" '.[$n].session_id = $s'
}

# Minden futo, nyilvantartott hid-agent sajat azonositojanak rogzitese.
bridge_record_sessions() {
  [[ -r "$BRIDGE_SPAWNED" ]] || return 0
  local n
  for n in ${(f)"$(jq -r 'keys[]' "$BRIDGE_SPAWNED" 2>/dev/null)"}; do
    [[ -n "$n" ]] || continue
    tmux has-session -t "agent-$n" 2>/dev/null || continue
    bridge_record_session "$n"
  done
}

# Osztozik-e MAS agent ugyanazon a futasideju cwd-n? A live/ nyilvantartason
# tul a hid sajat listajat ES a command centert is nezi (az utobbi cwd-je a
# ClaudeProjects gyoker, amit a spawner ures cwd eseten a gyerekeknek is ad).
bridge_cwd_shared() {                # $1 = nev, $2 = runtime cwd
  local name="$1" rt="$2" other spec c w
  [[ "$rt" == "${CLAUDE_AGENT_ROOT:A}" ]] && return 0
  typeset -f registry_cwd_shared >/dev/null && registry_cwd_shared "$name" "$rt" && return 0
  [[ -r "$BRIDGE_SPAWNED" ]] || return 1
  for other in ${(f)"$(jq -r 'keys[]' "$BRIDGE_SPAWNED" 2>/dev/null)"}; do
    [[ -z "$other" || "$other" == "$name" ]] && continue
    spec=$(find_spec "$other" 2>/dev/null); [[ -n "$spec" ]] || continue
    c=$(read_spec_field "$spec" cwd); w=$(read_spec_field "$spec" worktree)
    [[ "$(agent_runtime_cwd "$c" "$w" "$other")" == "$rt" ]] && return 0
  done
  return 1
}

resume_agent_session() {             # $1 = agent nev -> 0, ha fut a vegen
  local name="$1" sess="agent-$1" spec cwd wt rt sid model effort CLAUDE_BIN cmd
  spec=$(find_spec "$name") || { print -u2 "nincs spec-je: $name"; return 1 }
  [[ -n "$spec" ]] || { print -u2 "nincs spec-je: $name"; return 1 }
  cwd=$(read_spec_field "$spec" cwd)
  wt=$(read_spec_field "$spec" worktree)
  model=$(read_spec_field "$spec" model);   [[ -n "$model" ]]  || model=opus
  effort=$(read_spec_field "$spec" effort); [[ -n "$effort" ]] || effort=high
  rt=$(agent_runtime_cwd "$cwd" "$wt" "$name")
  # 1. a SAJAT, rogzitett azonosito (globalisan keresve — a worktree-s session
  #    atirata nem a worktree-bol szarmaztatott konyvtarban van);
  # 2. kulonben csak akkor talalgatunk, ha a cwd NEM osztott.
  sid=$(jq -r --arg n "$name" '.[$n].session_id // empty' "$BRIDGE_SPAWNED" 2>/dev/null)
  if [[ -z "$sid" ]] || ! transcript_exists "$sid"; then
    if bridge_cwd_shared "$name" "$rt"; then
      print -u2 "nincs rögzített session id, és a cwd osztott ($rt) — nem találgatok: $name"
      return 1
    fi
    sid=$(latest_session_id "$rt" 2>/dev/null) || { print -u2 "nincs visszaállítható átirat: $name"; return 1 }
  fi

  CLAUDE_BIN=$(command -v claude) || { print -u2 "nincs claude"; return 1 }
  # ⚠️ Ez az OTODIK inditasi pont. A 2026-08-24-i locale-fix a masik negyet
  # javitotta, ezt kihagyta — a hidon feltamasztott session ezert C-locale-ben
  # futott tovabb, es az ekezetek ott ujra romlottak.
  cmd="cd ${(qq)rt} && export LANG=${(qq)${CLAUDE_AGENT_LANG:-en_US.UTF-8}}"
  cmd+=" && export CLAUDE_AGENT_NAME=${(qq)name} && ${(qq)CLAUDE_BIN}"
  cmd+=" --resume ${(qq)sid} --remote-control ${(qq)name} --permission-mode auto"
  cmd+=" --model ${(qq)model} --effort ${(qq)effort} --brief --chrome"
  tmux new-session -d -s "$sess" "$cmd" || { print -u2 "tmux new-session sikertelen"; return 1 }
  sleep 6
  tmux has-session -t "$sess" 2>/dev/null || { print -u2 "a visszaállított session azonnal kilépett"; return 1 }
  # Teljes atvetel: az ujraindulas legyen lathatatlan.
  CLAUDE_AGENT_RESUME_MODE=full auto_dismiss_modals "$sess"
  print -r -- "$sid"
}

# RECONNECT: a folyamat el, de a Remote Control bridge-e leszakadt -- a telefonon
# eltunik, kozben tmuxbol elerheto marad. Eszlelni nem tudjuk (lasd TODO), de a
# felhasznalo latja; ez a muvelet hozza vissza: leallitjuk a sessiont, es
# --resume-mal ujrainditjuk, amivel UJ bridge regisztralodik. A beszelgetes nem
# vesz el, mert ugyanaz a session folytatodik.
reconnect_agent() {                  # $1 = id, $2 = normalizált kérés JSON
  local name sess sid
  name=$(print -r -- "$2" | jq -r '.target'); sess="agent-$name"
  source "$(dirname "${(%):-%x}")/_agent-lib.sh"
  bridge_is_spawned "$name" || { print -u2 "nem a híd indította: $name"; return 1 }

  if tmux has-session -t "$sess" 2>/dev/null; then
    tmux kill-session -t "$sess" 2>/dev/null
    # Megvarjuk a tenyleges kilepest, kulonben a nev meg foglalt.
    local w=0
    while tmux has-session -t "$sess" 2>/dev/null && (( w < 10 )); do sleep 1; w=$((w+1)); done
    sleep 2
  fi
  sid=$(resume_agent_session "$name") || return 1
  blog "RECONNECTED $name (session: $sid)"
  # A `run_request` a kimenet ELSO soraahoz maga fuzi az attach-tippet, ezert itt
  # NEM ismeteljuk — 2026-08-29-ig ketszer jelent meg a Telegram-uzenetben.
  print "újracsatlakoztatva: $name"
}

continue_agent() {                   # $1 = id, $2 = normalizált kérés JSON
  local id="$1" req="$2" name task sess spec cwd wt rt sid model effort
  name=$(print -r -- "$req" | jq -r '.target')
  task=$(print -r -- "$req" | jq -r '.task')

  source "$(dirname "${(%):-%x}")/_agent-lib.sh"

  if ! sess=$(agent_tmux_session "$name"); then
    # A GYOKER-agentet innen SOHA nem tamasztjuk fel: nincs specje (a start.sh
    # inditja), es egy masodik, azonos nevu `--remote-control` peldany elvinne a
    # futo session bridge-et (TODO.md, 2026-07-27). Azt a watchdog hozza vissza.
    if [[ "$name" == "${ROOT_AGENT_NAME:-mac-main}" ]]; then
      print -u2 "a parancsközpont ($name) nem fut — azt a watchdog indítja újra, a híd nem támasztja fel"
      return 1
    fi
    # Nem fut -> feltamasztjuk a sajat sessionjevel (kozos fuggveny).
    resume_agent_session "$name" >/dev/null || return 1
    blog "RESUMED $name (folytatáshoz)"
    sess=$(agent_tmux_session "$name") || { print -u2 "a visszaállított session nem található: $name"; return 1 }
  fi

  task=$(augment_task "$id" "$task")

  # ⚠️ 2026-08-31-i ELES HIBA: ez az ag NYERS, EGYBEN kuldott `send-keys`-t
  # hasznalt, ellenorzes nelkul — ugyanaz a hibaosztaly, amit a fork mar reggel
  # megkapott. A ~1KB feletti prompt ELEJE elveszett, a vege pedig elkuldetlenul
  # ott maradt a beviteli sorban ("Fejezd be a kört." — merve a CLI-agentnel),
  # a hid pedig `folytatás elküldve`-t irt. A cimzett soha nem kapta meg a
  # feladatot, es 39 percig tetlen maradt.
  # Mostantol a KOZOS, darabolt + atiratbol visszaigazolt kuldes megy.
  local ccwd
  ccwd=$(tmux display-message -p -t "$sess" '#{pane_current_path}' 2>/dev/null)
  [[ -n "$ccwd" ]] || ccwd=$(agent_session_cwd "$name" 2>/dev/null)
  [[ -n "$ccwd" ]] || { print -u2 "nem oldható fel a cwd a folytatáshoz: $name"; return 1 }
  if ! agent_send_prompt "$name" "$task" "$ccwd"; then
    print -u2 "a folytatás NEM ért célba (kétszer sem): $name — a feladat nem indult el"
    return 1
  fi

  # ⚠️ A nyilvantartast a FOLYTATAS is frissiti. Enelkul az agent -> keres-id
  # leikepezes a legelso keresnel ragadt, es a `bridge_publish_results` MINDEN
  # kesobbi jelentest a REGI id ala tett. Merve 2026-08-12: a deploy-b
  # jelentese az import-a-20260811.md-be kerult, mert a dimport-a agent
  # 07:07 ota az import-a-hoz volt kotve — a kuldo hiaba varta a sajat
  # id-je alatt. A legutobbi keres nyer: az agent most azon dolgozik.
  bridge_register_spawned "$name" "$id"
  print "folytatás elküldve: $name"
}

# A tenylegesen ervenyesulo jogosultsagi mod. Kulon fuggveny, hogy a teszt a
# VALODI dontest hivhassa, ne egy masolatot.
#   $1 = a keres altal kert mod
#   $2 = hogyan lett jovahagyva: "button" | "grant" | "audit" | ures
# A `bypassPermissions` az egyetlen emelt mod: csak kifejezett gombnyomasra.
# Minden mas ertek (es a HIANYZO ertek is) a szigorubb agra visz.
# A GOMBOS uzenet ele kerulo figyelmeztetes. A teljes osszefoglalo CSATOLMANYKENT
# megy (4096 bajtos uzenet-korlat), a gombok viszont a rovid uzeneten vannak —
# egy biztonsagi figyelmeztetes, amit a csatolmany megnyitasa nelkul nem latsz,
# nem tolti be a szerepet. 2026-08-29, a T3 regresszios teszt talalta meg:
# a "KORLATLAN JOGOSULTSAGOT KER" blokk elkeszult, de a felhasznalo nem latta.
#   $1 = normalizalt keres JSON -> a figyelmeztetes (vagy ures)
bridge_button_warning() {
  local req="$1" pm wt mode
  local -a w
  pm=$(print -r -- "$req"   | jq -r '.permission_mode // "auto"' 2>/dev/null)
  wt=$(print -r -- "$req"   | jq -r '.worktree // false'         2>/dev/null)
  mode=$(print -r -- "$req" | jq -r '.mode // "fork"'            2>/dev/null)
  if [[ "$pm" == "bypassPermissions" ]]; then
    w+=("⚠️ <b>KORLÁTLAN JOGOSULTSÁGOT KÉR</b> (bypassPermissions)")
    w+=("az agent semmit nem kérdez vissza, a gépeden bármit megtehet")
  fi
  if [[ "$mode" == "fork" && "$wt" != "true" ]]; then
    w+=("⚠️ <b>NINCS SAJÁT ÁG</b> — a szülő munkakönyvtárában dolgozik")
  fi
  # A LEZARAS visszafordithatatlan agai. 2026-08-29: a `transcript: delete`
  # figyelmeztetese csak a CSATOLMANYBAN volt — a felhasznalo a gomb mellett nem
  # latta, es ugy nyomta meg, hogy veglegesen torolt egy atiratot. Ez sulyosabb,
  # mint a bypassPermissions esete: azt legalabb a szeme elott futo agent teszi,
  # ezt viszont nem lehet visszacsinalni.
  if [[ "$mode" == "close" ]]; then
    local code tr
    code=$(print -r -- "$req" | jq -r '.code // "nowt"'       2>/dev/null)
    tr=$(print -r -- "$req"   | jq -r '.transcript // "keep"' 2>/dev/null)
    [[ "$tr" == "delete" ]] && \
      w+=("⚠️ <b>VÉGLEG TÖRLI AZ ÁTIRATOT</b> — visszafordíthatatlan")
    [[ "$code" == "drop" ]] && \
      w+=("⚠️ <b>ELDOBJA A MUNKÁT</b> — a worktree és az ág törlődik")
  fi
  # ⚠️ ZARO ujsor NELKUL: a hivo `$( )`-ben veszi at, az pedig levagja a zaro
  # ujsorokat — a hataroloval egybefolyt volna a gomb-szoveg. A hivo teszi be.
  (( ${#w} )) && print -rn -- "${(F)w}"
  return 0
}

bridge_effective_perm() {
  if [[ "$1" == "bypassPermissions" && "${2:-}" != "button" ]]; then
    print -r -- auto
  else
    print -r -- "$1"
  fi
}

spawn_from_request() {               # $1 = id, $2 = normalizált kérés JSON
  local id="$1" req="$2"
  local parent task cwd model effort worktree psid suffix perm resume
  parent=$(print -r -- "$req" | jq -r '.target')
  task=$(print -r -- "$req"   | jq -r '.task')
  cwd=$(print -r -- "$req"    | jq -r '.cwd')
  model=$(print -r -- "$req"  | jq -r '.model')
  effort=$(print -r -- "$req" | jq -r '.effort')
  worktree=$(print -r -- "$req" | jq -r 'if .worktree then "1" else "" end')
  perm=$(print -r -- "$req"   | jq -r '.permission_mode // "auto"')
  resume=$(print -r -- "$req" | jq -r '.resume // "none"')

  # A `bypassPermissions` a legtagabb mod: az agent semmit nem kerdez vissza.
  # Ezt CSAK akkor engedjuk, ha erre a KONKRET keresre gombot nyomtal. A masik
  # ket vegrehajtasi ag (idokorlatos felhatalmazas, `gate:"audit"`) felugyelet
  # nelkuli. A valtozo HIANYA a szigorubb ag: ha egy jovobeli hivo elfelejti
  # beallitani, akkor NEM emel jogosultsagot.
  local eff_perm; eff_perm=$(bridge_effective_perm "$perm" "${BRIDGE_APPROVAL:-}")
  if [[ "$eff_perm" != "$perm" ]]; then
    blog "PERM-DOWNGRADE $id $perm -> $eff_perm (jóváhagyás: ${BRIDGE_APPROVAL:-ismeretlen})"
  fi
  perm="$eff_perm"

  source "$(dirname "${(%):-%x}")/_agent-lib.sh"
  psid=$(agent_session_id "$parent" 2>/dev/null) || {
    print -u2 "a szülő nem fut vagy nincs állapotfájlja: $parent"; return 1
  }

  task=$(augment_task "$id" "$task")

  # A nev teljes hossza max 64 (a spawner es a hid validatora is ezt varja), es
  # `<szulo>-<suffix>` alaku. A suffix hatarat ezert a SZULO hosszabol szamoljuk,
  # nem fix 24-bol: az utobbi feleslegesen vagta le a keres-id vegen levo
  # DATUMOT (`rgC1-merge-elokeszites-20260829` -> `drgC1-merge-elokeszites-2`),
  # amitol ket kulonbozo napi keres ugyanarra a nevre kepzodott volna.
  local _base _max
  _base=$(print -r -- "$id" | tr -c 'a-zA-Z0-9' '-' | sed 's/-\+/-/g; s/-$//')
  _max=$(( 64 - ${#parent} - 2 ))          # a "-" es a "d" elotag
  (( _max < 8 )) && _max=8
  suffix="d${_base[1,$_max]}"
  if (( ${#_base} > _max )); then
    blog "NEV-CSONKOLVA $id: a suffix ${#_base} -> $_max karakter (szülő: $parent)"
  fi
  # --no-ask: a hidon inditott agent nem kerdezhet vissza (senki nem olvassa a
  # sessionjet). Kezi /fork-nal ez nem all, ezert csak innen adjuk at.
  local -a args; args=("$suffix" --model "$model" --effort "$effort" --permission-mode "$perm" --no-ask)
  [[ "$resume" == "summary" ]] && args+=(--summary)
  [[ "$resume" == "none"    ]] && args+=(--fresh)
  [[ -n "$worktree" ]] && args+=(--worktree)
  [[ -n "$cwd" ]] && args+=(--cwd "$cwd")
  args+=("$task")

  local out rc spawned
  out=$(CLAUDE_AGENT_NAME="$parent" CLAUDE_CODE_SESSION_ID="$psid" \
        "$(dirname "${(%):-%x}")/fork-agent" "${args[@]}" 2>&1); rc=$?
  print -r -- "$out"
  (( rc == 0 )) || return $rc
  # A tenyleges nevet a fork-agent mondja meg (nevutkozeskor -2..-99 suffix),
  # ezt kell nyilvantartani, kulonben a lezaras nem talalna meg.
  spawned=$(print -r -- "$out" | sed -n 's/^fork kész: //p' | head -1)
  [[ -n "$spawned" ]] && bridge_register_spawned "$spawned" "$id"
  return 0
}

# --- összefoglaló a Telegram-csatolmányhoz ---------------------------------
# NYERS SZÖVEG, nem markdown: a Telegram a csatolmányt sima szövegként
# jeleníti meg, ott a markdown-táblázatból csak a `|` és `---` jelek
# maradnának.
#
# ⚠️ Nincs oszlop-igazítás. A launchd környezetben nincs LANG, ott a printf
# szélessége BÁJTOKAT számol, nem karaktereket — az ékezetes címkék
# elcsúsznának. Telefon-szélességhez rövid sorok, cimke külön sorban.
summary_text() {                     # $1 = id, $2 = normalizált kérés JSON
  local id="$1" req="$2" f
  f() { print -r -- "$req" | jq -r "$1" }

  local mode; mode=$(f '.mode // "fork"')

  if [[ "$mode" == "reconnect" ]]; then
    print -r -- "ÚJRACSATLAKOZTATÁS"
    print -r -- "azonosító: $id"
    print -r -- "════════════════════════════"
    print -r --
    print -r -- "CÉLPONT"
    print -r -- "  $(f .target)"
    print -r --
    print -r -- "MI TÖRTÉNIK"
    print -r -- "  a session leáll, majd --resume-mal újraindul,"
    print -r -- "  amivel ÚJ Remote Control kapcsolat regisztrálódik"
    print -r -- "  (a telefonon újra meg fog jelenni)"
    print -r --
    print -r -- "  a beszélgetés NEM vész el — ugyanaz a session folytatódik,"
    print -r -- "  teljes átvétellel"
    print -r --
    print -r -- "════════════════════════════"
    print -r -- "Akkor van rá szükség, ha az agent eltűnt a telefonról, de a"
    print -r -- "gépen még fut. Ez kívülről csak a telefonon látszik."
    return 0
  elif [[ "$mode" == "close" ]]; then
    local nm cd cx
    nm=$(f .target); cd=$(f .code); cx=$(f .context)
    print -r -- "AGENT LEZÁRÁSA"
    print -r -- "azonosító: $id"
    print -r -- "════════════════════════════"
    print -r --
    print -r -- "CÉLPONT"
    print -r -- "  $nm"
    print -r --
    print -r -- "MI TÖRTÉNIK"
    case "$cd" in
      merge) print -r -- "  kód ............ MERGE a szülő ágába, utána a worktree és az ág törlődik" ;;
      drop)  print -r -- "  kód ............ DROP — a worktree és az ág TÖRLŐDIK, a munka elvész" ;;
      nowt)  print -r -- "  kód ............ csak a session áll le, a worktree marad" ;;
    esac
    # Egyertelmuen: KINEK a beszelgeteserol van szo es HOVA kerul.
    if [[ "$cx" == "merge" ]]; then
      print -r -- "  beszélgetés .... a lezárt agenté BELEFŰZŐDIK a szülője átiratába"
      print -r -- "                   (új, összefűzött fájl készül; egyik eredeti sem változik)"
    else
      print -r -- "  beszélgetés .... a lezárt agenté a helyén marad, nem fűződik sehova"
    fi
    if [[ "$(f '.transcript // "keep"')" == "delete" ]]; then
      print -r --
      print -r -- "  ⚠️  ÁTIRAT TÖRLÉSE KÉRVE — VISSZAFORDÍTHATATLAN"
      print -r -- "      a lezárt agent .jsonl átirata VÉGLEG törlődik a lemezről"
      print -r -- "      (a szülőé és a többi agenté nem)"
    else
      print -r -- "  átirat ......... megmarad a lemezen"
    fi
    print -r --
    print -r -- "ÉRINTETT AGENTEK (a lezárás kaszkádol)"
    if typeset -f list_descendants >/dev/null; then
      local d found=""
      for d in ${(f)"$(list_descendants "$nm" 2>/dev/null)"}; do
        [[ -n "$d" ]] || continue
        print -r -- "  • $d"; found=1
      done
      [[ -n "$found" ]] || print -r -- "  • $nm  (nem fut, csak a nyoma takarítódik)"
    else
      print -r -- "  • $nm és minden leszármazottja"
    fi
    print -r --
    print -r -- "════════════════════════════"
    if [[ "$(f '.transcript // "keep"')" == "delete" ]]; then
      print -r -- "Az átirat törlése kivétel: alapból soha nem törlünk átiratot."
    else
      print -r -- "Az átiratok nem törlődnek."
    fi
    return 0                         # lezárásnál nincs feladat -> nincs közös lábléc
  elif [[ "$mode" == "continue" ]]; then
    print -r -- "FOLYTATÁS — MEGLÉVŐ AGENTNEK"
    print -r -- "azonosító: $id"
    print -r -- "════════════════════════════"
    print -r --
    print -r -- "CÍMZETT AGENT"
    print -r -- "  $(f .target)"
    print -r -- "  (ugyanabba a beszélgetésbe megy, nem indul új)"
    print -r -- "  ha nem fut, előbb visszaáll a saját sessionje"
  else
    print -r -- "AGENT-INDÍTÁSI KÉRÉS — ÚJ AGENT"
    print -r -- "azonosító: $id"
    print -r -- "════════════════════════════"
    print -r --
    print -r -- "SZÜLŐ"
    print -r -- "  $(f .target)"
    print -r -- "  (a gyerek ennek a beszélgetését örökli)"
    print -r --
    print -r -- "MUNKAKÖNYVTÁR"
    print -r -- "  $(f 'if .cwd == "" then "a szülőé" else .cwd end')"
    print -r --
    print -r -- "BEÁLLÍTÁSOK"
    print -r -- "  worktree ....... $(f 'if .worktree then "igen, saját ág" else "NEM" end')"
    print -r -- "  model .......... $(f .model)"
    print -r -- "  effort ......... $(f .effort)"
    print -r -- "  kontextus ...... $(f 'if (.resume // "none") == "none" then "FRISS — nem örököl beszélgetést" elif (.resume // "none") == "summary" then "tömörített (gyors indulás)" else "a szülő teljes beszélgetése" end')"
    print -r -- "  jogosultság .... $(f '.permission_mode // "auto"')"
    if [[ "$(f '.permission_mode // "auto"')" == "bypassPermissions" ]]; then
      print -r --
      print -r -- "  ⚠️  KORLÁTLAN JOGOSULTSÁGOT KÉR (bypassPermissions)"
      print -r -- "      az agent semmit nem kérdez vissza, a gépeden bármit megtehet"
      print -r -- "      csak erre a gombnyomásra érvényes: felhatalmazás alatt vagy"
      print -r -- "      audit módban automatikusan auto-ra esik vissza"
    fi
    if [[ "$(f '.worktree')" != "true" ]]; then
      print -r --
      print -r -- "  ⚠️  NINCS SAJÁT ÁG"
      print -r -- "      a SZÜLŐ munkakönyvtárában fut — amit ír, közvetlenül oda kerül,"
      print -r -- "      nincs ág, amit külön átnézhetnél, mergelhetnél vagy eldobhatnál."
      local wn; wn=$(f '.worktree_note // ""')
      [[ -n "$wn" ]] && print -r -- "      ($wn)"
    fi
  fi
  print -r --
  print -r -- "AMIT CSINÁLNI FOG"
  print -r -- "────────────────────────────"
  print -r -- "$(f .task)"
  print -r --
  print -r -- "════════════════════════════"
  print -r -- "Elutasítás esetén semmi nem indul."
}
