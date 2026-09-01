---
description: EZ a session elágaztatása egy gyerek-agentbe. A gyerek ALAPBÓL NEM örökli a beszélgetést (friss session); az öröklés kifejezett kérés (--summary / --inherit). Ugyanaz a felelősség, mint a /new-agent-nél: amit elindítasz, azt felügyeled és lezárod. A fork szándékosan NEM éled újra magától egy újraindítás után — kísérleti leágazás.
---

**Leszármaztatsz** egy új háttér agentet EBBŐL a sessionből: a gyerek a te
munkakönyvtáradból (vagy saját worktree-ből) indul, és a te fádban lesz — de
**alapból friss lappal**, örökölt beszélgetés nélkül.

⚠️ **Az öröklés 2026-08-31 óta nem az alapértelmezés.** Kétszer bizonyítottan
előfordult, hogy az örökölt kontextus miatt a gyerek **a szülő szerepét
folytatta** a saját feladata helyett: egy 714 soros örökölt átiratban a feladat
a 703. sorban állt, és az agent a szülő munkáját vitte tovább. A rendszer-prompt
védekező mondata odaért, és nem volt elég ellene. Ha a gyereknek tényleg kell a
kontextus, kérd: `--summary` (tömörített) vagy `--inherit` (teljes).

Akkor ezt használd, ha a feladat a mostani beszélgetés kontextusára épül. Ha független témáról van szó, a `/new-agent` az olcsóbb.

## SZABÁLY — nincs picker

`AskUserQuestion` tool **TILOS**. Minden kérdés chat-ben, szabad szöveggel.

## 1. lépés — Mit csináljon a gyerek?

Ha a felhasználó a parancs után már megadta a feladatot, **ne kérdezz vissza**, használd azt.

Különben chat-ben:

> *"Mi legyen a gyerek feladata? (egy mondat is elég)"*

## 2. lépés — Saját ág kell-e a kódhoz?

> *"Kapjon saját git worktree-t (külön ág), vagy dolgozzon ebben a munkakönyvtárban?
> 1. Külön worktree — `worktree-<név>` ág, a végén mergelhető vagy eldobható
> 2. Itt, közös cwd-ben"*

- `1` → `--worktree`
- `2` / üres → nincs kapcsoló

## 3. lépés — Név

> *"Mi legyen a suffix? (a teljes név `<ez-a-session>-<suffix>` lesz)"*

Sanitizálás: `tr -c 'a-zA-Z0-9_-' '-'`, max 32 karakter.

## 4. lépés — Indítás

```bash
~/.claude/agent-queue/bin/fork-agent "<SUFFIX>" [--worktree] "<FELADAT>"
```

A script maga oldja fel a szülőt a `CLAUDE_CODE_SESSION_ID` és a `CLAUDE_AGENT_NAME` környezeti változókból — **ne add meg kézzel**.

Opcionális: `--model`, `--effort`, `--cwd`, illetve a kontextus-öröklés: `--summary` (összefoglalóból indul, olcsóbb) vagy `--inherit` (a teljes beszélgetés). Alapból egyik sem — friss session indul.

## 5. lépés — Visszaigazolás

A script kiírja a nevet, a cwd-t, az ágat és a csatlakozási parancsot. Add tovább, és tedd hozzá:

- *"A mobil Code tabon is megjelenik."*
- *"Lezárás: `/close-agent <név>` — vagy ha ezt a sessiont zárod le, kaszkádosan rámegy."*

## Amit mondj el, ha kérdezi

- A fork a **friss** előzményt örökli, nem a szülő teljes élettörténetét — a resume korlátos ablakot tölt be.
- A gyerek **saját** session id-t kap; a szülő átiratát semmi nem módosítja.
- A fork **nem** kerül a `live/` registrybe: reboot után nem támad fel magától. Ez szándékos — egy feature branch nem az, amit egy watchdog újraindít.
