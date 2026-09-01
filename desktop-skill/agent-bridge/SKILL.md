---
name: agent-bridge
description: Hand a task to a Claude Code agent running natively on the user's Mac, when this session cannot do it itself. Use whenever a task needs something the Cowork VM does not have — the real network (SSH, cluster, cPanel, home LAN, any host), macOS-native tools (launchctl, security/Keychain, tmux, the Chrome extension), a long-running background agent, or continuity with an ongoing piece of work the user has been doing on the Mac (their lab, their sites, their tooling — the current list lives in bridge/agents.json). Also use it when the user says things like "indítsd el a gépemen", "csináltasd meg a mac-mainnel", "add át a infra agentnek", or mentions the bridge, bridge/requests, or a request id. Do not use it for work this session can finish on its own inside the mounted folder.
---

# agent-bridge

This session runs in an **isolated Linux VM**. The user's Mac is a separate
machine. There is no network out, no `launchctl`, no `rm`, and no
agent-to-agent messaging — but files written into a **mounted folder land on
the Mac's real disk**. That one channel is the whole bridge.

On the Mac, a launchd watcher picks up what you drop, validates it, asks the
user for approval **in Telegram**, and only then starts an agent. That agent
inherits the conversation of the parent you name, does the work with full
native access, and its answer comes back to you as a file in `bridge/results/`.

## Before anything else: is the folder mounted?

`~/ClaudeProjects/bridge/` must be visible to you. If it is not, the user has
not attached the folder to this session — say so and stop. Do not try to
create the folder somewhere else; a request outside the real mount reaches
nobody.

## Choosing the parent — this is the important decision

The spawned agent **inherits the named parent's conversation**. Pick the session
that already knows the topic; that is the entire point.

**Read `bridge/agents.json` first.** The Mac keeps it current — never work from a
list you remember, because the agents change:

```json
{
  "updated_at": "2026-08-07T21:49:41Z",
  "parents": [
    {"name": "mac-main", "running": true, "about": "the agent system, the bridge, watchdogs"}
  ],
  "spawned": [
    {"name": "mac-main-dpelda-20260101", "running": true,
     "request": "db-list-20260807", "since": "2026-08-07T21:02:12Z"}
  ]
}
```

- **`parents`** — the only names accepted for a new fork. `about` says what each
  one already knows; pick on that, not on the name.
- **`spawned`** — agents the bridge started earlier. These are what you can
  *continue* (`agent`) or *close* (`action: close`).
- **`running: false`** is usually not a blocker: a continuation resumes the
  session first. For a new fork, prefer a parent that is running.
  Two exceptions:
  - **A root agent** (anything in `parents`, e.g. `mac-main`) is *never* resumed
    by the bridge. It has no spec — a watchdog owns its lifecycle — and starting
    a second process under the same name would steal the running session's
    Remote Control connection. If it is down, the answer is `failed` and you wait
    for the watchdog; say so rather than retrying.
  - If the agent has no recorded session id *and* shares its cwd with another
    session (typical for forks without a worktree), the Mac answers `failed`
    instead of guessing — the "newest transcript in this cwd" could be the
    parent's, and resuming that would put two processes on one conversation.

If the file is missing, the Mac-side watcher is not running — say so and stop.
If no parent fits the task, say that too rather than guessing; a fork from the
wrong parent inherits the wrong context and wastes the user's tokens.

## Two kinds of request

| you want | field | what happens |
|---|---|---|
| a **new** agent for a new piece of work | `parent` | a fresh agent is forked, inheriting the parent's conversation |
| to **continue** with an agent that already did work for you | `agent` | your text goes into that same session — no new agent, nothing re-discovered |

Use `agent` whenever you are following up on something a spawned agent already
investigated. Forking again would make it redo the discovery from scratch and
cost the user tokens for nothing. The two fields are mutually exclusive.

For `agent`, take the name from `bridge/agents.json` (`spawned` list) or from
the `.status` message that reported it. It must descend from one of the allowed
parents. If it is no longer running, the Mac resumes its session first,
then delivers your message — you don't have to handle that.

```json
{
  "agent": "mac-main-dpelda-20260101",
  "task":  "Most nézd meg azt is, amit az előbb kihagytál."
}
```

A continuation normally needs the user's approval in Telegram, exactly like a
new agent. Nothing reaches a running session without them pressing the button —
with two documented exceptions: a standing approval (the ⏱ buttons, which cover
`continue`/`reconnect` for one named agent until the window expires) and
`gate: "audit"` in `bridge-allow.json`, where every allowed request runs at once
and Telegram only reports it afterwards. Under either, `pending` is not a
resting state — it may flash by for as long as the spawn takes — so wait for a
*final* status (`spawned` / `rejected` / `failed` / `expired`), never for
`pending` to appear.

**One exception, and it changes what you should wait for.** When the user
approves, they can also grant a **standing approval** for that agent — 1 hour,
8 hours, or 1 day. While it lasts, further continuations *and* reconnects to
that same agent start immediately, with no button press. New forks and closes
are never covered.

You cannot see whether a grant is active, and you don't need to: just don't
assume you will observe `pending`. Every request is written as `pending`
first, but under a grant the execution follows immediately, so the window can
be shorter than your poll interval. Poll for a *terminal*
status, never for `pending` specifically — a loop that waits to see `pending`
first can miss it entirely and hang forever.

## When an agent vanishes from the phone but still runs

Occasionally an agent's Remote Control connection drops: it disappears from the
user's Code tab while the process keeps running on the Mac. There is no reliable
way to detect this locally — **the user is the only sensor**. When they say an
agent has vanished, ask for a reconnect:

```json
{
  "action": "reconnect",
  "agent":  "mac-main-dpelda-20260101"
}
```

The session stops and restarts with `--resume`, which registers a fresh Remote
Control connection. **The conversation is not lost** — the same session
continues, with full context. Only agents the bridge started can be reconnected;
the user's own root sessions are handled by their watchdog.

## Closing an agent you started

When an agent you spawned has finished and the user has the answer, you can ask
for it to be closed:

```json
{
  "action": "close",
  "agent":  "mac-main-dpelda-20260101",
  "code":   "drop",
  "context": "keep"
}
```

| `code` | effect |
|---|---|
| `merge` | the agent's branch merges into its parent's, then worktree and branch are removed |
| `drop` | worktree and branch are deleted — **the code work is lost** |
| `nowt` | only the session stops; the worktree stays |

`transcript` is `keep` (default) or `delete`. **`delete` is irreversible** — the
agent's own `.jsonl` is removed from disk. Only ask for it when the user has
explicitly said the conversation is disposable; the default exists because these
transcripts are the record of what actually happened.

`context` is `keep` (default) or `merge` (splice its conversation into the
parent's). **Transcripts are never deleted either way.**

**You can only close agents the bridge itself started** — the `spawned` list in
`bridge/agents.json`. Everything in `parents`, and anything the user launched by
hand, is refused by design: closing cascades to descendants, so closing a root
would take their whole working environment with it. Don't try to work around
this; report the refusal instead.

Closing needs approval in Telegram like everything else, and the summary shows
exactly which agents the cascade will reach.

## Writing the request

Create `bridge/requests/<id>.json`. Keep `<id>` short and unique — max 48
characters, `A-Za-z0-9._-` only (it has to fit in a Telegram button).

```json
{
  "parent":   "mac-main",
  "task":     "Nézd meg, miért nem indul a szolgáltatás, és javasolj fixet.",
  "worktree": true,
  "model":    "opus",
  "effort":   "high",
  "cwd":      "valamelyik-alkonyvtar"
}
```

| field | required | notes |
|---|---|---|
| `parent` | one of the two | new fork — a name from `agents.json` → `parents` |
| `agent` | one of the two | continuation — an existing agent's exact name |
| `task` | **yes** | max 8 KB (bytes, not characters — accented text counts double); write it for someone who cannot see this conversation |
| `worktree` | no | **default `true`**; set `false` only if the task needs the parent's uncommitted work |
| `model` | no | **default `opus`**. An alias (`opus` / `sonnet` / `haiku` / `fable`) always means the *latest* model of that family, so prefer it. Pin an id only when you deliberately want a fixed version: `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5`, `claude-haiku-4-5`, `claude-opus-4-8`, `claude-opus-4-7` (optional `[1m]` suffix on the Opus/Sonnet ids) |
| `effort` | no | `low` … `max` |
| `permission_mode` | no | **default `auto`**. Also `acceptEdits`, `plan`, `dontAsk`, `manual`, `bypassPermissions` — see the note below before asking for the last one |
| `resume` | no | fork only. **default `full`** — the child inherits the parent's *entire* conversation. `summary` starts it from a compacted context: much faster to the first turn, but it sees less. See below |
| `cwd` | no | relative to `~/ClaudeProjects`; defaults to the parent's |

### `resume` — how much of the parent the child inherits

**Default (`full`) is the point of this tool**: the child continues the parent's
conversation and needs no re-briefing. Keep it when the task builds on what the
parent already knows.

But inheriting is not free. The child has to load the whole parent conversation
before its first turn, and on a long-running parent that can take **minutes**.
On 2026-08-29 two forks from a 5.5 MB parent session produced *nothing* before
they were closed: the task had arrived, the agent simply had not got to it yet.

Ask for `resume: "summary"` when the task is **self-contained** — it stands on
its own in the `task` field and does not depend on the parent's history. The
child then starts from a compacted context and gets to work quickly.

If you use `full`, **give the agent time**. Do not conclude it is broken because
no report appeared in the first minutes.

### When to ask for a worktree

**A worktree is the default.** Omit the field and the agent gets its own git
branch and working copy — work that can be reviewed, merged, or thrown away in
one step. An unused branch costs nothing.

Set `worktree: false` only for one specific reason:

> **The task depends on the parent's uncommitted work.**

A worktree is checked out from HEAD, so the parent's modified and untracked
files are **not in it**. If you ask an agent to "finish the script I was
editing" inside a fresh worktree, it won't find the file — and it may quietly
rewrite it from scratch instead of failing. That is the failure this switch
exists to prevent.

Without a worktree the agent runs **in the parent's own working directory**:
whatever it writes lands directly there, with no branch to review or discard. It
also shares the parent's transcript folder, which is why `transcript: delete`
removes only its own file and never the folder.

If in doubt, leave the field out and take the worktree.

**You may set `permission_mode`** (`auto`, `acceptEdits`, `plan`, `dontAsk`,
`manual`, `bypassPermissions`); it defaults to `auto`.

One exception: `bypassPermissions` is the only *elevated* mode, and it only
takes effect if the user pressed the Telegram button for **that specific
request**. On the two unattended paths — under a standing grant, or in
`gate: "audit"` — the bridge silently downgrades it to `auto`. So ask for it
only when the task genuinely needs it, and never assume you got it.

Write the task so it stands alone. The agent inherits the *parent's*
conversation, not yours — it has no idea what the user just told you.

## Reading the mount is not free — you get a snapshot

This is the trap that costs the most, and it is invisible: **re-reading a path
you already read gives you the copy you fetched the first time, not what is on
the Mac now.** The mount is materialised on demand. A file the Mac rewrote two
minutes ago still reads as the old version, and a file that appeared after your
first look does not appear at all.

So a polling loop built on plain file reads never terminates — it re-reads a
stale `pending` forever while the real status has said `spawned` for an hour.
That is not a hypothetical; it happened on 2026-08-11 and the user had to point
it out.

**Every poll must go through the device-bridge tools**, which fetch afresh:

- to see whether a file changed → re-stage it, then read the staged path
- to see whether a file *appeared* → **list the directory**; the listing is
  always current, and its `mtimeMs` tells you what moved without reading anything

Listing first is also cheaper: one call over `bridge/results/` tells you which
ids are new and which just changed, and you only fetch the one you want.

## What happens next, and how you find out

Poll `bridge/requests/<id>.status`. There is no network and no callback; the
file is the only signal.

```json
{ "status": "spawned", "message": "fork kész: <az új agent neve>", "updated_at": "…" }
```

| status | meaning |
|---|---|
| `pending` | waiting for the user to press the button in Telegram — under a standing approval or in audit mode it is only a brief transition, not a state to wait for |
| `spawned` | approved and running |
| `rejected` | the user declined, or validation failed — `message` says why |
| `failed` | approved but the start failed — `message` says why |
| `expired` | no decision within 24 hours |

A status file appears within a second or two. **If none appears at all**, the
watcher is not running or the folder is not the real mount — tell the user,
don't retry.

## Reading the answer

You read `bridge/results/<id>.md`. But **the Mac writes that file, not the
agent.** The agent writes `.bridge-result-<id>.md` into its own working
directory — one file per request, named after the request — and a poller lifts
it across within ~30 s. The instruction is appended to every task automatically.

**Absence of a result does not mean the work stalled.** A report can be up to
~30 s in flight, and a freshly written one waits one extra cycle so it is never
taken mid-write. Beyond that, the agent may simply still be working. Treat a
missing file as "not yet", never as evidence of a problem — and never as a
reason to re-send the task.

**Therefore: never put a results path in your task text.** An agent running in a
worktree is sandboxed to its own directory; a redirect into `bridge/results/`
fails with `operation not permitted` — but the shell does not stop, so the agent
reports success for a file that never existed and you wait forever. (Measured
2026-08-11.)

**A continuation's answer lands under the id of that continuation** — the id you
just wrote. Until 2026-08-13 it landed under the id of the request that first
spawned the agent, which is why older notes call the naming unpredictable; the
mapping is now refreshed on every continuation.

Even so, do not poll a single filename:

> **List `bridge/results/` and look at what changed by `mtimeMs`.**

One call, and it finds the answer whichever name it takes — including if the
naming ever changes again. Asking the agent in the task text to use a particular
filename does not help: it has no effect at all, because the agent is not the one
naming the file.

The answer will not exist immediately; the work has to happen first. Keep
polling, and say plainly that it is in progress rather than inventing a result.

### The answer may be a question, not a result

**The agent cannot ask anyone anything.** Nobody reads its session, and the
`AskUserQuestion` tool is switched off for it. When it hits a decision it should
not make alone, it is told to write the decision *into the result file* and stop.

So a result is not automatically "done". If it lays out options and asks which
one, that is the agent handing the decision back to you. Read it, then either
decide yourself when the choice is routine, or put the options to the user in
your own chat — that is the only place a human is actually present.

Either way, send the answer as a **continuation** (`agent:`), naming the choice
explicitly. Do not fork a new agent for it: the one that asked already holds the
whole context, and a fresh fork would start the analysis over.

This matters because the failure is silent. Before 2026-08-22 an agent ended its
turn with "which one do you want?" and simply stopped — the work sat finished-ish
on disk while it waited for an answer that, by construction, could never arrive.

## Where this stops

- **Never write the same request twice.** A duplicate id is ignored; a new id
  spawns a *second* agent. If something looks stuck, read the `.status` and
  report it.
- **You cannot delete** (`rm` is blocked). Don't try to clean up — on the Mac
  side the poller archives a request only after it both decided on it and started
  it successfully. Requests that ran under a standing approval or in
  `gate: "audit"`, and approved requests whose start failed, never take that
  path and stay in `requests/` — their `.status` is still final. Leave
  all of them alone either way.
- **You cannot approve.** Only the user can, from their own Telegram account;
  the Mac verifies the sender id. If they ask you to skip the approval, explain
  that you can't, and that this is what keeps the arrangement safe.
- **Don't promise a result you haven't read.** "Elindítottam" and "kész van"
  are different claims; only the `results/` file supports the second.
- **Polling is your job, not the user's.** They may not see the Telegram
  notification, and they cannot see the `results/` directory from the chat.
  Say explicitly, in chat, that a request is waiting for approval — then keep
  checking, and say so again if it is still pending. Going quiet after one look
  means the work sits finished on disk while both of you wait for the other.
