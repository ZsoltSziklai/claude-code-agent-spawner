# Changelog

A formátum a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) elveit
követi, a verziószámozás a [Semantic Versioning](https://semver.org/spec/v2.0.0.html)-t.

## [1.0.0] — 2026-09-01

Az első nyilvános kiadás. Háttérben futó Claude Code agentek indítása,
felügyelete és rendezett lezárása macOS-en, launchd + tmux felett, Telegram-alapú
jóváhagyással.

### Fő képességek

- **Agent-indítás sorból** — a `new/` alá írt JSON specből ~2 másodperc alatt
  indul Remote Control session; a mobil Code tabon azonnal látszik.
- **Desktop-híd** — a Claude Desktop egy csatolt mappán át kér agent-indítást,
  folytatást vagy lezárást. Minden kérés Telegram-jóváhagyáshoz kötött.
- **Időkorlátos felhatalmazás** — egy agentre 1 óra / 8 óra / 1 nap adható, hogy
  a folytatások ne kérjenek külön gombot; bármikor visszavonható.
- **Fa-szerkezetű agentek** — a gyerekek a szülő nevének prefixét kapják, a
  lezárás kaszkádol: a legmélyebbtől felfelé, a munka a szülő ágába olvad.
- **Git-worktree izoláció** — opcionális saját ág és munkakönyvtár agentenként.
- **Watchdog** — az elhaló agenteket visszahozza, a gyökér sessiont is.

### Biztonsági korlátok

- **Jóváhagyási kapu** — agent-kezdeményezte indítás (`requested_by`) és fork
  Telegram-gombnyomás nélkül nem indul.
- **Fork-korlátok** — önmásolás-őr, mélységkorlát és sebességkorlát a
  fork-elszabadulás ellen; a csonkolt név ütközése hiba, nem figyelmeztetés.
- **Friss session az alapértelmezés** — a gyerek nem örökli a szülő
  beszélgetését, hacsak kifejezetten nem kérik (`--summary` / `--inherit`).
- **Ellenőrzött feladat-kézbesítés** — a `spawned` státusz azt jelenti, hogy a
  feladat bizonyítottan megérkezett: darabolva megy ki, és az agent átiratából
  igazoljuk vissza. Ha nem ér célba, a státusz `failed`.
- **Emelt jogosultság figyelmeztetéssel** — a `bypassPermissions` kérés a
  jóváhagyó üzeneten külön blokkot kap.

### Válaszidő

- A Telegram-gombnyomás **másodperceken belül** feldolgozódik: a poller a 30
  másodperces cikluson belül 25 másodpercig figyel, így gyakorlatilag
  folyamatosan nyitva van egy hosszú lekérdezés. Korábbi, rövidebb várakozásnál
  körönként ~15 másodperc holtidő maradt, ami alatt a felhasználó joggal hitte,
  hogy a gomb nem hatott — és újra nyomott.
- Az elavult (már nem függőben lévő) gombnyomás nem csinál semmit, de **szól
  róla**, és leveszi a gombokat, hogy ne lehessen újra rájuk nyomni.

### Tesztelés

- 225 állítás a füst-tesztben (`tests/smoke.sh`), CI-ben minden pusholásnál.
- Végigjátszható regressziós forgatókönyv (`tests/REGRESSION-RUN.md`), amely a
  hidat, a jóváhagyást, a valódi munkát és a lezárást élesben méri.

[1.0.0]: https://github.com/ZsoltSziklai/claude-code-agent-spawner/releases/tag/v1.0.0
