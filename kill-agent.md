---
description: List and kill background agent sessions (cascade tree for single name)
---

Háttér agent session-t ölsz meg.

> ⚠️ **Ez adatvesztő út.** Worktree-s agentnél az `agent-kill-one.sh` a session
> kilövése után `remove_worktree`-t hív: `git worktree remove --force` +
> `git branch -D worktree-<név>` + `rm -rf` — a **nem commitolt munka elvész**,
> és az ág sem marad meg. A `/close-agent` ezzel szemben előbb auto-commitol és
> merge-öl. Ha a munka számít, oda irányítsd a felhasználót.

### Step 1 — List

```bash
tmux ls 2>/dev/null | grep '^agent-' | sed 's/^agent-//; s/:.*//'
```

Ha üres → jelezd *"Nincs futó agent."* és STOP.

### Step 2 — Chat-question (NE picker!) — felsorolás, kézzel beírt név

Olvasd ki a meta-infót minden agent-hez a `done/*.json` spec-ekből (`model`/`effort`/`permission_mode`/`worktree`), és tedd fel a kérdést chat-ben **PONTOSAN ÍGY, NE RÖVIDÍTS**:

> *"Melyik agentet öld? (írd be a nevet — egész vagy egyértelmű suffix, vagy `mindet` / `mégse`)
> - \<NAME1\> (\<model\>/\<effort\>/\<perm\>\[, worktree\])
> - \<NAME2\> (...)
> - \<NAME3\> (...)"*

Példa (3 agent):

> *"Melyik agentet öld? (írd be a nevet — egész vagy egyértelmű suffix, vagy `mindet` / `mégse`)
> - mac-main-website (sonnet/max/bypassPermissions, worktree)
> - mac-main-xfnlh (haiku/high/auto)
> - mac-main-foo (opus/high/auto)"*

Ha a listában **worktree-s** agent is van, a kérdés alá tedd oda egy sorban:
*"⚠️ A worktree-s agenteknél a kill törli a worktree-t és az ágat is — a nem commitolt munka elvész. Megőrzéshez: `/close-agent`."*

Feldolgozás:
- **Pontos név match** (pl. `mac-main-xfnlh`) → `~/.claude/agent-queue/bin/agent-kill-tree.sh "<NAME>"`
- **Részleges match (suffix, pl. `xfnlh`)** → ha 1 egyezés van, használd; ha több, kérdezz vissza chat-ben hogy konkretizáljon
- **`mindet` / `all`** → minden agent kill (parent claude TERM nélkül):
  ```bash
  ~/.claude/agent-queue/bin/agent-kill-all.sh --no-parent
  ```
- **`mégse` / üres / `0`** → `"Megszakítva."`, STOP

### Step 3 — Verify

```bash
tmux ls 2>/dev/null | grep '^agent-' || echo "no agents"
```

Jelentés magyarul + *"Mobil Code tab pull-to-refresh után frissül."*

### Megjegyzés — auto-suffix és kaszkádos kill

A `list_descendants` regex (`^NAME$|^NAME-`) prefix-szel matchel — ha kétszer queue-zoltál ugyanazzal a névvel (pl. `foo`), a második `foo-2`-vé alakul auto-suffix-szel. Ha most a `foo`-t killeled, a kaszkád **véletlenül a `foo-2`-t is megöli** mert prefix-match. Ez a szándékos viselkedés (parent-child cascade), de duplikált-nevű spawn esetén meglepő lehet. Tipp: kerüld a duplikált nevet, vagy használj egyértelmű suffix-eket.
