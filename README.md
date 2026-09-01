# claude-code-agent-spawner

A queue-based background-agent orchestrator for [Claude Code](https://claude.com/claude-code). Spawn multiple parallel Claude Code sessions in the background — from your terminal, from another running agent, or remotely from the Claude mobile app's **Code** tab.

> macOS-only for now (launchd-based). A Linux port (systemd / inotify) would be straightforward — PRs welcome.

**🇭🇺 [Magyar változat](#magyar-változat)**

---

## What it does

- A persistent **command-center session** stays running in the background. You access it from the Claude mobile app or by attaching to its tmux session.
- From the command center (or any other Claude Code session) you can fire off new background agents with `/new-agent` — they each run in their own tmux session, optionally inside their own git worktree.
- Background agents inherit a **name prefix** from their parent, so the session tree stays traceable (`proj-main` → `proj-main-foo` → `proj-main-foo-bar`).
- A **watchdog** restarts the command-center session if it dies, so a crash does not cost you the session. (It restarts the *process*; a session whose Remote Control link has dropped is still alive but temporarily invisible on the phone — that is what `reconnect` is for.)
- A **file bridge** lets a network-isolated environment (Claude Desktop's agent sandbox) hand work to the Mac — gated by a Telegram approval you press on your phone.

## Why

Parallel agents are cheap to start and expensive to brief. The real cost is
re-explaining the context to every new session — what the project is, what was
already tried, what the constraint is. `fork-agent` removes that: the child
starts from the parent's conversation with `--resume … --fork-session`, so it
already knows what you would otherwise have to type again.

The rest follows from that one decision. Once agents descend from each other,
the tree needs a way back (cascade close, merging into the *parent's* branch);
once you delegate instead of watching, you want a gate in front of unattended
task intake and an alarm behind it.

## Slash commands

| Command | What it does |
|---|---|
| `/new-agent` | Menu-driven wizard to queue a new background session (name, cwd, prompt, model, effort, permission mode, worktree). Has a "Default" quick-start. |
| `/close-agent` | Gracefully close a running agent. If it ran in a worktree, asks whether to merge or drop. |
| `/kill-agent` | Pick from a list of running agents and kill them immediately. ⚠️ **Destructive for worktree agents**: the worktree and its `worktree-<name>` branch are deleted, uncommitted work included. Use `/close-agent` to keep the work. |
| `/fork` | Fork the *current* session into a child agent that inherits the conversation. |
| `/kill-all-exit` | Emergency stop — kill all background agents and exit the current session. ⚠️ Same worktree deletion as `/kill-agent`, for every agent at once. |

## Architecture (in a nutshell)

Four launchd jobs run on your machine — two for the core, two for the bridge:

- **Queue spawner** (`claude-agent-spawner`) — a launchd-driven file watcher on `~/.claude/agent-queue/new/`. When `/new-agent` (or anything else) drops a JSON "order" into that mailbox, the spawner picks it up and starts an independent Claude Code session in its own tmux window, optionally in a fresh git worktree.
- **Watchdog** (`bin/mac-main-watchdog.sh`) — runs every 300 s via launchd (`RunAtLoad` too). It restarts the main command-center session if it died, and then sweeps the children (below).
- **Bridge relay** and **bridge poller** — the Desktop bridge (below). They are installed and loaded unconditionally, but stay inert until `bridge-allow.json` is filled in: an empty config is a closed gate, so nothing starts.

Anything that can drop a JSON file into the queue can spawn an agent: a slash command, another agent, a cron job, an SSH-ed-in shell, a webhook, etc.

### Restart survival

A reboot kills every tmux session. The main session comes back by itself, and so do its children:

- On spawn, the spawner writes the agent's spec to a **live registry** (`~/.claude/agent-queue/live/<name>.json`) — "this agent is supposed to be running".
- `bin/agent-child-watchdog.sh` (called by the watchdog, so it shares the same 300 s tick) walks the registry. For every entry whose `agent-<name>` tmux session is gone, it re-spawns the agent with its **original** spec parameters plus `--resume`, so the conversation continues instead of starting from scratch. The id comes from the registry: while an agent runs, the watchdog records **its own** session id there. Guessing "the newest transcript in this cwd" is only a fallback, and only when no other registered agent shares that cwd — otherwise two agents would resume each other's conversation and neither would notice. Worktree agents are restored in the worktree, not the spec cwd.
- `/kill-agent`, `/close-agent` and `/kill-all-exit` **unregister** — an agent you closed on purpose stays closed.
- Restores are bounded (`CLAUDE_AGENT_MAX_RESTORE`, default 3 consecutive failures) so a permanently broken agent can't respawn forever. The counter only resets once the agent is **still** running on a later tick (`CLAUDE_AGENT_MIN_STABLE`, default 120s). Resetting right after the spawn would have bounded only the agent that crashes on startup — one that dies a minute in would respawn forever.
- Because nobody is attached to answer them, the one-shot startup modals (`--chrome` confirmation, the fullscreen-renderer offer, the "resume from summary?" prompt on large sessions) are auto-answered. Resume defaults to *full* — every caller (both watchdogs, `fork-agent`, the bridge's resume) sets it; export `CLAUDE_AGENT_RESUME_MODE=summary` for a cheaper restore that starts from a summary instead of the whole transcript. (That variable is read by the two watchdogs; `fork-agent` takes `--summary` instead, and the bridge's own resume is always full so a restart stays invisible.)

Kill-switches: `~/.claude/agent-queue/watchdog.disabled` (everything) or `child-watchdog.disabled` (children only). Everything is logged to `watchdog.log`, child lines prefixed `[child]`.

### The agent tree — branch, merge, discard

A child agent can be a **new repo** (any cwd) or a **worktree of the parent's repo**. Two payloads travel with it:

| | code | conversation |
|---|---|---|
| **branch** | `--worktree` → `worktree-<name>` | `fork-agent` → `--resume … --fork-session` |
| **merge** | `/close-agent <name> merge` | `/close-agent <name> merge merge` |
| **discard** | `/close-agent <name> drop` | `/close-agent` never deletes a transcript |

One exception to the right-hand column: a bridge request may carry `transcript: "delete"`, and that path *does* remove the agent's `.jsonl` after closing. It is the only way a transcript disappears and it never fires from `/close-agent`. The bridge prefers a transcript it can identify with certainty — the id it recorded while the agent ran, or the one read from a still-running session. If neither is available it falls back to the newest transcript in the agent's cwd, and *only* where that directory looks unshared; if the agent shares its cwd with another registered session, it refuses rather than guess, because the newest transcript there may well be the parent's. The fallback is a heuristic: a session started by hand in the same directory is not on any register, so the directory looks unshared to the bridge.

Closing cascades to every descendant, **deepest first**, and each branch merges into its **parent's** branch — only the root reaches `main`. The tree comes from the spec's `parent` field (names alone are ambiguous: the spawner appends `-2`…`-99` on collision). The merge runs inside the parent's worktree, so the repo never switches branch behind you; if the root's repo isn't on `main`, the merge is skipped with the manual command printed.

Two limits worth knowing:

- **A conversation merge cannot reach a running parent.** `merge-sessions.sh` writes a *new* transcript; the parent's live process owns its own. It takes effect on that file's next resume.
- **Resume loads a bounded window**, not the whole history — a fork inherits the *recent* conversation, not the parent's entire life story.

`--resume <id>` resolves the session id **globally**, not from the cwd-derived project dir — a fork in a worktree finds its parent's transcript with no copying.

### The Desktop bridge — work from a network-isolated environment

Claude Desktop's agent runs in an isolated Linux VM: no network, no `launchctl`,
no `/Users/...`, and `rm` is blocked. The only thing it *can* do is write a file
into a mounted folder — and that file lands on the real disk. So the file is the
whole channel, and the trigger has to sit on the Mac side.

```
Desktop (isolated VM)  →  bridge/requests/<id>.json        [real disk]
                             ↓  launchd WatchPaths
                          bridge-relay.sh   validates, asks on Telegram
                             ↓  you press ▶️ on your phone
                          bridge-poller.sh  getUpdates → spawns / continues
                             ↓
                          bridge/results/<id>.md  →  the Desktop reads it back
```

> **Note on language.** The bridge speaks Hungarian: its Telegram prompts, its
> button labels and the lines it writes to `bridge.log` are all Hungarian. The
> repo, the specs, the JSON fields and the status values are English, so nothing
> in the *interface* between components depends on it — but expect Hungarian on
> your phone and in the log. Translating it is a strings-only change; the strings
> are not extracted into a catalogue yet.

- **Approval gate.** Nothing runs before you press the button. The poller checks
  `from.id` against your own Telegram account — that one comparison is the whole
  security model. The poller reaches Telegram by polling outward, so there is no
  public endpoint, no webhook and no inbound port.

  ⚠️ The config also has a second mode, `gate: "audit"`, in which requests start
  **immediately** and you are only told afterwards. It is off by default and the
  approval gate above describes the default; if you turn it on, the bridge no
  longer gates anything. Audit mode still needs a Telegram token: without one the
  relay executes exactly the same, but the after-the-fact notification is silently
  skipped — everything runs and nobody is told.
- **Time-boxed standing approvals.** Approve with **+1 h / +8 h / +1 day** and
  further *continuations and reconnects* to that agent start without a button press. New forks
  and closes are never covered; every auto-start notifies you with a revoke button.
- **Results come back through the Mac.** The agent writes
  `.bridge-result-<id>.md` — one file per request — into its own working
  directory, and the poller publishes each to `bridge/results/<id>.md`. A
  worktree agent is sandboxed to its own directory and cannot write to the
  shared results folder itself. The per-request name matters: a single fixed
  filename is a one-slot mailbox, so a second round would overwrite the first
  report before the poller ever saw it.
- **The agent cannot ask questions.** Nobody reads its session, so
  `AskUserQuestion` is switched off for bridge-spawned agents and the task text
  tells it to write decisions into the report instead.
- **Stalled-agent detection.** Idle for N minutes with no report → a phone alert
  with a 🔔 button that pokes the session, so a silently finished agent that never
  reported does not sit unnoticed.

### Setting up the bridge

The bridge stays inert until you configure it — an empty `bridge-allow.json` is a
closed gate. Four steps:

**1. Create a dedicated Telegram bot.** Message [@BotFather](https://t.me/BotFather),
send `/newbot`, and keep the token it gives you. Use a *separate* bot: this token
lives on your machine and can only approve agent starts, so it must not be one
whose token is already deployed elsewhere.

**2. Find your numeric user id.** Message [@userinfobot](https://t.me/userinfobot),
or send `/start` to your new bot and read it from
`https://api.telegram.org/bot<TOKEN>/getUpdates` (`message.from.id`). You must send
`/start` to the bot at least once, or it cannot message you.

**3. Store the token.** The Keychain is preferred; a `0600` file is the fallback:

```bash
# preferred — service name and account are what the code looks for.
# `-w` with NO value: `security` prompts for it, so the token never reaches
# your shell history.
security add-generic-password -a "$(id -un)" -s claude-bridge-telegram -w

# fallback — `read -s` keeps it out of the history too
umask 077 && read -s "tok?token: " \
  && printf '%s' "$tok" > ~/.claude/agent-queue/telegram-approve.token && unset tok
```

Never put the token in a shell variable, a command line, or the repo.

**4. Fill in `~/.claude/agent-queue/bridge-allow.json`.** Set `user_id` to your
numeric id, list the agents that may be forked from in `parents`, and describe each
one in `about` — the Desktop side picks a parent from those descriptions, so a
missing `about` means it is guessing.

Then restart the two bridge jobs so they pick up the config:

```bash
for L in local.bridge-relay local.bridge-poller; do
  launchctl kickstart -k "gui/$(id -u)/$L"
done
```

**On the Claude Desktop side**, install `desktop-skill/agent-bridge/SKILL.md` as a
skill (Settings → Capabilities → Skills → upload), and give the Desktop agent
access to the folder that contains `bridge/` — that mounted folder is the entire
channel.

### The JSON spec

```json
{
  "name": "proj-main-refactor",
  "cwd": "/Users/<you>/ClaudeProjects/myproject",
  "prompt": "Refactor the auth module and add tests",
  "model": "opus",
  "effort": "high",
  "permission_mode": "auto",
  "brief": true,
  "worktree": true
}
```

The watcher validates: name regex (`[a-zA-Z0-9_-]{3,64}`), enum whitelists for `model` / `effort` / `permission_mode`, prompt length (<8 KB), cwd allowlist (`~/ClaudeProjects` only) — **the allowlist is checked before anything is created on disk**. A `cwd` that does not exist is an error, not an invitation: a typo would otherwise silently produce an empty directory and the agent would work in it instead of your project. Pass `"create_cwd": true` when a new directory is genuinely intended. Bad specs land in `failed/` with a `.reason` file. `model` accepts the `opus` / `sonnet` / `haiku` / `fable` aliases, the pinned Claude 5 ids `claude-opus-5` / `claude-sonnet-5` / `claude-fable-5` / `claude-haiku-4-5`, and the pinned Opus 4 ids `claude-opus-4-7` / `claude-opus-4-8` — with an optional `[1m]` context suffix on `claude-opus-4-7`, `claude-opus-4-8`, `claude-opus-5` and `claude-sonnet-5` (e.g. `claude-opus-5[1m]`). The same whitelist lives in three validators (spawner, bridge, `fork-agent`); they are kept in sync deliberately.

## How this compares to `claude remote-control` (server mode)

Claude Code ships its own way to start sessions from a phone: **server mode**
(`claude remote-control`). One process serves up to 32 sessions, `--spawn
worktree` gives each new session its own git worktree, and the phone can create
them on demand. Flags and limits below come from `claude remote-control --help`
and the [Remote Control docs](https://code.claude.com/docs/en/remote-control) —
check them there rather than trusting this table.

**This project is not a replacement for Remote Control — it is built on top of
it.** Every agent here *is* a Remote Control session. The overlap is only with
server mode, and it is worth being precise about who wins where.

| | `claude remote-control` | this project |
|---|---|---|
| start a session from the phone | ✅ built in | ✅ `/new-agent`, `/fork`, or the bridge |
| per-session git worktree | ✅ `--spawn worktree` | ✅ |
| **child inherits the parent's conversation** | ❌ starts blank | ✅ `--resume … --fork-session` |
| **named hierarchy, cascade close, merge into the parent's branch** | ❌ flat list | ✅ |
| **approval gate on unattended task intake** | n/a — no such channel exists | ✅ Telegram, with time-boxed grants — **bridge only** |
| **intake from a network-isolated environment** | ❌ | ✅ file bridge |
| **survives reboot** | ⚠️ needs a launchd/systemd unit you write | ✅ launchd + per-agent spec-driven `--resume` — for queued agents. Forks and bridge-started agents are deliberately *not* resurrected (see `fork.md`): a fork is a branch of a conversation, and bringing it back unasked is more often wrong than right. |
| agent finished but never reported | n/a — the app shows session state directly | ✅ detection + nudge (a bridge-specific failure mode) |
| processes | ✅ one, for all sessions | ❌ one full `claude` per agent |
| maintenance | ✅ none — first-party, supported | ❌ ~3,800 lines of zsh (all shell in the repo, tests included) you own |
| platform | macOS / Linux / WSL2 | macOS only (launchd) |
| setup | one command | installer + your own Telegram bot |

**Where the comparison is not apples-to-apples.** Three of the rows above
describe problems this architecture creates for itself. Server mode has no
approval gate because it has nothing to gate: a session starts only when you
press start in an authenticated client, and that press *is* the approval. This
project needed a gate because it opened an unattended intake channel — the file
bridge — and a gate is the price of that channel, not a bonus. The same goes for
"finished but never reported": that failure exists because bridge results travel
as files rather than through the session UI. And the gate covers **only** the
bridge — `/new-agent`, or anything else that can write into the queue (a cron
job, an SSH session, a webhook), spawns an agent with no approval at all. See
[What an agent can do](#what-an-agent-can-do).

**Where server mode is simply better.** If what you want is *"start me a fresh
session on my Mac, isolated, from my phone"*, use server mode and stop reading.
It is one command, it is maintained by the people who write Claude Code, and it
is dramatically cheaper: one process instead of one per agent. On the author's
machine 14 `claude` processes across 7 tmux sessions hold **~1.5 GB RSS** — server
mode would serve the same fan-out from a single process.

**Where this earns its keep.** The moment the work is *continuous* rather than
one-off, the picture flips:

- A fresh session knows nothing. Re-explaining the context to every new agent is
  the actual cost of parallel work, and `--fork-session` removes it — the child
  starts where the parent is.
- A tree of agents needs a way *back*. Cascade close merges each branch into its
  **parent's** branch, deepest first, so the hierarchy survives the merge instead
  of flattening into `main`.
- Anything that can drop a JSON file can commission work — including an
  environment with no network and no shell access to your machine. That is not a
  convenience feature; it is the only channel that exists.
- And when work is delegated rather than watched, you need a gate in front of it
  and an alarm behind it: approval before, stall detection after.

Server mode is a better *session launcher*. This is an *agent supervisor* — and it pays for that with a process per agent, a
macOS-only dependency on launchd, and a pile of shell that is yours to maintain
when Claude Code changes underneath it.

## Requirements

- macOS (launchd + zsh)
- [`claude`](https://claude.com/claude-code) CLI, logged in with a full claude.ai login (Remote Control needs full-scope auth — long-lived setup tokens don't work)
- `tmux`, `jq`, `uuidgen`, `git`
- *For the Desktop bridge only:* your own Telegram bot (a dedicated one — do not
  reuse a bot whose token lives on other machines) and its numeric user id

## Install

```bash
git clone https://github.com/ZsoltSziklai/claude-code-agent-spawner.git
cd claude-code-agent-spawner
zsh install.sh
```

The installer writes outside the repo and registers services that start on every
login, so here is the full list:

- copies the scripts to `~/.claude/agent-queue/` (and `start.sh` to a fixed path the watchdog can find)
- copies **five** slash commands to `~/.claude/commands/`: `new-agent`, `close-agent`, `kill-agent`, `kill-all-exit`, `fork`
- creates `~/ClaudeProjects/bridge/{requests,results,archive}` — the folder you attach on the Desktop side — and drops `bridge-README.md` there as `README.md`
- installs `bridge-allow.json.example`, and if no `bridge-allow.json` exists yet, a `0600` copy of it — **unfilled, which means a closed gate**
- renders four plist templates with your `$HOME` into `~/Library/LaunchAgents/` and `launchctl bootstrap`s them:
  `local.agent-spawner`, `local.mac-main-watchdog`, `local.bridge-relay`, `local.bridge-poller`

The two bridge jobs are installed whether or not you want the bridge. They load
at login and do nothing: with an empty `bridge-allow.json` every request is
rejected, and with no Telegram token the poller exits immediately. If you would
rather not have them at all, `launchctl bootout` them and delete the two plists —
the core keeps working.

Start the command-center session:

```bash
zsh start.sh
```

### Uninstall

```bash
for L in local.agent-spawner local.mac-main-watchdog local.bridge-relay local.bridge-poller; do
  launchctl bootout "gui/$(id -u)/$L" 2>/dev/null
  rm -f ~/Library/LaunchAgents/$L.plist
done
tmux kill-server                 # ⚠️ stops EVERY tmux session, not just agents
rm -rf ~/.claude/agent-queue     # scripts, registry, logs, bridge config
rm -f ~/.claude/commands/{new-agent,close-agent,kill-agent,kill-all-exit,fork}.md
# The bridge folder is left alone on purpose — it may hold reports you still want.
# Remove it yourself when you are done with them:  rm -rf ~/ClaudeProjects/bridge
```

Worktrees created under `<repo>/.claude/worktrees/` and their `worktree-*`
branches are left alone — remove them with `git worktree remove` if you want them
gone.

## What an agent can do

Worth understanding before you run this, because the answer is "a lot":

- A spawned agent is a full Claude Code session on your machine, with your
  filesystem, your MCP servers and your logged-in account. `permission_mode`
  defaults to `auto`, but the spec whitelist also accepts `dontAsk` and
  **`bypassPermissions`** — an agent started that way will not ask you before
  acting.
- **Anything that can write a JSON file into `~/.claude/agent-queue/new/` can
  start one**, with no approval step: a slash command, another agent, a cron job,
  an SSH session, a webhook. That is the design — it is also the widest part of
  the attack surface, and it is not gated. The Telegram gate protects the *bridge*
  channel only.
- The spec validator constrains `cwd` to an allowlist (`~/ClaudeProjects` by
  default), the name to `[a-zA-Z0-9_-]{3,64}`, and the prompt to 8 KB. It does
  not constrain what the agent then does inside that directory.
- The bridge is the narrow path by comparison: whitelisted parents, a
  `permission_mode` that defaults to `auto`, and a Telegram approval checked
  against your own `from.id`. A request may ask for `bypassPermissions`, but it
  only takes effect on an explicit button press for that request — under a
  standing grant or in `gate: "audit"` the bridge downgrades it to `auto` and
  logs `PERM-DOWNGRADE`.

If you want the queue itself gated, that gate does not exist yet.

## File map

| File | Purpose |
|---|---|
| `claude-agent-spawner` | The queue watcher — called by launchd when a file appears in `~/.claude/agent-queue/new/`. |
| `local.agent-spawner.plist.template` | launchd plist with `__HOME__` placeholder, rendered at install time. |
| `start.sh` | Launches the persistent `mac-main` command-center Remote Control session. |
| `install.sh` | One-shot installer. |
| `new-agent.md` / `close-agent.md` / `kill-agent.md` / `kill-all-exit.md` | Slash command definitions. |
| `tests/REGRESSION-RUN.md` | The runnable version: paste the opening prompt into a Cowork session, press the Telegram buttons per the map. The Desktop drives its own blocks and spawns a CLI agent over the bridge for the CLI ones — that agent reads its steps from this same file. |
| `tests/REGRESSION.md` | The end-to-end run-through: the Telegram gate, a real spawn, the work, the report coming back, the close. What `smoke.sh` cannot reach. On 2026-08-29 seven real bugs surfaced this way and **none** by reading the code — `spawned` does not mean the work happened. |
| `tests/smoke.sh` | `zsh tests/smoke.sh` — 198 assertions over the parts that can be isolated: standing approvals, the state file, the status machine, the three model whitelists agreeing, the prompt byte limit, the restart-counter gating, the tmux session-name resolution, and `zsh -n` on every script. Runs in a throwaway directory and never touches `~/.claude`. What it deliberately does not cover: spawning, merging and killing need a real tmux session, a real git repo and launchd — those are exercised on disposable agents. |
| `bin/agent-kill-one.sh` / `agent-kill-all.sh` / `agent-kill-tree.sh` / `agent-close-tree.sh` | Helpers called by the slash commands. |
| `bin/_agent-lib.sh` | Shared helpers: live registry, worktree/transcript resolution, modal auto-dismiss. |
| `bin/mac-main-watchdog.sh` | Keeps the command-center session alive; drives the child sweep. |
| `bin/agent-child-watchdog.sh` | Restores registered child agents (`--resume`) after a reboot or crash. |
| `bin/merge-sessions.sh` | Joins two session transcripts into one resumable session, when a restart split the history. |
| `bin/fork-agent` | Forks the calling session into a child agent that **inherits the conversation** (`--resume … --fork-session`). |
| `fork.md` | `/fork` slash command. |
| `local.mac-main-watchdog.plist.template` | launchd plist for the watchdog (300 s + `RunAtLoad`). |
| `bin/_bridge-lib.sh` | Bridge core: validation, Telegram, approvals + time-boxed grants, result publishing, stall detection. |
| `bin/bridge-relay.sh` | Picks up dropped requests (launchd `WatchPaths`), validates, asks for approval. |
| `bin/bridge-poller.sh` | Telegram `getUpdates` consumer: approvals, revocations, nudges; publishes results. |
| `bridge-README.md` | The contract for whoever drops requests into the bridge. |
| `bridge-allow.json.example` | Bridge config template — whitelist, gate mode, timeouts. |
| `desktop-skill/agent-bridge/SKILL.md` | The skill installed on the Claude Desktop side. |
| `local.bridge-relay.plist.template` / `local.bridge-poller.plist.template` | launchd jobs for the bridge. |
| `ROADMAP.md` / `TODO.md` | Pending refinements (Hungarian). |

## Status

Working in production on the author's machine — a command centre plus a handful
of long-running agents, driven from a phone, with the Desktop bridge commissioning
work through the Telegram gate. Rough edges remain — the backlog lives in `TODO.md`
and `ROADMAP.md`, which are written in Hungarian; if you want context on a
specific item, open an issue and ask, and I will answer in English.

---

## Magyar változat

Queue-alapú **háttér-agent orchestrator** [Claude Code](https://claude.com/claude-code)-hoz.
Több párhuzamos Claude Code session futtatása a háttérben — a termináldból, egy másik
futó agentből, vagy távolról, a Claude mobilapp **Code** füléről.

> Egyelőre csak macOS (launchd-alapú). Linux-port (systemd / inotify) nem lenne bonyolult — PR-t szívesen fogadok.

### Mit csinál

- A háttérben folyamatosan fut egy **command-center session**. A mobilapp felől éred el, vagy a tmux sessionjéhez csatlakozva.
- Onnan (vagy bármelyik másik Claude Code sessionből) új háttér-agenteket indíthatsz a `/new-agent`-tel — mindegyik a saját tmux sessionjében fut, igény szerint a saját git worktree-jében.
- A háttér-agentek **öröklik a szülő név-prefixét**, így a session-fa végigkövethető (`proj-main` → `proj-main-foo` → `proj-main-foo-bar`).
- Egy **watchdog** újraindítja a command-centert, ha meghalna — egy összeomlás így nem viszi el a sessiont. (A *folyamatot* indítja újra; az a session, aminek a Remote Control kapcsolata szakadt le, él ugyan, csak épp nem látszik a telefonon — erre való a `reconnect`.)
- Egy **fájl-híd** révén egy hálózat nélküli, izolált környezet (a Claude Desktop agent-sandboxa) is adhat munkát a Macnek — Telegram-jóváhagyás mögül, amit a telefonodon nyomsz meg.

### Miért

Párhuzamos agentet olcsó indítani, és drága eligazítani. A valódi költség a
kontextus újramagyarázása minden új sessionnek — mi a projekt, mit próbáltunk
már, mi a megkötés. A `fork-agent` ezt veszi el: a gyerek a szülő
beszélgetéséből indul (`--resume … --fork-session`), tehát eleve tudja azt,
amit különben újra be kellene gépelned.

A többi ebből az egy döntésből következik. Amint az agentek egymásból
származnak, kell út **visszafelé** is (kaszkádos lezárás, merge a *szülő*
ágába); amint delegálsz ahelyett, hogy néznéd, kell egy kapu a felügyelet
nélküli munkabevitel elé, és egy riasztó mögé.

### Slash parancsok

| Parancs | Mit csinál |
|---|---|
| `/new-agent` | Menüvezérelt varázsló új háttér-session sorba állításához (név, mappa, prompt, modell, effort, permission mode, worktree). Van „Default" gyorsindítás. |
| `/close-agent` | Futó agent rendes lezárása. Ha worktree-ben dolgozott, megkérdezi: merge vagy eldobás. |
| `/kill-agent` | Listából választható agentek azonnali kilövése. ⚠️ **Worktree-s agentnél adatvesztő**: a worktree és a `worktree-<név>` ág is törlődik, a nem commitolt munkával együtt. Ha meg akarod tartani: `/close-agent`. |
| `/fork` | Az **aktuális** sessiont forkolja gyerek-agentté, ami örökli a beszélgetést. |
| `/kill-all-exit` | Vészfék — minden háttér-agent kilövése és kilépés az aktuális sessionből. ⚠️ Ugyanaz a worktree-törlés, mint a `/kill-agent`-nél, csak egyszerre mindegyikre. |

### Felépítés dióhéjban

Négy launchd job fut a gépeden — kettő a magért, kettő a hídért:

- **Queue spawner** (`claude-agent-spawner`) — launchd-vezérelt fájlfigyelő a `~/.claude/agent-queue/new/` könyvtáron. Amikor a `/new-agent` (vagy bármi más) bedob egy JSON „megrendelőt" a postaládába, a spawner felkapja és elindít belőle egy önálló Claude Code sessiont saját tmux ablakban, opcionálisan friss git worktree-ben.
- **Watchdog** (`bin/mac-main-watchdog.sh`) — 300 másodpercenként fut launchd-ből (`RunAtLoad`-dal is). Újraindítja a command-centert, ha meghalt, majd végigsöpri a gyerekeket (lásd lentebb).
- **Bridge relay** és **bridge poller** — a Desktop-híd (lásd lentebb). Feltétel nélkül települnek és bejelentkezéskor betöltődnek, de tétlenek maradnak, amíg a `bridge-allow.json` kitöltetlen: az üres config zárt kaput jelent, tehát semmi nem indul.

**Bármi, ami képes egy JSON fájlt bedobni a queue-ba, tud agentet indítani:** egy slash parancs, egy másik agent, egy cron job, egy SSH-n bejelentkezett shell, egy webhook.

#### Újraindítás-túlélés

Egy reboot minden tmux sessiont megöl. A fő session magától visszajön, és vele a gyerekei is:

- Indításkor a spawner beírja az agent specifikációját egy **élő nyilvántartásba** (`~/.claude/agent-queue/live/<név>.json`) — „ennek az agentnek futnia kellene".
- A `bin/agent-child-watchdog.sh` (a watchdog hívja, tehát ugyanazon a 300 mp-es ütemen) végigmegy a nyilvántartáson. Minden olyan bejegyzésnél, amelynek az `agent-<név>` tmux sessionje eltűnt, újraindítja az agentet az **eredeti** spec-paramétereivel, plusz `--resume` — így a beszélgetés folytatódik, nem nulláról indul. Az azonosító a nyilvántartásból jön: amíg az agent fut, a watchdog beírja oda a **saját** session id-ját. A „cwd legfrissebb átirata" találgatás csak tartalék, és csak akkor, ha azon a cwd-n nem osztozik másik nyilvántartott agent — különben két agent egymás beszélgetését folytatná, és egyik sem venné észre. A worktree-s agentek a worktree-ben állnak vissza, nem a spec cwd-jében.
- A `/kill-agent`, `/close-agent` és `/kill-all-exit` **kiveszi a nyilvántartásból** — amit szándékosan lezártál, az zárva marad.
- Az újraindítás korlátos (`CLAUDE_AGENT_MAX_RESTORE`, alapból 3 egymást követő hiba), így egy véglegesen eltört agent nem tud a végtelenségig újraéledni. A számláló csak akkor nullázódik, ha az agent egy **későbbi** tickben is fut (`CLAUDE_AGENT_MIN_STABLE`, alapból 120 mp). A közvetlenül az indítás utáni nullázás csak az induláskor összeomló agentet fogta volna meg — amelyik egy perccel később hal meg, az a végtelenségig újraindulna.
- Mivel senki nincs a gép előtt, hogy válaszoljon rájuk, az egyszeri indítási modálokat (`--chrome` megerősítés, teljes képernyős renderelő ajánlata, nagy sessionöknél a „resume from summary?" kérdés) automatikusan megválaszoljuk. A resume alapból *full* — minden hívó ezt állítja (mindkét watchdog, a `fork-agent`, és a híd visszaállítása); `CLAUDE_AGENT_RESUME_MODE=summary` esetén olcsóbb a helyreállítás: összefoglalóból indul, nem a teljes átiratból. (Ezt a változót a két watchdog olvassa; a `fork-agent`-nél a `--summary` kapcsoló való erre, a híd saját visszaállítása pedig mindig teljes, hogy az újraindulás láthatatlan maradjon.)

Vészkapcsolók: `~/.claude/agent-queue/watchdog.disabled` (minden) vagy `child-watchdog.disabled` (csak a gyerekek). Minden a `watchdog.log`-ba kerül, a gyerek-sorok `[child]` előtaggal.

#### Az agent-fa — ág, merge, eldobás

Egy gyerek-agent lehet **külön repó** (bármilyen cwd) vagy **a szülő repójának worktree-je**. Két rakomány utazik vele:

| | kód | beszélgetés |
|---|---|---|
| **ág** | `--worktree` → `worktree-<név>` | `fork-agent` → `--resume … --fork-session` |
| **merge** | `/close-agent <név> merge` | `/close-agent <név> merge merge` |
| **eldobás** | `/close-agent <név> drop` | a `/close-agent` sosem töröl átiratot |

A jobb oldali oszlop alól egy kivétel van: egy híd-kérés hozhat `transcript: "delete"` mezőt, és az az út a lezárás után **valóban törli** az agent `.jsonl`-jét. Átirat csak így tűnhet el, és a `/close-agent`-ből sosem indul. A híd elsősorban olyan átiratot töröl, amit biztosan azonosít: a futás közben rögzített session-id-t, vagy a még futó sessionből olvasottat. Ha egyik sincs meg, a cwd legfrissebb átiratára esik vissza, de *csak* akkor, ha az a könyvtár nem látszik osztottnak; ha az agent egy másik nyilvántartott sessionnel osztozik rajta, inkább elutasítja — ott a legfrissebb átirat könnyen a szülőé lehet. Ez a visszaesési ág heurisztika: egy kézzel, ugyanabban a könyvtárban indított session nincs nyilvántartva, tehát a híd a könyvtárat nem látja osztottnak.

A lezárás **kaszkádol** minden leszármazottra, a **legmélyebbtől felfelé**, és minden ág a **szülő** ágába olvad — csak a gyökér ér el a `main`-ig. A fát a spec `parent` mezője adja (a nevek önmagukban félreérthetők: a spawner ütközéskor `-2`…`-99` utótagot ad). A merge a szülő worktree-jében fut, tehát a repó soha nem vált ágat a hátad mögött; ha a gyökér repója nem a `main`-en áll, a merge kimarad, és kiírjuk a kézi parancsot.

Két korlát, amit érdemes tudni:

- **A beszélgetés-merge nem éri el a futó szülőt.** A `merge-sessions.sh` egy *új* átiratot ír; a szülő élő folyamata a sajátját birtokolja. A fűzés annak a fájlnak a következő resume-jánál lép életbe.
- **A resume korlátos ablakot tölt be**, nem a teljes történetet — a fork a *közelmúltat* örökli, nem a szülő egész élettörténetét.

A `--resume <id>` a session-azonosítót **globálisan** oldja fel, nem a cwd-ből származtatott projekt-könyvtárból — így egy worktree-ben ülő fork másolás nélkül megtalálja a szülő átiratát.

#### A Desktop-híd — munka hálózat nélküli környezetből

A Claude Desktop agentje izolált Linux VM-ben fut: nincs hálózat, nincs `launchctl`,
nincs `/Users/...`, és az `rm` is tiltott. Az egyetlen dolog, amit *tud*: fájlt írni
egy csatolt mappába — és az a fájl a **valódi lemezre** kerül. Tehát a fájl maga a
teljes csatorna, a triggernek pedig a Mac oldalán kell ülnie.

```
Desktop (izolált VM)   →  bridge/requests/<id>.json        [valódi lemez]
                             ↓  launchd WatchPaths
                          bridge-relay.sh   validál, Telegramon kérdez
                             ↓  megnyomod a ▶️-t a telefonon
                          bridge-poller.sh  getUpdates → indít / folytat
                             ↓
                          bridge/results/<id>.md  →  a Desktop visszaolvassa
```

- **Jóváhagyási kapu.** Semmi nem indul a gombnyomás előtt. A poller a `from.id`-t
  a saját Telegram-fiókodhoz hasonlítja — ez az egyetlen összehasonlítás a teljes
  biztonsági modell. A poller kifelé kérdez, tehát nem kell publikus végpont,
  webhook vagy bejövő tűzfalnyitás.

  ⚠️ A configban van egy második mód is, a `gate: "audit"`: abban a kérések
  **azonnal indulnak**, és csak utólag kapsz értesítést. Alapból ki van kapcsolva,
  és a fenti kapu-leírás az alapértelmezésre vonatkozik — ha bekapcsolod, a híd
  többé nem kapuz semmit. Audit módhoz is kell Telegram-token: nélküle a relay
  ugyanúgy végrehajt, csak az utólagos értesítés marad el némán — vagyis minden
  fut, és senki nem tud róla.
- **Időkorlátos állandó jóváhagyás.** Jóváhagyhatsz **+1 óra / +8 óra / +1 nap**
  ablakkal, és az adott agentre érkező további *folytatások és reconnectek* gombnyomás nélkül
  indulnak. Új fork és lezárás sosem esik bele; minden automatikus indításról
  értesítés megy, rajta visszavonó gombbal.
- **Az eredmény a Macen keresztül megy vissza.** Az agent a saját munkakönyvtárába
  ír — **kérésenként külön fájlba** (`.bridge-result-<id>.md`) —, és a poller
  emeli át mindegyiket a `bridge/results/<id>.md`-be. A worktree-s agent
  sandboxa a saját könyvtárára szól, a közös eredmény-mappába maga nem tud írni.
  A kérésenkénti név lényeges: egyetlen fix fájlnév egyférőhelyes postaláda,
  tehát egy második kör felülírná az elsőt, mielőtt a poller egyáltalán látná.
- **Az agent nem kérdezhet vissza.** A sessionjét senki nem olvassa, ezért a
  hídon indított agenteknél az `AskUserQuestion` ki van kapcsolva, a feladatszöveg
  pedig arra utasítja, hogy a döntéseket a jelentésbe írja.
- **Beragadt agent észlelése.** N perce tétlen, jelentés nélkül → telefonos
  riasztás egy 🔔 gombbal, ami megböki a sessiont — így az az agent sem marad
  észrevétlen, amelyik csendben befejezte a munkát, de sosem jelentett.

#### A híd beüzemelése

A híd tétlen marad, amíg nem konfigurálod — az üres `bridge-allow.json` zárt kaput
jelent. Négy lépés:

**1. Hozz létre egy dedikált Telegram botot.** Írj a [@BotFather](https://t.me/BotFather)-nek,
küldd el a `/newbot` parancsot, és tedd el a kapott tokent. **Külön** botot
használj: ez a token a gépeden él, és csak agent-indítás jóváhagyására jó — ne
olyan boté legyen, aminek a tokenje már máshol is ott van.

**2. Keresd meg a numerikus felhasználó-azonosítódat.** Írj a
[@userinfobot](https://t.me/userinfobot)-nak, vagy küldj `/start`-ot az új botodnak,
és olvasd ki a `https://api.telegram.org/bot<TOKEN>/getUpdates` válaszából
(`message.from.id`). A `/start`-ot mindenképpen el kell küldened egyszer, különben
a bot nem tud neked üzenetet küldeni.

**3. Tárold el a tokent.** Elsődlegesen a Keychainben; a `0600`-as fájl a tartalék:

```bash
# elsődleges — a service-nevet és az accountot pontosan így keresi a kód
# A -w ÉRTÉK NÉLKÜL: a `security` interaktívan bekéri, így a token nem kerül
# a shell-historyba.
security add-generic-password -a "$(id -un)" -s claude-bridge-telegram -w

# tartalék — a `read -s` szintén kihagyja a historyból
umask 077 && read -s "tok?token: " \
  && printf '%s' "$tok" > ~/.claude/agent-queue/telegram-approve.token && unset tok
```

A tokent soha ne tedd shell-változóba, parancssorba vagy a repóba.

**4. Töltsd ki a `~/.claude/agent-queue/bridge-allow.json`-t.** A `user_id` a
numerikus azonosítód; a `parents` azokat az agenteket sorolja, amikből forkolni
szabad; az `about` pedig leírja mindegyiket — a Desktop ezekből a leírásokból
választ szülőt, tehát hiányzó `about` mellett vakon tippel.

Utána indítsd újra a két híd-jobot, hogy felvegyék a configot:

```bash
for L in local.bridge-relay local.bridge-poller; do
  launchctl kickstart -k "gui/$(id -u)/$L"
done
```

**A Claude Desktop oldalán** telepítsd a `desktop-skill/agent-bridge/SKILL.md`-t
skillként (Beállítások → Képességek → Skillek → feltöltés), és add meg a Desktop
agentnek a `bridge/`-et tartalmazó mappa elérését — az a csatolt mappa maga a
teljes csatorna.

#### A JSON spec

```json
{
  "name": "proj-main-refactor",
  "cwd": "/Users/<te>/ClaudeProjects/myproject",
  "prompt": "Refaktoráld az auth modult és írj hozzá teszteket",
  "model": "opus",
  "effort": "high",
  "permission_mode": "auto",
  "brief": true,
  "worktree": true
}
```

A figyelő validál: név-regex (`[a-zA-Z0-9_-]{3,64}`), enum-fehérlisták a `model` / `effort` / `permission_mode` mezőkre, prompt-hossz (<8 KB), cwd-engedélylista (csak `~/ClaudeProjects`) — **az engedélylista azelőtt dől el, hogy bármi létrejönne a lemezen**. A nem létező `cwd` hiba, nem felhívás: egy elgépelés különben csendben üres könyvtárat hozna létre, és az agent a projekt helyett abban dolgozna. Ha tényleg új könyvtár kell, add meg: `"create_cwd": true`. A hibás specek a `failed/` könyvtárba kerülnek egy `.reason` fájllal. A `model` elfogadja az `opus` / `sonnet` / `haiku` / `fable` aliasokat, a rögzített Claude 5 azonosítókat (`claude-opus-5` / `claude-sonnet-5` / `claude-fable-5` / `claude-haiku-4-5`), valamint a rögzített Opus 4 azonosítókat (`claude-opus-4-7` / `claude-opus-4-8`) — opcionális `[1m]` kontextus-utótaggal a `claude-opus-4-7`, `claude-opus-4-8`, `claude-opus-5` és `claude-sonnet-5` esetén (pl. `claude-opus-5[1m]`). Ugyanez a fehérlista három validátorban él (spawner, híd, `fork-agent`); szándékosan együtt mozognak.

### Miben más ez, mint a `claude remote-control` (szerver mód)?

A Claude Code-nak van saját módja arra, hogy telefonról indíts sessiont: a **szerver
mód** (`claude remote-control`). Egy folyamat akár 32 sessiont kiszolgál, a `--spawn
worktree` mindegyiknek saját git worktree-t ad, és a telefon igény szerint hozhat
létre újakat. Az alábbi kapcsolók és korlátok a `claude remote-control --help`
kimenetéből és a [Remote Control dokumentációjából](https://code.claude.com/docs/en/remote-control)
származnak — ellenőrizd ott, ne ezt a táblázatot hidd el.

**Ez a projekt nem helyettesíti a Remote Controlt — hanem ráépül.** Itt minden agent
*egy Remote Control session*. Az átfedés csak a szerver móddal van, és érdemes pontosan
kimondani, ki hol nyer.

| | `claude remote-control` | ez a projekt |
|---|---|---|
| session indítása telefonról | ✅ beépítve | ✅ `/new-agent`, `/fork` vagy a híd |
| sessiononkénti git worktree | ✅ `--spawn worktree` | ✅ |
| **a gyerek örökli a szülő beszélgetését** | ❌ üres lappal indul | ✅ `--resume … --fork-session` |
| **névhierarchia, kaszkádos lezárás, merge a szülő ágába** | ❌ lapos lista | ✅ |
| **jóváhagyási kapu a felügyelet nélküli munkabevitelen** | n/a — nincs ilyen csatorna | ✅ Telegram, időablakos felhatalmazással — **csak a hídon** |
| **munkaátvétel hálózat nélküli környezetből** | ❌ | ✅ fájl-híd |
| **túléli az újraindítást** | ⚠️ saját launchd/systemd unit kell hozzá | ✅ launchd + agentenkénti, spec-vezérelt `--resume` — a queue-ból indított agentekre. A forkokat és a híd indította agenteket **szándékosan nem** támasztjuk fel (lásd `fork.md`): a fork egy beszélgetés elágazása, és kérés nélkül visszahozni gyakrabban rossz, mint jó. |
| az agent végzett, de sosem jelentett | n/a — az app közvetlenül mutatja a session állapotát | ✅ észlelés + emlékeztető (híd-specifikus hibamód) |
| folyamatok | ✅ egy, az összes sessionhöz | ❌ agentenként egy teljes `claude` |
| karbantartás | ✅ nincs — első féltől, támogatott | ❌ ~3800 sor zsh (a teljes shell-kód, tesztekkel), amit te viszel |
| platform | macOS / Linux / WSL2 | csak macOS (launchd) |
| beüzemelés | egy parancs | telepítő + saját Telegram bot |

**Ahol az összevetés nem alma-almához.** A fenti sorok közül három olyan
problémát old meg, amit ez az architektúra maga teremt. A szerver módban azért
nincs jóváhagyási kapu, mert nincs mit kapuzni: session csak úgy indul, hogy
egy bejelentkezett kliensben megnyomod az indítást — és az a gombnyomás **maga**
a jóváhagyás. Ennek a projektnek azért kellett kapu, mert nyitott egy felügyelet
nélküli beviteli csatornát — a fájl-hidat —, és a kapu ennek az ára, nem
ráadás. Ugyanez áll a „végzett, de sosem jelentett" esetre: az a hibamód azért
létezik, mert a híd eredményei fájlként utaznak, nem a session felületén. És a
kapu **kizárólag** a hídra vonatkozik — a `/new-agent`, vagy bármi más, ami a
queue-ba tud írni (cron job, SSH-session, webhook), jóváhagyás nélkül indít
agentet. Lásd: [Mit tehet egy agent](#mit-tehet-egy-agent).

**Amiben a szerver mód egyszerűen jobb.** Ha az kell, hogy *„indíts nekem egy friss,
izolált sessiont a Macen, a telefonról"*, használd a szerver módot és ne olvass tovább.
Egy parancs, azok tartják karban, akik a Claude Code-ot írják, és drámaian olcsóbb:
egy folyamat agentenkénti helyett. A szerző gépén 14 `claude` folyamat 7 tmux
sessionben **~1,5 GB RSS-t** tart — a szerver mód ugyanezt egyetlen folyamatból
szolgálná ki.

**Amiért ez mégis megéri.** Abban a pillanatban, hogy a munka *folyamatos* és nem
egyszeri, megfordul a kép:

- Egy friss session semmit nem tud. A kontextus újramagyarázása minden új agentnek
  a párhuzamos munka valódi költsége — a `--fork-session` ezt elveszi: a gyerek ott
  kezdi, ahol a szülő tart.
- Egy agent-fához út is kell **visszafelé**. A kaszkádos lezárás minden ágat a
  **szülő** ágába mergel, a legmélyebbtől felfelé, így a hierarchia túléli a merge-öt
  ahelyett, hogy a `main`-be lapulna.
- Bármi, ami képes egy JSON fájlt lerakni, tud munkát rendelni — beleértve egy olyan
  környezetet, aminek nincs se hálózata, se shell-hozzáférése a gépedhez. Ez nem
  kényelmi funkció: ott ez az egyetlen létező csatorna.
- És ha a munkát delegálod ahelyett, hogy néznéd, kapu kell elé és riasztó mögé:
  jóváhagyás előtte, beragadás-észlelés utána.

A szerver mód jobb *session-indító*. Ez pedig *agent-felügyelő* — és ezért agentenkénti folyamattal, macOS-hez kötött
launchd-függéssel és egy rakás shell-lel fizet, amit neked kell karbantartanod,
ha a Claude Code alatta megváltozik.

### Követelmények

- macOS (launchd + zsh)
- [`claude`](https://claude.com/claude-code) CLI, teljes claude.ai bejelentkezéssel (a Remote Controlhoz full-scope auth kell — a hosszú élettartamú setup-tokenek nem működnek)
- `tmux`, `jq`, `uuidgen`, `git`
- *Csak a Desktop-hídhoz:* saját Telegram bot (dedikált — ne használj olyat, aminek a tokenje más gépeken is ott van) és a numerikus felhasználó-azonosítód

### Telepítés

```bash
git clone https://github.com/ZsoltSziklai/claude-code-agent-spawner.git
cd claude-code-agent-spawner
zsh install.sh
```

A telepítő a repón kívülre ír, és bejelentkezéskor induló szolgáltatásokat
regisztrál — ezért itt a teljes lista:

- a szkripteket a `~/.claude/agent-queue/` alá másolja (a `start.sh`-t egy rögzített útvonalra, hogy a watchdog megtalálja)
- **öt** slash parancsot tesz a `~/.claude/commands/` alá: `new-agent`, `close-agent`, `kill-agent`, `kill-all-exit`, `fork`
- létrehozza a `~/ClaudeProjects/bridge/{requests,results,archive}` mappát — ezt csatolod a Desktop oldalán —, és odateszi a `bridge-README.md`-t `README.md` néven
- felteszi a `bridge-allow.json.example`-t, és ha még nincs `bridge-allow.json`, abból egy `0600`-as másolatot — **kitöltetlenül, ami zárt kaput jelent**
- négy plist-sablont kitölt a te `$HOME`-oddal a `~/Library/LaunchAgents/` alá, és `launchctl bootstrap`-pel betölti őket:
  `local.agent-spawner`, `local.mac-main-watchdog`, `local.bridge-relay`, `local.bridge-poller`

A két híd-job akkor is települ, ha nem akarod a hidat. Bejelentkezéskor
betöltődnek, és nem csinálnak semmit: üres `bridge-allow.json` mellett minden
kérés elutasításra kerül, Telegram-token nélkül pedig a poller azonnal kilép.
Ha egyáltalán nem kellenek, `launchctl bootout`-tal vedd ki őket és töröld a két
plistet — a mag ettől még működik.

A command-center session indítása:

```bash
zsh start.sh
```

#### Eltávolítás

```bash
for L in local.agent-spawner local.mac-main-watchdog local.bridge-relay local.bridge-poller; do
  launchctl bootout "gui/$(id -u)/$L" 2>/dev/null
  rm -f ~/Library/LaunchAgents/$L.plist
done
tmux kill-server                 # ⚠️ MINDEN tmux-sessiont leállít, nem csak az agenteket
rm -rf ~/.claude/agent-queue     # szkriptek, nyilvántartás, naplók, híd-config
rm -f ~/.claude/commands/{new-agent,close-agent,kill-agent,kill-all-exit,fork}.md
# A bridge mappát szándékosan nem bántjuk — jelentések lehetnek benne. Ha már nem
# kellenek, magad töröld:  rm -rf ~/ClaudeProjects/bridge
```

A `<repo>/.claude/worktrees/` alatt létrejött worktree-ket és a `worktree-*`
ágakat nem bántja — azokat `git worktree remove`-val vedd le, ha nem kellenek.

### Mit tehet egy agent

Érdemes tudni, mielőtt futtatod, mert a válasz az, hogy „sokat":

- A spawnolt agent egy **teljes** Claude Code session a gépeden: a te
  fájlrendszereddel, MCP-szervereiddel és bejelentkezett fiókoddal. A
  `permission_mode` alapértéke `auto`, de a spec-fehérlista elfogadja a
  `dontAsk`-ot és a **`bypassPermissions`**-t is — az így indított agent nem
  kérdez rá, mielőtt cselekszik.
- **Bármi, ami JSON-t tud írni a `~/.claude/agent-queue/new/` alá, tud ilyet
  indítani**, jóváhagyási lépés nélkül: egy slash parancs, egy másik agent, egy
  cron job, egy SSH-session, egy webhook. Ez a tervezett működés — egyben ez a
  támadási felület legszélesebb pontja, és **nincs kapuzva**. A Telegram-kapu
  kizárólag a **híd** csatornáját védi.
- A spec-validátor korlátozza a `cwd`-t egy engedélylistára (alapból
  `~/ClaudeProjects`), a nevet a `[a-zA-Z0-9_-]{3,64}` mintára, a promptot 8 KB-ra.
  Azt viszont nem korlátozza, hogy az agent mit csinál azon a könyvtáron belül.
- A híd ehhez képest a szűk ösvény: fehérlistázott szülők, `auto`
  alapértelmezésű `permission_mode`, és a saját `from.id`-dhoz kötött
  Telegram-jóváhagyás. A kérés kérhet `bypassPermissions`-t, de az **csak
  kifejezett gombnyomásra** érvényesül — felhatalmazás alatt vagy `gate: "audit"`
  módban a híd `auto`-ra fokozza vissza, és `PERM-DOWNGRADE` sort naplóz.

Ha magát a queue-t is kapu mögé tennéd, az a kapu még nem létezik.

### Fájltérkép

| Fájl | Szerepe |
|---|---|
| `claude-agent-spawner` | A queue-figyelő — a launchd hívja, amikor fájl jelenik meg a `~/.claude/agent-queue/new/`-ban. |
| `local.agent-spawner.plist.template` | launchd plist `__HOME__` helykitöltővel, telepítéskor kitöltve. |
| `start.sh` | Elindítja az állandó `mac-main` command-center Remote Control sessiont. |
| `install.sh` | Egylépéses telepítő. |
| `new-agent.md` / `close-agent.md` / `kill-agent.md` / `kill-all-exit.md` | A slash parancsok definíciói. |
| `tests/REGRESSION-RUN.md` | A futtatható változat: a kezdő promptot beilleszted egy Cowork sessionbe, a gombokat a térkép szerint nyomod. A Desktop a saját blokkjait futtatja, a CLI-körhöz pedig a **hídon indít egy CLI-agentet**, ami ugyanebből a fájlból olvassa a lépéseit. |
| `tests/REGRESSION.md` | A végigjátszható forgatókönyv: Telegram-kapu, valódi indítás, a munka, a jelentés visszaútja, lezárás. Amit a `smoke.sh` nem ér el. 2026-08-29-én hét valódi hiba így került elő, és **egy sem** kódolvasással — a `spawned` nem jelenti azt, hogy a munka megtörtént. |
| `tests/smoke.sh` | `zsh tests/smoke.sh` — 198 állítás az izolálható részekre: állandó jóváhagyások, állapot-fájl, státusz-gép, a három modell-fehérlista egyezése, a prompt bájt-limitje, az újraindítás-számláló nullázása, a tmux session-név feloldása, és `zsh -n` minden szkriptre. Eldobható könyvtárban fut, a `~/.claude`-hoz hozzá sem nyúl. Amit szándékosan nem fed le: az indítás, a merge és a kilövés valódi tmux-sessiont, git-repót és launchd-t igényel — azokat eldobható agenteken teszteljük. |
| `bin/agent-kill-one.sh` / `agent-kill-all.sh` / `agent-kill-tree.sh` / `agent-close-tree.sh` | A slash parancsok segédszkriptjei. |
| `bin/_agent-lib.sh` | Közös segédfüggvények: élő nyilvántartás, worktree/átirat-feloldás, modál-automatika. |
| `bin/mac-main-watchdog.sh` | Életben tartja a command-centert; vezérli a gyerek-sweepet. |
| `bin/agent-child-watchdog.sh` | Visszaállítja a nyilvántartott gyerek-agenteket (`--resume`) reboot vagy összeomlás után. |
| `bin/merge-sessions.sh` | Két session-átiratot egyetlen resume-olható sessionné fűz, ha egy újraindítás kettévágta a történetet. |
| `bin/fork-agent` | A hívó sessiont gyerek-agentté forkolja, ami **örökli a beszélgetést** (`--resume … --fork-session`). |
| `fork.md` | A `/fork` slash parancs. |
| `local.mac-main-watchdog.plist.template` | A watchdog launchd plistje (300 mp + `RunAtLoad`). |
| `bin/_bridge-lib.sh` | A híd magja: validáció, Telegram, jóváhagyás + időablakos felhatalmazás, eredmény-publikálás, beragadás-észlelés. |
| `bin/bridge-relay.sh` | Felveszi a lerakott kéréseket (launchd `WatchPaths`), validál, jóváhagyást kér. |
| `bin/bridge-poller.sh` | A Telegram `getUpdates` fogyasztója: jóváhagyás, visszavonás, emlékeztető; publikálja az eredményeket. |
| `bridge-README.md` | A szerződés annak, aki kéréseket rak a hídra. |
| `bridge-allow.json.example` | A híd konfigurációs sablonja — fehérlista, kapu-mód, időkorlátok. |
| `desktop-skill/agent-bridge/SKILL.md` | A Claude Desktop oldalára telepített skill. |
| `local.bridge-relay.plist.template` / `local.bridge-poller.plist.template` | A híd launchd jobjai. |
| `ROADMAP.md` / `TODO.md` | Függő finomítások (magyarul). |

### Állapot

Éles használatban a szerző gépén — egy command center és néhány hosszan futó agent,
telefonról vezérelve, a Desktop-híddal, ami a Telegram-kapun át rendel munkát.
Vannak még érdes felületek — a hátralévő munka a `TODO.md`-ben és a `ROADMAP.md`-ben
(magyarul). Issue-t és PR-t szívesen fogadok.
