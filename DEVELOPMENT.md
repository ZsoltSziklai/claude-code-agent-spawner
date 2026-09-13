# Development prompt — claude-code-agent-spawner

**🇭🇺 [Magyar változat](#magyar-változat)**

This document is a self-contained, copy-pasteable prompt for Claude Code (or any other LLM-based coding agent). Whoever reads it should be able to reimplement the **core** of the system — the queue, the spawner, the watchdogs and the slash commands — from scratch on their own platform.

**Scope:** the Desktop bridge (relay, poller, grants, stall detection — roughly 1200 lines) and the internals of `fork-agent` are **not** included. For those, `bridge-README.md` and `desktop-skill/agent-bridge/SKILL.md` are the starting points.

> ⚠️ **If this document and the code disagree, the CODE is the truth.** This text is a reimplementation recipe, not a specification — `bin/` and `claude-agent-spawner` are always fresher. In several places (cwd handling, permission modes, the model list) the repository is deliberately stricter than what used to be written here; the text below already describes the corrected behaviour.

---

## 0. TL;DR of the task

Build a **queue-based background agent orchestrator** for [Claude Code](https://claude.com/claude-code). It lets the user start several parallel Claude Code sessions in the background — from a terminal, from a running agent, or from the Claude mobile app (Code tab). They can attach from their phone to a permanently running "command center" session and start new background agents from there with slash commands.

Two background services run on the system:

1. **Queue spawner** — a folder-watching file watcher. When a JSON spec file lands in the queue's `new/` subfolder, it starts a standalone `claude` CLI session from it in its own terminal-multiplexer window (tmux / screen / ConPTY), optionally in its own git worktree.
2. **Watchdog** — periodically checks whether the command-center session is alive. If it stopped, it restarts it.

Sessions started with the `claude --remote-control <name>` flag appear on the Code tab of the mobile Claude app — they can be driven from there. This requires a full claude.ai login (the long-lived `CLAUDE_CODE_OAUTH_TOKEN` env var **disables** it, which is why the spawner unsets it).

---

## 1. High-level architecture

```
┌──────────────────┐         ┌──────────────────────┐
│  user            │ ssh /   │   command center     │
│  (terminal or    │────────▶│   claude session     │
│   Claude mobile) │         │   (always running)   │
└──────────────────┘         └──────────┬───────────┘
                                        │ /new-agent
                                        ▼
                             ┌──────────────────────┐
                             │  ~/.../queue/new/    │
                             │      <uuid>.json     │◀── anything else may write here
                             └──────────┬───────────┘  (cron, webhook, another agent)
                                        │ inotify / FSEvents / ReadDirectoryChangesW
                                        ▼
                             ┌──────────────────────┐
                             │  queue spawner       │
                             │  (file watcher)      │
                             └──────────┬───────────┘
                                        │ spawn
                                        ▼
                             ┌──────────────────────┐
                             │  background agent #1 │  ◀── tmux / screen / ConPTY
                             │  background agent #2 │  ◀── optional git worktree
                             │  ...                 │
                             └──────────────────────┘
```

In parallel with this the `watchdog` checks the life of the command-center session every minute or every five minutes.

---

## 2. Components

### 2.1. Queue spawner (`claude-agent-spawner`)

A shell / Python / PowerShell script that the platform's background service starts on a file change event.

**Its input:** `~/.claude/agent-queue/new/<uuid>.json`

**Its output:**
- Success → `done/<uuid>.json` + `done/<uuid>.result` (started_at, tmux_session, remote_session_name, cwd, model, effort, permission_mode)
- Failure → `failed/<uuid>.json` + `failed/<uuid>.reason`

**Steps for one spec:**

1. **Atomic claim**: `mv new/<uuid>.json processing/<uuid>.json`. If the `mv` fails (another watcher already took it), `continue`.
2. **JSON validation**: parse it, and on a parse error → `failed/`.
3. **Field validation** (see the JSON spec in section 4).
4. **CWD setup**: **the allowlist check comes FIRST** (only under `~/ClaudeProjects`), and only then any creation — in the reverse order a cwd pointing outside would first create directories and only then fail. A non-existent cwd is an **error**, not an invitation: otherwise a typo would quietly get an empty directory, and the agent would work in that instead of the project. A deliberately new directory needs its own field (`create_cwd: true`).
5. **Tmux session collision check**: does `agent-<name>` already exist? The reference implementation adds an **auto suffix** (`-2` … `-99`) rather than rejecting the request.
6. **Spawn**: start the `claude` CLI in a new terminal-multiplexer session. Per-platform details below.
7. **Smoke check**: wait a few seconds, check whether the spawned process is alive. If not (auth failure, a bad flag, and so on) → `failed/`. The reference implementation waits **3** seconds after a plain spawn and **5** after a fork (the latter loads a transcript, so it reports itself alive more slowly) — set it too short and you will drop healthy sessions into `failed/`.
8. **Done**: `mv processing/<uuid>.json done/<uuid>.json` + write `done/<uuid>.result`.

**Starting claude:**

```bash
cd <cwd>
export CLAUDE_AGENT_NAME=<name>          # parent-child naming
unset CLAUDE_CODE_OAUTH_TOKEN             # CRITICAL — otherwise remote control is silently disabled
claude --remote-control <name> \
       --permission-mode <pm> \
       --model <model> \
       --effort <effort> \
       [--brief] \
       [--worktree=<name>] \             # explicit =<name> syntax (otherwise the prompt becomes the worktree name!)
       <prompt>
```

### 2.2. Watchdog

A periodic task (every 5 minutes, say):

1. It checks whether the command-center terminal-multiplexer session is alive. ⚠️ Its name is **not** `agent-` prefixed: in the reference implementation the command center is `mac-main` and the children are `agent-<name>`. So `tmux ls | grep ^agent-` gives exactly the children and not the command center — several scripts rely on this.
2. If it is not alive → restart it (the equivalent of `start.sh`).

It may contain further health checks too (queue spawner alive, queue size sane, and so on).

### 2.3. Command-center session (`start.sh`)

A script that starts the "main" `claude --remote-control` session in the background. This session has a **fixed name** (`mac-main`, `linux-main`, or something from the user's config). The mobile app connects to this.

The session's starting prompt returns the slash-command help banner on the user's first message — so the command palette is visible immediately on the phone.

### 2.4. Slash commands

Claude Code slash commands are markdown files under `~/.claude/commands/`. The spawner bundle ships **five**:

- **`/new-agent`** — a chat-question-based wizard that walks through the fields sequentially with free-text answers (name, cwd, prompt, model, effort, permission, worktree), then writes a JSON spec into the queue's `new/` folder. After choosing `opus` a conditional follow-up asks about the version (Opus 5 / 4.8 / 4.7) and the context (default / `[1m]`) — which is possible because the chat flow is sequential, and would not be with a batched picker. Step 0, "Default vs Custom", is the only place where an `AskUserQuestion` picker runs.
- **`/close-agent`** — the orderly close of a running agent. In worktree mode it asks separately: merge or drop.
- **`/kill-agent`** — an immediate kill of the agent(s) picked from a list (tmux kill-session, worktree drop if there was one).
- **`/kill-all-exit`** — kill every agent, and the current session exits too.
- **`/fork`** — branching the CURRENT session into a child agent that inherits the conversation.

The format of the markdown files: YAML frontmatter (`description:`) plus free text with instructions for Claude. See the existing `new-agent.md` / `close-agent.md` files as examples.

---

## 3. Platform-specific implementation

### 3.1. macOS

**Background service:** a `launchd` LaunchAgent (`~/Library/LaunchAgents/<label>.plist`)

```xml
<key>WatchPaths</key>
<array>
  <string>/Users/<you>/.claude/agent-queue/new</string>
</array>
<key>ThrottleInterval</key>
<integer>1</integer>
```

`WatchPaths` is a direct filesystem event (FSEvents), not polling.

The watchdog is a separate launchd plist with `StartInterval` 300 (5 minutes).

**Terminal multiplexer:** `tmux` — `brew install tmux`.

```bash
tmux new-session -d -s "agent-<name>" "<shell command>"
```

The tmux session survives the parent process exiting, and can be attached from anywhere.

**Installation**: `install.sh` (zsh), `launchctl bootstrap gui/$(id -u) <plist>`.

### 3.2. Linux

**Background service (3 options):**

**A) systemd user service + path unit** (modern, recommended)

`~/.config/systemd/user/agent-spawner.path`:
```ini
[Path]
PathChanged=%h/.claude/agent-queue/new
Unit=agent-spawner.service

[Install]
WantedBy=default.target
```

`~/.config/systemd/user/agent-spawner.service`:
```ini
[Service]
Type=oneshot
ExecStart=%h/.claude/agent-queue/bin/claude-agent-spawner
```

Activation: `systemctl --user enable --now agent-spawner.path`.

**B) an inotifywait loop** (simpler, if there is no systemd):

```bash
#!/bin/bash
while inotifywait -e create,moved_to "$HOME/.claude/agent-queue/new"; do
  "$HOME/.claude/agent-queue/bin/claude-agent-spawner"
done
```

Start it with `tmux new-session -d -s spawner-loop "..."` or `nohup ... &` or a simple systemd unit.

**C) cron polling** (the worst; do not pick this unless nothing else works)

**Terminal multiplexer:** `tmux` (or `screen`). Both work the same way. tmux is recommended.

**Watchdog:** a systemd timer (`agent-watchdog.timer` + `agent-watchdog.service`, `OnUnitActiveSec=5min`).

**Installation**: `install.sh` (bash), `systemctl --user enable --now ...`.

### 3.3. Windows

Two viable routes:

**A) WSL2 (Windows Subsystem for Linux) — recommended**

Install the Linux version inside a WSL2 distribution. Every Linux instruction applies. The `claude` CLI works perfectly when run from WSL. The queue folder is reachable from Windows too under `\\wsl$\<distro>\home\<user>\.claude\...`, if you want to drop a spec from Windows-side tooling.

The command-center session `claude --remote-control` is reachable from the mobile app just as on Linux/macOS.

**B) Native Windows**

Much more work, and `tmux` is not available natively. Implementation:

- **Background service:** a PowerShell `FileSystemWatcher` with `Register-ObjectEvent`; a Scheduled Task starts the watcher script at login.
  ```powershell
  $w = New-Object System.IO.FileSystemWatcher "$env:USERPROFILE\.claude\agent-queue\new"
  Register-ObjectEvent $w Created -Action { & "$env:USERPROFILE\.claude\agent-queue\bin\claude-agent-spawner.ps1" }
  ```
- **Instead of a terminal multiplexer:** there is no native tmux. Options:
  - A Windows Terminal new tab — scriptable with the `wt` CLI (`wt new-tab --title agent-<name> claude ...`), but it cannot be detached headlessly.
  - A background process with `Start-Process -WindowStyle Hidden` — it runs, but there is no easy "attach" mode.
  - **ConPTY** plus your own small multiplexer — serious work.
  - **GNU Screen on Cygwin** — it works, but by then WSL is worth it anyway.
- **Watchdog:** a Scheduled Task with `RepetitionInterval=PT5M`.
- **Installation**: a PowerShell `install.ps1`.

A native Windows port needs real product work on the multiplexer layer. **The WSL2 route is strongly recommended.**

### 3.4. Platform abstraction in the code

If the `claude-agent-spawner` script is written in Python (or another cross-platform language):

```python
import platform
import sys

def get_multiplexer():
    if platform.system() == "Windows":
        return WindowsTerminalMultiplexer()  # or ConPTY
    elif platform.system() == "Darwin" or platform.system() == "Linux":
        return TmuxMultiplexer()

def get_queue_dir():
    if platform.system() == "Windows":
        return Path(os.environ["USERPROFILE"]) / ".claude" / "agent-queue"
    else:
        return Path.home() / ".claude" / "agent-queue"
```

If it stays in bash: a separate `claude-agent-spawner.sh` (POSIX shell, macOS+Linux) and `claude-agent-spawner.ps1` (Windows).

---

## 4. The JSON spec format

```json
{
  "name": "proj-main-refactor",
  "cwd": "/Users/me/ClaudeProjects/myproject",
  "prompt": "Refactor the auth module and add tests",
  "model": "opus",
  "effort": "high",
  "permission_mode": "auto",
  "brief": true,
  "worktree": true
}
```

### Fields and validation

| field | type | validation |
|---|---|---|
| `name` | string | regex `^[a-zA-Z0-9_-]{3,64}$`. The watcher rejects anything outside it. The tmux session is `agent-<name>`. |
| `cwd` | string (absolute path) | Only under `~/ClaudeProjects` (allowlist, checked BEFORE creation). If relative: prepend `~/ClaudeProjects/`. If it does not exist: **an error** — except with `create_cwd: true`. Tilde and env expansion. |
| `prompt` | string | Non-empty, at most 8 KB. UTF-8. |
| `model` | enum | The `opus` / `sonnet` / `haiku` / `fable` aliases; pinned Claude 5: `claude-opus-5` / `claude-sonnet-5` / `claude-fable-5` / `claude-haiku-4-5`; pinned Opus 4: `claude-opus-4-7` / `claude-opus-4-8`; an optional `[1m]` context suffix (e.g. `claude-opus-5[1m]`). ⚠️ THREE validators hold this list (the spawner, the bridge, `fork-agent`) — they have to move together. |
| `effort` | enum | `low` / `medium` / `high` / `xhigh` / `max`. |
| `permission_mode` | enum | The actual choices of `claude --permission-mode`: `auto` / `manual` / `acceptEdits` / `plan` / `dontAsk` / `bypassPermissions`. ⚠️ `default` **does not exist** — the session dies within 3 seconds with it, with a misleading "check flags / auth" message. |
| `brief` | bool | Default `true`. In today's CLI it toggles the `SendUserMessage` tool, not the length of the answers. |
| `create_cwd` | bool | Default `false`. Only then is a non-existent cwd created — typo protection. |
| `worktree` | bool | Default `false`. If `true`: the cwd has to be a git repository. |

`name` must be prefixed with the parent session's name (parent-child naming):

```bash
PARENT="${CLAUDE_AGENT_NAME:-mac}"
if [[ "$NAME" != "${PARENT}-"* ]]; then
  NAME="${PARENT}-$NAME"
fi
```

This way the session tree is traceable: `mac-main` → `mac-main-foo` → `mac-main-foo-bar`.

### Queue states (the file system as a state machine)

```
~/.claude/agent-queue/
├── new/          ← drop here → the spawner picks it up
├── processing/   ← the spawner is working on it (race-safe atomic mv)
├── done/         ← started successfully; <uuid>.json + <uuid>.result
└── failed/       ← a bad spec; <uuid>.json + <uuid>.reason
```

The `processing/` step is race-condition protection for several concurrent watchers — `mv` is atomic at the filesystem level.

---

## 5. Slash command details

The key to the `/new-agent` slash command implementation is asking step by step. The reference implementation asks for the **fields with chat questions** (a picker runs only at the very first, "Default vs Custom" choice), and after the last parameter it writes the spec into the queue immediately, without confirmation. There is a single exception where it MUST ask back: when the given cwd does not exist.

### 5.1. Asking

Two modes, and the choice between them is the only place where a picker (`AskUserQuestion`) runs:
- **Default** — a default value for every field, queued immediately.
- **Custom** — 7 steps (name, cwd, prompt, model, effort, permission, worktree), with **chat questions** and free-text answers.

Why a chat question and not a picker: the sequential flow permits a **conditional follow-up** — after choosing `opus` comes the version (Opus 5 / 4.8 / 4.7), then the context (`default` / `[1m]`). This would not be possible with a batched picker, because the previous answer determines the next question.

On the enum fields, **ask back in chat** for an unrecognizable answer rather than guessing — the spawner's whitelist would reject it anyway, just in the `failed/` folder, where the user is not looking.

### 5.2. The worktree edge case

The `claude --worktree` flag needs the **explicit `=<name>` syntax**:

```bash
# GOOD:
claude --remote-control foo --worktree=foo <prompt>
# BAD — the prompt becomes the worktree name, because it is positional!
claude --remote-control foo --worktree foo <prompt>
```

### 5.3. The CWD allowlist

Only a path under `~/ClaudeProjects` is allowed. The user gives a **relative** path (relative to the `ClaudeProjects` root); absolute or `~/`-prefixed input → reject and re-prompt.

The spawner protects itself as well: if an absolute path outside `~/ClaudeProjects` does arrive in the JSON → `failed/`.

---

## 6. Watchdog details

```bash
#!/bin/bash
# watchdog.sh
TARGET_SESSION="${COMMAND_CENTER_NAME:-mac-main}"   # NOT `agent-` prefixed, see 2.2
if ! tmux has-session -t "$TARGET_SESSION" 2>/dev/null; then
  # not running → start it
  "$HOME/.claude/agent-queue/bin/start.sh"
  logger -t agent-watchdog "restarted $TARGET_SESSION"
fi
```

A reference interval: 5 minutes. More frequent (1 minute) is pointless; rarer (15+ minutes) gives a slow recovery.

The watchdog **has to protect itself** against an infinite restart loop: if the session dies 3 times in a row within 60 seconds, it should stop and put a "broken" marker into the queue (`~/.claude/agent-queue/watchdog.broken`), so it does not try to restart endlessly in the mobile app.

> ⚠️ The reference implementation **did not build this**: there is no `watchdog.broken` marker and no counter. What it does have is protection against a different danger (`mac-main-watchdog.sh:60`): during a launchd start the watchdog can see a LIVE session as dead and start a second one alongside it. Loop protection is still a good idea — but design it, do not copy it from here as if it were finished.

---

## 7. Critical gotchas

1. **Unsetting `CLAUDE_CODE_OAUTH_TOKEN` is mandatory** at the top of the spawner script. The long-lived token is inference-only auth, and it **silently disables** the Remote Control feature. The spawned agent still runs, but does not appear on the mobile Code tab. This is **hard to debug** if you do not know it.

2. **A full claude.ai login on the host machine.** The `claude /login` browser flow has to be completed. Spawned sessions run with that login's auth. If the login expires (~30 days), new spawns die silently. It is worth monitoring for this (see "Token expiry detect" in the ROADMAP).

3. **The positional-arg parser quirk of `--worktree`** — an explicit `=` is needed, see 5.2.

4. **Tmux session name uniqueness** — on an `agent-<name>` collision the reference implementation adds an **auto suffix** (`-2` … `-99`), see 2.1/5. ⚠️ Which has a price: the kill cascade matches on a prefix (`^NAME$|^NAME-`), so killing `foo` takes `foo-2` with it. If you do not want that, reject the duplicate name — but then tell the user, do not just drop it into `failed/`.

5. **Atomic mv** is only guaranteed on the same filesystem. Keep all four queue folders on the same partition.

6. **The spawner script should not do heavy work** in the watcher's event callback — it should only iterate over `new/` and spawn. If the spawn is slow, launchd / systemd will not be able to react to a new event in time (or it will, but they queue up — not optimal).

---

## 8. Implementation order (recommended)

1. **The JSON spec + validation** — a simple spawner script that reads, validates, and merely `echo`s instead of a successful spawn. Testable by hand with `cp spec.json ~/.../new/`.
2. **Spawn** — an actual `claude` start in a tmux session.
3. **launchd/systemd integration** — have the watcher started by file events.
4. **The `/new-agent` slash command** — in Default mode first, then Custom.
5. **`/kill-agent`** — listing, selection and a tmux kill.
6. **`/close-agent`** — kill plus a worktree merge/drop.
7. **`/kill-all-exit`** — the emergency brake.
8. **The command-center session + `start.sh`** — a fixed-name session with the help-banner system prompt.
9. **Watchdog** — a periodic health check.
10. **The installer** — an `install.sh` that puts all of this together.

---

## 9. Testing

**Unit level:** test the spawner script in isolation with a shell test framework (`bats` for shell, `pytest` for Python). Mock the `tmux` and `claude` binaries.

**Integration level:**

```bash
# 1. drop a spec
jq -n --arg name "test-spawn" --arg prompt "Say hello" \
  '{name:$name, prompt:$prompt}' \
  > ~/.claude/agent-queue/new/$(uuidgen).json

# 2. check it
sleep 3
tmux ls | grep agent-test-spawn
ls ~/.claude/agent-queue/done/

# 3. cleanup
tmux kill-session -t agent-test-spawn
```

**Mobile level:** open the Claude mobile app, Code tab. The spawned agent has to appear. Send it a "hello" and wait for an answer.

---

## 10. Definition of done

The project is finished when:

- [ ] On a fresh machine, after `install.sh` (or `.ps1`) has run, a single `/new-agent Default` run produces a working background agent that appears in the mobile app.
- [ ] All 5 slash commands are available and work robustly (try `/close-agent` with a deleted agent, `/kill-all-exit` with an empty queue, and so on).
- [ ] The watchdog restarts the command-center session when you kill it.
- [ ] A malformed JSON spec lands in `failed/` with an understandable `.reason` file.
- [ ] Race-condition test: two concurrent spawner runs on the same spec — exactly one spawn happens.
- [ ] The user sends specs whose names are prefixed from the `CLAUDE_AGENT_NAME` env variable, and the parent-child naming is traceable.
- [ ] Documentation: README plus installation plus the `claude /login` setup explained.

---

## 11. References

- The existing macOS implementation: this repository (https://github.com/ZsoltSziklai/claude-code-agent-spawner)
- Claude Code documentation: https://docs.claude.com/en/docs/claude-code
- The Remote Control feature: the `claude --remote-control <name>` flag (a full claude.ai login is required)
- tmux documentation: https://github.com/tmux/tmux/wiki
- systemd path units: https://www.freedesktop.org/software/systemd/man/systemd.path.html
- launchd WatchPaths: https://www.launchd.info/
- Windows FileSystemWatcher: https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher

---

**To get started:** read the existing `claude-agent-spawner` script and the `new-agent.md` slash command — those are the most valuable references. The rest (the Linux and Windows ports) is built on their pattern with the platform specifics described in section 3.

---

## Magyar változat

Ez a dokumentum egy önálló, copy-paste-elhető prompt Claude Code (vagy bármilyen másik LLM-alapú coding agent) számára. Aki ezt elolvassa, képes legyen a rendszer **magját** — a queue-t, a spawnert, a watchdogokat és a slash-parancsokat — a nulláról újraimplementálni a saját platformján.

**Hatókör:** a Desktop-híd (relay, poller, felhatalmazások, beragadás-észlelés — nagyjából 1200 sor) és a `fork-agent` belseje **nincs** benne. Azokhoz a `bridge-README.md` és a `desktop-skill/agent-bridge/SKILL.md` a kiindulás.

> ⚠️ **Ha ez a dokumentum és a kód ellentmond, a KÓD az igazság.** Ez a leírás
> újraimplementálási recept, nem specifikáció — a `bin/` és a `claude-agent-spawner`
> mindig frissebb. Több pontján (cwd-kezelés, permission-módok, modell-lista) a
> repó tudatosan szigorúbb annál, ami itt szerepelt korábban; a lentiek már a
> javított viselkedést írják le.

---

### 0. TL;DR a feladatról

Építs egy **queue-alapú háttér-agent orchestrator**-t [Claude Code](https://claude.com/claude-code)-hoz. Lehetővé teszi, hogy a felhasználó több párhuzamos Claude Code session-t indítson a háttérben — terminálból, futó agent-ből, vagy a Claude mobil app-ból (Code tab). Egy állandóan futó "command-center" session-re csatlakozhat a mobilról, és onnan slash command-okkal indít új háttér agenteket.

Két háttérszolgáltatás fut a rendszeren:

1. **Queue spawner** — egy mappa-figyelő file watcher. Amikor JSON spec fájl kerül a queue `new/` almappájába, elindít belőle egy önálló `claude` CLI session-t saját terminál-multiplexer ablakban (tmux / screen / ConPTY), opcionálisan saját git worktree-ben.
2. **Watchdog** — periodikusan ellenőrzi, hogy a command-center session él-e. Ha leállt, újraindítja.

A `claude --remote-control <name>` flag-gel indított session-ök megjelennek a mobil Claude app Code tabján — onnan vezérelhetők. Ehhez full claude.ai login kell (a long-lived `CLAUDE_CODE_OAUTH_TOKEN` env var ezt **letiltja**, ezért a spawner unset-eli).

---

### 1. Magas szintű architektúra

```
┌──────────────────┐         ┌──────────────────────┐
│  felhasználó     │ ssh /   │   command-center     │
│  (terminál vagy  │────────▶│   claude session     │
│   Claude mobile) │         │   (állandóan fut)    │
└──────────────────┘         └──────────┬───────────┘
                                        │ /new-agent
                                        ▼
                             ┌──────────────────────┐
                             │  ~/.../queue/new/    │
                             │      <uuid>.json     │◀── bármi más is írhat ide
                             └──────────┬───────────┘  (cron, webhook, másik agent)
                                        │ inotify / FSEvents / ReadDirectoryChangesW
                                        ▼
                             ┌──────────────────────┐
                             │  queue spawner       │
                             │  (file watcher)      │
                             └──────────┬───────────┘
                                        │ spawn
                                        ▼
                             ┌──────────────────────┐
                             │  háttér agent #1     │  ◀── tmux / screen / ConPTY
                             │  háttér agent #2     │  ◀── opcionális git worktree
                             │  ...                 │
                             └──────────────────────┘
```

A `watchdog` ezzel párhuzamosan, percenként vagy 5-percenként ellenőrzi a command-center session életét.

---

### 2. Komponensek

#### 2.1. Queue spawner (`claude-agent-spawner`)

Egy shell / Python / PowerShell script, amit a platform háttér-szolgáltatása indít file change esemény hatására.

**Bemenete:** `~/.claude/agent-queue/new/<uuid>.json`

**Kimenete:**
- Sikeres → `done/<uuid>.json` + `done/<uuid>.result` (started_at, tmux_session, remote_session_name, cwd, model, effort, permission_mode)
- Hibás → `failed/<uuid>.json` + `failed/<uuid>.reason`

**Lépések egy spec-re:**

1. **Atomic claim**: `mv new/<uuid>.json processing/<uuid>.json`. Ha az `mv` failel (más watcher már elvitte), `continue`.
2. **JSON validation**: parse-old, ha hibás → `failed/`.
3. **Field validation** (lásd 4. szakasz JSON spec).
4. **CWD setup**: **ELŐBB az allowlist-ellenőrzés** (csak `~/ClaudeProjects` alatt), és csak azután bármilyen létrehozás — fordított sorrendben egy kívülre mutató cwd előbb hozna létre könyvtárakat, és csak utána bukna. A nem létező cwd **hiba**, nem felhívás: egy elgépelés különben csendben üres könyvtárat kapna, és az agent a projekt helyett abban dolgozna. Szándékos új könyvtárhoz külön mező kell (`create_cwd: true`).
5. **Tmux session collision check**: `agent-<name>` névvel már létezik? A referencia-implementáció **auto-suffixet** ad (`-2` … `-99`), nem utasítja el a kérést.
6. **Spawn**: indítsd el a `claude` CLI-t egy új terminál-multiplexer session-ben. Részletek lent platformonként.
7. **Smoke check**: várj pár másodpercet, ellenőrizd hogy a spawnolt process él-e. Ha nem (auth fail, hibás flag, stb.) → `failed/`. A referencia-implementáció **3** másodpercet vár az egyszerű spawn után és **5**-öt a fork után (az utóbbi átiratot tölt be, tehát lassabban jelenti magát élőnek) — ha túl rövidre veszed, egészséges sessionöket fogsz a `failed/` mappába ejteni.
8. **Done**: `mv processing/<uuid>.json done/<uuid>.json` + write `done/<uuid>.result`.

**A claude indítása:**

```bash
cd <cwd>
export CLAUDE_AGENT_NAME=<name>          # parent-child naming
unset CLAUDE_CODE_OAUTH_TOKEN             # KRITIKUS — különben remote control silent-disable
claude --remote-control <name> \
       --permission-mode <pm> \
       --model <model> \
       --effort <effort> \
       [--brief] \
       [--worktree=<name>] \             # explicit =<name> szintaxis (különben a prompt-ot kapja worktree-névnek!)
       <prompt>
```

#### 2.2. Watchdog

Periodikus task (pl. 5 percenként):

1. Megnézi: él-e a command-center terminál-multiplexer session. ⚠️ Ennek a neve **nem** `agent-` prefixes: a referencia-implementációban a parancsközpont `mac-main`, a gyerekek `agent-<név>`. A `tmux ls | grep ^agent-` így pontosan a gyerekeket adja, a parancsközpontot nem — több szkript épít erre.
2. Ha nem él → indítsd újra (`start.sh` ekvivalens).

Tartalmazhat további egészségellenőrzéseket is (pl. queue spawner alive, queue size sane, stb.).

#### 2.3. Command-center session (`start.sh`)

Egy script ami indítja a "fő" `claude --remote-control` session-t a háttérben. Ennek a session-nek **rögzített név**-e van (pl. `mac-main`, `linux-main`, vagy felhasználói config alapján). A mobil app erre kapcsolódik.

A session indító prompt-ja a slash command help banner-t adja vissza a felhasználó első üzenetére — így mobilon azonnal látszik a parancs-paletta.

#### 2.4. Slash command-ok

A Claude Code slash command-ok markdown fájlok `~/.claude/commands/` alatt. A spawner bundle **ötöt** szállít:

- **`/new-agent`** — chat-question alapú wizard ami szekvenciálisan végigkérdezi a mezőket szabad-szöveges válaszokkal (név, cwd, prompt, model, effort, permission, worktree), majd a végén kiír egy JSON spec-et a queue `new/` mappájába. Az `opus` választása után feltételes al-kérdés jön a verzióra (Opus 5 / 4.8 / 4.7) és context-re (default / `[1m]`) — ez a szekvenciális chat-flow miatt lehetséges, batched pickerrel nem lenne. A Step 0 "Default vs Egyéni" az egyetlen hely ahol `AskUserQuestion` picker fut.
- **`/close-agent`** — futó agent rendezett lezárása. Worktree mode-nál külön megkérdezi: merge vagy drop.
- **`/kill-agent`** — listából kiválasztott agent(ek) azonnali killje (tmux kill-session, worktree drop ha volt).
- **`/kill-all-exit`** — minden agent kill + a jelenlegi session is kilép.
- **`/fork`** — az AKTUÁLIS session elágaztatása egy gyerek-agentbe, ami örökli a beszélgetést.

A markdown fájlok formátuma: YAML frontmatter (`description:`) + szabad szöveg instrukcióval Claude-nak. Lásd a meglévő `new-agent.md` / `close-agent.md` fájlokat példának.

---

### 3. Platform-specifikus implementáció

#### 3.1. macOS

**Háttér-szolgáltatás:** `launchd` LaunchAgent (`~/Library/LaunchAgents/<label>.plist`)

```xml
<key>WatchPaths</key>
<array>
  <string>/Users/<you>/.claude/agent-queue/new</string>
</array>
<key>ThrottleInterval</key>
<integer>1</integer>
```

A `WatchPaths` direkt fájlrendszeri esemény (FSEvents), nem polling.

A watchdog külön launchd plist `StartInterval` 300-zal (5 perc).

**Terminál multiplexer:** `tmux` — `brew install tmux`.

```bash
tmux new-session -d -s "agent-<name>" "<shell command>"
```

A tmux session megmarad ha a parent process kilép, és bárhonnan attach-elhető.

**Telepítés**: `install.sh` (zsh), `launchctl bootstrap gui/$(id -u) <plist>`.

#### 3.2. Linux

**Háttér-szolgáltatás (3 opció):**

**A) systemd user service + path unit** (modern, ajánlott)

`~/.config/systemd/user/agent-spawner.path`:
```ini
[Path]
PathChanged=%h/.claude/agent-queue/new
Unit=agent-spawner.service

[Install]
WantedBy=default.target
```

`~/.config/systemd/user/agent-spawner.service`:
```ini
[Service]
Type=oneshot
ExecStart=%h/.claude/agent-queue/bin/claude-agent-spawner
```

Aktiválás: `systemctl --user enable --now agent-spawner.path`.

**B) inotifywait loop** (egyszerűbb, ha nincs systemd):

```bash
#!/bin/bash
while inotifywait -e create,moved_to "$HOME/.claude/agent-queue/new"; do
  "$HOME/.claude/agent-queue/bin/claude-agent-spawner"
done
```

Indítás `tmux new-session -d -s spawner-loop "..."` vagy `nohup ... &` vagy egy egyszerű systemd unit.

**C) cron polling** (legrosszabb, ne ezt válaszd, csak ha más nem megy)

**Terminál multiplexer:** `tmux` (vagy `screen`). Mindkettő ugyanúgy működik. Tmux ajánlott.

**Watchdog:** systemd timer (`agent-watchdog.timer` + `agent-watchdog.service`, `OnUnitActiveSec=5min`).

**Telepítés**: `install.sh` (bash), `systemctl --user enable --now ...`.

#### 3.3. Windows

Két érdemi út:

**A) WSL2 (Windows Subsystem for Linux) — ajánlott**

Telepítsd a Linux verziót egy WSL2 disztribúción belül. Minden Linux-os útmutatás érvényes. A `claude` CLI WSL-ből futtatva tökéletesen működik. A queue mappa `\\wsl$\<distro>\home\<user>\.claude\...` alatt elérhető Windows-ról is, ha a Win-oldali toolokból akarsz spec-et beejteni.

A command-center session `claude --remote-control` ugyanúgy elérhető a mobil app-ból, mint Linux/macOS-en.

**B) Natív Windows**

Sokkal több munka, és a `tmux` nem érhető el natívan. Implementáció:

- **Háttér-szolgáltatás:** PowerShell `FileSystemWatcher` egy `Register-ObjectEvent`-tel; egy Scheduled Task indítja a watcher script-et bejelentkezéskor.
  ```powershell
  $w = New-Object System.IO.FileSystemWatcher "$env:USERPROFILE\.claude\agent-queue\new"
  Register-ObjectEvent $w Created -Action { & "$env:USERPROFILE\.claude\agent-queue\bin\claude-agent-spawner.ps1" }
  ```
- **Terminál multiplexer helyett:** nincs natív tmux. Opciók:
  - Windows Terminal new tab — script-elhető a `wt` CLI-vel (`wt new-tab --title agent-<name> claude ...`), de nem detach-elhető headless.
  - Háttér process `Start-Process -WindowStyle Hidden` — fut, de nincs könnyű "attach" mód.
  - **ConPTY** + saját kis multiplexer — komoly munka.
  - **GNU Screen Cygwin-en** — működik, de odáig már WSL is megéri.
- **Watchdog:** Scheduled Task `RepetitionInterval=PT5M`.
- **Telepítés**: PowerShell `install.ps1`.

A natív Windows port érdemi termékfejlesztést igényel a multiplexer-rétegen. **Erősen javasolt a WSL2 út.**

#### 3.4. Platform-abstrakció a kódban

Ha a `claude-agent-spawner` script Python-ban (vagy más cross-platform nyelven) készül:

```python
import platform
import sys

def get_multiplexer():
    if platform.system() == "Windows":
        return WindowsTerminalMultiplexer()  # vagy ConPTY
    elif platform.system() == "Darwin" or platform.system() == "Linux":
        return TmuxMultiplexer()

def get_queue_dir():
    if platform.system() == "Windows":
        return Path(os.environ["USERPROFILE"]) / ".claude" / "agent-queue"
    else:
        return Path.home() / ".claude" / "agent-queue"
```

Ha bash-ban marad: külön `claude-agent-spawner.sh` (POSIX shell, macOS+Linux) és `claude-agent-spawner.ps1` (Windows).

---

### 4. JSON spec formátum

```json
{
  "name": "proj-main-refactor",
  "cwd": "/Users/me/ClaudeProjects/myproject",
  "prompt": "Refactor the auth module and add tests",
  "model": "opus",
  "effort": "high",
  "permission_mode": "auto",
  "brief": true,
  "worktree": true
}
```

#### Mezők és validáció

| mező | típus | validáció |
|---|---|---|
| `name` | string | regex `^[a-zA-Z0-9_-]{3,64}$`. Watcher reject ha kívül esik. Tmux session = `agent-<name>`. |
| `cwd` | string (abszolút path) | Csak `~/ClaudeProjects` alatt (allowlist, a létrehozás ELŐTT ellenőrizve). Ha relatív: prepend `~/ClaudeProjects/`. Ha nem létezik: **hiba** — kivéve `create_cwd: true`. Tilde + env expansion. |
| `prompt` | string | Nem üres, max 8 KB. UTF-8. |
| `model` | enum | `opus` / `sonnet` / `haiku` / `fable` aliasok; pinned Claude 5: `claude-opus-5` / `claude-sonnet-5` / `claude-fable-5` / `claude-haiku-4-5`; pinned Opus 4: `claude-opus-4-7` / `claude-opus-4-8`; opcionális `[1m]` context-suffix (pl. `claude-opus-5[1m]`). ⚠️ A listát HÁROM validátor tartja (spawner, híd, fork-agent) — együtt kell mozogniuk. |
| `effort` | enum | `low` / `medium` / `high` / `xhigh` / `max`. |
| `permission_mode` | enum | A `claude --permission-mode` tényleges választéka: `auto` / `manual` / `acceptEdits` / `plan` / `dontAsk` / `bypassPermissions`. ⚠️ `default` **nem létezik** — a session 3 mp-en belül elhal vele, félrevezető „check flags / auth" üzenettel. |
| `brief` | bool | Default `true`. A mai CLI-ben a `SendUserMessage` toolt kapcsolja, nem a válaszok hosszát. |
| `create_cwd` | bool | Default `false`. Csak ekkor jön létre a nem létező cwd — elgépelés-védelem. |
| `worktree` | bool | Default `false`. Ha `true`: cwd-nek git repo-nak kell lennie. |

A `name` kötelezően prefix-elt a szülő session nevével (parent-child naming):

```bash
PARENT="${CLAUDE_AGENT_NAME:-mac}"
if [[ "$NAME" != "${PARENT}-"* ]]; then
  NAME="${PARENT}-$NAME"
fi
```

Így a session-fa végigkövethető: `mac-main` → `mac-main-foo` → `mac-main-foo-bar`.

#### Queue állapotok (file system mint state machine)

```
~/.claude/agent-queue/
├── new/          ← drop ide → spawner felkapja
├── processing/   ← spawner éppen dolgozik rajta (race-safe atomic mv)
├── done/         ← sikeresen elindítva; <uuid>.json + <uuid>.result
└── failed/       ← hibás spec; <uuid>.json + <uuid>.reason
```

A `processing/` lépés race-condition védelem több párhuzamos watcher esetén — `mv` filerendszeri szinten atomic.

---

### 5. Slash command részletek

A `/new-agent` slash command implementáció kulcsa a lépésenkénti kérdezés. A referencia-implementáció a **mezőket chat-kérdésekkel** kérdezi (picker csak a legelső, „Default vagy Egyéni" választásnál fut), és az utolsó paraméter után azonnal, megerősítés nélkül írja a specet a queue-ba. Egyetlen kivétel, ahol vissza KELL kérdezni: ha a megadott cwd nem létezik.

#### 5.1. Kérdezés

Két mód, és a választás az egyetlen hely, ahol picker (`AskUserQuestion`) fut:
- **Default** — minden mezőre alapértelmezett érték, azonnali queue.
- **Egyéni** — 7 lépés (név, cwd, prompt, model, effort, permission, worktree), **chat-kérdésekkel**, szabad-szöveges válaszokkal.

Miért chat-kérdés és nem picker: a szekvenciális folyam megengedi a **feltételes al-kérdést** — az `opus` választása után jön a verzió (Opus 5 / 4.8 / 4.7), majd a context (`default` / `[1m]`). Egy batchelt pickerrel ez nem lenne lehetséges, mert a következő kérdést az előző válasza határozza meg.

Az enum mezőknél a felismerhetetlen választ **chat-ben kérdezd vissza**, ne találgass — a spawner fehérlistája úgyis elutasítaná, csak épp a `failed/` mappában, ahol a felhasználó nem nézi.

#### 5.2. Worktree edge case

A `claude --worktree` flag-nél **explicit `=<name>` szintaxist** kell használni:

```bash
# JÓ:
claude --remote-control foo --worktree=foo <prompt>
# ROSSZ — a prompt lesz a worktree neve, mert positional!
claude --remote-control foo --worktree foo <prompt>
```

#### 5.3. CWD allowlist

Csak `~/ClaudeProjects` alatti útvonal engedélyezett. A felhasználó **relatív** útvonalat ad meg (a `ClaudeProjects` gyökérhez képest); abszolút vagy `~/` kezdetű input → reject + re-prompt.

A spawner is védi magát: ha mégis abszolút path jönne a JSON-ban, ami `~/ClaudeProjects`-en kívül van → `failed/`.

---

### 6. Watchdog részletei

```bash
#!/bin/bash
# watchdog.sh
TARGET_SESSION="${COMMAND_CENTER_NAME:-mac-main}"   # NEM `agent-` prefixes, lásd 2.2
if ! tmux has-session -t "$TARGET_SESSION" 2>/dev/null; then
  # nem fut → indítsuk
  "$HOME/.claude/agent-queue/bin/start.sh"
  logger -t agent-watchdog "restarted $TARGET_SESSION"
fi
```

Hivatkozási idő: 5 perc. Túl gyakori (1 perc) felesleges; ritkább (15+ perc) lassú feltápot ad.

A watchdog-nak **védenie kell magát** a végtelen újraindítási hurok ellen: ha a session 3-szor egymás után 60 másodpercen belül lehal, álljon meg és tegyen "broken" markert a queue-ba (`~/.claude/agent-queue/watchdog.broken`), a mobil app-ban ne próbáljon végtelenül újraindítani.

> ⚠️ Ezt a referencia-implementáció **így nem építette meg**: nincs `watchdog.broken` marker és nincs számláló. Amije van, az egy másik veszély elleni védelem (`mac-main-watchdog.sh:60`): a launchd-indítás alatt a watchdog egy ÉLŐ sessiont is halottnak láthat, és mellé indítana egy másodikat. A hurok-védelem továbbra is jó ötlet — de tervezd meg, ne másold innen késznek.

---

### 7. Kritikus gotchas

1. **`CLAUDE_CODE_OAUTH_TOKEN` unset kötelező** a spawner script elején. A long-lived token inference-only auth, a Remote Control feature-t **csendben letiltja**. A spawnolt agent még fut, de nem jelenik meg a mobil Code tabján. Ezt **nehéz debug-olni**, ha nem tudod.

2. **Full claude.ai login a host gépen.** A `claude /login` browser flow-ját végig kell csinálni. A spawnolt session-ök ennek a login-nak az auth-jával futnak. Ha a login lejár (~30 nap), az új spawnok némán halnak meg. Erre érdemes monitoringot tenni (lásd ROADMAP "Token expiry detect").

3. **Az `--worktree` positional arg parser quirk-je** — explicit `=` kell, lásd 5.2.

4. **Tmux session név uniqueness** — `agent-<name>` ütközésnél a referencia-implementáció **auto-suffixet** ad (`-2` … `-99`), lásd 2.1/5. ⚠️ Aminek viszont ára van: a kill-kaszkád prefix-szel matchel (`^NAME$|^NAME-`), tehát a `foo` kilövése a `foo-2`-t is elviszi. Ha ezt nem akarod, a duplikált nevet utasítsd el — de akkor mondd is meg a felhasználónak, ne csak a `failed/`-be ejtsd.

5. **Atomic mv** csak ugyanazon a filesystem-en garantált. A queue mind a 4 mappáját ugyanazon a partíción tartsd.

6. **A spawner script ne futtasson nehéz munkát** a watcher esemény-callback-jében — csak iteráljon a `new/`-en és spawnoljon. Ha lassú a spawn, a launchd / systemd nem fog tudni új eseményre reagálni időben (vagy fog, de queue-zódnak — nem optimális).

---

### 8. Implementációs sorrend (ajánlott)

1. **JSON spec + validáció** — egy egyszerű spawner script ami beolvas, validál, és csak `echo`-zik a sikeres spawn helyett. Tesztelhető manuális `cp spec.json ~/.../new/`-vel.
2. **Spawn** — tényleges `claude` indítás tmux session-ben.
3. **launchd/systemd integráció** — a watcher legyen a fájl-eseményekre indítva.
4. **`/new-agent` slash command** — Default módban először, majd Egyéni.
5. **`/kill-agent`** — listázás + select + tmux kill.
6. **`/close-agent`** — kill + worktree merge/drop.
7. **`/kill-all-exit`** — vészfék.
8. **Command-center session + `start.sh`** — fixed-name session help-banner system prompttal.
9. **Watchdog** — periodikus health check.
10. **Telepítő** — `install.sh` ami mindezt összerakja.

---

### 9. Tesztelés

**Unit-szint:** a spawner script-et izoláltan tesztelni shell test framework-kel (`bats` shell-re, `pytest` Python-ra). Mock-old a `tmux` és `claude` binárisokat.

**Integration-szint:**

```bash
# 1. drop egy spec-et
jq -n --arg name "test-spawn" --arg prompt "Say hello" \
  '{name:$name, prompt:$prompt}' \
  > ~/.claude/agent-queue/new/$(uuidgen).json

# 2. ellenőrizd
sleep 3
tmux ls | grep agent-test-spawn
ls ~/.claude/agent-queue/done/

# 3. cleanup
tmux kill-session -t agent-test-spawn
```

**Mobil-szint:** nyisd meg a Claude mobile app-ot, Code tab. A spawnolt agentnek meg kell jelennie. Küldj neki egy "szia" üzenetet, várj választ.

---

### 10. Done definition

A projekt akkor kész, ha:

- [ ] Friss gépen `install.sh` (vagy `.ps1`) lefutása után, egyetlen `/new-agent Default` futtatás működő háttér agentet eredményez ami megjelenik a mobil app-ban.
- [ ] Az 5 slash command mind elérhető és hibatűrően működik (próbálj törölt agenttel `/close-agent`-et, üres queue-val `/kill-all-exit`-et, stb.).
- [ ] A watchdog újraindítja a command-center session-t ha kill-eled.
- [ ] Hibás JSON spec a `failed/` mappába kerül érthető `.reason` fájllal.
- [ ] Race condition-test: két párhuzamos spawner futás ugyanarra a spec-re — pontosan egy spawn történik.
- [ ] A user `CLAUDE_AGENT_NAME` env változó alapján prefixelt nevű spec-eket küld, a parent-child naming végigkövethető.
- [ ] Dokumentáció: README + telepítés + `claude /login` setup magyarázva.

---

### 11. Referenciák

- A meglévő macOS implementáció: ez a repó (https://github.com/ZsoltSziklai/claude-code-agent-spawner)
- Claude Code dokumentáció: https://docs.claude.com/en/docs/claude-code
- Remote Control feature: a `claude --remote-control <name>` flag (full claude.ai login kell)
- tmux dokumentáció: https://github.com/tmux/tmux/wiki
- systemd path units: https://www.freedesktop.org/software/systemd/man/systemd.path.html
- launchd WatchPaths: https://www.launchd.info/
- Windows FileSystemWatcher: https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher

---

**A kezdéshez:** olvasd el a meglévő `claude-agent-spawner` script-et és a `new-agent.md` slash command-ot — ezek a legértékesebb referenciák. A többi (Linux, Windows port) ezek mintájára épül a 3. szakaszban leírt platform-specifikumokkal.
