#!/bin/zsh
# Cascade close: NAME + descendants.
#
#   agent-close-tree.sh <NAME> <merge|drop|nowt> [merge|keep]
#                              ^ kód-művelet      ^ beszélgetés (default: keep)
#
# A fa a spec `parent` mezőjéből épül (hiányában leghosszabb-prefix
# származtatás), és MÉLYSÉG SZERINT, a legmélyebbtől fölfelé zárul — így egy
# unoka munkája még a szülő ágába kerül, mielőtt a szülő maga beolvad.
#
# A kód-merge a SZÜLŐ ágába megy, nem a main-be, és a szülő worktree-jében fut:
# `git -C <szülő-worktree> merge`. Így nincs `git checkout`, a valódi repó nem
# vált ágat a felhasználó háta mögött.
emulate -L zsh
setopt nullglob
set -u
source "$(dirname "${(%):-%x}")/_agent-lib.sh"

# ⚠️ A nev VALIDALASA kotelezo, mielott grep-mintaba kerul (list_descendants).
# Enelkul egy `.*` argumentum — elgepeles vagy egy slash parancsot ertelmezo
# modell hibaja — MINDEN futo agentre kiterjesztene a kaszkadot: a hibas bemenet
# nem megallitana, hanem hatokort tagitana. A spawner es a hid mar validal, a
# kaszkad-parancsok eddig nem.
ROOT="${1:?usage: $0 <NAME> <merge|drop|nowt> [merge|keep]}"
[[ "$ROOT" =~ '^[a-zA-Z0-9_-]{3,64}$' ]] || {
  print -u2 "érvénytelen agent-név: $ROOT (megengedett: [a-zA-Z0-9_-]{3,64})"; exit 2 }
ACTION="${2:?usage: $0 <NAME> <merge|drop|nowt> [merge|keep]}"
CTX_ACTION="${3:-keep}"
ROOT="${ROOT#agent-}"

case "$ACTION" in merge|drop|nowt) ;;
  *) print -u2 "ERROR: invalid code action: $ACTION"; exit 2;;
esac
case "$CTX_ACTION" in merge|keep) ;;
  *) print -u2 "ERROR: invalid context action: $CTX_ACTION"; exit 2;;
esac

MERGE_SESSIONS="$(dirname "${(%):-%x}")/merge-sessions.sh"

# ---------------------------------------------------------------------------
# Csomópontok + a fa
# ---------------------------------------------------------------------------

typeset -a NODES
NODES=("${(@f)$(list_descendants "$ROOT")}")
NODES=("${(@)NODES:#}")            # üres sorok ki
if (( ${#NODES} == 0 )); then
  # ⚠️ 2026-08-31: itt regen FELTETEL NELKUL kileptunk, es a nyilvantartas-
  # kivezetes sosem futott le. Egy magatol meghalt agent (osszeomlas, reboot,
  # kezi kill) igy OROKRE bent ragadt a `bridge-spawned`-ben: a nev foglalt
  # maradt, es a "kiurult-e a nyilvantartas" ellenorzes hamis eredmenyt adott.
  # A session hianya nem ok arra, hogy az allapotot koszosan hagyjuk.
  _cleaned=0
  for _bl in "$CLAUDE_AGENT_QUEUE/bin/_bridge-lib.sh" "${0:A:h}/_bridge-lib.sh"; do
    [[ -r "$_bl" ]] && { source "$_bl"; break }
  done
  if typeset -f bridge_is_spawned >/dev/null && bridge_is_spawned "$ROOT"; then
    bridge_unregister_spawned "$ROOT"
    print "  $ROOT: nem futott, de a híd nyilvántartásából kivezetve"
    _cleaned=1
  fi
  if typeset -f fork_tree_forget >/dev/null; then
    fork_tree_forget "$ROOT" && _cleaned=1
  fi
  if (( _cleaned )); then
    print "Nincs futó agent ezzel a névvel: $ROOT — az elárvult állapot eltakarítva"
  else
    print "Nincs futó agent ezzel a névvel: $ROOT"
  fi
  exit 0
fi

# A szülő gyakran NEM zárul le (egy gyereket zárunk a futó szülőbe) — ezért a
# névtér az összes futó agent, nem csak a lezárandó részfa.
typeset -a UNIVERSE
UNIVERSE=("${(@f)$(list_running_agents)}")
UNIVERSE=("${(@)UNIVERSE:#}")
UNIVERSE+=("${NODES[@]}")
UNIVERSE=("${(@u)UNIVERSE}")

typeset -A SPEC_OF PARENT_OF
# Ha egy csomópontba már fűztünk gyerek-beszélgetést, a következő szinten NEM
# az élő átiratából kell dolgozni, hanem a fűzés eredményéből — különben a
# mélyebb szintek munkája kiesne a láncból. Explicit láncolás, nem mtime.
typeset -A MERGED_SID
spec_for() {                       # memoizált find_spec
  local n="$1"
  if [[ -z "${SPEC_OF[$n]-}" ]]; then
    SPEC_OF[$n]="$(find_spec "$n")"
    [[ -z "${SPEC_OF[$n]}" ]] && SPEC_OF[$n]="-"
  fi
  [[ "${SPEC_OF[$n]}" == "-" ]] && return 1
  print -r -- "${SPEC_OF[$n]}"
}

field_of() {                       # $1=név $2=mező
  local s; s=$(spec_for "$1") || return 1
  read_spec_field "$s" "$2"
}

# Szülő: elsősorban a spec `parent` mezője. Hiányában leghosszabb-prefix a
# névtérből — de ez NEM megbízható önmagában, mert a spawner ütközéskor
# `-2`…`-99` suffixet ad (mac-main-web-2 nem gyereke a mac-main-web-nek),
# ezért az explicit mező az elsődleges.
parent_for() {
  local n="$1"
  if [[ -n "${PARENT_OF[$n]-}" ]]; then
    [[ "${PARENT_OF[$n]}" == "-" ]] && return 1
    print -r -- "${PARENT_OF[$n]}"; return 0
  fi
  local p; p=$(field_of "$n" parent 2>/dev/null) || p=""
  if [[ -z "$p" ]]; then
    local cand best=""
    for cand in "${UNIVERSE[@]}"; do
      [[ "$cand" == "$n" ]] && continue
      [[ "$n" == "$cand-"* ]] || continue
      (( ${#cand} > ${#best} )) && best="$cand"
    done
    p="$best"
  fi
  PARENT_OF[$n]="${p:--}"
  [[ -z "$p" ]] && return 1
  print -r -- "$p"
}

depth_of() {                       # hány ős — a rendezéshez
  local n="$1" d=0 i=0 p
  while (( i < 32 )); do
    p=$(parent_for "$n") || break
    [[ -z "$p" ]] && break
    d=$((d + 1)); n="$p"; i=$((i + 1))
  done
  print -r -- "$d"
}

# Mélység szerint csökkenő sorrend: a legmélyebb csomópont zárul először.
typeset -a ORDERED
ORDERED=("${(@f)$(for n in "${NODES[@]}"; do print -r -- "$(depth_of "$n")	$n"; done | sort -rn -k1,1 | cut -f2-)}")

# ---------------------------------------------------------------------------
# Beszélgetés-merge
# ---------------------------------------------------------------------------

# A gyerek transcriptjét a SZÜLŐ projekt-könyvtárába fűzi. Az eredetiket nem
# bántja; a merge-sessions.sh új fájlt gyárt.
# $1=gyerek $2=szülő $3=gyerek futásidejű cwd $4=gyerek session id
# ⚠️ A gyerek cwd-jét és session id-ját a HÍVÓ oldja fel, MÉG a kód-művelet
# előtt: a worktree eltávolítása után a futásidejű cwd (és vele a
# transcript-könyvtár) már nem lenne feloldható.
merge_context() {
  local child="$1" parent="$2" c_rt="$3" c_sid="$4"
  local p_cwd p_wt p_rt p_sid c_dir p_dir

  [[ -n "$c_rt" && -n "$c_sid" ]] || { print "  ctx: a gyereknek nincs transcriptje"; return 0; }
  p_cwd=$(field_of "$parent" cwd 2>/dev/null)  || { print "  ctx: a szülőnek nincs spec-je ($parent)"; return 0; }
  p_wt=$(field_of "$parent" worktree 2>/dev/null) || p_wt=false

  p_rt=$(agent_runtime_cwd "$p_cwd" "$p_wt" "$parent")
  # Ha a szülőbe már fűztünk (több gyerek esetén), az eredményre fűzünk tovább.
  p_sid="${MERGED_SID[$parent]-}"
  if [[ -z "$p_sid" ]]; then
    p_sid=$(agent_session_id "$parent" 2>/dev/null) \
      || p_sid=$(latest_session_id "$p_rt" 2>/dev/null) \
      || { print "  ctx: a szülőnek nincs transcriptje"; return 0; }
  fi

  c_dir=$(transcript_dir "$c_rt"); p_dir=$(transcript_dir "$p_rt")
  local c_file="$c_dir/$c_sid.jsonl" p_file="$p_dir/$p_sid.jsonl"
  [[ -r "$c_file" && -r "$p_file" ]] || { print "  ctx: hiányzó transcript-fájl"; return 0; }

  # Fork-dedup: ha a gyerek forkkal készült, a transcriptje a szülő
  # előzményének MÁSOLATÁVAL kezdődik — azt kihagyjuk, különben duplikálódna.
  # (Sima /new-agent gyereknél nincs átfedés, ilyenkor ez no-op.)
  local tmp_id out_id pu
  tmp_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  out_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  pu=$(jq -r 'select(.uuid) | .uuid' "$p_file" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -c --argjson pu "$pu" '
    ($pu | map({(.): true}) | add // {}) as $seen
    | select((.uuid == null) or (($seen[.uuid] // false) | not))
  ' "$c_file" > "$p_dir/$tmp_id.jsonl"

  local kept total
  kept=$(wc -l < "$p_dir/$tmp_id.jsonl"); total=$(wc -l < "$c_file")
  if (( kept == 0 )); then
    rm -f "$p_dir/$tmp_id.jsonl"
    print "  ctx: a gyerekben nincs új rekord a szülőhöz képest — kihagyva"
    return 0
  fi

  if "$MERGE_SESSIONS" "$p_sid" "$tmp_id" "$p_dir" "$out_id" >/dev/null 2>&1; then
    MERGED_SID[$parent]="$out_id"     # a következő szint erre fűz tovább
    print "  ctx: $child → $parent  (új: $out_id, $kept/$total rekord)"
  else
    print "  ctx: MERGE SIKERTELEN ($child → $parent)"
  fi
  rm -f "$p_dir/$tmp_id.jsonl"
}

# ---------------------------------------------------------------------------
# Egy csomópont lezárása
# ---------------------------------------------------------------------------

close_one() {
  local NAME="$1"
  # Unregister ELŐSZÖR — különben a child watchdog visszahozhatná a tmux-kill
  # és a registry-takarítás közti ablakban.
  unregister_agent "$NAME"

  # ⚠️ 2026-09-01: a hid-nyilvantartasbol valo kivezetes a fuggveny VEGEN allt,
  # ezert a "nincs spec" ag (lentebb, `return`-nel) TELJESEN kihagyta. Az agent
  # eltunt, a bejegyzese bent maradt: a nev foglalt maradt, es a "kiurult-e a
  # nyilvantartas" ellenorzes hamis eredmenyt adott. Csonk-sessionnel
  # reprodukalva. A kivezetes ezert ELORE kerult — minden agra vonatkozik.
  for _bl in "$CLAUDE_AGENT_QUEUE/bin/_bridge-lib.sh" "${0:A:h}/_bridge-lib.sh"; do
    [[ -r "$_bl" ]] && { source "$_bl"; break }
  done
  typeset -f bridge_grant_revoke_by_agent >/dev/null && bridge_grant_revoke_by_agent "$NAME"
  typeset -f fork_tree_forget            >/dev/null && fork_tree_forget "$NAME"
  if typeset -f bridge_is_spawned >/dev/null && bridge_is_spawned "$NAME"; then
    bridge_unregister_spawned "$NAME"
    print "  $NAME: a híd nyilvántartásából is kivezetve"
    print -u2 "  megjegyzés: ezt az agentet a HÍD indította — legközelebb a hídon zárd (action: close), hogy a küldő is értesüljön"
  fi

  local SPEC CWD WT WT_PATH BRANCH PARENT
  if ! SPEC=$(spec_for "$NAME"); then
    print "no spec found for $NAME — only killing tmux"
    kill_one_tmux "$NAME"
    return
  fi
  # ⚠️ A spec literal `~`-t tarolhat (a spawner csak INDITASKOR bontja ki), es a
  # `git -C ~/...` egy nem letezo utra mutatna.
  CWD=$(expand_tilde "$(read_spec_field "$SPEC" cwd)")
  WT=$(read_spec_field "$SPEC" worktree)
  WT_PATH=$(worktree_path "$CWD" "$WT" "$NAME")
  BRANCH="worktree-$NAME"
  PARENT=$(parent_for "$NAME") || PARENT=""

  # A futásidejű cwd-t és a session id-t MOST oldjuk fel — a kód-művelet
  # eltávolítja a worktree-t, azután a transcript-könyvtár nem lenne
  # visszakereshető (a worktree cwd-jéből származik).
  # Elsődlegesen a FUTÓ folyamat állapotfájljából — a közös cwd-n osztozó
  # (worktree nélküli) gyerek és szülő különben ugyanazt az átiratot kapná.
  local RT SID
  RT=$(agent_runtime_cwd "$CWD" "$WT" "$NAME")
  SID="${MERGED_SID[$NAME]-}"
  if [[ -z "$SID" ]]; then
    SID=$(agent_session_id "$NAME" 2>/dev/null) || SID=$(latest_session_id "$RT" 2>/dev/null) || SID=""
  fi

  case "$ACTION" in
    merge)
      local MERGED=false
      if [[ -n "$WT_PATH" ]]; then
        # Piszkos munka mentése, hogy a --force remove ne vigye el.
        # ⚠️ A `git status` BUKASA (serult repo, zarolt index) ures kimenetet ad,
        # amit a regi feltetel "tiszta"-nak olvasott — es a lezaro `rm -rf`-fel
        # elvitte volna a worktree-t. Kulon nezzuk a kilepesi kodot.
        local dirty_out dirty_rc
        dirty_out=$(git -C "$WT_PATH" status --porcelain 2>&1); dirty_rc=$?
        if (( dirty_rc != 0 )); then
          print -u2 "  ✗ $NAME: a 'git status' elbukott a worktree-ben — NEM nyúlok hozzá"
          print -u2 "     $(print -r -- "$dirty_out" | tail -1)"
          kill_one_tmux "$NAME"
          print "closed: $NAME (leállítva, a worktree érintetlen)"
          return
        fi
        if [[ -n "$dirty_out" ]]; then
          # ⚠️ A KIMENETELT ELLENORIZNI KELL. Ha az auto-commit elbukik (nincs
          # user.email, index.lock, tele diszk), a merge a REGI agcsucsot viszi
          # at — sikerrel —, es a lentebbi remove_worktree `--force` + `rm -rf`
          # letorli a commitolatlan munkat. Egy elnyelt hibakod itt kozvetlenul
          # adatvesztesse fordul. A `| tail -1` ezt ketszeresen elrejtette: az
          # exit code a tail-e lett, a sikeruzenet pedig feltetel nelkul ment ki.
          local cout crc
          if ! git -C "$WT_PATH" add -A 2>&1; then
            print -u2 "  ✗ $NAME: a 'git add -A' elbukott a worktree-ben — NEM nyulok hozza"
            print -u2 "     a worktree es a commitolatlan munka a helyen marad: $WT_PATH"
            kill_one_tmux "$NAME"
            print "closed: $NAME (leallitva, a munka megorizve)"
            return
          fi
          cout=$(git -C "$WT_PATH" commit -m "WIP from agent $NAME" --no-verify 2>&1); crc=$?
          if (( crc != 0 )); then
            print -u2 "  ✗ $NAME: az auto-commit elbukott — NEM mergelek es NEM torlok semmit"
            print -u2 "     $(print -r -- "$cout" | tail -2)"
            print -u2 "     a commitolatlan munka a helyen marad: $WT_PATH"
            kill_one_tmux "$NAME"
            print "closed: $NAME (leallitva, a munka megorizve)"
            return
          fi
          print "  auto-committed uncommitted changes in $NAME worktree"
        fi

        # Merge-cél: a SZÜLŐ ága, ha a szülőnek van worktree-je; különben main.
        local TARGET_DIR="" TARGET_DESC=""
        if [[ -n "$PARENT" ]]; then
          local p_cwd p_wt p_path
          p_cwd=$(field_of "$PARENT" cwd 2>/dev/null) || p_cwd=""
          p_wt=$(field_of "$PARENT" worktree 2>/dev/null) || p_wt=false
          if [[ -n "$p_cwd" ]]; then
            p_path=$(worktree_path "$p_cwd" "$p_wt" "$PARENT")
            if [[ -n "$p_path" ]]; then
              TARGET_DIR="$p_path"; TARGET_DESC="worktree-$PARENT"
            fi
          fi
        fi
        if [[ -z "$TARGET_DIR" ]]; then
          local TOP CUR
          TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
          CUR=$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null)
          if [[ -n "$TOP" && "$CUR" == "main" ]]; then
            TARGET_DIR="$TOP"; TARGET_DESC="main"
          else
            # NEM váltunk ágat a felhasználó háta mögött.
            print -u2 "  merge KIHAGYVA ($NAME): a repóban '$CUR' van kicsekkolva, nem 'main'"
            print -u2 "     a worktree és a(z) $BRANCH ág MEGMARAD; kézzel: git -C ${TOP:-$CWD} merge --no-ff $BRANCH"
          fi
        fi

        if [[ -n "$TARGET_DIR" ]]; then
          # ⚠️ A CEL EGY ELO MUNKAKONYVTAR: a szulo agent EBBEN dolgozik tovabb.
          # Ezert (a) nem inditunk merge-et, ha ott mar folyik egy, es (b)
          # konfliktusnal ABORTALUNK, nem hagyjuk ott a felkesz allapotot.
          #
          # A korabbi valtozat konfliktusnal egyszeruen visszatert: a celban
          # ottmaradt a MERGE_HEAD es a konfliktus-markerek, a szulo pedig
          # gyanutlanul dolgozott tovabb egy felkesz merge-ben. Ennel is rosszabb,
          # hogy a kaszkad KOVETKEZO gyereke ugyanabba a celba mergelt volna: a
          # git a folyamatban levo muvelet miatt bukik, amit HAMISAN szinten
          # konfliktuskent jelentettunk — egy konfliktus megmergezte az egesz
          # hatralevo kaszkadot.
          # ⚠️ --absolute-git-dir, NEM --git-dir: normal reponal az utobbi RELATIV
          # `.git`-et ad, amit a `[[ -e "$gdir/MERGE_HEAD" ]]` a SCRIPT sajat
          # cwd-jehez kepest ertekelne ki — worktree-celnal veletlenul jo volt
          # (ott abszolut), fo-repo celnal viszont vakon futott. Merve 2026-08-26.
          local gdir
          gdir=$(git -C "$TARGET_DIR" rev-parse --absolute-git-dir 2>/dev/null)
          if [[ -n "$gdir" && -e "$gdir/MERGE_HEAD" ]]; then
            print -u2 "  ⚠️ $NAME: a célban ($TARGET_DESC) MÁR folyamatban van egy merge"
            print -u2 "     nem indítok újat; oldd fel ott, majd: git -C ${(qq)TARGET_DIR} merge --no-ff ${(qq)BRANCH}"
            print -u2 "     a worktree és a(z) $BRANCH ág megmarad"
            kill_one_tmux "$NAME"
            print "closed: $NAME (kihagyva, folyamatban lévő merge)"
            return
          fi

          # ⚠️ A git VALODI hibaja kell. 2026-08-30: egy beragadt
          # `.git/index.lock` miatt a merge "could not write index / stash failed"
          # -del bukott — a kod viszont MINDEN bukast KONFLIKTUSnak cimkezett, es
          # a jelentesbol nem derult ki az igazi ok. Fel oraba kerult kideriteni,
          # hogy nem is volt utkozes (a `merge-tree` tisztan mergelt volna).
          local _mgout _mgrc
          _mgout=$(git -C "$TARGET_DIR" merge --no-ff -m "Merge $BRANCH" "$BRANCH" 2>&1); _mgrc=$?
          if (( _mgrc == 0 )); then
            MERGED=true
            print "  merge: $BRANCH → $TARGET_DESC"
          else
            # Visszaallitjuk a celt, hogy a szulo hasznalhato maradjon. A gyerek
            # aga es worktree-je MEGMARAD, tehat semmi nem vesz el — csak kezzel
            # kell osszefesulni.
            if [[ -n "$gdir" && -e "$gdir/MERGE_HEAD" ]]; then
              git -C "$TARGET_DIR" merge --abort 2>/dev/null \
                && print "  (a cél visszaállítva: merge --abort)" \
                || print -u2 "  ⚠️ a 'merge --abort' nem sikerült — nézd meg kézzel: $TARGET_DIR"
            fi
            # Utkozes VAGY egyeb git-hiba? A kettot kulon kell mondani: az elsot
            # kezzel kell osszefesulni, a masodik altalaban kornyezeti (beragadt
            # lock, jogosultsag, tele diszk) es MAGATOL elmulhat.
            if print -r -- "$_mgout" | grep -qiE 'conflict|automatic merge failed'; then
              print -u2 "  MERGE-KONFLIKTUS: $BRANCH → $TARGET_DESC"
            else
              print -u2 "  MERGE NEM FUTOTT LE (nem ütközés): $BRANCH → $TARGET_DESC"
              print -u2 "     git: $(print -r -- "$_mgout" | head -2 | tr '\n' ' ')"
              # A leggyakoribb kornyezeti ok: egy felbeszakadt git-parancs
              # ottfelejtett zarja. Ezt kimondjuk, mert a git uzenete
              # ("could not write index") errol semmit nem arul el.
              if [[ -n "$gdir" && -e "$gdir/index.lock" ]]; then
                print -u2 "     ⚠️ BERAGADT ZÁR: $gdir/index.lock — ha nem fut git a repón, törölhető"
              fi
            fi
            print -u2 "     a cél érintetlen maradt; a worktree és az ág megmarad"
            print -u2 "     kézzel: git -C ${(qq)TARGET_DIR} merge --no-ff ${(qq)BRANCH}"
            kill_one_tmux "$NAME"
            # A hivo (hid/slash) nem lathat sikert ott, ahol a kert merge NEM
            # tortent meg: a session lezarult, de a munka az agban maradt. A fa
            # vegen ezert 3-mal lepunk ki (1 = hasznalati hiba).
            CONFLICTS=$((CONFLICTS + 1))
            print "closed: $NAME (merge, KONFLIKTUS — az ág megmaradt, a merge nem futott le)"
            return
          fi
        fi
        # ⚠️ CSAK SIKERES MERGE UTAN torlunk. A korabbi valtozat a "merge
        # KIHAGYVA" agon is idejutott: torolte a `worktree-<nev>` agat ES a
        # worktree-t, benne az imenti auto-committal — az reflogba esett, a
        # kiirt kezi merge-parancs pedig egy mar nem letezo agra mutatott.
        if $MERGED; then
          remove_worktree "$CWD" "$WT_PATH" "$BRANCH"
        else
          print -u2 "  $NAME: a worktree és az ág MEGMARAD (nem volt sikeres merge): $WT_PATH"
        fi
      elif [[ "$WT" == "true" ]]; then
        print "  $NAME: worktree=true, de a worktree nincs meg — nincs mit mergelni"
      else
        print "  $NAME: nincs worktree (saját repó vagy közös cwd) — a kód-merge nem értelmezett"
      fi
      ;;
    drop)
      if [[ -n "$WT_PATH" ]]; then
        # A visszateresi erteket MOST MAR nezzuk: a `drop` eddig akkor is
        # sikeresnek latszott, ha a zarolt worktree metaadata es az ag ottmaradt.
        remove_worktree "$CWD" "$WT_PATH" "$BRANCH" \
          || print -u2 "  $NAME: a drop csak RESZBEN sikerult — nezd meg: git -C $CWD worktree list"
      fi
      ;;
    nowt) : ;;
  esac

  if [[ "$CTX_ACTION" == "merge" ]]; then
    if [[ -n "$PARENT" ]]; then
      merge_context "$NAME" "$PARENT" "$RT" "$SID"
    else
      print "  ctx: nincs ismert szülő ($NAME) — a beszélgetés a helyén marad"
    fi
  fi

  kill_one_tmux "$NAME"
  # ⚠️ Ha a HID inditotta ezt az agentet, a hid nyilvantartasabol is ki kell
  # vezetni — kulonben a bejegyzes arvan marad, es egy kesobbi hid-lezaras
  # "ezt az agentet nem a hid inditotta" hibaval utasitja el (a GC addigra mar
  # kiszedte). 2026-08-29: pontosan ez tortent, mert a CLI-rol zartam le egy
  # hid-inditotta agentet. A CLI vegkijarat marad, de az allapotot rendben hagyja.
  # ⚠️ A kivezetes (hid-nyilvantartas, felhatalmazas, fork-fa) 2026-09-01 ota a
  # fuggveny ELEJEN tortenik — lasd ott. Itt AZERT nincs masodpeldany, mert a
  # "nincs spec" ag korai `return`-nel kilep, es egy vegen allo blokkot
  # teljesen kihagyna: az agent eltunt, a bejegyzese bent maradt.
  print "closed: $NAME ($ACTION/$CTX_ACTION)"
}

COUNT=0
CONFLICTS=0
for NAME in "${ORDERED[@]}"; do
  [[ -z "$NAME" ]] && continue
  close_one "$NAME"
  COUNT=$((COUNT + 1))
done
print "tree closed: $ROOT ($COUNT agent, sorrend: legmélyebb → legfelső)"
if (( CONFLICTS > 0 )); then
  print -u2 "MERGE-KONFLIKTUS $CONFLICTS agentnél — a lezárás megtörtént, a merge NEM"
  exit 3
fi
