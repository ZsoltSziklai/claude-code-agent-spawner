---
description: Háttér agent lezárása: worktree merge vagy eldobás, majd kilövés (kaszkádol a leszármazottakra). Használd, amint egy általad indított agent végzett — magára hagyva folyamatot és memóriát fog. `drop` előtt KÖTELEZŐ megnézni, van-e a worktree-ben commitolatlan munka: azt a drop visszahozhatatlanul törli.
---

Háttér agent session-t **zársz le rendben**.

### Step 1 — List

```bash
tmux ls 2>/dev/null | grep '^agent-' | sed 's/^agent-//; s/:.*//'
```

Ha üres → *"Nincs futó agent."* STOP.

### Step 2 — Chat-question agent-választás — felsorolás, kézzel beírt név

> *"Melyik agentet zárd le? (írd be a nevet — egész vagy egyértelmű suffix, vagy `mindet` / `mégse`)
> - \<NAME1\> (\<model\>/\<effort\>/\<perm\>\[, worktree\])
> - \<NAME2\> (...)"*

Feldolgozás:
- **Pontos / suffix-match** → continue Step 3-ra az adott NAME-mel
- **`mindet`** → loop minden agentre, mindegyikre Step 3 (külön worktree-döntés!)
- **`mégse` / üres** → STOP

### Step 3 — Worktree döntés (per agent, csak ha worktree=true)

Olvasd a spec-et:

```bash
SPEC=$(grep -l "\"name\": \"<NAME>\"" ~/.claude/agent-queue/done/*.json 2>/dev/null \
       | xargs -r ls -t 2>/dev/null | head -1)
WT=$(jq -r '.worktree // false' "$SPEC")
```

**Ha `$WT == true`** → chat-question:

> *"<NAME> — mit csináljak a worktree-vel? (`merge` vagy `drop`)"*

- `merge` / `m` → action = `merge` (auto-commit + merge a **SZÜLŐ** ágába — csak a gyökér megy `main`-be)
- `drop` / `d` / `eldobás` → action = `drop`

**Ha `$WT != true`** → action = `nowt` (nincs kérdés)

#### Step 3a — ⚠️ `drop` ELŐTT: nézd meg, van-e ott menthetetlen munka

A `drop` a worktree-t **és** az ágát törli. Ami nincs commitolva — beleértve a
**követetlen** (`??`) fájlokat —, az visszahozhatatlanul elvész. A `merge` ág
auto-committal ezt megfogja, a `drop` **nem**.

```bash
WT_PATH="<CWD>/.claude/worktrees/<NAME>"
git -C "$WT_PATH" status --short                    # követetlen + módosított
git -C "$WT_PATH" log --oneline main..HEAD          # commit, ami nincs a main-ben
```

Ha bármelyik nem üres, **sorold fel a felhasználónak, mielőtt kérdezel**, és
ajánld fel a kimentést (pl. a jelentés-fájlok átmásolása a `reviews/`-ba,
commitolva). 2026-08-29-én két agent worktree-jében egy-egy **commitolatlan**
jelentés volt (`AUDIT5.md`, `JELENTES.md`) — a `drop` mindkettőt vitte volna, és
az egyik egy ötrészes átvizsgálás-sorozat hiányzó darabja volt.

Ez a lépés akkor is kell, ha a felhasználó már kimondta, hogy `drop`: ő nem
feltétlenül tudja, mi hever a worktree-ben.

**Merge esetén a cél a SZÜLŐ ága**, nem a `main` — csak a fa gyökere megy a `main`-be. A lezárás a legmélyebb leszármazottól halad fölfelé, hogy az unoka munkája még a szülő ágába kerüljön.

### Step 3b — Beszélgetés-döntés (per agent)

Chat-question:

> *"<NAME> — a beszélgetését is fűzzem a szülőébe? (`merge` vagy `keep`)"*

- `merge` / `m` → ctx = `merge`
- `keep` / `k` / üres → ctx = `keep`

**Mondd el a korlátot, ha `merge`-öt választ:** a fűzés egy **új** transcript-fájlt hoz létre a szülő projekt-könyvtárában; a szülő **futó** folyamata ezt nem látja, csak a következő resume-nál lép életbe. Az eredeti átiratokat semmi nem bántja.

#### Ha a HÍD indította az agentet

Nézd meg, szerepel-e a `~/.claude/agent-queue/bridge-spawned.json`-ban:

```bash
jq -r 'keys[]' ~/.claude/agent-queue/bridge-spawned.json
```

Ha igen, **a hídon zárd le** (`action: "close"` egy kérés-fájlban), ne innen — így
a küldő is értesül a lezárásról, és a nyilvántartás szabályosan ürül. A CLI-ág
végkijáratnak marad; kivezeti ugyan a nyilvántartásból, de a küldő nem tudja meg,
mi lett a munkájával.

### Step 4 — Execute

```bash
~/.claude/agent-queue/bin/agent-close-tree.sh "<NAME>" "<merge|drop|nowt>" "<merge|keep>"
```

Kaszkádosan a `<NAME>` + leszármazottak, a legmélyebbtől fölfelé.

### Step 5 — Verify + jelentés

```bash
tmux ls 2>/dev/null | grep '^agent-' || echo "no agents"
```

Magyarul jelentés + *"Mobil Code tab pull-to-refresh után frissül."* Merge-konfliktus esetén ne próbáld feloldani — jelezd hogy a `$CWD`-ben kézzel kell intézni.
