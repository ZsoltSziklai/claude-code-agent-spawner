# Changelog

A formátum a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) elveit
követi, a verziószámozás a [Semantic Versioning](https://semver.org/spec/v2.0.0.html)-t.

## [1.0.1] — 2026-09-13

### Javítva

- **A modál-kezelő megölhette a saját agentjét.** A generikus ág bármilyen
  „Enter to confirm" feliratú ablakra Entert nyomott; a Claude Code bizalmi
  párbeszédében viszont a kijelölt válasz a **`No, exit`**, tehát az Enter
  kiléptette a frissen indult forkot. Ismeretlen párbeszédre már nem tippelünk.
- **A bizalmi kérdést az agent magától megválaszolja** — de csak az
  **engedélyezett gyökéren belüli** munkakönyvtárra, és a döntés a párbeszédből
  kiolvasott útvonalon múlik, nem egy átadott változón. A felügyelet nélküli
  üzemmód lényege, hogy a jóváhagyás után az agent végigcsinálja a munkát; a
  kapu a Telegram-jóváhagyás, nem egy második kérdés ugyanarra. Gyökéren kívüli
  útvonalra viszont megáll.
- **A hibaüzenet hazudott.** Ha a session megszűnt, a készenlét-figyelő
  „nem állt fel időben"-t írt, holott a folyamat meghalt. A kettő most külön
  ág, és a halál okát a képernyő utolsó képe mutatja.
- **A halál oka eddig elveszett**: a tmux a parancs kilépésekor megszüntette a
  sessiont. A pane mostantól `remain-on-exit`-tel túléli.
- **A duplikált kérés-azonosító már nem nyelődik el némán.** Egy már használt
  id-re érkező új kérést a híd szó nélkül átugrott: se agent, se hiba, se
  üzenet — a küldő egy sosem változó státuszra várt. Mostantól `rejected`
  státuszt és Telegram-üzenetet kap, benne a korábbi állapottal. A már
  feldolgozott kérést továbbra is csendben átugorja (különben minden körben
  üzenne); a kettőt a fájlok kora különbözteti meg.
- **A jelentés a szerzőjéhez kerül könyvelésre.** Két agent osztozhat egy
  munkakönyvtáron (a projektgyökér a gyökér-agent és minden `cwd` nélküli fork
  közös cwd-je), és a publikáló az egyik körében szedte fel a másik jelentését.
  A fájlnév hordozza a kérés-azonosítót, ezért a publikálás helyes volt — de a
  lezárás-jelölés a rossz agentre került, és így **mindkettő lezáratlan maradt**:
  a beragadás-figyelő hamisan tüzelhetett rájuk. A szerzőt mostantól a
  kérés-azonosítóból oldjuk fel, és a napló megmondja, ha közös cwd miatt máshol
  találtuk meg.
- **A bukás `failed` státuszt kap**, nem `spawned`-et — a Desktop a `spawned`-et
  sikernek olvassa. Az indok a beszédes hibasor, nem az utolsó képernyő-töredék.

## [1.0.0] — 2026-09-04

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

- 243 állítás a füst-tesztben (`tests/smoke.sh`), CI-ben minden pusholásnál.
- Végigjátszható regressziós forgatókönyv (`tests/REGRESSION-RUN.md`), amely a
  hidat, a jóváhagyást, a valódi munkát és a lezárást élesben méri.

[1.0.0]: https://github.com/ZsoltSziklai/claude-code-agent-spawner/releases/tag/v1.0.0
[1.0.1]: https://github.com/ZsoltSziklai/claude-code-agent-spawner/releases/tag/v1.0.1
