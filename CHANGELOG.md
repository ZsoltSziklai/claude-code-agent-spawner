# Changelog

**🇭🇺 [Magyar változat](#magyar-változat)**

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), the
version numbering follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.1] — 2026-10-02

### Fixed

- **Delivery verification reported success when there was no evidence at all.**
  The check was `find … -newermt "@<epoch>" -print0 | xargs -0 grep -q …`, and it
  had two independent holes that lined up into a false green:

  - macOS's `/usr/bin/find` **cannot parse `@<epoch>`**
    (`find: Can't parse date/time: @1790930971`) and **exits 0** anyway, so not
    even a `|| return 1` would have caught it. On a developer's interactive shell
    `find` may be an alias for a replacement that does understand it — launchd
    jobs get `/usr/bin/find`.
  - BSD `xargs` **does not run the command at all** on empty input and **exits 0**,
    so the pipeline's status was success.

  Together: no fresh transcript → `find` silent → `xargs` exits 0 → "the task
  arrived". The less evidence there was, the more certain the success. This means
  the project's core guarantee — *`spawned` means the task provably arrived* — did
  not hold under launchd. The check is now a function of its own
  (`fresh_transcript_has`) with no `xargs` and no external date parsing (zsh glob
  + `stat -f %m`), and **an empty file list is false, not true**.

- **A failed `send-keys` went unnoticed.** Its exit status was discarded, so when
  tmux rejected the target the error only appeared on stderr while the function
  ran on to the verification above. After a failed send there is nothing to
  verify: the attempt now aborts and says so.

- **Pane targets need `=name:`, not `=name`.** v1.2.0 switched every tmux target
  to the exact-match `=` prefix, which is right for *session* targets
  (`has-session`, `kill-session`, `list-panes`) but **not for pane targets**:
  `capture-pane` and `send-keys` reject `=name` with `can't find pane`. This broke
  task delivery, modal auto-dismissal and fork diagnostics for one day — 22 call
  sites, now `=name:`.

  Measured consequence: request `hw-p1-01` was approved, the bridge wrote
  `spawned` within 6 seconds with the message `can't find pane: …`, and the agent
  sat idle. The task was re-delivered by hand and the round completed.

### Changed

- 285 assertions in the smoke test (was 266). The new ones are **functional**:
  the four tmux verbs are run against a real throwaway session, the empty-`xargs`
  trap is demonstrated before it is guarded, and `fresh_transcript_has` is
  exercised on the launchd-style minimal `PATH`. Two assertions that pinned the
  **old, broken** implementation (`xargs -0 grep -qlF`) were replaced — a test
  that asserts the presence of a bug protects the bug.

## [1.2.0] — 2026-10-01

### Fixed

- **A tmux session target matched by prefix, and the watchdog went blind.**
  `tmux has-session -t <name>` accepts a prefix, not just an exact name. With a
  running `mac-main-sziklaizsolthu-dsolar-web`, the check for
  `mac-main-sziklaizsolthu` therefore reported *healthy* — so the watchdog
  **never restored that agent from 2026-08-26 onwards**, and not one log line
  mentioned it. The user restarted it by hand several times and it simply stayed
  down.

  Worse, the same resolution wrote the registry: on the "healthy" branch the
  watchdog records `last_session_id` from the session it found, so **another
  agent's session id landed in this agent's `live/` entry**. A later restore
  would have continued a stranger's conversation — and once it did, two
  processes were writing one transcript. Every tmux session target now matches
  exactly (tmux's `=` prefix), guarded by a test that also demonstrates the
  prefix behaviour live.

### Added

- **`bin/agent-update-restart.sh`** — updates the CLI and restarts the agents
  running in tmux onto the new binary, each continuing **its own** conversation.
  It exists because the manual "exit and let it come back" round has three traps:

  - **the update has to come first.** Restart first and the freshly started
    instance installs the next version itself and asks for a restart again —
    measured: started 08:32:45 on 2.1.274, and by 08:33:01 2.1.286 was on disk.
  - **the argv's resume id is not the agent's own session.** In an inherited
    fork's argv the *parent's* session id sits there, so reusing the argv would
    hand the child the parent's conversation. The agent's own id is read from the
    running process, before it is killed.
  - **what cannot be restored must not be killed.** Forks have no `live/` entry
    (they are deliberately not resurrected), so the script restarts each agent
    itself and only kills one for which it has already built a complete restart
    command. An agent already on the current binary is skipped, so a second run
    is a no-op.

### Changed

- 266 assertions in the smoke test (was 251).

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

### [1.2.1] — 2026-10-02

#### Javítva

- **A kézbesítés-ellenőrzés sikert jelentett, amikor semmi bizonyíték nem volt.**
  A próba `find … -newermt "@<epoch>" -print0 | xargs -0 grep -q …` volt, és két
  független lyuk állt össze benne hamis zölddé:

  - a macOS `/usr/bin/find` **nem érti az `@<epoch>` alakot**
    (`find: Can't parse date/time: @1790930971`), és **mégis 0-val lép ki** — tehát
    még egy `|| return 1` sem fogta volna meg. A fejlesztő interaktív shelljében a
    `find` lehet egy alias egy olyan programra, ami érti; a launchd-jobok a
    `/usr/bin/find`-ot kapják.
  - a BSD `xargs` üres bemenetre **el sem indítja** a parancsot, és **0-val lép
    ki**, tehát a pipeline kilépési értéke siker.

  A kettő együtt: nincs friss átirat → a `find` néma → az `xargs` 0-val kilép →
  „a feladat megérkezett". Minél kevesebb a bizonyíték, annál biztosabb a siker.
  Ez azt jelenti, hogy a projekt alapgaranciája — *a `spawned` azt jelenti, hogy a
  feladat bizonyítottan megérkezett* — a launchd alatt nem teljesült. A próba
  mostantól önálló függvény (`fresh_transcript_has`), `xargs` és külső
  dátum-értelmezés nélkül (zsh-glob + `stat -f %m`), és **az üres fájllista hamis,
  nem igaz**.

- **Az elbukott `send-keys` észrevétlen maradt.** A kilépési értékét eldobtuk, így
  amikor a tmux elutasította a célt, a hiba csak stderr-en látszott, a függvény
  pedig továbbfutott a fenti ellenőrzésig. Elbukott küldés után nincs mit
  ellenőrizni: a próbálkozás mostantól megáll, és meg is mondja, miért.

- **A pane-célokhoz `=név:` kell, nem `=név`.** Az 1.2.0 minden tmux-célt a pontos
  illesztésű `=` előtagra váltott, ami a **session**-céloknál helyes
  (`has-session`, `kill-session`, `list-panes`), a **pane**-céloknál viszont nem: a
  `capture-pane` és a `send-keys` `can't find pane`-nel elutasítja a `=név` alakot.
  Ez egy napra eltörte a feladat-kézbesítést, a modál-megválaszolást és a
  fork-diagnosztikát — 22 hívási hely, mostantól `=név:`.

  A mért következmény: a `hw-p1-01` kérést jóváhagyták, a híd 6 másodperc alatt
  `spawned`-et írt `can't find pane: …` üzenettel, az agent pedig tétlenül állt. A
  feladatot kézzel újraküldtük, és a kör lezárult.

#### Változott

- 285 állítás a füst-tesztben (eddig 266). Az újak **funkcionálisak**: a négy
  tmux-ige valódi, eldobható sessionön fut le, az üres-`xargs` csapdát megmutatjuk,
  mielőtt védünk ellene, és a `fresh_transcript_has` a launchd-szerű minimál
  `PATH`-on is mérve van. Két állítás a **régi, hibás** implementációt rögzítette
  (`xargs -0 grep -qlF`) — azokat lecseréltük: egy teszt, amelyik egy hiba
  jelenlétét állítja, magát a hibát védi.

### [1.2.0] — 2026-10-01

#### Javítva

- **A tmux session-cél prefixre illeszkedett, és a watchdog megvakult tőle.**
  A `tmux has-session -t <név>` nem csak pontos névre, **prefixre is**
  illeszkedik. A futó `mac-main-sziklaizsolthu-dsolar-web` miatt a
  `mac-main-sziklaizsolthu` vizsgálata *épnek* jelezte — a watchdog ezért
  **2026-08-26 óta egyszer sem állította vissza**, és egyetlen naplósor sem szólt
  róla. A felhasználó többször újraindította kézzel, és egyszerűen nem jött
  vissza.

  Rosszabb: ugyanez a feloldás írta a nyilvántartást is. Az „ép" ágon a watchdog
  a megtalált sessionből rögzíti a `last_session_id`-t, tehát **egy másik agent
  session-id-je került ennek az agentnek a `live/` bejegyzésébe**. Egy későbbi
  visszaállítás idegen beszélgetést folytatott volna — és amikor megtörtént, két
  folyamat írta ugyanazt az átiratot. Mostantól minden tmux session-cél pontosan
  illeszt (a tmux `=` előtagja), és ezt teszt őrzi, amelyik élesben meg is
  mutatja a prefix-viselkedést.

#### Hozzáadva

- **`bin/agent-update-restart.sh`** — frissíti a CLI-t, majd a tmuxban futó
  agenteket újraindítja az új binárisra, mindegyiket a **saját** beszélgetésével.
  Azért kell, mert a kézi „kilépek és majd visszajön" kör három csapdát rejt:

  - **a frissítésnek előbb kell futnia.** Ha előbb indítunk újra, az újonnan
    indult példány maga telepíti a következő verziót, és megint újraindítást kér
    — mérve: 08:32:45-kor indult 2.1.274-tel, és 08:33:01-kor már a 2.1.286 volt
    a lemezen.
  - **az argv resume-ja nem az agent saját sessionje.** Egy örökölt fork
    argv-jében a *szülő* session-idje áll, tehát az argv újrahasznosítása a szülő
    beszélgetésébe tenné a gyereket. A saját id-t a futó folyamatból olvassuk ki,
    a killelés előtt.
  - **amit nem lehet visszaállítani, azt nem szabad megölni.** A forkoknak nincs
    `live/` bejegyzése (szándékosan nem élesztjük újra őket), ezért a script maga
    indítja újra mindegyiket, és csak azt öli meg, amire már összeállított egy
    teljes újraindítási parancsot. A friss binárison futó agentet kihagyja, tehát
    a második futás nem tesz semmit.

#### Változott

- 266 állítás a füst-tesztben (eddig 251).

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
[1.2.0]: https://github.com/ZsoltSziklai/claude-code-agent-spawner/releases/tag/v1.2.0
[1.2.1]: https://github.com/ZsoltSziklai/claude-code-agent-spawner/releases/tag/v1.2.1
