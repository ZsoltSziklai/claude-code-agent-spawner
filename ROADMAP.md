# agent-spawner — Roadmap

**🇭🇺 [Magyar változat](#magyar-változat)**

The `~/.claude/agent-queue/` system, for a mobile-only / cross-session "command
center" use case. It works in production; the items below are still open — a
bullet-level reminder so they do not get forgotten.

## Installed

- launchd watcher: `~/Library/LaunchAgents/local.agent-spawner.plist`
- watchdog: `~/Library/LaunchAgents/local.mac-main-watchdog.plist` (every 5
  minutes plus `RunAtLoad`; restarts the command-center session if it dropped,
  then sweeps through the child agents)
- script: `~/.claude/agent-queue/bin/claude-agent-spawner`
- slash commands: `~/.claude/commands/{new-agent,close-agent,kill-agent,kill-all-exit,fork}.md`
  (five files — the earlier `{new,close,kill,kill-all-exit}-agent.md` brace list
  expanded into wrong names)
- queue dirs: `~/.claude/agent-queue/{new,processing,done,failed,live}`

Reinstall: `zsh <repo>/install.sh`

### 2026-07-27 — surviving a restart

After a reboot for an update the command center came back on its own, but every
child agent started from it stayed dead, and mac-main's history was split in two.
For these:

- **live/ registry** — on spawn the spawner records the agent's spec
  (`live/<name>.json`); `/kill-agent`, `/close-agent` and `/kill-all-exit` delete
  it, so an intentionally closed agent stays closed.
- **`bin/agent-child-watchdog.sh`** — agents present in the registry but not
  running are restored with their original spec parameters plus
  `--resume <latest session id>` (a worktree agent in its worktree, not in the
  spec's cwd). Limited retries: `CLAUDE_AGENT_MAX_RESTORE` (default 3), reset
  while the agent runs.
- **`start.sh` resume** — the command center continues the latest transcript of
  the cwd instead of opening a new session on every reboot.
  `CLAUDE_AGENT_RESUME=false` → a deliberately clean start. Guard: a second
  instance under the same name does not start (two processes would attach to one
  transcript file).
- **`auto_dismiss_modals()`** — answering the one-off modals that block an
  unattended start (chrome-confirm, fullscreen renderer, "resume from summary?").
- **`bin/merge-sessions.sh`** — splicing two transcripts into one resumable
  session, with validation. ⚠️ Good for preservation and searchability, **not for
  restoring memory**: a resume loads a bounded window, and the old content does
  not come back into working memory (measured: a spliced session 154k vs. new-only
  171k of context).

Two bugs surfaced during testing, both fixed: the variable name `TMUX` collides
with tmux's own socket variable (→ `TMUX_BIN` + `unset TMUX`), and `tmux
new-session` does not pass on the caller's environment, so the config has to be
exported into the command string.

## Pending refinements

- **done/ rotation** — weekly cron / launchd CalendarInterval, deleting entries
  older than 7 days; without it the directory will keep growing
- **failed/ readability** — merging `.json` + `.reason` into a single file
- **Token expiry detection** — the Mac claude.ai login expires → spawned sessions
  die; watch for it and warn
- **Per-spec budget** — an optional `max_budget_usd` field → a `--max-budget-usd`
  flag at spawn time
- **Bridge health check** — the watchdog looks at process existence, not at the
  Remote Control bridge; with a dropped bridge the session is invisible on the
  phone while the watchdog considers everything fine

## Done — previously on this list

- **cwd allowlist** — the spawner rejects a cwd outside `~/ClaudeProjects`
  (`cwd outside allowed root`), with symlinks resolved
- **main callback** — `done/<uuid>.result` (remote session name, tmux session,
  `started_at`, model, effort, permission mode)
- **spawner.log / watchdog.log rotation** — `rotate_log()` in the shared lib (see
  `TODO.md`)

## Code-signing experiment (closed, not worth it)

We tried a self-signed code signing certificate so that Login Items would not say
`unidentified developer`. Result: a self-signed certificate can be trusted
locally and `codesign` runs fine, but macOS Login Items only accepts an **Apple
Developer ID Application** certificate for displaying the developer name. Without
$99/year this use case cannot be solved — the signing infrastructure was removed.

---

## Magyar változat

A `~/.claude/agent-queue/` rendszer mobil-only / cross-session "command center" use case-re. Élesben működik, az alábbiak még nyitottak — bullet-szintű reminder, hogy ne felejtődjön el.

### Telepítve

- launchd watcher: `~/Library/LaunchAgents/local.agent-spawner.plist`
- watchdog: `~/Library/LaunchAgents/local.mac-main-watchdog.plist` (5 percenként + `RunAtLoad`; újraindítja a command-center session-t ha leesett, majd végigsöpri a gyerek-agenteket)
- script: `~/.claude/agent-queue/bin/claude-agent-spawner`
- slash commands: `~/.claude/commands/{new-agent,close-agent,kill-agent,kill-all-exit,fork}.md` (öt darab — a korábbi `{new,close,kill,kill-all-exit}-agent.md` brace-lista hibás nevekre bomlott)
- queue dirs: `~/.claude/agent-queue/{new,processing,done,failed,live}`

Reinstall: `zsh <repo>/install.sh`

#### 2026-07-27 — restart-túlélés

Egy frissítés miatti reboot után a command-center magától visszajött, de minden belőle indított gyerek-agent halott maradt, és a mac-main előzménye kettészakadt. Ezekre:

- **live/ registry** — a spawner spawnkor rögzíti az agent spec-jét (`live/<name>.json`); a `/kill-agent`, `/close-agent`, `/kill-all-exit` törli, így a szándékosan lezárt agent lezárva marad.
- **`bin/agent-child-watchdog.sh`** — a registryben szereplő, de nem futó agenteket az eredeti spec-paraméterekkel + `--resume <legfrissebb session-id>` visszaállítja (worktree-s agentet a worktree-ben, nem a spec cwd-ben). Korlátozott újrapróbálkozás: `CLAUDE_AGENT_MAX_RESTORE` (default 3), futó agentnél nullázódik.
- **`start.sh` resume** — a command-center a cwd legfrissebb átiratát folytatja, nem nyit új sessiont minden rebootnál. `CLAUDE_AGENT_RESUME=false` → szándékosan tiszta indulás. Guard: azonos néven nem indul második példány (két folyamat egy transcript-fájlra kötne be).
- **`auto_dismiss_modals()`** — a felügyelet nélküli induláskor beragadó egyszeri modálok megválaszolása (chrome-confirm, fullscreen renderer, „resume from summary?").
- **`bin/merge-sessions.sh`** — két transcript összefűzése egy resume-olható sessionné, validációval. ⚠️ Megőrzésre és kereshetőségre jó, **emlékezet-visszaállításra nem**: a resume korlátos ablakot tölt be, a régi tartalom nem kerül vissza a munkamemóriába (mérve: fűzött session 154k vs csak-új 171k kontextus).

Két hiba a tesztelés során derült ki, mindkettő javítva: a `TMUX` változónév ütközik a tmux socket-változójával (→ `TMUX_BIN` + `unset TMUX`), és a `tmux new-session` nem adja át a hívó környezetét, ezért a konfigot a parancs-stringbe kell exportálni.

### Függőben lévő refinement-ek

- **done/ rotáció** — weekly cron / launchd CalendarInterval, 7 napnál régebbi entry-k törlése; nélküle nőni fog
- **failed/ olvashatóság** — `.json` + `.reason` mergelése egy fájlba
- **Token expiry detect** — Mac claude.ai login lejár → spawn-olt session-ök meghalnak; figyelni és figyelmeztetni
- **Per-spec budget** — opcionális `max_budget_usd` mező → `--max-budget-usd` flag a spawn-nál
- **Bridge-health check** — a watchdog process-létezést néz, nem Remote Control bridge-et; leszakadt bridge-dzsel a session a telefonon láthatatlan, a watchdog szerint meg minden rendben

### Elkészült — korábban ezen a listán volt

- **cwd allowlist** — a spawner elutasítja a `~/ClaudeProjects`-en kívüli cwd-t (`cwd outside allowed root`), symlink-feloldással
- **main-callback** — `done/<uuid>.result` (remote session név, tmux session, `started_at`, model, effort, permission mode)
- **spawner.log / watchdog.log rotáció** — `rotate_log()` a közös libben (lásd `TODO.md`)

### Code-signing kísérlet (lezárva, nem ér)

Próbáltunk self-signed code signing cert-tel hogy a Login Items-ben ne `unidentified developer` legyen. Eredmény: a self-signed cert lokálisan trustolható, a `codesign` lefut, de a macOS Login Items kizárólag **Apple Developer ID Application** cert-et fogad el a developer név megjelenítéséhez. $99/év nélkül ez a használati eset nem megoldható — a signing infrastruktúrát eltávolítottuk.
