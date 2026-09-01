#!/bin/zsh
# bridge-relay.sh — a Desktop által letett kéréseket veszi fel.
#
# launchd WatchPaths a ~/ClaudeProjects/bridge/requests/ könyvtárra (ugyanaz a
# minta, mint a local.agent-spawner). A Desktop device-bridge nem tud a
# ~/.claude/-ba írni és nem tud natív parancsot futtatni — a csatolt mappa az
# egyetlen csatorna, a trigger ezért ül itt, a Mac oldalán.
#
# ⚠️ A WatchPaths EGYEDUL NEM ELEG (2026-08-31-i eles hiba). A launchd nem
# allitja sorba az esemenyt, ha a job eppen fut — eldobja. Egy masik keres
# feldolgozasa kozben erkezo keres igy OROKRE nema maradt. A plist ezert
# StartInterval-t is kapott; az garantalja a feldolgozast, a WatchPaths pedig
# a gyors valaszidot.
#
# Kapu: whitelist + Telegram-értesítés csatolmánnyal. A jóváhagyást a
# bridge-poller.sh veszi át (getUpdates). `gate: audit` esetén azonnal indít,
# és utólag értesít.
emulate -L zsh
setopt nullglob
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
unset CLAUDE_CODE_OAUTH_TOKEN
unset TMUX

source "$(dirname "${(%):-%x}")/_bridge-lib.sh"
source "$(dirname "${(%):-%x}")/_agent-lib.sh"

# --- egypeldanyos zar ------------------------------------------------------
# ⚠️ Ez a lock KORABBAN SZANDEKOSAN HIANYZOTT, es az indoklas helyes is volt:
# tisztan WatchPaths-triggerelt jobnal a zar miatti kilepes egy triggert DOBNA
# EL, es az a keres soha nem indulna el. A StartInterval bevezetesevel viszont
# a feltevés megdolt: a kihagyott kor 20 masodperc mulva magatol megismetlodik,
# tehat a kihagyas mar ingyen van — a parhuzamos futas viszont nem. A statusz
# check-then-act nelkul ket peldany ugyanazt a kerest hajthatna vegre ketszer
# (egy lezaras ketszer futna le).
RELAY_LOCK="$CLAUDE_AGENT_QUEUE/bridge-relay.lock"
if ! mkdir "$RELAY_LOCK" 2>/dev/null; then
  _rpid=$(cat "$RELAY_LOCK/pid" 2>/dev/null)
  if [[ -n "$_rpid" ]] && kill -0 "$_rpid" 2>/dev/null; then
    exit 0                             # tenyleg fut egy masik peldany
  fi
  blog "WARN elárvult relay-lock eltávolítva (pid=${_rpid:-?})"
  rm -rf "$RELAY_LOCK"
  mkdir "$RELAY_LOCK" 2>/dev/null || exit 0
fi
print -r -- "$$" > "$RELAY_LOCK/pid"
trap 'rm -rf "$RELAY_LOCK"' EXIT INT TERM
rotate_log "$BRIDGE_LOG" 2>/dev/null || true

DRY_RUN=false
[[ "${1-}" == "--dry-run" ]] && DRY_RUN=true

mkdir -p "$REQ_DIR" "$RES_DIR" "$ARCHIVE_DIR"

# A Desktop ebbol tudja meg, mi elerheto -- ne hardcode-olja.
bridge_write_agents

GATE=$(bridge_cfg '.gate' 'approval')

notify() {                            # $1 = szöveg, $2 = markup
  $DRY_RUN && { print "  [dry-run] Telegram: $1"; return 0 }
  tg_ready || { blog "WARN nincs token — az értesítés kimarad"; return 0 }
  tg_send_message "$1" "${2-}" >/dev/null 2>&1
}

for f in "$REQ_DIR"/*.json; do
  id="${f:t:r}"
  # A callback_data 64 bájtos kerete miatt az azonosító rövid és szűk.
  [[ "$id" =~ '^[A-Za-z0-9._-]{1,48}$' ]] || { blog "SKIP érvénytelen id: $id"; continue }
  [[ "$(req_status "$id")" == "new" ]] || continue

  blog "REQUEST $id"
  if ! req=$(validate_request "$f" 2>"$REQ_DIR/$id.err"); then
    reason=$(<"$REQ_DIR/$id.err")
    set_status "$id" rejected "validáció: $reason"
    notify "⛔️ <b>Elutasítva</b> — <code>$id</code>"$'\n'"$reason"
    rm -f "$REQ_DIR/$id.err"
    print "elutasítva: $id ($reason)"
    continue
  fi
  rm -f "$REQ_DIR/$id.err"

  # .txt, NEM .md: a Telegram ismeretlen kiterjesztésnél eldobja a megadott
  # MIME-típust (mérve: a .md feltöltésre nem is rögzített mime_type-ot, a
  # .txt-re text/plain-t), és a beépített előnézet ilyenkor rosszul találja ki
  # a kódolást — az ékezetek elromlanak. A tartalom továbbra is markdown.
  sum="$REQ_DIR/$id.summary.txt"
  summary_text "$id" "$req" > "$sum"

  if [[ "$GATE" == "audit" ]]; then
    # Audit-ág: indul, és utólag szólunk.
    # ⚠️ Ugyanaz a versenyhelyzet, mint a felhatalmazásos ágon: a relay
    # WatchPaths-triggerelt és nincs rajta a poller egypéldányos lockja, ezért a
    # státuszt a VÉGREHAJTÁS ELŐTT kell elvenni a `new`-ból.
    set_status "$id" pending "audit mód — jóváhagyás nélkül indul"
    # Felugyelet nelkuli ag: a `bypassPermissions` itt NEM ervenyesul, a hid
    # `auto`-ra fokozza vissza (lasd _bridge-lib.sh: spawn_from_request).
    BRIDGE_APPROVAL=audit
    if run_request "$id" "$req"; then
      $DRY_RUN || { tg_ready && tg_send_document "$sum" "▶️ Elindult: <code>$id</code>" >/dev/null 2>&1 }
      print "elindítva (audit): $id"
    else
      notify "⚠️ <b>Indítás sikertelen</b> — <code>$id</code>"
      print "sikertelen: $id"
    fi
    continue
  fi

  # --- felhatalmazas: idokorlatos allando jovahagyas -------------------------
  # Ha az agentre el felhatalmazas, a folytatas/reconnect gombnyomas nelkul
  # indul. Fork es close SOHA nem esik bele.
  mode=$(print -r -- "$req" | jq -r '.mode // "fork"')
  target=$(print -r -- "$req" | jq -r '.target // empty')
  if [[ "$mode" == "continue" || "$mode" == "reconnect" ]] \
     && [[ -n "$target" ]] && guntil=$(bridge_grant_until "$target"); then
    greq=$(jq -r --arg a "$target" '(.grants // {})[$a].req // empty' "$BRIDGE_STATE" 2>/dev/null)
    # ⚠️ A statusz a VEGREHAJTAS ELOTT valtozik. A relay WatchPaths-triggerelt,
    # es nincs rajta a poller egypeldanyos lockja: ha az execute_request sokaig
    # tart, egy masodik trigger a `new` statuszt latva UJRA elinditana ugyanazt.
    set_status "$id" pending "felhatalmazás alapján indul (érvényes: $(bridge_grant_human "$guntil"))"
    if $DRY_RUN; then
      print "  [dry-run] felhatalmazás alapján indulna: $id (érvényes $(bridge_grant_human "$guntil")-ig)"
      continue
    fi
    # Felugyelet nelkuli ag: a `bypassPermissions` itt NEM ervenyesul, a hid
    # `auto`-ra fokozza vissza (lasd _bridge-lib.sh: spawn_from_request).
    BRIDGE_APPROVAL=grant
    if run_request "$id" "$req"; then
      blog "AUTO-RUN $id (felhatalmazás: $target, lejár: $(bridge_grant_human "$guntil"))"
      if tg_ready; then
        rvmk=$(jq -nc --arg r "$greq" \
          '{inline_keyboard:[[{text:"🚫 Felhatalmazás visszavonása",callback_data:("rv:" + $r)}]]}')
        tg_send_message "⚡️ <b>Felhatalmazás alapján elindult</b> — <code>$id</code>"$'\n'"<pre>$(print -r -- "$BRIDGE_LAST_OUT" | head -3)</pre>"$'\n'"A felhatalmazás eddig él: <b>$(bridge_grant_human "$guntil")</b>" "$rvmk" >/dev/null 2>&1
      fi
      print "felhatalmazás alapján elindítva: $id"
    else
      blog "AUTO-FAILED $id"
      notify "⚠️ <b>Felhatalmazás alapján indult, de elbukott</b> — <code>$id</code>"
      print "sikertelen (felhatalmazás): $id"
    fi
    continue
  fi

  # Jóváhagyásos ág: semmi nem indul a gombnyomás előtt.
  set_status "$id" pending "jóváhagyásra vár"
  # Az idoablakos gombok a `close`-on NEM jelennek meg: a lezaras kaszkadol,
  # agat es worktree-t torol, visszafordithatatlan — arra allando jovahagyas
  # nem adhato. A prefixek rovidek, mert a callback_data 64 bajt (id max 48).
  if [[ "$mode" == "close" ]]; then
    markup=$(jq -nc --arg id "$id" \
      '{inline_keyboard:[[{text:"▶️ Indítás",callback_data:("ok:" + $id)},
                          {text:"✖️ Elutasítás",callback_data:("no:" + $id)}]]}')
  else
    markup=$(jq -nc --arg id "$id" \
      '{inline_keyboard:[[{text:"▶️ Indítás",callback_data:("ok:" + $id)},
                          {text:"✖️ Elutasítás",callback_data:("no:" + $id)}],
                         [{text:"⏱ +1 óra",callback_data:("g1:" + $id)},
                          {text:"⏱ +8 óra",callback_data:("g8:" + $id)},
                          {text:"⏱ +1 nap",callback_data:("gd:" + $id)}]]}')
  fi
  if $DRY_RUN; then
    print "  [dry-run] jóváhagyásra várna: $id"
    print "  [dry-run] összefoglaló: $sum"
  elif tg_ready; then
    tg_send_document "$sum" "🤖 <b>Agent-indítási kérés</b> — <code>$id</code>" >/dev/null 2>&1
    # A message_id-t eltesszuk: LEJARATKOR ebbol tudjuk levenni a gombokat
    # (ott nincs gombnyomas, amibol kiolvashatnank).
    # A figyelmeztetes a GOMBOS uzenetre kerul, nem (csak) a csatolmanyba: amit a
    # csatolmany megnyitasa nelkul nem latsz, az nem tolti be a szerepet.
    btn="Elindítsam? <code>$id</code>"
    warn=$(bridge_button_warning "$req")
    [[ -n "$warn" ]] && btn="$warn"$'\n\n'"$btn"
    # ⚠️ A GOMBOS UZENET SZOVEGET LEMEZRE IS KIIRJUK. Eddig a "megjelent-e a
    # figyelmeztetes" ellenorzes azon mult, hogy valaki elolvassa a telefonjan —
    # felejtheto, es utolag nem visszakereshetó. A `.button.txt` fajlbol a teszt
    # PROGRAMBOL allithatja, hogy ott volt-e az atirat-torles, a munka eldobasa
    # vagy a KORLATLAN JOGOSULTSAG figyelmeztetes. Ez erosebb a szemrevetelezesnel.
    print -r -- "$btn" > "$REQ_DIR/$id.button.txt" 2>/dev/null
    resp=$(tg_send_message "$btn" "$markup" 2>/dev/null)
    mid=$(print -r -- "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)
    [[ -n "$mid" ]] && bridge_remember_msg "$id" "$mid"
  else
    blog "WARN nincs token — $id jóváhagyásra vár, de nem tudtam szólni"
  fi
  print "jóváhagyásra vár: $id"
done
