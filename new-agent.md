---
description: Háttér agent indítása. EZ AZ EGYETLEN megengedett út — soha ne írj spec-JSON-t közvetlenül az agent-queue/new/ alá. Ha TE döntöttél az indításról (nem a felhasználó kérte), a spec `requested_by` mezőjét ki kell töltened: az agent-indította kérés Telegram-jóváhagyáshoz kötött. Amit elindítasz, azt fel is ügyeled és lezárod (/close-agent) — egy elindult agent nem pörög magától.
---

Új háttér Remote Control session-t indítasz a felhasználónak. A spec JSON ~2 mp múlva spawnolódik egy launchd watcher által, és megjelenik a mobil Claude app **Code** tabján.

## SZABÁLY — picker csak Step 0-ban, MINDEN MÁS chat-question

**`AskUserQuestion` tool csak EGYETLEN HELYEN engedett**: a Step 0 "Default vagy Egyéni" kérdés. Mindenhol máshol — Step 1-4 mezők, validáció hibák, classifier-blokkolt értékek, alternative-kínálás — **TILOS** pickert hívni. Chat-ben kérdezz szabad-szöveggel.

**Tilos:** alternatíva-picker kínálása ha az aktuálisan választott érték valamiért nem megy (pl. auto-mode classifier blokk). Ilyenkor chat-ben kérdezz vissza, nem picker. A user **kifejezetten kérte** hogy soha ne ugorjon fel batched/alternative picker.

## 0.a lépés — KÖTELEZŐ ELSŐ LÉPÉS: parent-név lekérdezés

A flow LEGELSŐ tooljaként hívd a Bash tool-t és tárold a parent nevét:

```bash
echo "PARENT=${CLAUDE_AGENT_NAME:-mac}"
```

Az output `PARENT=mac-main` formátumú lesz (vagy `mac-main-x7k2a` ha nested agent). Jegyezd meg ezt — minden generált / sanitize-olt névnek `${PARENT}-` prefix-szel KELL kezdődnie.

**Bug fenntartására:** ha bármilyen mezőre saját nevet generálsz vagy sanitizálsz (1. lépés, vagy Default mód), a JSON-ba írt `name` mezőnek MINDIG `${PARENT}-<base>` formátumúnak kell lennie. Ha nem ezzel kezdődik, javítsd ki a JSON kiírás ELŐTT.

## 0. lépés — Default vagy Egyéni?

Chat-ben **PONTOSAN AZ ALÁBBI SZÖVEGGEL, SOR-SORRÓL, SUBBULLET-ELÉSEKKEL EGYÜTT — TILOS RÖVIDÍTENI**:

> *"Default indítás (gyors) vagy egyéni végigkérdezéssel?
> 1. Default:
>    - név: `${PARENT}-x<random4>` (pl. `mac-main-x7k2a`)
>    - cwd: `~/ClaudeProjects`
>    - prompt: `Szia, Claude!`
>    - model: `opus` (a legfrissebb Opus, default context), effort: `high`, permission: `auto`, worktree: `Nem`
> 2. Egyéni — végigkérdezem a 7 mezőt"*

Feldolgozás:
- **`1` / `default`** → Default mód
- **`2` / `egyéni`** → Egyéni mód végigkérdezéssel
- **Bármi egyéb** → chat-ben kérdezz vissza

**Ha "Default"** → ugord át az 1–4 lépést, használd: name=`${PARENT}-x<hash>`, cwd=`~/ClaudeProjects`, prompt=`Szia, Claude!`, model=`opus`, effort=high, permission=auto, worktree=Nem; menj a 5. lépésre.

**Ha "Egyéni"** → folytatás az 1. lépéssel.


## 1. lépés — Név (csak Egyéni módban)

Chat-ben:

> *"Mi legyen a session neve?
> 1. Random hash
> 2. Egyéni név (írd be)"*

Feldolgozás:
- **`1` / üres / `auto` / `random`** → generálj rövid random hash-t: `x$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4)`
- **`2`** → kérdezz vissza chat-ben: *"Mi legyen a név?"*
- **Bármi egyéb** → sanitize: `tr -c 'a-zA-Z0-9_-' '-' | cut -c1-32 | sed 's/-\+/-/g; s/^-//; s/-$//'`. Üres → auto-fallback. Ha változott: *"Sanitize: `<CLEAN>`."*

A bázisnév max 32 char, a prefix-szel együtt max 64 char.

### KÖTELEZŐ prefix: szülő session neve

**Minden** új session neve a **szülő** session-név prefix-szével kell kezdődjön. A szülő nevét a `CLAUDE_AGENT_NAME` env változóból olvasd (`PARENT` változó a 0.a lépésből):

```bash
if [[ "$NAME" != "${PARENT}-"* ]]; then
  NAME="${PARENT}-$NAME"
fi
NAME=$(echo "$NAME" | cut -c1-64)
```

A prefix-elt nevet írd a JSON `name` mezőjébe.

### A `parent` mező — a fa explicit rögzítése

A `PARENT` értékét (0.a lépés) **írd bele a JSON `parent` mezőjébe is**. Ebből épül a fa lezáráskor: a `/close-agent` ez alapján tudja, melyik ágba kell visszamergelni a gyereket. Névből következtetni nem elég — ütközéskor a spawner `-2`…`-99` suffixet ad, és a `mac-main-web-2` nem gyereke a `mac-main-web`-nek.

## 2. lépés — cwd (csak Egyéni módban)

Először listázd a meglévő alkönyvtárakat:

```bash
ls -d ~/ClaudeProjects/*/ 2>/dev/null | sed "s|$HOME/ClaudeProjects/||; s|/$||" | paste -sd ',' -
```

Aztán chat-ben:

> *"Melyik munkakönyvtár?
> 1. ~/ClaudeProjects root
> 2. Egyéni relatív útvonal (írd be, pl. `foo` vagy `foo/bar`)
> Meglévő alkönyvtárak: `<LIST>`."*

Feldolgozás:
- **`1` / üres / `root` / `ClaudeProjects`** → `~/ClaudeProjects`
- **`2`** → kérdezz vissza chat-ben: *"Mi legyen az alkönyvtár?"*
- **Bármi egyéb** → relatív útvonalként kezeld:

  ```bash
  RAW="<USER_INPUT>"
  if [[ "$RAW" == /* || "$RAW" == ~* ]]; then
    # abszolút tilt — kérdezz vissza chat-ben
  fi
  TARGET="$HOME/ClaudeProjects/$RAW"
  ABS="${TARGET:A}"
  NEW=false; [[ -d "$TARGET" ]] || NEW=true
  ```

⚠️ **NE hozd létre a könyvtárat.** Ha nem létezik, az legtöbbször elgépelés — és
egy némán létrehozott üres könyvtárban az agent a projekt helyett a semmiben
kezdene dolgozni. A spawner ezt szándékosan hibának tekinti; a wizard nem
játszhatja ki a saját védelmét.

- Ha `NEW=false`: a JSON-ba az abszolút path, `create_cwd` **nélkül**.
- Ha `NEW=true`: **kérdezz vissza chat-ben** — *"A `<ABS>` nem létezik. Elgépelés,
  vagy tényleg új könyvtár legyen?"* Csak kifejezett megerősítés után tedd a
  specbe a `"create_cwd": true` mezőt. (Ez az egyetlen kivétel a néma-írás
  szabálya alól, és azért az, mert a másik ág csendben rossz könyvtárat adna.)

A JSON-ba mindig az abszolút path kerül.


## 3. lépés — Prompt (csak Egyéni módban)

Chat-ben:

> *"Mi legyen az indító prompt?
> 1. `Szia, Claude!`
> 2. Egyéni szöveg (írd be)"*

Feldolgozás:
- **`1` / üres** → `Szia, Claude!`
- **`2`** → kérdezz vissza chat-ben: *"Mi legyen a prompt?"*
- **Bármi egyéb** → használd promptként (max 8KB)


## 4. lépés — Tech paraméterek (csak Egyéni módban) — mind chat-question

### 4a. Model

> *"Melyik model?
> 1. opus
> 2. sonnet
> 3. haiku
> 4. fable"*

Feldolgozás:
- **`1` / `opus`** → menj a **4a-bis** opus-finomításra (verzió + context)
- **`2` / `sonnet`** → `sonnet`, ugord át a 4a-bis-t
- **`3` / `haiku`** → `haiku`, ugord át a 4a-bis-t
- **`4` / `fable`** → `fable`, ugord át a 4a-bis-t
- **Rögzített azonosító kézzel** (pl. `claude-sonnet-5`, `claude-haiku-4-5`,
  `claude-fable-5`) → fogadd el úgy, ahogy beírta; a spawner fehérlistája
  úgyis ellenőrzi. Ne kényszerítsd bele az alias-menübe.
- **Bármi egyéb** → chat-ben kérdezz vissza

### 4a-bis. Opus verzió + context (csak ha 4a = opus)

Két chat-question egymás után (NE picker).

**Verzió:**

> *"Melyik verzió?
> 1. Opus 5 (legújabb)
> 2. Opus 4.8
> 3. Opus 4.7"*

- **üres** → `opus` — az alias mindig a LEGFRISSEBB Opust jelenti (a CLI súgója szerint), ezért nem avul el
- **`1` / `5`** → `claude-opus-5` (rögzített azonosító, ha szándékosan verziót akarsz kötni)
- **`2` / `4.8`** → `claude-opus-4-8`
- **`3` / `4.7`** → `claude-opus-4-7`
- **Bármi egyéb** → chat-ben kérdezz vissza

**Context window:**

> *"Context window?
> 1. Default (a model natív context-je)
> 2. 1M (`[1m]` — nagy context, lassabb/drágább)"*

- **`1` / `default` / üres** → suffix nélkül
- **`2` / `1m` / `1M`** → tedd a `[1m]` suffixet a model string végére
- **Bármi egyéb** → chat-ben kérdezz vissza

A `<MODEL>` érték a JSON-ban az összevont string lesz, pl. `claude-opus-5`, `claude-opus-5[1m]`, `claude-opus-4-8`, vagy `claude-opus-4-7[1m]`. A `[1m]` utótag csak az Opus 4-7/4-8, az Opus 5 és a Sonnet 5 azonosítón érvényes.

### 4b. Worktree

> *"Új git worktree-ben fusson?
> 1. Nem
> 2. Igen"*

Feldolgozás:
- **`1` / `nem` / `Nem` / `false`** → `false`
- **`2` / `igen` / `Igen` / `true`** → `true`

### 4c. Effort

> *"Effort szint?
> 1. high
> 2. low
> 3. medium
> 4. xhigh
> 5. max"*

Feldolgozás:
- **`1` / `high`** → `high`
- **`2` / `low`** → `low`
- **`3` / `medium`** → `medium`
- **`4` / `xhigh`** → `xhigh`
- **`5` / `max`** → `max`

### 4d. Permission mode

> *"Permission mode?
> 1. auto
> 2. manual
> 3. acceptEdits
> 4. plan
> 5. dontAsk
> 6. bypassPermissions"*

Feldolgozás:
- **`1` / `auto`** → `auto`
- **`2` / `manual`** → `manual`
- **`3` / `acceptEdits`** → `acceptEdits`
- **`4` / `plan`** → `plan`
- **`5` / `dontAsk`** → `dontAsk`
- **`6` / `bypassPermissions`** → `bypassPermissions`

<!-- A lista a `claude --permission-mode` tényleges választékát tükrözi.
     A korábbi `default` érték NEM létezik: a spawn 3 mp-en belül elhalt vele,
     és a "child claude exited within 3s (check flags / auth)" hibaüzenet
     auth-problémára terelte a gyanút. -->

Ha a `auto`-val JSON-write blokkolva (classifier), ne kínálj alternatíva-pickert, hanem chat-ben kérdezz hogy a 6 közül melyiket írj helyette.


## 4.5. lépés — Worktree validáció (csak ha worktree=Igen)

Tényleges git check a cwd-n:

```bash
( cd "<CWD>" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) \
  && echo "GIT_OK" || echo "GIT_MISSING"
```

- `GIT_OK` → menj tovább
- `GIT_MISSING` → **silent fallback** worktree=Nem-re; jelezd egy mondatban: *"Worktree=Igen-t Nem-re váltottam, mert a cwd nem git repo."* Ne kérdezz semmit, menj a 5. lépésre.


## 5. lépés — JSON kiírás (mind Default mind Egyéni — NO confirm)

### `<REQUESTED_BY>` — ki kérte az indítást

- **A felhasználó kérte** (bármilyen formában szólt, hogy induljon agent) →
  `<REQUESTED_BY>` = **üres**. A mező kimarad, a spawner azonnal indít. Ez a
  megszokott, kapu nélküli út.
- **Magadtól döntöttél úgy, hogy agentet indítasz** → `<REQUESTED_BY>` = a saját
  session-neved (`$CLAUDE_AGENT_NAME`). Ilyenkor a spawner **nem indít azonnal**:
  Telegram-jóváhagyást kér, ugyanúgy, mint a híd.

**Miért:** amíg a felhasználó ír a queue-ba, az indítás maga a jóváhagyás. Amint
egy agent ír bele, az ugyanolyan felügyelet nélküli beviteli csatorna, mint a
híd — csak kapu nélkül. A kapu ott legyen, ahol a kockázat.

Ha bizonytalan vagy, melyik eset áll fenn, **töltsd ki**. Egy fölösleges
gombnyomás olcsó; egy kapu nélkül indított agent nem az.


**TILOS** bármilyen `AskUserQuestion` vagy chat-question a paraméterek után. **SOHA ne kérdezz** "Mehet?", "Submit?", "Send?", "Küldés?", "Confirm?" vagy bármi hasonlót. Az utolsó paraméter (4c. Permission) után **AZONNAL és HANGTALANUL** írd a spec-et a queue-ba a 6. lépés bash-blokkjával. Ne foglald össze a paramétereket, ne erősíttesd meg semmivel. A user már mindent megadott.

```bash
# <CREATE_CWD_BOOL> = `false`, KIVEVE ha a 2. lepesben a felhasznalo kifejezetten
# megerositette a nem letezo cwd letrehozasat. A spawner enelkul a nem letezo
# cwd-t hibanak veszi (szandekosan: az elgepeles kulonben csendben ures
# konyvtarat kapna).
UUID=$(uuidgen)
SPEC=~/.claude/agent-queue/new/$UUID.json
jq -n \
  --arg name "<NAME>" \
  --arg parent "<PARENT>" \
  --arg cwd "<ABS_CWD>" \
  --arg prompt "<PROMPT>" \
  --arg model "<MODEL>" \
  --arg effort "<EFFORT>" \
  --arg pm "<PERMISSION_MODE>" \
  --argjson brief true \
  --argjson worktree <WORKTREE_BOOL> \
  --argjson create_cwd <CREATE_CWD_BOOL> \
  --arg requested_by "<REQUESTED_BY>" \
  '{name:$name, parent:$parent, cwd:$cwd, prompt:$prompt, model:$model, effort:$effort, permission_mode:$pm, brief:$brief, worktree:$worktree, create_cwd:$create_cwd}
   + (if $requested_by == "" then {} else {requested_by:$requested_by} end)' \
  > "$SPEC"
echo "Spec written: $SPEC"
```

## 6. lépés — Visszaigazolás

- *"Queue-be írva, ~2 mp múlva spawnol."*
- *"Nézd a mobil Code tab-ot, ott lesz `<NAME>` zöld ponttal."*
- *"Ha valami akad: `~/.claude/agent-queue/failed/` vagy `tail -f ~/.claude/agent-queue/spawner.log`."*

Ne pollozz, ne ellenőrizz spawn-t, ne hívj felesleges toolt.

## 7. lépés — Ha TE indítottad: felügyeld és zárd le

Ez **nem** a spawn ellenőrzése (azt a 6. lépés tiltja) — hanem a munka vége.

Egy elindított agent **nem pörög magától**. Ha befejezte a kört, ott áll és vár:
nem dolgozik tovább, nem szól, és nem zárja le magát. Aki elindította, felelős
érte:

1. **Nézd meg, végzett-e** — fut-e még a session:
   ```bash
   tmux has-session -t "agent-<NAME>" && echo fut || echo "nem fut"
   ```
2. **Olvasd el, amit csinált** — a munkája a worktree-jében van, nem a fejedben.
3. **Zárd le a `/close-agent`-tel.** Ne hagyd ott „hátha még kell": egy magára
   hagyott agent folyamatot és memóriát fog, a worktree-je pedig gyűlik.

Ha a felhasználó kérte az indítást, a lezárásról **kérdezz**, ne döntsd el
magadtól — ő tudja, kell-e még a munka.
