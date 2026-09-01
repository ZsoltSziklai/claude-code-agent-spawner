# agent-spawner — Roadmap

A `~/.claude/agent-queue/` rendszer mobil-only / cross-session "command center" use case-re. Élesben működik, az alábbiak még nyitottak — bullet-szintű reminder, hogy ne felejtődjön el.

## Telepítve

- launchd watcher: `~/Library/LaunchAgents/local.agent-spawner.plist`
- watchdog: `~/Library/LaunchAgents/local.mac-main-watchdog.plist` (5 percenként + `RunAtLoad`; újraindítja a command-center session-t ha leesett, majd végigsöpri a gyerek-agenteket)
- script: `~/.claude/agent-queue/bin/claude-agent-spawner`
- slash commands: `~/.claude/commands/{new-agent,close-agent,kill-agent,kill-all-exit,fork}.md` (öt darab — a korábbi `{new,close,kill,kill-all-exit}-agent.md` brace-lista hibás nevekre bomlott)
- queue dirs: `~/.claude/agent-queue/{new,processing,done,failed,live}`

Reinstall: `zsh <repo>/install.sh`

### 2026-07-27 — restart-túlélés

Egy frissítés miatti reboot után a command-center magától visszajött, de minden belőle indított gyerek-agent halott maradt, és a mac-main előzménye kettészakadt. Ezekre:

- **live/ registry** — a spawner spawnkor rögzíti az agent spec-jét (`live/<name>.json`); a `/kill-agent`, `/close-agent`, `/kill-all-exit` törli, így a szándékosan lezárt agent lezárva marad.
- **`bin/agent-child-watchdog.sh`** — a registryben szereplő, de nem futó agenteket az eredeti spec-paraméterekkel + `--resume <legfrissebb session-id>` visszaállítja (worktree-s agentet a worktree-ben, nem a spec cwd-ben). Korlátozott újrapróbálkozás: `CLAUDE_AGENT_MAX_RESTORE` (default 3), futó agentnél nullázódik.
- **`start.sh` resume** — a command-center a cwd legfrissebb átiratát folytatja, nem nyit új sessiont minden rebootnál. `CLAUDE_AGENT_RESUME=false` → szándékosan tiszta indulás. Guard: azonos néven nem indul második példány (két folyamat egy transcript-fájlra kötne be).
- **`auto_dismiss_modals()`** — a felügyelet nélküli induláskor beragadó egyszeri modálok megválaszolása (chrome-confirm, fullscreen renderer, „resume from summary?").
- **`bin/merge-sessions.sh`** — két transcript összefűzése egy resume-olható sessionné, validációval. ⚠️ Megőrzésre és kereshetőségre jó, **emlékezet-visszaállításra nem**: a resume korlátos ablakot tölt be, a régi tartalom nem kerül vissza a munkamemóriába (mérve: fűzött session 154k vs csak-új 171k kontextus).

Két hiba a tesztelés során derült ki, mindkettő javítva: a `TMUX` változónév ütközik a tmux socket-változójával (→ `TMUX_BIN` + `unset TMUX`), és a `tmux new-session` nem adja át a hívó környezetét, ezért a konfigot a parancs-stringbe kell exportálni.

## Függőben lévő refinement-ek

- **done/ rotáció** — weekly cron / launchd CalendarInterval, 7 napnál régebbi entry-k törlése; nélküle nőni fog
- **failed/ olvashatóság** — `.json` + `.reason` mergelése egy fájlba
- **Token expiry detect** — Mac claude.ai login lejár → spawn-olt session-ök meghalnak; figyelni és figyelmeztetni
- **Per-spec budget** — opcionális `max_budget_usd` mező → `--max-budget-usd` flag a spawn-nál
- **Bridge-health check** — a watchdog process-létezést néz, nem Remote Control bridge-et; leszakadt bridge-dzsel a session a telefonon láthatatlan, a watchdog szerint meg minden rendben

## Elkészült — korábban ezen a listán volt

- **cwd allowlist** — a spawner elutasítja a `~/ClaudeProjects`-en kívüli cwd-t (`cwd outside allowed root`), symlink-feloldással
- **main-callback** — `done/<uuid>.result` (remote session név, tmux session, `started_at`, model, effort, permission mode)
- **spawner.log / watchdog.log rotáció** — `rotate_log()` a közös libben (lásd `TODO.md`)

## Code-signing kísérlet (lezárva, nem ér)

Próbáltunk self-signed code signing cert-tel hogy a Login Items-ben ne `unidentified developer` legyen. Eredmény: a self-signed cert lokálisan trustolható, a `codesign` lefut, de a macOS Login Items kizárólag **Apple Developer ID Application** cert-et fogad el a developer név megjelenítéséhez. $99/év nélkül ez a használati eset nem megoldható — a signing infrastruktúrát eltávolítottuk.
