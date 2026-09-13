# Changelog

**🇭🇺 [Magyar változat](#magyar-változat)**

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), the
version numbering follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-09-13

### Added

- **The language of Telegram is now configurable.** The `lang` key of
  `bridge-allow.json` takes `"hu"` or `"en"`; the default stays `hu`, so an
  existing installation does not switch language silently on upgrade. It covers
  everything the user sees: button labels, the bubble replies to a button press,
  the approval and report messages, and the duration labels inside them.
- **Every document in the repository is bilingual** — English first, a
  `Magyar változat` section after it. Previously only `README.md` was.

### Changed

- **User-facing text lives in one catalogue.** Telegram strings used to sit at
  the call sites across three files; they now come from `BRIDGE_MSG` in
  `bin/_bridge-lib.sh` through `t <key>`. An unknown key renders **as the key**,
  not as an empty string — a missing translation is visible rather than silent.
- 251 assertions in the smoke test (was 243).

## [1.0.1] — 2026-09-13

### Fixed

- **The modal handler could kill its own agent.** The generic branch pressed
  Enter on any window labelled "Enter to confirm"; in Claude Code's trust dialog,
  however, the selected answer is **`No, exit`**, so Enter quit the freshly
  started fork. We no longer guess on an unknown dialog.
- **The agent answers the trust question by itself** — but only for a working
  directory **inside the allowed root**, and the decision rests on the path read
  out of the dialog, not on a variable passed in. The point of unattended mode is
  that after approval the agent gets the job done; the gate is the Telegram
  approval, not a second question about the same thing. For a path outside the
  root it still stops.
- **The error message lied.** When the session was gone, the readiness watcher
  wrote "did not come up in time" even though the process had died. The two are
  now separate branches, and the last frame of the screen shows the cause of death.
- **The cause of death used to be lost**: tmux destroyed the session when the
  command exited. The pane now survives it with `remain-on-exit`.
- **A duplicate request id is no longer swallowed silently.** A new request
  arriving on an already-used id was skipped without a word: no agent, no error,
  no message — the sender waited on a status that would never change. It now gets
  a `rejected` status and a Telegram message carrying the earlier state. An
  already-processed request is still skipped quietly (otherwise it would speak up
  every cycle); the age of the files tells the two apart.
- **A report is booked to its author.** Two agents can share a working directory
  (the project root is the common cwd of the root agent and every fork without a
  `cwd`), and the publisher picked up the other one's report during its own
  round. The filename carries the request id, so publishing was correct — but the
  close marker landed on the wrong agent, leaving **both unclosed**: the stall
  watcher could fire on them falsely. The author is now resolved from the request
  id, and the log says when a shared cwd made us find it elsewhere.
- **A failure gets the `failed` status**, not `spawned` — the Desktop reads
  `spawned` as success. The reason is the expressive error line, not the last
  fragment of the screen.

## [1.0.0] — 2026-09-04

The first public release. Starting, supervising and cleanly closing background
Claude Code agents on macOS, over launchd + tmux, with Telegram-based approval.

### Main capabilities

- **Starting agents from a queue** — a JSON spec written under `new/` starts a
  Remote Control session in about two seconds; it shows up immediately on the
  mobile Code tab.
- **Desktop bridge** — Claude Desktop asks for an agent start, continuation or
  close through an attached folder. Every request is gated on Telegram approval.
- **Time-boxed authorization** — an agent can be granted 1 hour / 8 hours / 1 day
  so continuations do not each need their own button; revocable at any time.
- **Tree-shaped agents** — children take the parent's name as a prefix, and
  closing cascades: from the deepest upwards, the work merging into the parent's
  branch.
- **Git worktree isolation** — an optional branch and working directory per agent.
- **Watchdog** — brings back dying agents, including the root session.

### Safety limits

- **Approval gate** — an agent-initiated start (`requested_by`) and a fork do not
  run without a Telegram button press.
- **Fork limits** — a self-replication guard, a depth limit and a rate limit
  against runaway forking; a truncated-name collision is an error, not a warning.
- **A fresh session is the default** — a child does not inherit the parent's
  conversation unless explicitly asked (`--summary` / `--inherit`).
- **Verified task delivery** — the `spawned` status means the task provably
  arrived: it is sent in chunks and confirmed back from the agent's transcript.
  If it does not land, the status is `failed`.
- **Elevated permission with a warning** — a `bypassPermissions` request gets its
  own block on the approval message.

### Response time

- A Telegram button press is processed **within seconds**: inside its 30-second
  cycle the poller listens for 25, so a long poll is practically always open.
  With the earlier, shorter wait about 15 seconds of dead time were left per
  cycle, during which the user rightly believed the button had not worked — and
  pressed again.
- A stale (no longer pending) button press does nothing, but **says so**, and
  removes the buttons so they cannot be pressed again.

### Testing

- 243 assertions in the smoke test (`tests/smoke.sh`), in CI on every push.
- A playable regression scenario (`tests/REGRESSION-RUN.md`) measuring the
  bridge, the approval, real work and the close live.

---

## Magyar változat

A formátum a [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) elveit
követi, a verziószámozás a [Semantic Versioning](https://semver.org/spec/v2.0.0.html)-t.

### [1.1.0] — 2026-09-13

#### Hozzáadva

- **A Telegram nyelve beállítható.** A `bridge-allow.json` `lang` kulcsa `"hu"`
  vagy `"en"`; az alapértelmezés marad a `hu`, tehát egy meglévő telepítés nem
  vált nyelvet magától a frissítéstől. Mindenre kiterjed, amit a felhasználó lát:
  a gombfeliratokra, a gombnyomásra jövő buborék-válaszokra, a jóváhagyó és
  jelentő üzenetekre, és a bennük szereplő időtartam-címkékre.
- **A repó minden dokumentuma kétnyelvű** — elöl az angol, alatta a
  `Magyar változat` szakasz. Eddig csak a `README.md` volt az.

#### Változott

- **A felhasználónak szóló szöveg egy katalógusban él.** A Telegram-szövegek
  eddig három fájlban, a hívás helyén álltak; mostantól a `bin/_bridge-lib.sh`
  `BRIDGE_MSG` táblájából jönnek a `t <kulcs>` hívással. Ismeretlen kulcsnál
  **maga a kulcs** jelenik meg, nem üres sztring — egy hiányzó fordítás így
  látható, nem néma.
- 251 állítás a füst-tesztben (eddig 243).

### [1.0.1] — 2026-09-13

#### Javítva

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

### [1.0.0] — 2026-09-04

Az első nyilvános kiadás. Háttérben futó Claude Code agentek indítása,
felügyelete és rendezett lezárása macOS-en, launchd + tmux felett, Telegram-alapú
jóváhagyással.

#### Fő képességek

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

#### Biztonsági korlátok

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

#### Válaszidő

- A Telegram-gombnyomás **másodperceken belül** feldolgozódik: a poller a 30
  másodperces cikluson belül 25 másodpercig figyel, így gyakorlatilag
  folyamatosan nyitva van egy hosszú lekérdezés. Korábbi, rövidebb várakozásnál
  körönként ~15 másodperc holtidő maradt, ami alatt a felhasználó joggal hitte,
  hogy a gomb nem hatott — és újra nyomott.
- Az elavult (már nem függőben lévő) gombnyomás nem csinál semmit, de **szól
  róla**, és leveszi a gombokat, hogy ne lehessen újra rájuk nyomni.

#### Tesztelés

- 243 állítás a füst-tesztben (`tests/smoke.sh`), CI-ben minden pusholásnál.
- Végigjátszható regressziós forgatókönyv (`tests/REGRESSION-RUN.md`), amely a
  hidat, a jóváhagyást, a valódi munkát és a lezárást élesben méri.

[1.0.0]: https://github.com/ZsoltSziklai/claude-code-agent-spawner/releases/tag/v1.0.0
[1.0.1]: https://github.com/ZsoltSziklai/claude-code-agent-spawner/releases/tag/v1.0.1
[1.1.0]: https://github.com/ZsoltSziklai/claude-code-agent-spawner/releases/tag/v1.1.0
