#!/bin/zsh
# smoke.sh — a híd izolálható részeinek füst-tesztje.
#
# Miért ez a kör és nem több: a spawner és a close-tree valódi tmux-sessiont,
# git-repót és launchd-t érint — azt élesben teszteljük, eldobható agenteken.
# Ami VISZONT tiszta függvény (állapot-fájl, felhatalmazások, státusz-gép,
# validátorok), az itt fut le, egy eldobható könyvtárban, a rendszer
# állapotának érintése nélkül.
#
# Használat:  zsh tests/smoke.sh        (0 = minden zöld)

emulate -L zsh
set -u

HERE="${0:A:h}"
ROOT="${HERE:h}"

# --- izolált világ: SEMMI nem mutat az éles ~/.claude alá ---------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/spawner-smoke.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_AGENT_ROOT="$TMP/projects"
export CLAUDE_AGENT_QUEUE="$TMP/queue"
export BRIDGE_DIR="$TMP/bridge"
export BRIDGE_STATE="$TMP/queue/bridge-state.json"
export BRIDGE_CONFIG="$TMP/queue/bridge-allow.json"
export BRIDGE_LOG="$TMP/queue/bridge.log"
export BRIDGE_SPAWNED="$TMP/queue/bridge-spawned.json"
mkdir -p "$CLAUDE_AGENT_QUEUE" "$CLAUDE_AGENT_ROOT" "$BRIDGE_DIR"/{requests,results,archive}
print '{"allow":[],"gate":"telegram"}' > "$BRIDGE_CONFIG"

typeset -i PASS=0 FAIL=0
ok()   { PASS+=1; printf '  \033[32m✓\033[0m %s\n' "$1" }
bad()  { FAIL+=1; printf '  \033[31m✗\033[0m %s\n' "$1"; [[ $# -gt 1 ]] && printf '      %s\n' "$2" }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "kapott: ${2:-<üres>}   várt: ${3:-<üres>}" }
yes_() { if "${@:2}"; then ok "$1"; else bad "$1" "a feltétel hamis"; fi }
no_()  { if "${@:2}"; then bad "$1" "a feltétel igaz, pedig hamisnak kéne"; else ok "$1"; fi }

source "$ROOT/bin/_bridge-lib.sh" || { print -u2 "a lib nem töltődött be"; exit 2 }
source "$ROOT/bin/_agent-lib.sh"  || { print -u2 "az agent-lib nem töltődött be"; exit 2 }

print "\n\033[1mfelhatalmazások\033[0m"
bridge_grant_set agent-a 3600 req-a >/dev/null
yes_ "beállítás után él"                bridge_grant_active agent-a
no_  "ismeretlen agentre nem él"        bridge_grant_active agent-b
is   "a lejárat a jövőben van"          "$(( $(bridge_grant_until agent-a) > $(date -u +%s) ))" 1

# Lejárt bejegyzés: a `set` a MOSTANIHOZ ad, ezért negatívval a múltba tesszük.
bridge_grant_set agent-exp -60 req-exp >/dev/null
no_  "a lejárt felhatalmazás nem él"    bridge_grant_active agent-exp
bridge_grant_prune
is   "a prune kiszedte a lejártat"      "$(jq -r '(.grants // {}) | has("agent-exp")' "$BRIDGE_STATE")" "false"
is   "az élőt NEM szedte ki"            "$(jq -r '(.grants // {}) | has("agent-a")'   "$BRIDGE_STATE")" "true"

bridge_grant_set agent-c 3600 req-c >/dev/null
is   "visszavonás kérés-id alapján"     "$(bridge_grant_revoke_by_req req-a)" "agent-a"
no_  "a visszavont már nem él"          bridge_grant_active agent-a
yes_ "a MÁSIK érintetlen maradt"        bridge_grant_active agent-c

print "\n\033[1mállapot-fájl\033[0m"
# A grants-írás nem tapossa el a hid tobbi allapotat (ez egy valodi regresszio volt).
state_edit "$BRIDGE_STATE" '.updates_offset = 4242'
bridge_grant_set agent-d 3600 req-d >/dev/null
is   "az updates_offset túléli a grant-írást" "$(jq -r '.updates_offset' "$BRIDGE_STATE")" "4242"
# ⚠️ A `>/dev/null` ide NEM johet: az a teljes `yes_` hivast iranyitana at, tehat
# a ✓/✗ sora — es egy bukas jelzese — is lathatatlan lenne.
is   "az állapot érvényes JSON maradt" "$(jq -e . "$BRIDGE_STATE" >/dev/null 2>&1 && print ok)" "ok"

print "\n\033[1mstátusz-gép\033[0m"
is   "hiányzó kérés = new"              "$(req_status nincs-ilyen)" "new"
set_status vizsga pending "várakozik"
is   "beállítás után pending"           "$(req_status vizsga)" "pending"
print 'ez nem json' > "$BRIDGE_DIR/requests/romlott.status"
is   "olvashatatlan státusz = corrupt"  "$(req_status romlott)" "corrupt"

print "\n\033[1membernek szánt formázás\033[0m"
# ⚠️ ELTELT idot formaz ("egy oraja"), nem idotartamot — a beragadas-riasztas
# szovegehez keszult. A ⏱ gombok ablakat a bridge_grant_human irja ki.
is   "30 perc"                          "$(bridge_dur_human 30)"   "30 perce"
is   "60 perc"                          "$(bridge_dur_human 60)"   "egy órája"
is   "180 perc"                         "$(bridge_dur_human 180)"  "3 órája"
is   "1440 perc"                        "$(bridge_dur_human 1440)" "egy napja"
is   "4320 perc"                        "$(bridge_dur_human 4320)" "3 napja"
is   "a lejárat-formázó nem üresen tér vissza" "$([[ -n "$(bridge_grant_human $(date -u +%s))" ]] && print ok)" "ok"

print "\n\033[1mvalidátorok (a spawner fehérlistái)\033[0m"
# A harom validator listajanak EGYEZNIE kell — ez a teszt fogja meg, ha egy uj
# modell csak az egyik helyre kerul be (haromszor tortent meg).
#
# ⚠️ A `case`-AGAKBAN kell keresni, nem az egesz fajlban: a modellnevek a
# kommentekben is szerepelnek, tehat egy fajl-szintu grep akkor is zold lenne,
# ha valaki a modellt kiveszi a fehérlistabol, de a kommentet ottfelejti — pont
# azt a hibat nem fogna meg, ami miatt ez a teszt keszult.
case_arms() {                        # $1 = fajl -> csak a case-agak sorai
  # ⚠️ A vezeto APOSZTROF is megengedett: a `[1m]`-valtozatok idezojelben allnak
  # (`'claude-opus-5[1m]') ;;`), es az elso valtozat regexe ezeket kihagyta —
  # a spawner ket modellje igy lathatatlan volt a tesztnek.
  grep -E "^[[:space:]]*'?[a-zA-Z0-9_-]+[^#]*\)[[:space:]]*;;" "$1" 2>/dev/null
}
# A case-agakbol CSAK a modell-alternativak. A szuro nem elhagyhato: a spawner
# ugyanilyen alaku case-blokkal validalja az effortot es a permission-modot is,
# a hid es a fork-agent viszont nem — szures nelkul harom kulonbozo halmazt
# hasonlitanank ossze, es a teszt vagy mindig bukna, vagy (ahogy az elso
# valtozatban) csendben zoldet adna.
model_set() {                        # $1 = fajl -> egy modellnev soronkent
  case_arms "$1" \
    | sed "s/)[[:space:]]*;;.*//; s/^[[:space:]]*//" \
    | tr '|' '\n' \
    | sed "s/^'//; s/'\$//; s/^[[:space:]]*//; s/[[:space:]]*\$//" \
    | grep -E '^(claude-[a-z0-9.-]+(\[1m\])?|opus|sonnet|haiku|fable)$' \
    | sort -u
}
VALIDATORS=("$ROOT/claude-agent-spawner" "$ROOT/bin/_bridge-lib.sh" "$ROOT/bin/fork-agent")

# 1. A nevesitett modellek mind a haromban ott vannak.
for m in claude-opus-5 claude-sonnet-5 claude-fable-5 claude-haiku-4-5 opus fable; do
  n=0
  for f in "${VALIDATORS[@]}"; do
    # TELJES case-alternativara illesztunk, nem substringre: a puszta `fable`
    # benne van a `claude-fable-5`-ben, tehat a substring-kereses akkor is zold
    # volt, ha az aliast kivettuk a fehérlistabol.
    case_arms "$f" | grep -qE "(^|[|( 	'\"])${m}([|)'\"]|\$)" && (( n++ ))
  done
  is "a(z) $m mind a 3 validátor case-ágában ott van" "$n" "3"
done

# 2. ...es a HAROM HALMAZ AZONOS. Ez az elozonel tobb: egy UJ modell is
# elbuktatja, ha csak az egyik helyre kerul be — pontosan ez a hibaminta
# ismetlodott haromszor. A nevesitett lista ezt nem fogja meg, mert fix
# neveket keres.
sp=$(model_set "${VALIDATORS[1]}")
is "a spawner fehérlistája nem üres" "$([[ -n "$sp" ]] && print ok)" "ok"
for f in "${VALIDATORS[2]}" "${VALIDATORS[3]}"; do
  other=$(model_set "$f")
  if [[ "$sp" == "$other" ]]; then
    ok "a modell-fehérlista azonos: ${VALIDATORS[1]:t} vs ${f:t}"
  else
    bad "a modell-fehérlista azonos: ${VALIDATORS[1]:t} vs ${f:t}" \
        "csak az egyikben: $(print -r -- "$sp"$'\n'"$other" | sort | uniq -u | tr '\n' ' ')"
  fi
done

# 3. Ugyanez a drift-osztaly a PERMISSION-listakra. 2026-08-29-ig ez nem volt
# kockazat (a hid fixen "auto"-t irt), de amiota a keres kerhet modot, mind a
# harom validatornak ugyanazt kell elfogadnia.
perm_set() {                         # $1 = fajl -> egy mod soronkent
  case_arms "$1" \
    | sed "s/)[[:space:]]*;;.*//; s/^[[:space:]]*//" \
    | tr '|' '\n' \
    | sed "s/^'//; s/'\$//; s/^[[:space:]]*//; s/[[:space:]]*\$//" \
    | grep -E '^(auto|acceptEdits|plan|dontAsk|manual|bypassPermissions)$' \
    | sort -u
}
psp=$(perm_set "${VALIDATORS[1]}")
is "a spawner permission-listája nem üres" "$([[ -n "$psp" ]] && print ok)" "ok"
for f in "${VALIDATORS[2]}" "${VALIDATORS[3]}"; do
  pother=$(perm_set "$f")
  if [[ "$psp" == "$pother" ]]; then
    ok "a permission-fehérlista azonos: ${VALIDATORS[1]:t} vs ${f:t}"
  else
    bad "a permission-fehérlista azonos: ${VALIDATORS[1]:t} vs ${f:t}" \
        "csak az egyikben: $(print -r -- "$psp"$'\n'"$pother" | sort | uniq -u | tr '\n' ' ')"
  fi
done

print "\n\033[1mhíd: emelt jogosultság csak gombnyomásra\033[0m"
# A `bypassPermissions` az egyetlen emelt mod. A felugyelet nelkuli agakon
# (idokorlatos felhatalmazas, gate:"audit") NEM ervenyesulhet — es ha egy hivo
# elfelejti megjelolni, hogy hogyan lett jovahagyva, akkor SEM.
is   "gombnyomásra érvényesül"           "$(bridge_effective_perm bypassPermissions button)" "bypassPermissions"
is   "felhatalmazás alatt visszaesik"    "$(bridge_effective_perm bypassPermissions grant)"  "auto"
is   "audit módban visszaesik"           "$(bridge_effective_perm bypassPermissions audit)"  "auto"
is   "jelöletlen hívónál visszaesik"     "$(bridge_effective_perm bypassPermissions '')"     "auto"
is   "a többi módot nem bántja"          "$(bridge_effective_perm acceptEdits '')"           "acceptEdits"

print "\n\033[1mprompt-limit\033[0m"
# 8192 ekezetes karakter = 16384 bajt: a doksi "8 KB"-ot iger, tehat BUKNIA kell.
long=$(printf 'á%.0s' {1..8192})
is   "8192 ékezetes karakter > 8 KB"    "$(( $(printf %s "$long" | wc -c) > 8192 ))" "1"
# A kommentben is szerepel a `wc -c`, ezert a TENYLEGES osszehasonlitasra
# szurunk, ne a magyarazatra.
is   "a spawner bájtot mér, nem karaktert" \
     "$(grep -cE '\(\(.*wc -c.*(>|<=) *8192' "$ROOT/claude-agent-spawner")" "1"
is   "a híd is bájtot mér"                 \
     "$(grep -cE '\(\(.*wc -c.*(>|<=) *8192' "$ROOT/bin/_bridge-lib.sh")" "1"
no_  "sehol nem maradt karakter-alapú 8192-es limit" \
     grep -qE '\(\( *\$\{#(prompt|task)\} *(<=|>) *8192' "$ROOT/claude-agent-spawner" "$ROOT/bin/_bridge-lib.sh"

print "\n\033[1mhíd: a tmux-session nevének feloldása\033[0m"
# A gyerekek `agent-<nev>` alatt futnak, a parancskozpont ELOTAG NELKUL. A hid
# fixen `agent-<nev>`-et keresett, ezert a `mac-main`-nek cimzett folytatas
# halottnak hitte a parancskozpontot es fel akarta tamasztani -> "nincs spec-je".
FAKE_SESSIONS=""
tmux() {                             # csak a has-session agat utanozzuk
  [[ "$1" == "has-session" ]] || return 1
  [[ " $FAKE_SESSIONS " == *" $3 "* ]]
}
FAKE_SESSIONS="agent-valami valami"
is   "mindkettő létezik → az agent- előtagos nyer" \
     "$(agent_tmux_session valami)" "agent-valami"
FAKE_SESSIONS="mac-main"
is   "csak előtag nélküli (a parancsközpont) → azt adja" \
     "$(agent_tmux_session mac-main)" "mac-main"
FAKE_SESSIONS="valami-mas"
no_  "egyik sem létezik → hamis" agent_tmux_session nincs-ilyen
unfunction tmux

# A hirdetett lista (agents.json) es a folytatas NEM terhet el egymastol: ha a
# lista futonak mond egy agentet, a folytatasnak is meg kell talalnia.
CONT_BODY=$(sed -n '/^continue_agent() {/,/^}/p' "$ROOT/bin/_bridge-lib.sh")
yes_ "a folytatás a közös feloldót használja" \
     grep -q 'agent_tmux_session' <<< "$CONT_BODY"
# ⚠️ A fenti allitas ONMAGABAN gyenge: a fuggveny torzseben kesobb is szerepel a
# feloldo neve, ezert akkor is atmenne, ha az ELEJEN visszakerulne a fix nev.
# Ezt a lyukat mutacios teszt mutatta meg 2026-08-29-en.
no_  "a folytatás nem kódolja fixen a session nevét" \
     grep -q 'sess="agent-\$name"' <<< "$CONT_BODY"

print "\n\033[1mwatchdog: az újraindítás-számláló nullázása\033[0m"
# A korlat ("ne éledjen újra a végtelenségig") csak akkor ér valamit, ha a
# szamlalo NEM nullazodik kozvetlenul a spawn utan. Kulonben a 60 masodperc
# utan ismetlodve meghalo agent orokke ujraindul.
NOW=$(date -u +%s)
yes_ "régi bejegyzés (nincs restored_at) → nullázható" \
     restore_counter_should_reset 0 "$NOW" 120
no_  "éppen most állt vissza → NEM nullázható" \
     restore_counter_should_reset "$NOW" "$NOW" 120
no_  "60 másodperce fut (a tick alatt halna meg) → NEM nullázható" \
     restore_counter_should_reset "$((NOW - 60))" "$NOW" 120
yes_ "túlélt egy 300s-es ticket → nullázható" \
     restore_counter_should_reset "$((NOW - 300))" "$NOW" 120
# Pontosan a határon: a küszöb ELÉRÉSE már elég (>=), nem kell túllépni. E nélkül
# egy `>`-re csúszó feltétel némán átmenne a fenti négy állításon.
yes_ "pontosan a küszöbön (=min) → már nullázható" \
     restore_counter_should_reset "$((NOW - 120))" "$NOW" 120

print "\n\033[1melárvult nyilvántartás-bejegyzés\033[0m"
# ⚠️ 2026-08-31: a lezaras FELTETEL NELKUL kilepett, ha nem talalt futo sessiont —
# a `bridge-spawned` kivezetes sosem futott le. Egy magatol meghalt agent
# (osszeomlas, reboot, kezi kill) igy OROKRE bent ragadt: a nev foglalt maradt,
# es a "kiurult-e a nyilvantartas" ellenorzes hamis eredmenyt adott. A session
# hianya nem ok arra, hogy az allapotot koszosan hagyjuk.
SPJ="$TMP/spawned.json"
jq -n '{"halott-agent":{"request":"r1"},"elo-agent":{"request":"r2"}}' > "$SPJ"
( BRIDGE_SPAWNED="$SPJ" CLAUDE_AGENT_QUEUE="$TMP" \
  zsh "$ROOT/bin/agent-close-tree.sh" halott-agent drop keep ) >/dev/null 2>&1
no_  "a halott agent kikerül a nyilvántartásból" \
     eval 'jq -e ".[\"halott-agent\"]" "$SPJ" >/dev/null'
yes_ "a többi bejegyzés érintetlen marad" \
     eval 'jq -e ".[\"elo-agent\"]" "$SPJ" >/dev/null'
# ⚠️ 2026-09-01: a lezaras kivezette az agentet a bridge-spawned-bol es a
# fork-fabol, de a FELHATALMAZAS bent maradt.
# ⚠️ 2026-09-01: a kivezetes a fuggveny VEGEN allt, ezert a "nincs spec" ag
# (korai `return`) teljesen kihagyta — az agent eltunt, a bejegyzese bent
# maradt. Csonk-sessionnel reprodukalva. A kivezetesnek a spec-kereses ELOTT
# kell allnia, hogy minden agra vonatkozzon.
# ⚠️ A `head -1` HAMIS ZOLDET adott: a fajlban HAROM kivezetes van, es az elso a
# korai-kilepes ага, ami mindig a "no spec found" elott all. Az AGENTENKENTI
# kivezetest kell merni: `bridge_unregister_spawned "$NAME"`.
_ctln(){ grep -n "$1" "$ROOT/bin/agent-close-tree.sh" | tail -1 | cut -d: -f1 }
is   "a kivezetés a spec-keresés ELŐTT történik" \
     "$(( $(_ctln "bridge_unregister_spawned .\$NAME.") < $(_ctln "no spec found for") ))" "1"
yes_ "a lezárás a felhatalmazást is kivezeti" \
     grep -q 'bridge_grant_revoke_by_agent "$NAME"' "$ROOT/bin/agent-close-tree.sh"
yes_ "és jelzi is, hogy takarított" \
     grep -q 'az elárvult állapot eltakarítva' "$ROOT/bin/agent-close-tree.sh"

print "\n\033[1mszintetikus jóváhagyás — a regresszió automatizálása\033[0m"
# ⚠️ MIERT NEM BONGESZO. A kezenfekvo otlet az volt, hogy egy agent kattintson a
# Telegram Weben. Rossz: az agent a felhasznalo TELJES Telegramjahoz ferne hozza,
# a UI-automatizalas torekeny, es a gomb MAGA a merendo dolog. Ehelyett a
# Telegram VALASZAT utanozzuk — a fajlbol olvasott jovahagyas ugyanolyan
# callback_query lesz, es onnan a teljes meglevo kodut fut valtozatlanul.
yes_ "a teszt-csatorna csak létező könyvtárral él" \
     grep -q 'if \[\[ -d "$TESTCB_DIR" \]\]; then' "$ROOT/bin/bridge-poller.sh"
yes_ "csak reg-előtagú kérés-id fogadható el" \
     grep -q '\[\[ "$_rid" == reg\* \]\] && _istest=true' "$ROOT/bin/bridge-poller.sh"
# ⚠️ A QUEUE-KAPU gombja a spec UUID-jat viszi (`qa:8C58A834-…`), nem beszedes
# id-t — merve a naploban. Ha csak az elotagot neznenk, a G2 lepes
# SYNTHETIC-DENY-vel halna el, es az automatizalt kor pont ott bukna.
yes_ "a queue-kapu a spec NEVÉBŐL dönti el a teszt-voltot" \
     grep -q 'gated/$_rid.json' "$ROOT/bin/bridge-poller.sh"
# ⚠️ A spec NEVE a szulo prefixevel jon (`mac-main-regG2-…`), NEM `regG2-…`.
# Az elso valtozat `reg*` kezdetet vart; a teszt azert volt zold, mert KITALALT
# nevet hasznaltam. Elesben a G2 lepes SYNTHETIC-DENY-vel allt meg.
yes_ "a prefixelt spec-nevet is felismeri" \
     eval '[[ "mac-main-regG2-20260901i" == (reg[A-Z]*|*-reg[A-Z]*) ]]'
no_  "éles nevű kapuzott kérést viszont nem" \
     eval '[[ "mac-main-eles-munka" == (reg[A-Z]*|*-reg[A-Z]*) ]]'
yes_ "és a kód is ezt a mintát használja" \
     grep -q 'reg\[A-Z\]\*|\*-reg\[A-Z\]\*' "$ROOT/bin/bridge-poller.sh"
yes_ "az action fehérlistázott" \
     grep -q 'ok|no|g1|g8|gd|rv|nu|s8|sd|sw|qa|qn' "$ROOT/bin/bridge-poller.sh"
yes_ "minden ilyen esemény naplóba kerül" \
     grep -q 'SYNTHETIC-CALLBACK' "$ROOT/bin/bridge-poller.sh"
yes_ "a fájl egyszer használatos (felhasználáskor törlődik)" \
     grep -q 'rm -f "$_f"' "$ROOT/bin/bridge-poller.sh"
# ⚠️ SORREND: a gyujtes a getUpdates ELOTT fut. Eloszor utana tettem, es a
# teszt-fajlok nem fogytak el — a getUpdates idotullepesekor a poller mar
# kilepett. Egy teszt-eszkoz nem fugghet a Telegram elerhetosegetol.
yes_ "a teszt-csatorna a getUpdates ELŐTT fut" \
     eval 'awk "/TESTCB_DIR=/{t=NR} /tg_call getUpdates/{g=NR} END{exit !(t && g && t<g)}" "$ROOT/bin/bridge-poller.sh"'
yes_ "Telegram-hiba esetén is feldolgozza" \
     grep -q 'a teszt-csatorna igy is feldolgozasra kerul' "$ROOT/bin/bridge-poller.sh"
# A vizualis ellenorzest is kodba emeltuk: a gombos uzenet szovege lemezre kerul,
# igy a figyelmeztetesek megleTE PROGRAMBOL allithato, nem szemrevetelezessel.
# ⚠️ A KODSORT horgonyozzuk, ne a puszta stringet: a `.button.txt` a KOMMENTBEN
# is szerepel, es a mutacios proba (a kiiras torlese) igy HAMIS ZOLDET adott.
# Ez ma a negyedik ilyen — komment-egyezes miatti hamis allitas.
yes_ "a gombos üzenet szövege lemezre kerül" \
     grep -q 'print -r -- "$btn" > "$REQ_DIR/$id.button.txt"' "$ROOT/bin/bridge-relay.sh"

print "\n\033[1ma kézbesítés-ellenőrzés csak FRISS átiratot fogad el\033[0m"
# ⚠️ 2026-09-01, ELES HIBA. Az ellenorzes a projekt-konyvtar OSSZES atiratat
# nezte — abban viszont a KORABBI korok atiratai is ott vannak (merve: 14 fajl),
# es a teszt-feladatok szovege korrol korre SZO SZERINT AZONOS. Igy egy TEGNAPI
# atiratra illeszkedett, sikert jelentett, es a `spawned` megint hazudott,
# mikozben a feladat el sem indult.
yes_ "csak a küldés óta írt átirat számít" \
     grep -q "find \"\$tdir\" -name '\*.jsonl' -newermt" "$ROOT/bin/_agent-lib.sh"
# A minta a LAPOSITOTT szovegbol jon: a nyers valtozat sortoresei tobbsoros
# grep-mintat csinalnanak.
yes_ "a minta a lapított szövegből jön" \
     grep -q 'frag="${flat\[1,60\]}"' "$ROOT/bin/_agent-lib.sh"

print "\n\033[1ma darabolás kötőjeles blokkot is átvisz\033[0m"
# ⚠️ 2026-09-01, ELES HIBA. A darabolas kozepen egy blokk KOTOJELLEL kezdodhet
# (a feladat szovegeben levo `print -r --` reszlet miatt), es a tmux azt
# KAPCSOLONAK veszi: `command send-keys: unknown flag -r`. A blokk elveszett, a
# feladat kozepe kiesett — a G6 lepes ezen bukott el. ES a statusz megis
# `spawned` lett, mert az ellenorzes csak az ELSO 60 karaktert nezte.
yes_ "a send-keys lezárja az opciókat (--)" \
     grep -q 'send-keys -t "$sess" -l -- "${flat' "$ROOT/bin/_agent-lib.sh"
yes_ "a szöveg VÉGÉT is ellenőrizzük" \
     grep -q 'fragend="${flat\[-60,-1\]}"' "$ROOT/bin/_agent-lib.sh"
yes_ "és mindkét mintának meg kell lennie" \
     grep -q 'xargs -0 grep -qlF -- "$fragend"' "$ROOT/bin/_agent-lib.sh"

print "\n\033[1mblokkoló modal a küldés előtt\033[0m"
# ⚠️ 2026-09-01: egy FUTO agent sessionjeben KOZBEN ugrott fel a "Teach auto mode
# about your environment?" ablak, es onnantol minden bekuldott feladat a semmibe
# ment. Az `auto_dismiss_modals` csak INDULASKOR fut, ezt senki nem vette le.
yes_ "a küldés előtt megnézzük a blokkoló modalt" \
     grep -q 'Teach auto mode about your environment' "$ROOT/bin/_agent-lib.sh"
# ⚠️ ESC, NEM Enter: az az ablak a shell-elozmenyek es a tobbi repo
# atvizsgalasat ajanlja fel — az a felhasznalo dontese, nem a mienk.
yes_ "Escape-pel zárjuk, nem Enterrel" \
     grep -q 'send-keys -t "$sess" Escape' "$ROOT/bin/_agent-lib.sh"

print "\n\033[1ma FOLYTATÁS kézbesítése is ellenőrzött\033[0m"
# ⚠️ 2026-08-31, ELES HIBA. A fork mar reggel megkapta az ellenorzott kuldest, a
# FOLYTATAS viszont nem: nyers, egyben kuldott `send-keys`-szel ment. A ~1KB
# feletti prompt eleje elveszett, a vege elkuldetlenul ott maradt a beviteli
# sorban ("Fejezd be a kört."), a hid pedig `folytatás elküldve`-t irt. A cimzett
# 39 percig tetlen maradt — a kuldo oldalan minden zold volt.
yes_ "a folytatás a közös, ellenőrzött küldést hívja" \
     grep -q 'agent_send_prompt "$name" "$task" "$ccwd"' "$ROOT/bin/_bridge-lib.sh"
yes_ "sikertelen kézbesítésnél HIBÁT jelez, nem sikert" \
     grep -q 'a folytatás NEM ért célba' "$ROOT/bin/_bridge-lib.sh"
is   "nincs nyers egyben-küldés a folytatásban" \
     "$(grep -c 'send-keys -t "$sess" -l "$task"' "$ROOT/bin/_bridge-lib.sh")" "0"
# ⚠️ A beviteli sort ki kell takaritani kuldes elott: egy korabbi csonkolt kuldes
# maradeka ott ulhet, es osszeragadna az uj szoveggel.
yes_ "küldés előtt kitakarítjuk a beviteli sort" \
     grep -q 'send-keys -t "$sess" C-u' "$ROOT/bin/_agent-lib.sh"

print "\n\033[1magent-send-prompt: szűk, auditálható küldés\033[0m"
# ⚠️ 2026-08-31: a CLI-kor G5 lepese (kaszkados lezaras) azt igenyli, hogy egy
# agent uzenjen a sajat gyerekenek. A nyers `tmux send-keys`-t az auto-mode
# classifier LETILTJA — helyesen, mert az barmelyik sessionbe irhat, beleertve a
# felhasznalo eles agentjeit. A wrapper hatara ezert szuk: CSAK lefele a fadban.
SP="$ROOT/bin/agent-send-prompt"
yes_ "a wrapper létezik és futtatható" test -x "$SP"
# ⚠️⚠️ A CELNEVEK KITALALTAK, ES EZT KI IS KENYSZERITJUK. Elso valtozatban VALODI
# agent-neveket hasznaltam (egy eles agentet es a `mac-main`-t), abbol a hibas
# feltevesbol, hogy a hataror ugyis elutasitja oket. A MUTACIOS proba viszont
# eppen a hatarort iktatja ki — es a teszt akkor ELO sessionbe irt: a `mac-main`
# parancskozpontba tenyleg bekerult egy teszt-uzenet. A hatar-ellenorzes a
# session-kereses ELOTT fut, tehat nem letezo nevekkel is pontosan ugyanaz
# merheto — csak nem tud kart okozni.
_sp() {
  # Vegso vedelem: ha a cel BARMIERT letezo sessionre mutat, meg se probaljuk.
  if tmux has-session -t "agent-$2" 2>/dev/null || tmux has-session -t "$2" 2>/dev/null; then
    print "TESZT-HIBA: a cél létező session ($2) — kitalált nevet használj"; return 1
  fi
  env CLAUDE_AGENT_NAME="$1" zsh "$SP" "$2" "teszt-szoveg" 2>&1
}
yes_ "idegen ágra nem enged" \
     eval '_sp teszt-szulo-nincs teszt-idegen-nincs | grep -q "csak a saját leszármazottadnak"'
yes_ "a SZÜLŐRE sem enged (csak lefelé)" \
     eval '_sp teszt-szulo-nincs-gyerek teszt-szulo-nincs | grep -q "csak a saját leszármazottadnak"'
yes_ "testvérre sem enged" \
     eval '_sp teszt-szulo-nincs teszt-masik-ag-nincs | grep -q "csak a saját leszármazottadnak"'
# ⚠️ KONTROLL: a sajat leszarmazott ATJUT a hataroron — kulonben a wrapper
# hasznalhatatlan lenne, es a teszt rossz okbol latszana zoldnek.
yes_ "a saját leszármazott átjut a határőrön" \
     eval '_sp teszt-szulo-nincs teszt-szulo-nincs-gyerek | grep -q "nincs ilyen futó agent"'
yes_ "CLAUDE_AGENT_NAME nélkül elutasít" \
     eval 'env -u CLAUDE_AGENT_NAME zsh "$SP" barmi szoveg 2>&1 | grep -q "nincs CLAUDE_AGENT_NAME"'

print "\n\033[1ma hosszú feladat darabolva megy ki\033[0m"
# ⚠️ 2026-08-31, ELES HIBA. Egy 1796 karakteres promptbol PONTOSAN 774 erkezett
# meg, SZOKOZEPEN kezdve — az elso ~1022 karakter (egy 1KB-os bemeneti puffer)
# elveszett. Se a `send-keys -l`, se a `paste-buffer` nem segit: nem a modszer a
# baj, hanem az egyben atadott MERET. Az eles regresszioban emiatt csak a prompt
# utolso 12 karaktere ("d nincs meg." — a boilerplate zaro szavai) maradt, es az
# agent AZT kapta feladatnak. Haromszor bukott el emiatt a C1 lepes.
yes_ "a promptot 400 karakteres blokkokban küldjük" \
     grep -q 'send-keys -t "$sess" -l -- "${flat\[$pos,$((pos+399))\]}"' "$ROOT/bin/_agent-lib.sh"
yes_ "a blokkok között várunk" \
     grep -q 'sleep 0.3' "$ROOT/bin/_agent-lib.sh"
# ⚠️ Az egyben-kuldes ne johessen vissza semmilyen formaban.
# A kommentek szandekosan emlitik a paste-buffert (miert NEM az a megoldas),
# ezert a KOD-hasznalatot allitjuk, nem a puszta elofordulast.
is   "nincs egyben-küldés paste-bufferrel" \
     "$(grep -c '"\$TMUX_BIN" paste-buffer' "$ROOT/bin/fork-agent")" "0"

print "\n\033[1ma feladat kiküldése ellenőrzött\033[0m"
# ⚠️ 2026-08-31: a `PROMPT-SENT` naplosor OPTIMISTA volt — azt jelentette, hogy a
# send-keys lefutott, nem azt, hogy a feladat megerkezett. Egy Remote Control-
# uzenet UGYANABBAN A MASODPERCBEN felulirhatja a beirt promptot: a feladat
# nyomtalanul eltunik, a naplo sikert jelent, az agent pedig ul es var.
# Merve: PROMPT-SENT 11:49:14Z, a betolakodo uzenet 11:49:14.443Z; az agent
# atirataban (22 sor) a feladat NEM szerepelt, csak a betolakodo uzenet.
# ⚠️ NE a pane-t nezzuk: a TUI sortorest tesz a hosszu szovegbe, a grep igy HAMIS
# NEGATIVOT ad — 2026-08-31-en emiatt kuldte ki a fuggveny KETSZER a feladatot.
# Az atirat a hiteles forras: ott a user-uzenet egyben all.
yes_ "a kiküldést az ÁTIRATBÓL ellenőrizzük" \
     grep -q 'xargs -0 grep -qlF -- "$frag"' "$ROOT/bin/_agent-lib.sh"
is   "és nem a pane-ből" \
     "$(grep -c 'capture-pane .*grep -qF' "$ROOT/bin/_agent-lib.sh")" "0"
yes_ "sikertelenség esetén újrapróbál" \
     grep -q 'for try in 1 2; do' "$ROOT/bin/_agent-lib.sh"
yes_ "a napló megkülönbözteti az ELLENŐRZÖTT küldést" \
     grep -q 'PROMPT-SENT \$NAME (\${#PROMPT} karakter, ellenorizve)' "$ROOT/bin/fork-agent"
yes_ "és van külön PROMPT-LOST ág" \
     grep -q 'PROMPT-LOST \$NAME' "$ROOT/bin/fork-agent"
# ⚠️ Az optimista naplozas ne johessen vissza: ellenorzes NELKULI PROMPT-SENT
# nem szerepelhet a fajlban.
is   "nincs ellenőrizetlen PROMPT-SENT" \
     "$(grep -c 'log "PROMPT-SENT' "$ROOT/bin/fork-agent")" "1"

print "\n\033[1mfriss session: örökölt kontextus nélkül\033[0m"
# ⚠️ 2026-08-31, ELES HIBA. A fork a szulo TELJES beszelgeteset orokli, es a
# feladat egyetlen uzenetkent a VEGERE kerul. Merve az atiratbol: 714 sor, a
# feladat a 703. sorban — a gyerek nem azt csinalta, hanem a szulo SZEREPET
# folytatta (parancskozpontkent monitorozott, sajat munka nelkul). A rendszer-
# prompt lefokozo mondata BIZONYITHATOAN ODAERT (a parancssorban szerepelt), es
# megsem volt eleg. A determinisztikus valasz: ne orokoljon egyaltalan.
# A telepito hangos figyelmeztetese 2026-08-31-ig a heredocba szorult, tehat
# SZOVEGKENT irodott ki kod helyett — soha nem szolalt meg, es a `set -u` a
# telepito vegen hibara futott. Azert nem tunt fel, mert a kimenetet /dev/null-ba
# iranyitottam. A lezaro EOF-nak a blokk ELOTT kell allnia.
yes_ "a telepítő hibafigyelmeztetése a heredocon KÍVÜL van" \
     eval 'awk "/^EOF\$/{e=NR} /FAILED_SERVICES:-/{f=NR} END{exit !(e && f && f>e)}" "$ROOT/install.sh"'
yes_ "a fork-agent ismeri az --inherit kapcsolót" \
     grep -q -- '--inherit)   RESUME_MODE="full"' "$ROOT/bin/fork-agent"
# ⚠️ A KET default kulon el (CLI es hid). A hid-oldalit mertem, a CLI-oldalit nem,
# es a mutacio (vissza `full`-ra) csendben atment. Ket helyen kell allitani.
is   "a fork-agent CLI alapértelmezése is none" \
     "$(grep -oE '^RESUME_MODE="[a-z]+"' "$ROOT/bin/fork-agent")" 'RESUME_MODE="none"' 
yes_ "a fork-agent ismeri a --fresh kapcsolót" \
     grep -q -- '--fresh)     RESUME_MODE="none"' "$ROOT/bin/fork-agent"
yes_ "friss módban nincs --resume/--fork-session" \
     grep -q 'if \[\[ "$RESUME_MODE" != "none" \]\]; then' "$ROOT/bin/fork-agent"
yes_ "friss módban az orientáció sem beszél örökölt szövegről" \
     grep -q 'ÖNÁLLÓ session. Nem örököltél beszélgetést' "$ROOT/bin/fork-agent"
# ⚠️ A `full|summary|none)` string a HIBAUZENETBEN is szerepel — a puszta grep
# arra is illeszkedett, es a mutacio (a case-ag szukitese) HAMIS ZOLDET adott.
# A case-agat kell horgonyozni, sor eleji behuzassal.
yes_ "a híd elfogadja a resume: none értéket" \
     grep -qE '^ +full\|summary\|none\) ;;' "$ROOT/bin/_bridge-lib.sh"
yes_ "és továbbadja --fresh-ként" \
     grep -q -- '"$resume" == "none"    \]\] && args+=(--fresh)' "$ROOT/bin/_bridge-lib.sh"
yes_ "a Telegram-összefoglaló jelzi a friss kontextust" \
     grep -q 'FRISS — nem örököl beszélgetést' "$ROOT/bin/_bridge-lib.sh"
# ⚠️ KONTROLL: a sima fork tovabbra is OROKOLJON — kulonben a --fresh bevezetese
# csendben eltorte volna a fork alapfunkciojat.
yes_ "a sima fork viszont továbbra is örököl" \
     grep -q 'cmd_args=(--resume "$PARENT_SID" --fork-session "${cmd_args\[@\]}")' "$ROOT/bin/fork-agent"

print "\n\033[1mfork-bomba elleni őrök\033[0m"
# ⚠️ 2026-08-30, ELES ESET: egy `--summary` fork gyereke a szulo beszelgetes-
# osszefoglalojaban levo runbookot SAJAT feladatlistanak olvasta, es ujra
# forkolta ugyanazt — negy nemzedek. A lancot NEM vedelem allitotta meg, hanem
# veletlen: a nev 64 karakteren elfogyott. Azota ket or all az uton.
FG="$TMP/forkguard"; mkdir -p "$FG/proj" "$FG/home/.local/bin"; print '{}' > "$FG/fork-tree.json"
# ⚠️ CSONK — ket okbol kell, es MINDKETTO fajt mar:
# 1) A CI-runneren nincs `tmux`/`claude`, es a fork-agent MAR A 3. SORABAN meghal
#    ("tmux not found"). A tesztek igy nem a vizsgalt agon buktak el, hanem egy
#    sokkal korabbin — a klasszikus "rossz okbol piros". 9 teszt bukott igy.
# 2) Ha egy or mutacios probaval kikerul, a fork VEGIGMENNE. Csonk nelkul ez
#    ELEVEN Claude sessiont indit: 2026-08-30-an ketszer megtortent.
# A csonk NEM barhova mehet: a fork-agent a sajat elejen ujraexportalja a PATH-t
# ($HOME/.local/bin elore), ezert oda tesszuk, es a HOME-ot is atallitjuk.
ln -sf "$(command -v jq)" "$FG/home/.local/bin/jq"
for _b in tmux claude; do
  print '#!/bin/sh' > "$FG/home/.local/bin/$_b"
  print 'exit 1'   >> "$FG/home/.local/bin/$_b"
  chmod +x "$FG/home/.local/bin/$_b"
done
# ⚠️⚠️ MINDEN _fork_try hivas `--cwd nincs-ilyen`-nel fusson! Enelkul az or
# KIIKTATASAKOR (mutacios proba) a fork vegigmegy es ELEVEN agentet indit.
# 2026-08-30: pontosan ez tortent — ket valodi Claude session indult, a suite
# idotullepesig futott, es a "0 piros" hamis zoldnek latszott. A nem letezo cwd
# egy kesobbi, olcso vegallomas: az or meglete igy is merheto, indulas nelkul.
_fork_try() {                    # $1=szulo $2=suffix [$3=extra kapcsolo...]
  local par="$1" suf="$2"; shift 2
  env HOME="$FG/home" CLAUDE_CODE_SESSION_ID=teszt-sid CLAUDE_AGENT_NAME="$par" \
      CLAUDE_AGENT_QUEUE="$FG" FORK_TREE="$FG/fork-tree.json" \
      CLAUDE_AGENT_ROOT="$FG/proj" \
      zsh "$ROOT/bin/fork-agent" "$suf" --model sonnet --effort low "$@" 2>&1
}
yes_ "az önmásoló fork elbukik" \
     eval '_fork_try "mac-main-x-regG4-20260830" "regG4-20260830" --cwd nincs-ilyen | grep -q "önmásolás"'
print '{"m-a":"m","m-a-b":"m-a","m-a-b-c":"m-a-b"}' > "$FG/fork-tree.json"
yes_ "a túl mély fork elbukik" \
     eval '_fork_try "m-a-b-c" "uj-munka" --cwd nincs-ilyen | grep -q "túl mély"'
yes_ "a mélységkorlát felülbírálható" \
     eval 'CLAUDE_AGENT_MAX_DEPTH=9 _fork_try "m-a-b-c" "uj-munka" --cwd nincs-ilyen | grep -q "a cwd nem létezik"'
# ⚠️ KONTROLL: az orok nem blokkolhatnak tul sokat. A `--cwd nincs-ilyen` miatt a
# szabalyos fork a KESOBBI cwd-agon bukik — ez bizonyitja, hogy az orokon
# ATJUTOTT, es kozben NEM indul valodi agent. (Kapcsolo nelkul ez a teszt eleven
# agentet inditana: 2026-08-30-an pontosan ez tortent velem.)
print '{}' > "$FG/fork-tree.json"
yes_ "a szabályos fork átjut az őrökön" \
     eval '_fork_try "mac-main" "rendes-nev" --cwd nincs-ilyen | grep -q "a cwd nem létezik"'
# A csonkolas a suffix kozepen is vaghat; a regi valtozat zaro kotojelu nevet adott.
# ⚠️ A csonkolas EDDIG NEMA volt: egy unoka neve `…-unoka-2026083` lett (a zaro
# `1` lemaradt), es a hivo majdnem hamis idotullepest jelentett, mert a KERT
# nevet kereste. Negy szint melyen a nevek elerik a 64-es korlatot.
# ⚠️ A csonkolas UTKOZHET: a megkulonbozteto resz a nev VEGEN van, es eppen azt
# vagjuk le. Ket kulonbozo kert nev igy ugyanarra a csonkra eshet, es mivel a
# tmux-session, a git-ag es a fork-fa mind ezt hasznalja, az utkozes NEMA lenne:
# a masodik fork a MASIK agent sessionjebe dolgozna. Ezert HIBA, nem warning.
yes_ "a csonkolt név ütközése futó agenttel HIBA" \
     grep -q 'a csonkolt név ütközik egy futó agenttel' "$ROOT/bin/fork-agent"
yes_ "és git-ággal is HIBA" \
     grep -q 'a csonkolt névhez már tartozik git-ág' "$ROOT/bin/fork-agent"
yes_ "a név-csonkolás figyelmeztet" \
     grep -q 'WARN nev-csonkolas' "$ROOT/bin/fork-agent"
yes_ "és a hívónak is szól róla" \
     grep -q 'a név 64 karakternél csonkolva' "$ROOT/bin/fork-agent"
yes_ "a csonkolt névről lejön a záró kötőjel" \
     grep -qF 'cut -c1-64 | sed' "$ROOT/bin/fork-agent"
yes_ "a fork rögzíti az élt a fában" \
     grep -q 'fork_tree_record "$NAME" "$PARENT_NAME"' "$ROOT/bin/fork-agent"
yes_ "a lezárás kivezeti a fából" \
     grep -q 'fork_tree_forget "$NAME"' "$ROOT/bin/agent-close-tree.sh"

# --- kapu + sebessegkorlat -------------------------------------------------
mkdir -p "$FG/bridge/requests"; print '{}' > "$FG/fork-tree.json"; : > "$FG/fork.log"
yes_ "az agent-kezdeményezte fork nem indul, hanem sorba kerül" \
     eval '_fork_try "mac-main" "kapu-proba" --requested-by mac-main --cwd nincs-ilyen | grep -q "jóváhagyásra vár"'
# ⚠️ `jq -e` az URES sztringet is igaznak veszi (csak null/false bukik), ezert a
# puszta letezes-ellenorzes HAMIS ZOLD volt: az ures requested_by atment rajta.
# Mutacios probaval derult ki. Az ERTEKET kell nezni, nem a letezest.
is   "a sorba írt kérés hordozza a requested_by-t" \
     "$(jq -r '.requested_by' "$FG"/bridge/requests/*.json 2>/dev/null)" "mac-main"
# ⚠️ SORREND: a fork-bombat el kell UTASITANI, nem jovahagyasra kuldeni. Ha az orok
# a kapu MOGE kerulnenek, a felhasznalo gombot kapna egy onmasolo forkra.
rm -f "$FG"/bridge/requests/*.json
yes_ "az önmásoló fork a kapuval együtt is elutasítás" \
     eval '_fork_try "mac-main-x-regG4" "regG4" --requested-by mac-main --cwd nincs-ilyen | grep -q "önmásolás"'
is   "és nem is kerül a sorba" \
     "$(ls "$FG"/bridge/requests/*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
# ⚠️ A kapu ONBEVALLASOS (mint a spawnere). A determinisztikus vedelem EZ:
for i in 1 2 3 4 5 6 7 8 9 10; do print "$(date -u +%Y-%m-%dT%H:%M:%SZ) FORKED p$i from=x" >> "$FG/fork.log"; done
yes_ "a sebességkorlát fog" \
     eval '_fork_try "mac-main" "hetedik" --cwd nincs-ilyen | grep -q "sebességkorlát"'
: > "$FG/fork.log"
for i in 1 2 3 4 5 6 7 8 9 10; do print "$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ) FORKED regi$i from=x" >> "$FG/fork.log"; done
# ⚠️ A regressziós futas csucsa 5 fork / 10 perc. Ha valaki a korlatot 6 ala
# viszi, a SAJAT tesztunk bukna el hamisan — ezt fogjuk meg itt.
yes_ "a korlát elbírja a regressziós futás csúcsát (mért: 5/10 perc)" \
     eval '[[ $(grep -o "CLAUDE_AGENT_MAX_BURST:-[0-9]*" "$ROOT/bin/fork-agent" | grep -o "[0-9]*$") -ge 8 ]]'
yes_ "a régi forkok nem számítanak bele" \
     eval '_fork_try "mac-main" "hetedik" --cwd nincs-ilyen | grep -q "a cwd nem létezik"'
: > "$FG/fork.log"
# --- az orokolt kontextus lefokozasa ---------------------------------------
# ⚠️ Ez a mondat allitotta volna meg a 2026-08-30-i bombat a forrasnal: a regi
# orientacios szoveg csak a MUNKAKONYVTARAT fokozta le, az utasitasokat nem.
yes_ "a fork lefokozza az örökölt utasításokat" \
     grep -q 'HÁTTÉR-INFORMÁCIÓ, NEM feladatlista' "$ROOT/bin/fork-agent"
yes_ "és kimondja, hogy ne folytassa a szülő munkáját" \
     grep -q 'ne folytasd, ahol a szülő tartott' "$ROOT/bin/fork-agent"

print "\n\033[1mberagadás-némítás: \"köszi, de erről ne szólj\"\033[0m"
# Van, amirol a felhasznalo TUDJA, hogy szandekosan all (parkolt agent, vagy a
# parancskozpont ket kor kozott) — ott a riasztas zaj. A nemitas IDOKORLATOS:
# lejarat utan magatol visszaall, tehat egy valodi beragadas nem marad rejtve.
MST="$TMP/mute-state.json"; print '{}' > "$MST"
no_  "alapból nincs némítva" \
     env BRIDGE_STATE="$MST" zsh -c 'source "'"$ROOT"'/bin/_bridge-lib.sh"; bridge_stall_muted proba-agent >/dev/null'
( BRIDGE_STATE="$MST" zsh -c 'source "'"$ROOT"'/bin/_bridge-lib.sh"; bridge_stall_mute_set proba-agent 28800' ) >/dev/null
yes_ "némítás után néma" \
     env BRIDGE_STATE="$MST" zsh -c 'source "'"$ROOT"'/bin/_bridge-lib.sh"; bridge_stall_muted proba-agent >/dev/null'
# lejart nemitas: NEM nema, es a bejegyzes ki is takarodik
jq '.stall_mute["proba-agent"] = 1' "$MST" > "$MST.t" && mv "$MST.t" "$MST"
no_  "lejárt némítás után újra szól" \
     env BRIDGE_STATE="$MST" zsh -c 'source "'"$ROOT"'/bin/_bridge-lib.sh"; bridge_stall_muted proba-agent >/dev/null'
is   "a lejárt bejegyzést kitakarítja" \
     "$(jq -r '(.stall_mute // {}) | has("proba-agent")' "$MST")" "false"
# ⚠️ 2026-09-03: a gyoker agent (parancskozpont) egy reg halott keres-id-vel bent
# maradt a nyilvantartasban, a figyelo tetlennek latta, es NUDGE-olta. Az
# emlekezteto azt allitja, hogy "nincs kihez visszakerdezned" — a
# parancskozpontnal ez pont forditva igaz, ott ul a felhasznalo. Az uzenet a
# beszelgeteset szakitotta felbe. A gyokeret a watchdog kezeli, nem a hid.
# ⚠️ A gyoker-ellenorzes HAROM helyen szerepel a fajlban (feltamasztas-tilalom,
# lezaras, beragadas-figyelo). A puszta grep barmelyikre illeszkedik, tehat a
# figyelo agabol kiveve is zold maradna. A FUGGVENYEN BELUL kell allitani.
yes_ "a figyelő kihagyja a parancsközpontot" \
     eval 'sed -n "/^bridge_detect_stalled()/,/^}/p" "$ROOT/bin/_bridge-lib.sh" | grep -q ROOT_AGENT_NAME'
yes_ "a figyelő nézi a némítást" \
     grep -q 'bridge_stall_muted "$name"' "$ROOT/bin/_bridge-lib.sh"
# Harom idoablak: 8 ora / 1 nap / 1 het. A gombot es a POLLER-agat egyutt
# merjuk — kulon-kulon zold lehet ugy is, hogy a gomb nyomasa nem csinal semmit.
for _p in s8 sd sw; do
  yes_ "a riasztáson ott a(z) $_p gomb" \
       grep -q "\"$_p:\" + \$r" "$ROOT/bin/_bridge-lib.sh"
  yes_ "a poller ismeri a(z) $_p ágat" \
       grep -q "^ *$_p) msec=" "$ROOT/bin/bridge-poller.sh"
  # ⚠️ A case-ag megléte NEM elég: az action-szuro if-nek is be kell engednie.
  # Mutacios probaval derult ki, hogy enelkul a gomb + ag egyutt is HOLT lehet
  # (a gomb latszik, a nyomasa nem csinal semmit) — es minden teszt zold marad.
  yes_ "a szűrő beengedi a(z) $_p gombot" \
       grep -q "action\" == \"$_p\"" "$ROOT/bin/bridge-poller.sh"
done
yes_ "a poller kezeli a némítást" \
     grep -q 'STALL-MUTED' "$ROOT/bin/bridge-poller.sh"
# Az egyhetes nemitas tenyleg egy hetre szol (a masodperc konnyen elgepelheto).
is   "1 hét = 604800 másodperc" \
     "$(grep -o 'sw) msec=[0-9]*' "$ROOT/bin/bridge-poller.sh")" "sw) msec=604800"
# ⚠️ A Telegram a callback_data-t 64 BAJTBAN maximalja. A prefix 3 bajt, a
# keres-id max 48 -> 51. Ha valaki hosszabb prefixet vagy id-t vezet be, ez bukik.
is   "a némító gomb adata belefér 64 bájtba" \
     "$(( 3 + 48 <= 64 ))" "1"

print "\n\033[1mlong polling: a gombnyomás ne várjon fél percet\033[0m"
# A dupla gombnyomas OKA a varakozas volt: `timeout=0` mellett a nyomasrol csak a
# kovetkezo 30 mp-es tickkor ertesultunk, es a felhasznalo joggal nyomott ujra.
# ⚠️ A poll-timeoutnak a curl `--max-time` ALATT kell maradnia, kulonben a curl
# vagja el a kapcsolatot, mielott a Telegram valaszolna.
is   "a poll-timeout a curl kerete ALATT van" \
     "$(( BRIDGE_POLL_TIMEOUT < BRIDGE_HTTP_MAX_TIME ))" "1"
is   "és nem nulla (tényleg long polling)" \
     "$(( BRIDGE_POLL_TIMEOUT > 0 ))" "1"
# ⚠️ 2026-09-04: a 15 mp-es varakozas NEM volt eleg. A poller 30 mp-enkent indul,
# tehat koronkent ~15 mp HOLTIDO maradt, amikor a gombnyomas allt a sorban.
# Merve a naplobol: 32 ismetelt gombnyomas, MEDIAN 33 mp-es idokozzel — ez nem
# remego ujj, hanem "megnyomtam, nem tortent semmi, ujra megnyomtam". A
# varakozasnak a 30 mp-es ciklus TOBBSEGET le kell fednie.
is   "a várakozás lefedi a ciklus többségét (>=20 mp)" \
     "$(( BRIDGE_POLL_TIMEOUT >= 20 ))" "1"
# A KOMMENT emliti a `timeout=0`-t magyarazatkent — a VEGREHAJTHATO hivasra
# szurunk, kulonben a sajat magyarazatunk buktatna el a tesztet.
no_  "a poller nem kérdez timeout=0-val" \
     grep -q -- '-d "timeout=0"' "$ROOT/bin/bridge-poller.sh"
# A tulzott ertek nem szallhat el: a lib visszavagja a curl kerete ala.
BRIDGE_POLL_TIMEOUT=999 BRIDGE_HTTP_MAX_TIME=20 zsh -c '
  source "'"$ROOT"'/bin/_bridge-lib.sh" 2>/dev/null
  print $BRIDGE_POLL_TIMEOUT' > "$TMP/pt.txt" 2>/dev/null
is   "a túl nagy érték vissza van vágva" \
     "$(( $(cat "$TMP/pt.txt" 2>/dev/null || print 999) < 20 ))" "1"

print "\n\033[1mgombnyomás: az elavult/üresbe futó válasz nem töröl üzenetet\033[0m"
# 2026-08-30: dupla gombnyomas. A masodik, uresbe futo visszavonas
# `editMessageText`-tel ATIRTA azt az uzenetet, amelyik egy SIKERES auto-inditast
# dokumentalt — a felhasznalonak ugy tunt, hogy a B4 lepes "eltunt". Ugyanez a
# STALE-PRESS agakon. Egy no-op valasz nem torolhet el egy elvegzett muvelet
# nyomat; a gombot viszont le kell venni.
yes_ "van külön 'csak a gombot veszi le' hívás" \
     grep -q '^tg_clear_markup()' "$ROOT/bin/_bridge-lib.sh"
yes_ "az editMessageReplyMarkup API-t használja" \
     grep -q 'editMessageReplyMarkup' "$ROOT/bin/_bridge-lib.sh"
# ⚠️ Darabszamot NE rogzitsunk: ahogy uj gomb-agak jonnek (pl. a beragadas-
# nemitas), a szam valtozik, es a teszt jo valtoztatasra bukna el. Azt allitjuk,
# hogy HASZNALJUK, es hogy a szoveget nem irja at senki (lasd a kovetkezo sort).
is   "több ág is csak a gombot veszi le" \
     "$(( $(grep -c 'tg_clear_markup "\$cqmid"' "$ROOT/bin/bridge-poller.sh") >= 3 ))" "1"
# A buborekban (answer_callback) a szoveg RENDBEN van — csak az UZENETET nem
# szabad atirni. Ezert kifejezetten a `tg_edit_message` hivasokra szurunk.
no_  "elavult/no-op ág nem ír át üzenetet" \
     grep -qE 'tg_edit_message.*(már nem él|már nem függőben)' "$ROOT/bin/bridge-poller.sh"

print "\n\033[1mmerge-bukás: ütközés vagy környezeti hiba?\033[0m"
# 2026-08-30: egy beragadt `.git/index.lock` miatt a merge elbukott
# ("could not write index / stash failed"), a close-tree viszont MINDEN bukast
# KONFLIKTUSnak cimkezett — es a git valodi hibajat /dev/null-ba nyelte. A
# jelentesbol nem derult ki, hogy nem is volt utkozes.
no_  "a merge hibája nincs /dev/null-ba nyelve" \
     grep -qF 'merge --no-ff -m "Merge $BRANCH" "$BRANCH" >/dev/null 2>&1' "$ROOT/bin/agent-close-tree.sh"
yes_ "a kimenetet eltesszük" \
     grep -qF '_mgout=$(git -C "$TARGET_DIR" merge' "$ROOT/bin/agent-close-tree.sh"
yes_ "az ütközést megkülönbözteti az egyéb hibától" \
     grep -qF 'MERGE NEM FUTOTT LE (nem ütközés)' "$ROOT/bin/agent-close-tree.sh"
yes_ "a beragadt zárra külön figyelmeztet" \
     grep -qF 'BERAGADT ZÁR' "$ROOT/bin/agent-close-tree.sh"

print "\n\033[1mberagadás-figyelő: a lezárult kör nem riaszt újra\033[0m"
# 2026-08-30: a mac-main-re HAMIS beragadas-riasztas jott egy 4 oraval korabban
# LEZARULT korre. Az elnyomas a `results/<id>.md` LETEZESEN mult — a teszt-fajlok
# kitakaritasa utan a rendszer ugy latta, hogy a jelentes sosem erkezett meg.
SP="$TMP/stall.json"
print '{"proba-agent":{"request":"kor-1"}}' > "$SP"
no_  "jelzés nélkül nem tudja, hogy lezárult" \
     test "$(jq -r '.["proba-agent"].answered // "-"' "$SP")" = "kor-1"
# A publikalas utani allapot:
state_edit "$SP" --arg k "proba-agent" --arg r "kor-1" '.[$k].answered = $r'
is   "a publikálás rögzíti a lezárult kört" \
     "$(jq -r '.["proba-agent"].answered' "$SP")" "kor-1"
yes_ "a figyelő az állapotot nézi, nem csak a fájlt" \
     grep -q 'answered // empty' "$ROOT/bin/_bridge-lib.sh"
yes_ "a publikálás beírja a jelzést" \
     grep -qF 'answered = $r' "$ROOT/bin/_bridge-lib.sh"

print "\n\033[1mnév-képzés és a lezárás státusz-üzenete\033[0m"
# 2026-08-29: a suffix fix `cut -c1-24` volt, ami levagta a keres-id vegen levo
# DATUMOT (`rgC1-merge-elokeszites-20260829` -> `drgC1-merge-elokeszites-2`) —
# ket kulonbozo napi keres ugyanarra a nevre kepzodott volna. A hatart most a
# szulo hosszabol szamoljuk, a 64-es keretbol.
nev() {                              # $1=szulo $2=keres-id -> a kepzett nev
  local base max
  base=$(print -r -- "$2" | tr -c 'a-zA-Z0-9' '-' | sed 's/-\+/-/g; s/-$//')
  max=$(( 64 - ${#1} - 2 )); (( max < 8 )) && max=8
  print -r -- "${1}-d${base[1,$max]}"
}
yes_ "a kérés-id dátuma nem vész el" \
     grep -q '20260829$' <<< "$(nev mac-main rgC1-merge-elokeszites-20260829)"
is   "hosszú szülővel is belefér a 64-be" \
     "$(( $(nev mac-main-hosszabb-szulonev rgC1-merge-elokeszites-20260829 | wc -c) - 1 <= 64 ))" "1"
no_  "nincs fix 24-es vágás a kódban" \
     grep -q 'cut -c1-24' "$ROOT/bin/_bridge-lib.sh"
# ⚠️ A fenti ONMAGABAN gyenge: egy `_max=24` visszairas nem tartalmazza a regi
# stringet, tehat atmenne. Azt kell allitani, hogy a hatar a SZULO hosszabol
# szamol. Ezt a lyukat mutacios teszt mutatta meg.
yes_ "a határt a szülő hosszából számolja" \
     grep -q '_max=$(( 64 - ${#parent} - 2 ))' "$ROOT/bin/_bridge-lib.sh"

# A lezaras kimenete tobbsoros; a statuszba az OSSZEGZO sor kell, nem a behuzott
# elso merge-sor — abbol a kuldo nem latta, mi tortent az agenttel.
zaro() {
  local out="$1" m
  m=$(print -r -- "$out" | grep -m1 '^tree closed:') \
    || m=$(print -r -- "$out" | grep -m1 '^closed:') \
    || m=$(print -r -- "$out" | head -1)
  print -r -- "$m"
}
OUT='  merge: worktree-proba → main
closed: mac-main-proba (merge/keep)
tree closed: mac-main-proba (2 agent)'
yes_ "a lezárás státuszába az összegző sor kerül" \
     grep -q '^tree closed:' <<< "$(zaro "$OUT")"
yes_ "a kód is az összegző sort keresi" \
     grep -q "grep -m1 '\^tree closed:'" "$ROOT/bin/_bridge-lib.sh"

print "\n\033[1mfork: worktree-hiba kezelése\033[0m"
# 2026-08-29, a kaszkad-teszt talalta: egy unoka-fork elbukott, es a naplo csak
# annyit mondott, hogy "git worktree add sikertelen" — a valodi ok (az ag mar
# letezett) nem latszott. Raadasul a `-b` altal letrehozott ARVA AG miatt az
# ujraprobalas is bukott volna: a muvelet megismetelhetetlenne valt.
yes_ "a git valódi hibaüzenete bekerül a jelentésbe" \
     grep -q 'nincs git-hibaüzenet' "$ROOT/bin/fork-agent"
yes_ "bukás után eldobja az árva ágat" \
     grep -q 'branch -D "worktree-\$NAME"' "$ROOT/bin/fork-agent"
no_  "a git hibája nincs /dev/null-ba nyelve" \
     grep -q 'worktree add -q -b "worktree-\$NAME" "\$WT" >/dev/null 2>&1' "$ROOT/bin/fork-agent"

print "\n\033[1mCLI-lezárás: a híd nyilvántartását is rendezi\033[0m"
# 2026-08-29: egy HID-inditotta agentet a CLI-rol zartam le. A bejegyzes arvan
# maradt a bridge-spawned.json-ban, a GC kesobb kiszedte, es amikor a Desktop a
# hidon akarta lezarni, jogosan azt kapta: "ezt az agentet nem a hid inditotta".
yes_ "a close-tree kivezet a híd nyilvántartásából" \
     grep -q 'bridge_unregister_spawned "\$NAME"' "$ROOT/bin/agent-close-tree.sh"
yes_ "és szól, hogy a hídon kellett volna zárni" \
     grep -q 'legközelebb a hídon zárd' "$ROOT/bin/agent-close-tree.sh"
yes_ "a close-agent eljárás is kimondja" \
     grep -q 'bridge-spawned.json' "$ROOT/close-agent.md"

print "\n\033[1mfork: a feladat send-keys-szel megy, nem a parancssorban\033[0m"
# 2026-08-29, elesben bizonyitva: a `claude --resume <sid> --fork-session`
# MEGNYITJA az orokolt beszelgetest, es a pozicionalis promptot ELDOBJA. A session
# keszen allt, a beviteli sor URES volt, a feladat sehol. Ezert nem dolgozott
# EGYETLEN hidon inditott fork sem — mikozben minden FOLYTATAS mukodott, mert
# azok send-keys-szel mennek. A beragadt agentnek send-keys-szel elkuldve
# ugyanazt a szoveget, azonnal dolgozni kezdett.
no_  "a prompt NEM kerül a parancssorba" \
     grep -q 'shell_cmd+=" \${(qq)PROMPT}"' "$ROOT/bin/fork-agent"
yes_ "a fork a közös, ellenőrzött küldést hívja" \
     grep -q 'agent_send_prompt "$NAME" "$PROMPT" "$RUN_CWD"' "$ROOT/bin/fork-agent"
yes_ "előtte megvárja, hogy a session felálljon" \
     grep -q 'capture-pane -p -t "agent-\$NAME"' "$ROOT/bin/fork-agent"
yes_ "és egy sorba vonja a többsoros feladatot" \
     grep -q 'flat="${text//$\x27\\n\x27/ }"' "$ROOT/bin/_agent-lib.sh"

print "\n\033[1mmodál-kezelés: várni kell, nem feladni\033[0m"
# 2026-08-29: az `auto_dismiss_modals` az ELSO nem-illeszkedo pane-nel feladta.
# Egy nagy beszelgetest betolto fork 5 masodperc utan meg tolt, tehat a
# "Resuming the full session" modal meg meg sem jelent — a fuggveny visszatert,
# a modal valaszolatlan maradt, es a parancssorban atadott FELADAT SOSEM
# submitolodott. Ezert nem dolgozott EGYETLEN hidon inditott fork sem.
MODLOG="$TMP/modal.log"; : > "$MODLOG"
# ⚠️ A `pane=$(tmux ...)` ALHEJBAN fut, ezert egy valtozo-szamlalo novelese
# elveszne — a csonk fajlban tartja a lepest. Ebbe elsore beleestem.
MODIDX="$TMP/modal.idx"; print 0 > "$MODIDX"
tmux() {
  case "$1" in
    has-session) return 0 ;;
    capture-pane)
      local k; k=$(( $(<"$MODIDX") + 1 )); print $k > "$MODIDX"
      case $k in
        1|2) print -r -- "betöltés..." ;;
        3)   print -r -- "Resuming the full session from where it left off" ;;
        *)   print -r -- "❯ " ;;
      esac ;;
    send-keys) print -r -- "${@:3}" >> "$MODLOG" ;;
  esac
  return 0
}
sleep() { : }                        # a teszt ne varjon valodi masodperceket
CLAUDE_AGENT_MODAL_TRIES=8 CLAUDE_AGENT_RESUME_MODE=summary auto_dismiss_modals proba
unfunction tmux sleep
yes_ "a betöltés alatt NEM adja fel, kivárja a modált" \
     grep -q '1' "$MODLOG"
yes_ "meg is nyomja rá az Entert" \
     grep -q 'Enter' "$MODLOG"

print "\n\033[1mfork-kontextus: resume full|summary\033[0m"
# A fork a szulo TELJES beszelgeteset orokli; nagy szulonel az elso kor percekig
# tart. 2026-08-29: ket teszt-agent emiatt maradt nema — a feladat megerkezett,
# de egy kort sem produkaltak, mire lezartak oket.
RSQ="$TMP/rsq"; mkdir -p "$RSQ"/{requests,results,archive}
print '{"parents":["mac-main"],"gate":"approval"}' > "$RSQ/allow.json"
rs_val() {                           # $1 = resume ertek ("" = nincs megadva)
  ( BRIDGE_DIR="$RSQ" BRIDGE_CONFIG="$RSQ/allow.json" BRIDGE_STATE="$RSQ/s.json" \
    BRIDGE_LOG="$RSQ/l" BRIDGE_SPAWNED="$RSQ/sp.json" CLAUDE_AGENT_ROOT="$TMP/proj"
    if [[ -n "$1" ]]; then jq -n --arg r "$1" '{parent:"mac-main",task:"x",resume:$r}' > "$RSQ/requests/v.json"
    else jq -n '{parent:"mac-main",task:"x"}' > "$RSQ/requests/v.json"; fi
    validate_request "$RSQ/requests/v.json" 2>/dev/null | jq -r '.resume // "HIBA"' )
}
# ⚠️ 2026-08-31: az alapertelmezes `full`-rol `none`-ra valtott. Az orokles
# KETSZER bizonyitottan a szulo SZEREPET adta at a gyereknek a sajat feladata
# helyett; az orokles azota TUDATOS valasztas (`summary` / `full`).
is   "alapértelmezés: none (friss session, nem örököl)" "$(rs_val '')"        "none"
is   "a full továbbra is kérhető"                       "$(rs_val full)"      "full"
is   "a summary elfogadva"                                "$(rs_val summary)"   "summary"
is   "érvénytelen érték elutasítva"                       "$(rs_val gyors)"     ""
yes_ "a fork tovább is adja a --summary kapcsolót" \
     grep -q 'args+=(--summary)' "$ROOT/bin/_bridge-lib.sh"

print "\n\033[1mgombos üzenet: a figyelmeztetés a gomb mellett\033[0m"
# 2026-08-29, T3: a teljes osszefoglalo CSATOLMANYKENT megy (4096 bajtos
# uzenet-korlat), a gombok viszont egy rovid uzeneten vannak. A
# "KORLATLAN JOGOSULTSAGOT KER" blokk igy a csatolmanyba kerult — a felhasznalo
# a gomb mellett NEM latta. Egy biztonsagi figyelmeztetes, amit meg kell nyitni,
# nem tolti be a szerepet.
JBP='{"mode":"fork","permission_mode":"bypassPermissions","worktree":true}'
JNW='{"mode":"fork","permission_mode":"auto","worktree":false}'
JOK='{"mode":"fork","permission_mode":"auto","worktree":true}'
yes_ "emelt jogosultságnál figyelmeztet" \
     grep -q 'KORLÁTLAN' <<< "$(bridge_button_warning "$JBP")"
yes_ "worktree nélküli forknál figyelmeztet" \
     grep -q 'NINCS SAJÁT ÁG' <<< "$(bridge_button_warning "$JNW")"
is   "szokásos kérésnél néma" "$(bridge_button_warning "$JOK")" ""
# ⚠️ A hivo `$( )`-ben veszi at, ami LEVAGJA a zaro ujsorokat — ezert a
# fuggveny nem tehet a vegere hataroloт. Ket sor = EGY ujsor.
is   "nincs záró újsor (a hívó teszi be a határolót)" \
     "$(bridge_button_warning "$JBP" | wc -l | tr -d ' ')" "1"
# A LEZARAS visszafordithatatlan agai. 2026-08-29: a `transcript: delete`
# figyelmeztetese csak a csatolmanyban volt, ezert a felhasznalo ugy nyomott
# gombot, hogy veglegesen torolt egy atiratot — nem latta elore.
JDEL='{"mode":"close","code":"drop","transcript":"delete"}'
JNOWT='{"mode":"close","code":"nowt","transcript":"keep"}'
yes_ "átirat-törlésnél figyelmeztet" \
     grep -q 'VÉGLEG TÖRLI AZ ÁTIRATOT' <<< "$(bridge_button_warning "$JDEL")"
yes_ "drop-nál figyelmeztet a munka elvesztésére" \
     grep -q 'ELDOBJA A MUNKÁT' <<< "$(bridge_button_warning "$JDEL")"
is   "ártalmatlan lezárásnál néma" "$(bridge_button_warning "$JNOWT")" ""

print "\n\033[1mjelentés-publikálás: a gyökér agentnek nincs specje\033[0m"
# 2026-08-29, a T1 regresszios teszt talalta: a hid KI TUDTA kezbesiteni a
# folytatast a parancskozpontnak, de a valasza SOSEM jutott vissza — a publikalo
# `find_spec`-et kert, a gyokernek pedig nincs specje (a start.sh inditja).
# A kor csendben a VISSZAUTON tort el.
PR="$TMP/pub"; mkdir -p "$PR/root" "$PR/res"
print '{"mac-main":{"request":"proba-kor-1"}}' > "$PR/spawned.json"
print "T1-PROBA" > "$PR/root/.bridge-result-proba-kor-1.md"
# A settle-ido miatt a frissen irt fajl varna egy kort — visszadatoljuk.
touch -t 202001010000 "$PR/root/.bridge-result-proba-kor-1.md"
(
  BRIDGE_SPAWNED="$PR/spawned.json" RES_DIR="$PR/res" \
  CLAUDE_AGENT_ROOT="$PR/root" ROOT_AGENT_NAME="mac-main" \
  bridge_publish_results
) >/dev/null 2>&1
yes_ "a gyökér jelentése publikálódik spec nélkül is" \
     test -f "$PR/res/proba-kor-1.md"
no_  "és a munkakönyvtárból elkerül" \
     test -f "$PR/root/.bridge-result-proba-kor-1.md"

print "\n\033[1mqueue-kapu: agent-indította spec\033[0m"
# A queue eddig KAPUZATLAN volt. Ha AGENT ir bele (`requested_by`), az ugyanolyan
# felugyelet nelkuli bevitel, mint a hid — ezert jovahagyast kell kernie.
# ⚠️ A teszt bizonyithatoan OFFLINE: a token MINDKET forrasat nem letezo helyre
# allitjuk, igy `tg_ready` hamis, es a spawner a FAIL-SAFE agra megy. Telegram
# feluletet nem erint. A `tmux`/`claude` csonk miatt egy esetleges ATENGEDES sem
# tudna valodi sessiont inditani.
# ⚠️ A `CLAUDE_AGENT_ROOT` beallitasa KOTELEZO: enelkul a spec mar a
# cwd-ellenorzesen elbukik, es a teszt ROSSZ OKBOL latszana zoldnek. Ez elsore
# pontosan igy tortent.
GQ="$TMP/gq"; mkdir -p "$GQ"/{new,processing,done,failed,gated,live} "$TMP/.local/bin" "$TMP/proj"
# ⚠️ A csonk NEM barhova mehet: a spawner a SAJAT elejen ujraexportalja a PATH-t
# (`export PATH="$HOME/.local/bin:...:$PATH"`), tehat egy elore fuzott sajat
# konyvtar HATRABB kerul, es a VALODI tmux/claude fut le. 2026-08-29-en pontosan
# ez tortent: a teszt eleven Remote Control sessiont inditott. Ezert a csonkot
# oda tesszuk, ahova a spawner maga nez eloszor — `$HOME/.local/bin` —, es a
# HOME-ot is a teszt-konyvtarra allitjuk.
for b in tmux claude; do
  print '#!/bin/sh' > "$TMP/.local/bin/$b"; print 'exit 1' >> "$TMP/.local/bin/$b"
  chmod +x "$TMP/.local/bin/$b"
done
run_spawner() {
  ( HOME="$TMP" \
    CLAUDE_AGENT_QUEUE="$GQ" CLAUDE_AGENT_LIVE="$GQ/live" CLAUDE_AGENT_ROOT="$TMP/proj" \
    BRIDGE_TOKEN_KC_SERVICE="nincs-ilyen-service-teszt" \
    BRIDGE_TOKEN_FILE="$TMP/nincs-ilyen-token" \
    zsh "$ROOT/claude-agent-spawner" ) >/dev/null 2>&1
}
GU="11111111-2222-3333-4444-555555555555"
jq -n --arg c "$TMP/proj" '{name:"kapu-proba-gated", cwd:$c, prompt:"x", worktree:false, requested_by:"mac-main-teszt"}' \
  > "$GQ/new/$GU.json"
run_spawner
no_  "agent-kérésre NEM indul (nincs done/ bejegyzés)" \
     test -f "$GQ/done/$GU.json"
yes_ "az indok a hiányzó kapura hivatkozik" \
     grep -q 'kapu nem elérhető' "$GQ/failed/$GU.reason"

# KONTROLL: `requested_by` NELKUL a kapunak nem szabad megszolalnia. A spawn a
# CSONKOLT tmux-on bukik el — es kulon allitjuk, hogy NEM indult session.
GU2="66666666-7777-8888-9999-000000000000"
jq -n --arg c "$TMP/proj" '{name:"kapu-proba-sima", cwd:$c, prompt:"x", worktree:false}' \
  > "$GQ/new/$GU2.json"
run_spawner
no_  "felhasználói kérés (nincs requested_by) nem kapuzódik" \
     grep -q 'kapu nem elérhető' "$GQ/failed/$GU2.reason"
no_  "a teszt NEM indított valódi sessiont" \
     tmux has-session -t agent-kapu-proba-sima

print "\n\033[1mspec-cwd: a tilde kibontása\033[0m"
# 2026-08-29: a spec literal `~/...`-t tarolt (a spawner csak INDITASKOR bontja
# ki), ezert a `merge`-os lezaras "a worktree nincs meg"-gel ATLEPTE a
# beolvasztast, es a munka a lezarando agon maradt.
is   "a ~ kibomlik"                   "$(expand_tilde '~/Proba')"        "$HOME/Proba"
is   "az abszolút út változatlan"     "$(expand_tilde '/tmp/Proba')"     "/tmp/Proba"
is   "a szó közbeni ~ marad"          "$(expand_tilde '/a/b~c')"         "/a/b~c"
# A vegpontok is kibontanak, nem csak a segedfuggveny:
is   "az agent_runtime_cwd is kibont" "$(agent_runtime_cwd '~/Proba' false proba)" "$HOME/Proba"

print "\n\033[1mworktree-takarítás (zárolt worktree)\033[0m"
# 2026-08-29: egy `drop` FELIG sikerult. A futo claude session ZAROLJA a sajat
# worktree-jet, es a `git worktree remove --force` a zarolast NEM tori at —
# ezert a git-metaadat es az ag ottmaradt, mikozben a konyvtarat egy kesobbi
# `rm -rf` mar letorolte. A fuggveny raadasul mindig 0-val tert vissza.
WTREPO="$TMP/wtrepo"
git init -q "$WTREPO" >/dev/null 2>&1
git -C "$WTREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1
mkdir -p "$WTREPO/.claude/worktrees"
git -C "$WTREPO" worktree add -q -b worktree-proba "$WTREPO/.claude/worktrees/proba" >/dev/null 2>&1
git -C "$WTREPO" worktree lock "$WTREPO/.claude/worktrees/proba" >/dev/null 2>&1
yes_ "a próba-worktree létrejött és zárolt" \
     test -f "$WTREPO/.git/worktrees/proba/locked"
remove_worktree "$WTREPO" "$WTREPO/.claude/worktrees/proba" worktree-proba
is   "a zárolt worktree könyvtára eltűnt" \
     "$(test -d "$WTREPO/.claude/worktrees/proba" && print maradt || print nincs)" "nincs"
is   "az ága is törlődött" \
     "$(git -C "$WTREPO" rev-parse --verify --quiet worktree-proba >/dev/null 2>&1 && print maradt || print nincs)" "nincs"
is   "a git-metaadat is elfogyott" \
     "$(git -C "$WTREPO" worktree list 2>/dev/null | wc -l | tr -d ' ')" "1"

print "\n\033[1mrelay: a WatchPaths egyedül nem elég\033[0m"
# ⚠️ 2026-08-31, ELES HIBA: a launchd a WatchPaths-esemenyt NEM allitja sorba, ha
# a job eppen fut — eldobja. Egy masik keres feldolgozasa kozben erkezo keres
# igy OROKRE nema maradt: se statusz, se naplo, se ujraprobalas. Merve: a keres
# az elozo statuszaval AZONOS masodpercben erkezett; egy nappal korabban ugyanez
# 5 masodperc resnel hibatlanul lefutott — a lassabb tempo elfedte a versenyt.
yes_ "a relay plistjében van StartInterval" \
     grep -q '<key>StartInterval</key>' "$ROOT/local.bridge-relay.plist.template"
yes_ "a WatchPaths is megmarad (gyors válaszidő)" \
     grep -q '<key>WatchPaths</key>' "$ROOT/local.bridge-relay.plist.template"
# A periodikus futas mellett mar KELL zar: kulonben ket peldany ugyanazt a
# kerest hajthatja vegre ketszer (egy lezaras ketszer futna le).
yes_ "a relay egypéldányos zárat kap" \
     grep -q 'RELAY_LOCK=' "$ROOT/bin/bridge-relay.sh"
yes_ "az elárvult zárat felismeri és eltávolítja" \
     grep -q 'elárvult relay-lock' "$ROOT/bin/bridge-relay.sh"
yes_ "a zárat kilépéskor elengedi" \
     grep -q "trap 'rm -rf \"\$RELAY_LOCK\"' EXIT" "$ROOT/bin/bridge-relay.sh"

print "\n\033[1mtelepítő: a szolgáltatás-betöltés ellenőrzött\033[0m"
# 2026-08-29: a `bootout` aszinkron, ezert a rogton utana jovo `bootstrap` NEMAN
# elbukott, es a bridge-poller nem toltodott be. A plist kiirodott, a telepito
# sikeresnek latszott, a Telegram-gombnyomas viszont orakon at nem jutott sehova.
# A tanulsag: a bootstrap kilepesi kodjat MEG KELL nezni.
is   "launchctl bootstrap EGYETLEN végrehajtható helyen" \
     "$(grep -cE '^[[:space:]]*launchctl bootstrap' "$ROOT/install.sh")" "1"
yes_ "a betöltést a bootstrap_service ellenőrzi" \
     grep -q 'FAILED_SERVICES' "$ROOT/install.sh"

print "\n\033[1mszintaxis\033[0m"
for f in "$ROOT"/bin/*.sh "$ROOT/bin/fork-agent" "$ROOT/claude-agent-spawner" \
         "$ROOT/install.sh" "$ROOT/start.sh"; do
  [[ -f "$f" ]] || continue
  if zsh -n "$f" 2>/dev/null; then ok "${f:t}"; else bad "${f:t}" "zsh -n elbukott"; fi
done

# ⚠️ Onellenorzes: aritmetikai hibanal (pl. ures operandus egy `$(( ))`-ben) a
# zsh a suite KOZEPEN kilep. Az exit-kod ugyan nem-nulla, tehat CI-ben nem
# hazudik zoldet — de a kimenet megszakad, es enelkul a sor nelkul nem latszana,
# hogy allitasok maradtak ki. Ha szandekosan teszel hozza tesztet, ird at.
: ${SMOKE_EXPECTED:=225}
if (( PASS + FAIL != SMOKE_EXPECTED )); then
  print -u2 "\n\033[31m⚠️  csak $((PASS + FAIL)) állítás futott le a várt $SMOKE_EXPECTED helyett — a suite félbeszakadt\033[0m"
  exit 1
fi

print ""
if (( FAIL == 0 )); then
  print "\033[32m$PASS teszt zöld\033[0m"
  exit 0
fi
print "\033[31m$FAIL bukott, $PASS zöld\033[0m"
exit 1
