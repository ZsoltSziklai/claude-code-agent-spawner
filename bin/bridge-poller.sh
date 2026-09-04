#!/bin/zsh
# bridge-poller.sh — a Telegram-jóváhagyást veszi át és indít.
#
# A Bot API `getUpdates`-et a Mac KIFELÉ hívja, LONG POLLINGGAL
# (`BRIDGE_POLL_TIMEOUT`, ma 25 mp): a kapcsolat nyitva marad, és a gombnyomás
# ~1 másodpercen belül megérkezik. Rövid pollingnál (`timeout=0`) a nyomásról
# csak a következő 30 mp-es tickkor értesültünk volna: nincs szükség publikus végpontra, webhookra vagy bejövő
# tűzfalnyitásra. A laptop nem kerül ki sehova.
#
# ⚠️ Botonként EGYETLEN getUpdates-fogyasztó lehet. Ezért van dedikált bot: a
# cluster-bot (riasztás/heartbeat) update-folyamát nem foglaljuk le.
emulate -L zsh
setopt nullglob
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
unset CLAUDE_CODE_OAUTH_TOKEN
unset TMUX

source "$(dirname "${(%):-%x}")/_bridge-lib.sh"
source "$(dirname "${(%):-%x}")/_agent-lib.sh"
rotate_log "$BRIDGE_LOG" 2>/dev/null || true

mkdir -p "$REQ_DIR" "$RES_DIR" "$ARCHIVE_DIR"

# --- egypéldányos futás -----------------------------------------------------
# A launchd 30 mp-enként indít, de az execute_request (lezárás, fork, resume)
# ennél tovább is tarthat. Két átfedő példány UGYANAZT a callback_query-t kapná
# meg — az offset csak a futás VÉGÉN perzisztálódik —, és a `pending` guard is
# átengedné mindkettőt, mert a `spawned` státusz szintén csak az
# execute_request UTÁN íródik. Az eredmény kétszeres végrehajtás: egy lezárás
# kétszer futna le. Atomi mkdir-lock, mert macOS-en nincs flock(1).
#
# 2026-08-31 ota a relay IS kap ilyen lockot. Korabban nem kapott, azzal az
# indokkal, hogy WatchPaths-triggerelt jobnal a lock miatti kilepes egy triggert
# dobna el. Az indok helyes volt, a kovetkeztetes nem: kiderult, hogy a launchd
# a futas kozben erkezo WatchPaths-esemenyt amugy is eldobja, es ujraprobalas
# hijan a keres OROKRE nema maradt. A relay ezert StartInterval-t kapott, es
# azzal a kihagyas mar nala is ingyen van.
LOCK_DIR="$CLAUDE_AGENT_QUEUE/bridge-poller.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  lpid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null; then
    exit 0                           # tényleg fut egy másik példány
  fi
  blog "WARN elárvult poller-lock eltávolítva (pid=${lpid:-?})"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
print -r -- "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

# A jelentesek atemelese az agentek munkakonyvtarabol. A GC ELOTT fut: a GC
# ures worktree-ket takarit, es egy meg nem publikalt jelentes elveszne vele.
# A futo hid-agentek sajat session-id-janak rogzitese: ez az egyetlen pillanat,
# amikor biztosan tudjuk, melyik atirat az ove.
bridge_record_sessions

bridge_publish_results

# A lejart felhatalmazasok kiszedese. Nem a helyesseghez kell (a lejaratot
# hasznalatkor is ellenorizzuk), hanem hogy az allapotfajl ne hizzon.
bridge_grant_prune

# Takaritas: kezzel lezart agentek utan maradt szemet (turelmi idovel).
bridge_gc_spawned

# A Desktop ebbol tudja meg, mi elerheto -- ne hardcode-olja.
bridge_write_agents

# --- lejárat: a jóváhagyatlan kérés ne lógjon örökre ------------------------
MAXH=$(bridge_cfg '.max_pending_hours' '24')

# A queue-kapu ala kerult, agent-inditotta specek ugyanezzel a hataridovel
# jarnak le — kulonben orokre a `gated/` alatt ulnenek.
for g in "${CLAUDE_AGENT_QUEUE}/gated"/*.json(N); do
  gmt=$(stat -f %m "$g" 2>/dev/null) || continue
  (( ( $(date -u +%s) - gmt ) / 3600 >= MAXH )) || continue
  gid="${g:t:r}"
  mv -f "$g" "${CLAUDE_AGENT_QUEUE}/failed/$gid.json" 2>/dev/null
  print "nem érkezett jóváhagyás ${MAXH} órán belül (agent-indította kérés)" \
    > "${CLAUDE_AGENT_QUEUE}/failed/$gid.reason" 2>/dev/null
  blog "QUEUE-EXPIRED $gid"
done
now=$(date -u +%s)
for s in "$REQ_DIR"/*.status; do
  id="${s:t:r}"; id="${id%.status}"
  [[ "$(req_status "$id")" == "pending" ]] || continue
  ts=$(jq -r '.updated_at // empty' "$s" 2>/dev/null)
  [[ -n "$ts" ]] || continue
  then_s=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null) || continue
  (( (now - then_s) / 3600 >= MAXH )) || continue
  set_status "$id" expired "nem érkezett jóváhagyás ${MAXH} órán belül"
  mv -f "$REQ_DIR/$id.json" "$ARCHIVE_DIR/" 2>/dev/null
  # Itt nincs gombnyomas, amibol kiolvashatnank az uzenetet — ezert kell a relay
  # altal eltett message_id. A tg_ready-t kulon nezzuk: ez a ciklus a
  # token-ellenorzes ELOTT fut.
  if tg_ready; then
    emsg="⌛️ <b>Lejárt</b> — <code>$id</code>"$'\n'"${MAXH} órán belül nem érkezett jóváhagyás, a kérés archiválva."
    mid=$(bridge_msg_id "$id")
    if [[ -n "$mid" ]]; then
      tg_edit_message "$mid" "$emsg A gombok lekerültek." >/dev/null 2>&1
    else
      # Nincs eltett message_id -> nem volt gombos uzenet. Ez NEM elmeleti
      # eset: audit modban es felhatalmazas mellett nem kuldunk gombsort, es
      # ha a statusz-foglalas es a vegrehajtas kozott elszall a relay, a
      # keres itt `pending`-ben all a lejaratig. Szerkesztes helyett kuldjunk
      # ujat, kulonben a lejarat SZO NELKUL tortenne meg.
      tg_send_message "$emsg" >/dev/null 2>&1
    fi
    bridge_forget_msg "$id"
  fi
  print "lejárt: $id"
done

tg_ready || { print "nincs token-fájl ($BRIDGE_TOKEN_FILE) — a poller nem fut"; exit 0 }

ALLOWED_USER=$(bridge_cfg '.user_id')
[[ -n "$ALLOWED_USER" && "$ALLOWED_USER" != "null" ]] \
  || { blog "ERROR nincs user_id a configban — a poller nem fut"; exit 1 }

# Beragadt agentek: tetlen + nincs jelentes. A megelozes (utasitas +
# AskUserQuestion tiltas) LLM-fuggo, ezert kell melle eszleles is.
bridge_detect_stalled

# --- SZINTETIKUS JOVAHAGYASOK (csak teszthez) ------------------------------
# ⚠️ MIERT IGY. A regresszios kor ~15 gombnyomast igenyel egy embertol, 90 percen
# at. A kezenfekvo otlet — egy agent kattintson a Telegram Weben — rossz: az
# agent a felhasznalo TELJES Telegramjahoz ferne hozza, a UI-automatizalas
# torekeny, es a gomb MAGA a merendo dolog (emberi jovahagyas).
# Ehelyett a Telegram valaszat utanozzuk: a fajlbol olvasott jovahagyas
# UGYANOLYAN callback_query objektumma alakul, es onnan a TELJES meglevo kodut
# fut valtozatlanul — ugyanaz az elagazas, validacio, naplozas. Nem megkeruljuk
# a kaput, csak az ujjat potoljuk.
#
# NEGY KORLAT:
#   1. csak akkor el, ha a konyvtar LETEZIK (a felhasznalo hozza letre/torli)
#   2. csak `reg`-gel kezdodo keres-id — eles keresre nem gyarthato jovahagyas
#   3. minden ilyen esemeny SYNTHETIC-CALLBACK sorral a naploba kerul
#   4. a fajl felhasznalas utan TOROLODIK (egyszer hasznalatos)
#
# ⚠️ A GYUJTES A getUpdates ELOTT FUT. Eloszor utana tettem, es a teszt-fajlok
# nem fogytak el: ha a getUpdates idotullepesre fut (curl 28), a poller MAR
# KILEPETT, mielott a teszt-csatornahoz ert volna. Egy teszt-eszkoz nem fugghet
# a Telegram elerhetosegetol.
typeset -a _synth; _synth=()
TESTCB_DIR="${BRIDGE_TEST_CALLBACKS:-$CLAUDE_AGENT_QUEUE/test-callbacks}"
if [[ -d "$TESTCB_DIR" ]]; then
  for _f in "$TESTCB_DIR"/*(N.); do
    _d=$(head -1 "$_f" 2>/dev/null | tr -d '\r\n')
    rm -f "$_f"
    [[ -n "$_d" ]] || continue
    _act="${_d%%:*}"; _rid="${_d#*:}"
    if [[ "$_act" != (ok|no|g1|g8|gd|rv|nu|s8|sd|sw|qa|qn) ]]; then
      blog "SYNTHETIC-DENY ismeretlen action: $_d"
      continue
    fi
    # ⚠️ A TESZT-VOLTOT KELL BIZONYITANI, es ez ketfelekeppen tortenik:
    #
    #  a) a hid-kerések id-je beszedes (`regB1-...`) -> eleg a `reg` elotag;
    #  b) a QUEUE-KAPU gombja viszont a spec UUID-jat viszi (`qa:8C58A834-...`),
    #     amin semmilyen elotag nem latszik. Merve a naploban. Ha csak az
    #     elotagot neznenk, a G2 lepes SYNTHETIC-DENY-vel halna el — az
    #     automatizalt kor pont ott bukna, zavaros indoklassal.
    #     Ezert a `gated/<uuid>.json` spec `name` mezojet nezzuk meg: az
    #     kezdodjon `reg`-gel. Igy az eles, kapuzott keresekre EZ SEM ad
    #     jovahagyast — csak a teszt sajatjaira.
    _istest=false
    if [[ "$_act" == (qa|qn) ]]; then
      # ⚠️ A spec NEVE a szulo prefixevel jon: `mac-main-regG2-20260901i`, NEM
      # `regG2-…`. Az elso valtozat `reg*` kezdetet vart, es a G2 lepes
      # SYNTHETIC-DENY-vel allt meg. A tesztem azert volt zold, mert KITALALT
      # nevet hasznaltam a valosagos, prefixelt alak helyett.
      # A `reg` + NAGYBETU mintat keressuk barhol: a teszt-agentek regA/regB/…/regG
      # alakuak; az eles munka agentnevei ezt a mintat nem tartalmazzak.
      _gname=$(jq -r '.name // empty' "$CLAUDE_AGENT_QUEUE/gated/$_rid.json" 2>/dev/null)
      [[ "$_gname" == (reg[A-Z]*|*-reg[A-Z]*) ]] && _istest=true
    else
      [[ "$_rid" == reg* ]] && _istest=true
    fi
    if ! $_istest; then
      blog "SYNTHETIC-DENY nem teszt-kérés: $_d"
      continue
    fi
    blog "SYNTHETIC-CALLBACK data=$_d (teszt-csatorna)"
    # update_id = -1: a valodi offsetet NEM mozgatja (a max_id csak novelhet).
    _synth+=("$(jq -nc --arg d "$_d" --arg u "$ALLOWED_USER" \
      '{update_id:-1, callback_query:{id:"synthetic",
        from:{id:($u|tonumber)}, data:$d, message:{message_id:0, date:0}}}')")
  done
fi

offset=$(state_get updates_offset)
updates=$(tg_call getUpdates -d "offset=$offset" -d "timeout=$BRIDGE_POLL_TIMEOUT" -d 'allowed_updates=["callback_query"]') \
  || { blog "WARN getUpdates sikertelen"
       (( ${#_synth} )) || exit 0
       blog "a teszt-csatorna igy is feldolgozasra kerul (${#_synth} db)"
       updates='{"ok":true,"result":[]}' }
print -r -- "$updates" | jq -e '.ok == true' >/dev/null 2>&1 \
  || { blog "WARN getUpdates nem ok: $(print -r -- "$updates" | head -c 200)"
       (( ${#_synth} )) || exit 0
       updates='{"ok":true,"result":[]}' }

# A teszt-csatorna elemei UGYANABBA a listaba kerulnek: onnantol a teljes
# meglevo kodut fut valtozatlanul.
for _sj in "${_synth[@]}"; do
  updates=$(print -r -- "$updates" | jq -c --argjson e "$_sj" '.result += [$e]')
done

count=$(print -r -- "$updates" | jq '.result | length')
(( count > 0 )) || exit 0

max_id=$offset
# Process substitution, NEM pipe: a pipe a ciklust subshellbe tenné, és a
# max_id (az offset) elveszne — ugyanaz a csapda, amit az agent-kill-tree.sh
# már dokumentál.
while read -r u; do
  uid=$(print -r -- "$u" | jq -r '.update_id')
  (( uid + 1 > max_id )) && max_id=$((uid + 1))

  cq=$(print -r -- "$u" | jq -c '.callback_query // empty')
  [[ -n "$cq" ]] || continue
  from=$(print -r -- "$cq" | jq -r '.from.id // empty')
  cbid=$(print -r -- "$cq" | jq -r '.id')
  data=$(print -r -- "$cq" | jq -r '.data // empty')
  # A megnyomott UZENET azonositoja: ebbol tudjuk levenni rola a gombokat.
  # A callbackbol jon, tehat a valtozas elotti uzenetek is rendbe tehetok.
  cqmid=$(print -r -- "$cq" | jq -r '.message.message_id // empty')
  # Proveniencia: sikeres jóváhagyásnál eddig csak `SPAWNED <id>` került a
  # naplóba, amiből NEM derül ki, melyik üzenet melyik gombja nyomódott meg és
  # mikor. 2026-08-11-en pont ez tette eldönthetetlenné egy indítás eredetét.
  # msg_date = a gombos ÜZENET kelte: ha ez jóval korábbi a mostaninál, akkor
  # egy régi üzenet gombja nyomódott meg, nem a friss kérésé.
  blog "CALLBACK update_id=$uid from=$from data=$data msg_date=$(print -r -- "$cq" | jq -r '.message.date // "?"') most=$(date -u +%s)"

  # ⚠️ A LEGFONTOSABB EGYETLEN ELLENŐRZÉS: csak a saját fiók hagyhat jóvá.
  # Enélkül bárki, aki megtalálja a botot, agentet indíthatna a gépen.
  if [[ "$from" != "$ALLOWED_USER" ]]; then
    blog "DENY idegen from.id=$from data=$data"
    tg_answer_callback "$cbid" "Nem engedélyezett." >/dev/null 2>&1
    continue
  fi

  action="${data%%:*}"; id="${data#*:}"
  [[ "$id" =~ '^[A-Za-z0-9._-]{1,48}$' ]] || continue

  # ⚠️ A visszavonas a `pending` OR ELE kerul: a gomb annak a keresnek az
  # id-jet viszi, amelyik a felhatalmazast adta — az viszont mar `spawned`,
  # tehat az "elavult gombnyomas" ag nyelne el.
  # --- beragadas-nemitas: "koszi, de errol most ne szolj" ---------------------
  # Ugyanaz a kulcsolas, mint a visszavonasnal: a gomb a KERES id-jet viszi (a
  # 64 bajtos callback_data miatt), az agentet abbol keressuk vissza.
  if [[ "$action" == "s8" || "$action" == "sd" || "$action" == "sw" ]]; then
    # Tabla-vezerelt: egy uj idoablak EGY sor, nem egy uj if-ag.
    case "$action" in
      s8) msec=28800;  mlab="8 óra" ;;
      sd) msec=86400;  mlab="1 nap" ;;
      sw) msec=604800; mlab="1 hét" ;;
    esac
    mag=$(jq -r --arg r "$id" 'to_entries[] | select(.value.request == $r) | .key' \
            "$BRIDGE_SPAWNED" 2>/dev/null | head -1)
    if [[ -z "$mag" ]]; then
      tg_answer_callback "$cbid" "Nem találom, melyik agentről van szó." >/dev/null 2>&1
      blog "STALL-MUTE-NOOP (keres: $id)"
      continue
    fi
    if muntil=$(bridge_stall_mute_set "$mag" "$msec"); then
      tg_answer_callback "$cbid" "Rendben, $mlab-ig nem szólok róla." >/dev/null 2>&1
      # A szoveget MEGHAGYJUK (dokumentalja a beragadast), csak a gombokat
      # vesszuk le, es kulon uzenetben nyugtazunk.
      tg_clear_markup "$cqmid" >/dev/null 2>&1
      tg_send_message "🔕 <b>Rendben</b> — <code>$mag</code>"$'\n'"Erről az agentről <b>$mlab</b>-ig nem küldök beragadás-értesítést (eddig: <b>$(bridge_grant_human "$muntil")</b>)." >/dev/null 2>&1
      blog "STALL-MUTED $mag ($mlab, lejar: $(bridge_grant_human "$muntil"), keres: $id)"
    else
      tg_answer_callback "$cbid" "Nem sikerült." >/dev/null 2>&1
      blog "STALL-MUTE-FAILED $mag (keres: $id)"
    fi
    continue
  fi

  if [[ "$action" == "nu" ]]; then
    # A keres id-jebol keressuk vissza az agentet — a gombra a 64 bajtos keret
    # miatt ugyanugy az id kerul, nem az agentnev.
    nag=$(jq -r --arg r "$id" 'to_entries[] | select(.value.request == $r) | .key' \
            "$BRIDGE_SPAWNED" 2>/dev/null | head -1)
    if [[ -n "$nag" ]] && bridge_nudge_agent "$nag" "$id"; then
      tg_answer_callback "$cbid" "Szóltam neki." >/dev/null 2>&1
      tg_edit_message "$cqmid" "🔔 <b>Emlékeztető elküldve</b> — <code>$nag</code>"$'\n'"Ha döntésre várt, most a jelentésébe fogja írni." \
        || tg_send_message "🔔 Emlékeztető elküldve — <code>$nag</code>" >/dev/null 2>&1
      blog "NUDGED $nag (keres: $id)"
    else
      tg_answer_callback "$cbid" "Nem sikerült (nem fut?)." >/dev/null 2>&1
      tg_edit_message "$cqmid" "⚠️ Az emlékeztetőt nem sikerült elküldeni — az agent már nem fut." >/dev/null 2>&1
      blog "NUDGE-FAILED (keres: $id)"
    fi
    continue
  fi

  if [[ "$action" == "rv" ]]; then
    if ag=$(bridge_grant_revoke_by_req "$id"); then
      tg_answer_callback "$cbid" "Visszavonva." >/dev/null 2>&1
      tg_edit_message "$cqmid" "🚫 <b>Felhatalmazás visszavonva</b> — <code>$ag</code>"$'\n'"A további folytatások ismét jóváhagyást kérnek." \
        || tg_send_message "🚫 Felhatalmazás visszavonva — <code>$ag</code>" >/dev/null 2>&1
      blog "GRANT-REVOKED $ag (keres: $id)"
    else
      # ⚠️ NEM irjuk at az uzenetet: az gyakran egy SIKERES auto-inditast
      # dokumental, es egy dupla gombnyomas masodik korebol jovo no-op valasz
      # torolne a nyomat (2026-08-30: igy "tunt el" a B4 lepes). Csak a gombot
      # vesszuk le; a buborek elmondja, mi tortent.
      tg_answer_callback "$cbid" "Ez a felhatalmazás már nem él (lejárt vagy visszavonva)." >/dev/null 2>&1
      tg_clear_markup "$cqmid" >/dev/null 2>&1
      blog "GRANT-REVOKE-NOOP (keres: $id)"
    fi
    continue
  fi

  # --- QUEUE-KAPU: agent-inditotta spec jovahagyasa --------------------------
  # Ezek NEM a `requests/` alatt elnek, hanem a queue `gated/` konyvtaraban,
  # ezert a lenti `req_status` alapu elavultsag-or nem ertelmezheto rajuk.
  if [[ "$action" == "qa" || "$action" == "qn" ]]; then
    gspec="${CLAUDE_AGENT_QUEUE}/gated/$id.json"
    if [[ ! -f "$gspec" ]]; then
      tg_answer_callback "$cbid" "Ez a kérés már nem függőben." >/dev/null 2>&1
      tg_clear_markup "$cqmid" >/dev/null 2>&1
      blog "STALE-PRESS $id (queue-kapu: a spec nincs a gated/ alatt)"
      continue
    fi
    gname=$(jq -r '.name // "?"' "$gspec" 2>/dev/null)
    if [[ "$action" == "qn" ]]; then
      mv -f "$gspec" "${CLAUDE_AGENT_QUEUE}/failed/$id.json" 2>/dev/null
      print "elutasítva Telegramban (agent-indította kérés)" \
        > "${CLAUDE_AGENT_QUEUE}/failed/$id.reason" 2>/dev/null
      tg_answer_callback "$cbid" "Elutasítva." >/dev/null 2>&1
      tg_edit_message "$cqmid" "✖️ <b>Elutasítva</b> — <code>$gname</code>" \
        || tg_send_message "✖️ Elutasítva — <code>$gname</code>" >/dev/null 2>&1
      blog "QUEUE-REJECTED $id name=$gname"
      continue
    fi
    # Jovahagyas: a spec `approved` jelolessel VISSZAKERUL a new/-ba, es a
    # WatchPaths-triggerelt spawner mar kapu nelkul futtatja.
    if jq '.approved = true' "$gspec" > "$gspec.tmp" 2>/dev/null; then
      mv "$gspec.tmp" "${CLAUDE_AGENT_QUEUE}/new/$id.json" && rm -f "$gspec"
      tg_answer_callback "$cbid" "Indítom." >/dev/null 2>&1
      tg_edit_message "$cqmid" "▶️ <b>Jóváhagyva, indul</b> — <code>$gname</code>" \
        || tg_send_message "▶️ Jóváhagyva, indul — <code>$gname</code>" >/dev/null 2>&1
      blog "QUEUE-APPROVED $id name=$gname"
    else
      rm -f "$gspec.tmp"
      tg_answer_callback "$cbid" "Nem sikerült." >/dev/null 2>&1
      blog "QUEUE-APPROVE-FAILED $id name=$gname"
    fi
    continue
  fi

  st=$(req_status "$id")
  if [[ "$st" != "pending" ]]; then
    tg_answer_callback "$cbid" "Már nem függőben: $st" >/dev/null 2>&1
    # A buborek konnyen elsiklik felette — ezert a chatben is kimondjuk, es a
    # gombokat levesszuk, hogy ne lehessen ujra rajuk nyomni.
    # A szoveget MEGHAGYJUK: a jovahagyo uzenet dokumentalja, MIT hagytal jova
    # (pl. az emelt jogosultsag figyelmeztetéset). Csak a gombokat vesszuk le —
    # egy elavult gombnyomas nem torolhet el egy dokumentalo uzenetet.
    tg_clear_markup "$cqmid" >/dev/null 2>&1
    tg_send_message "⌛️ <code>$id</code> már nem függőben (<b>$st</b>) — a gombnyomás nem csinált semmit." >/dev/null 2>&1
    blog "STALE-PRESS $id (allapot=$st, data=$data)"
    continue
  fi

  case "$action" in
    no)
      set_status "$id" rejected "elutasítva Telegramban"
      mv -f "$REQ_DIR/$id.json" "$ARCHIVE_DIR/" 2>/dev/null
      tg_answer_callback "$cbid" "Elutasítva." >/dev/null 2>&1
      # Helyben atirjuk a kereset: latszik a tenye, es a gombok lekerulnek.
      # Ha az atiras nem megy (regi uzenet, torolt uzenet), kulon uzenetet
      # kuldunk — az elutasitas tenye NEM maradhat el.
      tg_edit_message "$cqmid" "✖️ <b>Elutasítva</b> — <code>$id</code>" \
        || tg_send_message "✖️ Elutasítva — <code>$id</code>" >/dev/null 2>&1
      bridge_forget_msg "$id"
      blog "REJECTED $id"
      ;;
    ok|g1|g8|gd)
      # Az idoablakos gombok ugyanazt inditjak, mint az `ok` — csak a vegen
      # felhatalmazast is adnak. A `close` sosem kap ilyen gombot (relay).
      case "$action" in
        g1) gsec=3600   ; glab="1 óra" ;;
        g8) gsec=28800  ; glab="8 óra" ;;
        gd) gsec=86400  ; glab="1 nap" ;;
        *)  gsec=0      ; glab="" ;;
      esac
      req=$(validate_request "$REQ_DIR/$id.json" 2>/dev/null) || {
        set_status "$id" failed "a kérés időközben érvénytelenné vált"
        tg_answer_callback "$cbid" "Érvénytelen kérés." >/dev/null 2>&1
        continue
      }
      # EZ az egyetlen ag, ahol a felhasznalo erre a KONKRET keresre gombot
      # nyomott — csak itt ervenyesulhet a `bypassPermissions`.
      BRIDGE_APPROVAL=button
      if run_request "$id" "$req"; then
        mv -f "$REQ_DIR/$id.json" "$ARCHIVE_DIR/" 2>/dev/null
        gnote=""
        if (( gsec > 0 )); then
          # A cel: folytatas/reconnect eseten a kereseben megnevezett agent;
          # FORK eseten a MOST letrejott agent — annak a neve csak a
          # vegrehajtas utan derul ki, ezert all itt es nem feljebb.
          gmode=$(print -r -- "$req" | jq -r '.mode // "fork"')
          if [[ "$gmode" == "continue" || "$gmode" == "reconnect" ]]; then
            gag=$(print -r -- "$req" | jq -r '.target // empty')
          else
            gag="$BRIDGE_LAST_NAME"
          fi
          if [[ -n "$gag" ]] && guntil=$(bridge_grant_set "$gag" "$gsec" "$id"); then
            gnote=$'\n'"⏱ Felhatalmazás <b>$glab</b>-ra: <code>$gag</code> folytatásai eddig jóváhagyás nélkül indulnak: <b>$(bridge_grant_human "$guntil")</b>"
            blog "GRANT-SET $gag ($glab, lejar: $(bridge_grant_human "$guntil"), keres: $id)"
          else
            gnote=$'\n'"⚠️ A felhatalmazást nem sikerült beállítani (nincs cél-agent)."
            blog "GRANT-FAILED $id"
          fi
        fi
        tg_answer_callback "$cbid" "Elindítva.${glab:+ (+$glab)}" >/dev/null 2>&1
        tg_edit_message "$cqmid" "▶️ <b>Elindítva</b> — <code>$id</code>${glab:+  ·  ⏱ +$glab}" >/dev/null 2>&1
        bridge_forget_msg "$id"
        tg_send_message "▶️ Elindult — <code>$id</code>"$'\n'"<pre>$(print -r -- "$BRIDGE_LAST_OUT" | head -5)</pre>"$'\n'"Csatlakozás: <code>$(attach_hint "$BRIDGE_LAST_NAME")</code>$gnote" >/dev/null 2>&1
        blog "SPAWNED $id"
      else
        tg_answer_callback "$cbid" "Indítás sikertelen." >/dev/null 2>&1
        tg_edit_message "$cqmid" "⚠️ <b>Indítás sikertelen</b> — <code>$id</code>" >/dev/null 2>&1
        bridge_forget_msg "$id"
        tg_send_message "⚠️ Indítás sikertelen — <code>$id</code>"$'\n'"<pre>$(print -r -- "$BRIDGE_LAST_OUT" | tail -3)</pre>" >/dev/null 2>&1
        blog "FAILED $id"
      fi
      ;;
  esac
done < <(print -r -- "$updates" | jq -c '.result[]')

# Offset perzisztálása — enélkül minden körben újrafeldolgoznánk.
state_set updates_offset "$max_id"
