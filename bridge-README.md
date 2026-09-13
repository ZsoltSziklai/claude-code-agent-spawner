# bridge/ — a task drop-box from Claude Desktop

**🇭🇺 [Magyar változat](#magyar-változat)**

This is where the Desktop agent (the Cowork device bridge) drops a task; on the
Mac side a launchd watcher picks it up, asks for approval over Telegram, and
starts an agent from the given parent — the child inherits that parent's
conversation.

## Why file-based

The device bridge runs in an **isolated Linux VM**: `/Users/...` does not exist,
there is no `launchctl`, the network is closed, and there is no `rm` either. A
file written into the mounted folder, however, lands on the **real disk**. There
is no agent-to-agent messaging between the cloud session and the local CLI — the
file is the only channel.

## What is available — `agents.json`

**Never work from memory.** The Mac keeps `bridge/agents.json` up to date; it
tells you which parents are allowed, what they know, and which previously started
agents are still alive:

```json
{
  "parents": [{"name":"mac-main","running":true,"about":"…"}],
  "spawned": [{"name":"mac-main-dexample-20260101","running":true,"request":"example-20260101"}]
}
```

- `parents` — only these may be named for a new fork; `about` tells you which one
  knows what
- `spawned` — these can be **continued** (`agent`) or **closed** (`action: close`)
- `running: false` is usually not an obstacle: a continuation restores the session
  first. **There are two exceptions:**
  - A **root agent** (anything from the `parents` list, e.g. `mac-main`) is
    **never resurrected** by the bridge. It has no spec — its lifecycle belongs to
    the watchdog — and a second process under the same name would steal the
    running session's Remote Control connection. If it is not running the answer
    is `failed`, and you have to wait for the watchdog.
  - If the agent has no recorded session id AND shares its cwd with another
    session (typically forks without a worktree), the Mac answers `failed` rather
    than guessing. The "latest transcript" could belong to the parent, and
    starting that one would put two processes on the same conversation.

If the file is missing, the watcher on the Mac side is not running.

## Two kinds of request

| what you want | field | what happens |
|---|---|---|
| a **new** agent for new work | `parent` | a fresh agent is forked, inheriting the parent's conversation |
| **continuing** with an agent already at work | `agent` | your text goes into the same session — nothing new starts, nothing has to be rediscovered |

The two are mutually exclusive. If a spawned agent has already done something and
you want to ask about it, **use `agent`** — re-forking would start the discovery
from scratch, for nothing.

```json
{
  "agent": "mac-main-dexample-20260101",
  "task":  "Now look at the thing you skipped a moment ago as well."
}
```

The agent's name comes from the message in `.status`. If it is no longer running,
the Mac restores its session first and then delivers the message — except for
root agents, which the watchdog brings back (see above). By default a
continuation is **gated on Telegram approval** just like a new start. There are
two documented exceptions: a **time-boxed standing approval** (the ⏱ buttons —
for the `continue`/`reconnect` requests of one named agent, until the given
window expires), and `gate: "audit"` in `bridge-allow.json`, where every allowed
request starts immediately and Telegram only reports afterwards. In both cases
`pending` is **not a resting state**: the Mac writes it out for a moment (so that
a concurrent trigger does not start the same thing twice), but only for the
duration of the spawn/resume — which can be 5–20 seconds — and then it goes
straight to `spawned`. Do not wait for `pending` to appear.

## When an agent disappeared from the phone but is still running

It happens that an agent's Remote Control connection drops: it vanishes from the
Code tab while the process keeps running on the Mac. This cannot be detected
reliably from the local side — **the only sensor is the user**. In that case:

```json
{
  "action": "reconnect",
  "agent":  "mac-main-dexample-20260101"
}
```

The session stops and restarts with `--resume`, which registers a new Remote
Control connection. **The conversation is not lost** — the same session
continues, with a full handover.

## Closing an agent

When an agent you started is done:

```json
{
  "action": "close",
  "agent":  "mac-main-dexample-20260101",
  "code":   "drop",
  "context": "keep"
}
```

| `code` | effect |
|---|---|
| `merge` | the branch merges into the parent's, then the worktree and the branch are deleted |
| `drop` | the worktree and the branch are deleted — **the code work is lost** |
| `nowt` | only the session stops, the worktree stays |

`transcript` is `keep` (default) or `delete`. **`delete` is irreversible** — the
agent's own `.jsonl` transcript is removed from disk. Only ask for it if the user
explicitly said it is disposable.

`context` is `keep` (default) or `merge`. **Transcripts are not deleted in either
case.**

⚠️ **Only an agent started by the bridge can be closed** — one that appears in
the `spawned` list of `agents.json`. Everything in `parents`, and every manually
started agent, is rejected: closing cascades, and closing a root would take the
whole working environment with it.

## Dropping a request

Write a JSON here: `requests/<id>.json`

Keep `<id>` short (at most 48 characters, `A-Za-z0-9._-`), because it has to fit
into the Telegram button data as well.

```json
{
  "parent":   "mac-main",
  "task":     "Find out why the service does not start, and propose a fix.",
  "worktree": true,
  "model":    "claude-opus-5",
  "effort":   "high",
  "cwd":      "some-subdirectory"
}
```

| field | required | note |
|---|---|---|
| `parent` | one of the two | a new fork — which agent it should descend from; whitelisted |
| `agent` | one of the two | a continuation — the exact name of an existing agent |
| `task` | **yes** | the child's job, at most 8 KB (bytes, not characters — accented text counts double) |
| `worktree` | no | **`true` by default**; `false` only if you need the parent's uncommitted work |
| `model` | no | `opus`/`sonnet`/`haiku`/`fable`, or a pinned id: `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5`, `claude-haiku-4-5`, `claude-opus-4-8`, `claude-opus-4-7` (the `[1m]` suffix on the Opus/Sonnet ids) |
| `effort` | no | `low`…`max` |
| `cwd` | no | may be relative to `cwd_root` |

### When to ask for a worktree

**The worktree is the default.** Leave the field out and the agent gets its own
git branch and working copy — its work can be reviewed, merged, or dropped in one
step. An unused branch costs nothing.

`worktree: false` is needed for **one reason only**:

> **when the task builds on the parent's uncommitted work.**

The worktree is made from HEAD, so the parent's modified and new files are **not
in it**. If in a fresh worktree you ask it to "finish the script I wrote", the
agent will not find the file — and in the worse case it does not get stuck but
quietly rewrites it from scratch.

Without a worktree the agent runs in the **parent's own working directory**: what
it writes goes straight there, with no branch to review or discard. It also
shares the parent's transcript directory — which is why `transcript: delete` then
removes only its own file, never the directory.

The stall alert carries three kinds of button: `🔔 Remind` (sends a reminder to
the agent), and `🔕 8 hours`, `🔕 1 day` and `🔕 1 week`. The three mute buttons
turn the stall notification off **for that agent** — useful when you know it is
standing still on purpose (parked work, or the command center between rounds).
The mute is **time-boxed**: it lifts by itself when it expires, so a real stall
does not stay hidden.

## What `spawned` means — and what it does not

The `spawned` status means the task **provably arrived** at the agent: the bridge
sends it in chunks and confirms from the agent's **transcript** that the text
landed. If that fails, the status is `failed`, not `spawned`.

This holds on both paths — for a new fork and for a continuation alike.
⚠️ It did not use to, and the status lied on two separate occasions: everything
was green on the sending side while the agent sat there empty. Sent in one piece,
a prompt above ~1KB loses its **beginning**, and its end is left unsent in the
input line.

**`spawned` still does not mean the work happened** — only that the task reached
its destination. The work is evidenced by the report.

## Messaging a descendant agent — `agent-send-prompt`

When an agent has to speak to **its own child** (for cascading work, say),
`bin/agent-send-prompt` is the tool:

```bash
agent-send-prompt <agent-name> <text>
```

**The boundary is narrow: downwards in your tree only.** The target's name must
start with the caller's name (`$CLAUDE_AGENT_NAME-*`); the parent, the siblings
and the user's production agents are outside it.

⚠️ **Do not use a raw `tmux send-keys` for this.** The auto-mode classifier
blocks it — rightly, because that could write into any session. This wrapper
exists so there is a narrow, auditable route to the same thing.

Delivery is **chunked** (in 400-character blocks) and confirmed from the
**transcript** — sent in one piece, a prompt above 1KB loses its beginning, and
the agent receives the stump as its task.

## The guarantee on request processing

The relay is started by launchd's **`WatchPaths`** (for fast response) **and** by
a **`StartInterval`** (for the guarantee). Both are needed:

⚠️ launchd **does not queue** a `WatchPaths` event **while the job is running** —
it simply drops it. On 2026-08-31 a valid request stayed **silent forever**
because of this: no status, no log, no retry, while the sender waited for an
answer that would never come. The request arrived in the *same second* as the
previous request's status; a day earlier the same thing ran flawlessly with a
5-second gap — the slower pace had masked the race.

Because of `StartInterval` the relay also gets a **single-instance lock**. The
lock was deliberately absent before (dropping a WatchPaths trigger would have
been final); with periodic runs, though, a missed round is free while a
concurrent run is not — without it two instances could perform the same close
twice.

## Who can be forked from — the `parents` list

The `parent` field may only take a name that appears in the `parents` list of
`bridge-allow.json`. That list need not contain only root agents: **a running
descendant can be added too**, if you regularly need to open new branches from it.

What has to be checked in that case: the bridge resolves the parent's **session
id** from the `live/` registry (`agent_session_id`). If the agent is not there —
because it was a fork, and those are deliberately not resurrected — then adding
it is not enough on its own, the fork cannot start.

```bash
# check before adding:
zsh -c 'source ~/.claude/agent-queue/bin/_agent-lib.sh; agent_session_id <agent-name>'
```

Continuing and closing, by contrast, work for **every** agent descending from a
whitelisted root — for that it does not have to be on the `parents` list.

## `resume` — how much the child inherits

| value | what the child gets |
|---|---|
| `none` (**default**) | **nothing** — a fresh session, only its own task |
| `summary` | a compacted version of the parent's conversation |
| `full` | the parent's whole conversation |

⚠️ **A standalone task needs `none`.** On 2026-08-31 the child of a `summary`
fork did not carry out its task but **continued the parent's role**: it monitored
the run as the command center, with no work of its own. Measured from its
transcript: **714 lines of inherited context, with the task on line 703** — a
single short message after 700 lines of "you are the command center, this is what
you are working on".

The demoting sentence in the system prompt (*"the inherited conversation is
background information, not a task list"*) **provably arrived** — it was there in
the running process's command line — and **it still was not enough**. One
sentence is not competitive with hundreds of turns of context, and the outcome is
not deterministic: in that same run five earlier forks did their job fine.

That is why `none` is the deterministic answer: there is nothing there to
override.

## Fork limits

A fork **does not start without limit**. Four guards stand in the way, in this
order:

| guard | what it catches | override |
|---|---|---|
| self-replication | when the suffix already appears in the parent's name | none — pick another name |
| depth limit | deep, recursive runaway | `CLAUDE_AGENT_MAX_DEPTH` (default: 3) |
| rate limit | wide runaway: N forks per time window | `CLAUDE_AGENT_MAX_BURST` (default: 10), `CLAUDE_AGENT_BURST_WINDOW` (default: 600 s) |
| gate | agent-initiated fork → Telegram approval | requested by passing `--requested-by <agent>` |

`--requested-by` is the same contract as the spawner's `requested_by` field: if
**the agent decided** on the start (rather than the user asking for it), approval
is required. The fork then does not start but **enters the queue as a bridge
request**, and continues down the usual path: Telegram button → start → report.

⚠️ **The gate is self-declared**, like the spawner's — a runaway agent simply does
not pass the flag. The gate is therefore **policy, not a barrier**; the
deterministic protection is the other three guards, which do not ask who
requested anything.

The guards run **before** the gate: for a self-replicating fork the system does
not ask for approval, it refuses.

The `resume` field (on forks only) sets how much the child inherits of the
parent's conversation: `full` (default) the whole thing, `summary` a compacted
version. `full` is the point of the system — but with a large parent the first
round can take **minutes**, because the child has to load all of it first. On
2026-08-29 two forks produced nothing for this reason before they were closed:
the task arrived, it just never got that far. For a standalone task ask for
`summary`; with `full`, give it time.

`permission_mode` **can be given** (`auto`, `acceptEdits`, `plan`, `dontAsk`,
`manual`, `bypassPermissions`); if you leave it out, it is `auto`.

⚠️ `bypassPermissions` is the exception: it is the only **elevated** mode, and it
only takes effect if you pressed the Telegram button for that **specific**
request. On the two unattended execution paths — under a time-boxed grant, and in
`gate: "audit"` mode — the bridge quietly downgrades it to `auto` and writes a
`PERM-DOWNGRADE` line into `bridge.log`. The approval message warns separately
when a request asks for elevated permission.

## What happens next

1. The relay validates. A bad request → `requests/<id>.status` = `rejected`, with
   a reason.
2. A good request → `pending`, and a **summary attachment** goes to Telegram (what
   it is going to do), with **Start / Reject** buttons underneath.
3. After approval it starts, `status` = `spawned`.
4. If no decision arrives within 24 hours → `expired`, the request is archived.

Besides **Start**, the approval message also offers **⏱ +1 hour / +8 hours /
+1 day**. That is a **grant**: while it lasts, `agent:` continuations and
`reconnect` for that agent **start without approval** — `pending` flashes at most
for the duration of the execution, and is not the signal to wait for. A new fork
and `close` never fall under it.

Every request started this way sends a Telegram message with a **Revoke** button;
otherwise the grant expires on its own.

⚠️ **One thing follows from this on the Desktop side:** do not wait for the status
to become **`pending`**, wait for it to become **final** (`spawned` / `rejected` /
`failed` / `expired`). Under a grant, `pending` is visible only transiently, for
the duration of the execution — it is not the signal to wait for.

## Reading the status back

There is **no network** from the VM, so the disk is your only source of
information: read `requests/<id>.status`.

```json
{ "status": "spawned", "message": "fork done: <the new agent's name>", "updated_at": "..." }
```

Possible values: `pending`, `spawned`, `rejected`, `failed`, `expired`.

## Writing the result back

You still read the result from here: **`results/<id>.md`**. That file is put there
by the Mac — **not by the agent**.

The agent writes into its own working directory, into **a separate file per
request** (`.bridge-result-<id>.md`), and the poller moves it across — all of them
in one round. The per-request name is needed because the earlier fixed name was a
single-slot mailbox: if the agent ran two rounds before the publisher took the
first, the second **overwrote** it — the first report was lost without a trace.

⚠️ **A missing result does NOT mean stalled work.** The report may be in transit
(~30 s), and a freshly written file deliberately waits a round so we do not take
it mid-write. Beyond that, the agent may simply still be working. A missing file
means "not yet", not "something is wrong" — and it is certainly not a reason to
resend the task. The bridge appends this instruction to the task by itself; **you
do not have to ask for it**, and do not ask the agent to write into `results/`
directly either.

⚠️ **Why this way:** an agent running in a worktree has a sandbox that only allows
writing **into its own working directory**. A redirection aimed at
`bridge/results/` fails with `operation not permitted` — but the shell **does not
stop because of it**, so the agent could report "done" in good faith for a file
that was never created, while the Desktop waited forever. (Measured on 2026-08-11,
in the `dfetch-x` run.)

## The result may be a question

**An agent started over the bridge cannot ask back.** Nobody reads its session,
and the `AskUserQuestion` tool is disabled for it too. When it reaches a decision
it cannot make alone, its instructions say to **write it into the result** and
finish the round.

So the result is not always "done" — it may list options and ask for a decision.
Read it, decide (or put the question to the user in your own conversation —
**that is the only place there is a human**), and send the answer back as a
**continuation** (`agent:`), naming the decision. Do not start a new fork for it:
the agent that asked already has the full context.

The converse holds too: when the question is a detail and there is a sensible
default, the agent's instructions are to **decide for itself** and say in the
report what it chose — so do not expect a question for every small thing.

## Cleanup

You **cannot delete** from the VM (`rm` is forbidden). Do not try: processed
requests are archived by the **poller** on the Mac side, under `archive/` (after
the approval, the rejection or the expiry). ⚠️ A request that started under a
grant or in `gate: "audit"` mode does not pass through this branch of the poller:
its `.json` stays under `requests/`. The same goes for an approved request whose
start **failed** — the poller only archives after a successful execution. This is
deliberate — `.status` shows the final state either way — but expect it when
cleaning up.

---

## Magyar változat

Ide teszi le a Desktop agent (Cowork device-bridge) a feladatot; a Mac oldalán
egy launchd watcher veszi fel, Telegramon jóváhagyást kér, és indít egy agentet
a megadott szülőből — a gyerek örökli annak beszélgetését.

### Miért fájl-alapú

A device-bridge **izolált Linux VM**-ben fut: a `/Users/...` nem létezik, nincs
`launchctl`, a hálózat zárva, és `rm` sincs. A csatolt mappába írt fájl viszont
a **valódi lemezre** kerül. Nincs agent-to-agent messaging a felhő-session és a
lokális CLI között — a fájl az egyetlen csatorna.

### Mi érhető el? — `agents.json`

**Soha ne dolgozz emlékezetből.** A Mac folyamatosan frissíti a
`bridge/agents.json`-t; ebből derül ki, mely szülők engedélyezettek, mit tudnak,
és mely korábban indított agentek élnek még:

```json
{
  "parents": [{"name":"mac-main","running":true,"about":"…"}],
  "spawned": [{"name":"mac-main-dpelda-20260101","running":true,"request":"pelda-20260101"}]
}
```

- `parents` — csak ezek adhatók meg új forkhoz; az `about` mondja meg, melyik mit tud
- `spawned` — ezeket lehet **folytatni** (`agent`) vagy **lezárni** (`action: close`)
- `running: false` általában nem akadály: a folytatás előbb visszaállítja a
  sessiont. **Két kivétel van:**
  - **Gyökér agentet** (bármit a `parents` listából, pl. `mac-main`) a híd
    **soha nem támaszt fel**. Nincs specje — az életciklusát a watchdog viszi —,
    és egy azonos nevű második folyamat elvenné a futó session Remote Control
    kapcsolatát. Ha nem fut, a válasz `failed`, és meg kell várni a watchdogot.
  - Ha az agentnek nincs rögzített session-id-je ÉS a cwd-jén osztozik egy másik
    sessionnel (jellemzően a worktree nélküli forkok), a Mac `failed`-del
    válaszol ahelyett, hogy találgatna. A „legfrissebb átirat" ilyenkor a szülőé
    is lehet, és annak az elindítása két folyamatot tenne ugyanarra a
    beszélgetésre.

Ha a fájl hiányzik, a Mac-oldali watcher nem fut.

### Két kérés-típus

| amit akarsz | mező | mi történik |
|---|---|---|
| **új** agent új munkához | `parent` | friss agent forkolódik, örökli a szülő beszélgetését |
| **folytatás** egy már dolgozó agenttel | `agent` | a szöveged ugyanabba a sessionbe megy — nem indul új, nem kell újra felderíteni |

A kettő kizárja egymást. Ha egy spawnolt agent már megcsinált valamit, és arra
kérdezel rá, **`agent`-et használj** — az újraforkolás elölről kezdetné a
felderítést, feleslegesen.

```json
{
  "agent": "mac-main-dpelda-20260101",
  "task":  "Most nézd meg azt is, amit az előbb kihagytál."
}
```

Az agent nevét a `.status` üzenete adja meg. Ha már nem fut, a Mac előbb
visszaállítja a sessionjét, aztán kézbesíti az üzenetet — kivéve a gyökér
agenteket, azokat a watchdog hozza vissza (lásd fentebb). A folytatás alapesetben **ugyanúgy
Telegram-jóváhagyáshoz kötött**, mint az új indítás. Két dokumentált kivétel van:
egy **időkorlátos állandó jóváhagyás** (a ⏱ gombok — egy megnevezett agent
`continue`/`reconnect` kéréseire, a megadott ablak lejártáig), illetve a
`bridge-allow.json`-beli `gate: "audit"`, ahol minden engedélyezett kérés azonnal
indul, és a Telegram csak utólag jelent. Mindkettőnél a `pending` **nem
nyugalmi állapot**: a Mac egy pillanatra kiírja (hogy egy párhuzamos trigger ne
indítsa el ugyanazt kétszer), de a spawn/resume idejére — ez 5–20 másodperc is
lehet —, aztán rögtön `spawned` lesz. Ne a `pending` megjelenésére várj.

### Ha egy agent eltűnt a telefonról, de még fut

Előfordul, hogy egy agent Remote Control kapcsolata leszakad: eltűnik a Code
tabról, miközben a folyamat a Macen fut tovább. Ezt lokálisan nem lehet
megbízhatóan észlelni — **az egyetlen érzékelő a felhasználó**. Ilyenkor:

```json
{
  "action": "reconnect",
  "agent":  "mac-main-dpelda-20260101"
}
```

A session leáll, majd `--resume`-mal újraindul, amivel új Remote Control
kapcsolat regisztrálódik. **A beszélgetés nem vész el** — ugyanaz a session
folytatódik, teljes átvétellel.

### Agent lezárása

Ha egy általad indított agent végzett:

```json
{
  "action": "close",
  "agent":  "mac-main-dpelda-20260101",
  "code":   "drop",
  "context": "keep"
}
```

| `code` | hatás |
|---|---|
| `merge` | az ág beolvad a szülőébe, utána a worktree és az ág törlődik |
| `drop` | a worktree és az ág törlődik — **a kód-munka elvész** |
| `nowt` | csak a session áll le, a worktree marad |

A `transcript` `keep` (alapértelmezett) vagy `delete`. A **`delete`
visszafordíthatatlan** — az agent saját `.jsonl` átirata törlődik a lemezről.
Csak akkor kérd, ha a felhasználó kifejezetten eldobhatónak mondta.

A `context` `keep` (alapértelmezett) vagy `merge`. **Az átiratok egyik esetben
sem törlődnek.**

⚠️ **Csak a híd által indított agent zárható le** — ami az `agents.json`
`spawned` listájában szerepel. Minden, ami a `parents`-ben van, és minden kézzel
indított agent elutasításra kerül: a lezárás kaszkádol, egy gyökér lezárása az
egész munkakörnyezetet elvinné.

### Kérés letétele

Írj egy JSON-t ide: `requests/<id>.json`

Az `<id>` rövid legyen (max 48 karakter, `A-Za-z0-9._-`), mert bele kell férnie
a Telegram gomb-adatába is.

```json
{
  "parent":   "mac-main",
  "task":     "Nézd meg, miért nem indul a szolgáltatás, és javasolj fixet.",
  "worktree": true,
  "model":    "claude-opus-5",
  "effort":   "high",
  "cwd":      "valamelyik-alkonyvtar"
}
```

| mező | kötelező | megjegyzés |
|---|---|---|
| `parent` | a kettő egyike | új fork — melyik agentből származzon le; whitelistázva van |
| `agent` | a kettő egyike | folytatás — egy létező agent pontos neve |
| `task` | **igen** | a gyerek feladata, max 8 KB (bájt, nem karakter — az ékezetes szöveg duplán számít) |
| `worktree` | nem | **alapból `true`**; `false` csak ha a szülő nem commitolt munkája kell |
| `model` | nem | `opus`/`sonnet`/`haiku`/`fable`, vagy pinned id: `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5`, `claude-haiku-4-5`, `claude-opus-4-8`, `claude-opus-4-7` (`[1m]` utótag az Opus/Sonnet azonosítókon) |
| `effort` | nem | `low`…`max` |
| `cwd` | nem | a `cwd_root`-hoz képest relatív is lehet |

#### Mikor kérj worktree-t

**A worktree az alapértelmezés.** Ha elhagyod a mezőt, az agent saját git ágat
és munkapéldányt kap — a munkája átnézhető, mergelhető vagy egy lépésben
eldobható. Egy fel nem használt ág semmibe nem kerül.

`worktree: false` **egyetlen okból** kell:

> **ha a feladat a szülő nem commitolt munkájára épül.**

A worktree a HEAD-ről készül, tehát a szülő módosított és új fájljai **nincsenek
benne**. Ha egy friss worktree-ben azt kéred, hogy „fejezd be a scriptet, amit
írtam", az agent nem találja a fájlt — és rosszabb esetben nem elakad, hanem
csendben újraírja nulláról.

Worktree nélkül az agent a **szülő saját munkakönyvtárában** fut: amit ír,
közvetlenül oda kerül, nincs ág, amit átnézni vagy eldobni lehetne. Emellett
osztozik a szülő transcript-könyvtárán is — ezért töröl a `transcript: delete`
ilyenkor csak a saját fájlt, sosem a könyvtárat.

A beragadás-riasztáson három gomb van: `🔔 Emlékeztetem` (emlékeztetőt küld az
agentnek), illetve `🔕 8 óra`, `🔕 1 nap` és `🔕 1 hét`. A három némító gomb
**erre az agentre** kapcsolja ki a beragadás-értesítést — hasznos, ha tudod, hogy
szándékosan áll (parkolt munka, vagy a parancsközpont két kör között). A némítás
**időkorlátos**: lejárat után magától visszaáll, tehát egy valódi beragadás nem
marad rejtve.

### Mit jelent a `spawned` — és mit nem

A `spawned` státusz azt jelenti, hogy **a feladat bizonyítottan megérkezett** az
agenthez: a híd darabolva küldi, és az agent **átiratából** igazolja vissza,
hogy a szöveg bekerült. Ha nem sikerül, a státusz `failed` lesz, nem `spawned`.

Ez mindkét úton így van — új forknál és folytatásnál egyaránt. ⚠️ Korábban nem
így volt, és két külön alkalommal is hazudott a státusz: a küldő oldalán minden
zöld volt, az agent mégis üresen ült. A ~1KB feletti prompt **eleje** vész el
egyben küldve, a vége pedig elküldetlenül ott marad a beviteli sorban.

**A `spawned` továbbra sem jelenti, hogy a munka megtörtént** — csak azt, hogy a
feladat célba ért. A munkát a jelentés igazolja.

### Üzenet egy leszármazott agentnek — `agent-send-prompt`

Ha egy agentnek a **saját gyerekéhez** kell szólnia (pl. kaszkádos munkánál),
arra a `bin/agent-send-prompt` való:

```bash
agent-send-prompt <agent-nev> <szoveg>
```

**A határ szűk: csak lefelé a fádban.** A cél nevének a hívó nevével kell
kezdődnie (`$CLAUDE_AGENT_NAME-*`); a szülő, a testvérek és a felhasználó éles
agentjei kívül esnek rajta.

⚠️ **Nyers `tmux send-keys`-t ne használj erre.** Az auto-mode classifier
letiltja — helyesen, mert az bármelyik sessionbe írhat. Ez a wrapper azért
létezik, hogy legyen szűk, auditálható út ugyanarra.

A küldés **darabolva** megy (400 karakteres blokkokban), és az **átiratból**
igazolja, hogy megérkezett — egy 1KB feletti prompt egyben küldve elveszíti az
elejét, és az agent a csonkot kapja feladatnak.

### A kérés-feldolgozás garanciája

A relayt a launchd **`WatchPaths`** indítja (gyors válaszidő), **és** egy
**`StartInterval`** is (garancia). Mindkettő kell:

⚠️ A launchd a `WatchPaths`-eseményt **nem állítja sorba, ha a job éppen fut** —
egyszerűen eldobja. 2026-08-31-én emiatt egy érvényes kérés **örökre néma
maradt**: se státusz, se napló, se újrapróbálás, a küldő pedig egy sosem érkező
válaszra várt. A kérés az előző kérés státuszával *azonos másodpercben* érkezett;
egy nappal korábban ugyanez 5 másodperc réssel hibátlanul lefutott — a lassabb
tempó elfedte a versenyt.

A `StartInterval` miatt a relay **egypéldányos zárat** is kap. A zár korábban
szándékosan hiányzott (egy WatchPaths-trigger eldobása végleges lett volna);
periodikus futással viszont a kihagyott kör ingyen van, a párhuzamos futás
viszont nem — enélkül két példány ugyanazt a lezárást hajthatná végre kétszer.

### Kiből lehet forkolni — a `parents` lista

A `parent` mező **csak** olyan nevet vehet fel, ami a `bridge-allow.json`
`parents` listájában szerepel. Ez a lista nem csak gyökér-agenteket tartalmazhat:
**egy futó leszármazott is felvehető**, ha rendszeresen kell belőle új ágat
nyitni.

Amit ilyenkor ellenőrizni kell: a híd a szülő **session-azonosítóját** a
`live/` nyilvántartásból oldja fel (`agent_session_id`). Ha az agent nincs ott —
például fork volt, azokat szándékosan nem élesztjük újra —, akkor a
felvétele önmagában nem elég, a fork nem tud elindulni.

```bash
# ellenőrzés felvétel előtt:
zsh -c 'source ~/.claude/agent-queue/bin/_agent-lib.sh; agent_session_id <agent-név>'
```

Folytatni és lezárni ezzel szemben **minden** whitelistázott gyökérből származó
agentet lehet — ahhoz nem kell a `parents` listán szerepelnie.

### `resume` — mennyit örököljön a gyerek

| érték | mit kap a gyerek |
|---|---|
| `none` (**alap**) | **semmit** — friss session, csak a saját feladatát |
| `summary` | a szülő beszélgetésének tömörített változatát |
| `full` | a szülő teljes beszélgetését |

⚠️ **Önálló feladathoz `none` kell.** 2026-08-31-én egy `summary` fork gyereke
nem a feladatát hajtotta végre, hanem **a szülő szerepét folytatta**: a
parancsközpontként monitorozta a futást, saját munka nélkül. Az átiratából
kimérve: **714 sor örökölt kontextus, és a feladat a 703. sorban** — egyetlen
rövid üzenet 700 sornyi „te vagy a parancsközpont, ezen dolgozol" után.

A rendszer-promptban lévő lefokozó mondat (*„az örökölt beszélgetés
háttér-információ, nem feladatlista"*) **bizonyíthatóan odaért** — ott volt a
futó folyamat parancssorában —, és **mégsem volt elég**. Egy mondat nem
versenyképes több száz forduló kontextusával, és a kimenetel nem determinisztikus:
ugyanabban a futásban öt korábbi fork rendben elvégezte a dolgát.

Ezért a `none` a deterministikus válasz: ott nincs mit felülírni.

### Fork-korlátok

Egy fork **nem indul korlátlanul**. Négy őr áll az úton, ebben a sorrendben:

| őr | mit fog meg | felülbírálás |
|---|---|---|
| önmásolás | ha a suffix már szerepel a szülő nevében | nincs — adj más nevet |
| mélységkorlát | a mély, rekurzív elszabadulás | `CLAUDE_AGENT_MAX_DEPTH` (alap: 3) |
| sebességkorlát | a széles elszabadulás: N fork / időablak | `CLAUDE_AGENT_MAX_BURST` (alap: 10), `CLAUDE_AGENT_BURST_WINDOW` (alap: 600 mp) |
| kapu | agent-kezdeményezte fork → Telegram-jóváhagyás | `--requested-by <agent>` megadásával kérhető |

A `--requested-by` ugyanaz a szerződés, mint a spawner `requested_by` mezője: ha
**az agent döntött** az indításról (nem a felhasználó kérte), akkor jóváhagyás
kell. Ilyenkor a fork nem indul el, hanem **híd-kérésként a sorba kerül**, és a
megszokott úton megy tovább: Telegram-gomb → indítás → jelentés.

⚠️ **A kapu önbevallásos**, mint a spawneré — egy elszabadult agent egyszerűen
nem adja meg a kapcsolót. Ezért a kapu **politika**, nem gát; a determinisztikus
védelem a másik három őr, amelyik nem kérdez rá, ki kérte.

Az őrök a kapu **előtt** futnak: egy önmásoló forkra a rendszer nem kér
jóváhagyást, hanem elutasítja.

A `resume` mező (csak forknál) azt szabja meg, mennyit örököl a gyerek a szülő
beszélgetéséből: `full` (alapértelmezés) a teljeset, `summary` egy tömörített
változatot. A `full` a rendszer lényege — de nagy szülőnél az első kör **percekig**
tarthat, mert a gyereknek előbb be kell töltenie az egészet. 2026-08-29-én két
fork emiatt nem produkált semmit, mielőtt lezárták őket: a feladat megérkezett,
csak nem jutott el odáig. Önmagában álló feladathoz kérj `summary`-t; `full`
esetén pedig adj neki időt.

A `permission_mode` **megadható** (`auto`, `acceptEdits`, `plan`, `dontAsk`,
`manual`, `bypassPermissions`); ha nem adod meg, `auto`.

⚠️ A `bypassPermissions` kivétel: az az egyetlen **emelt** mód, és csak akkor
érvényesül, ha erre a **konkrét** kérésre megnyomtad a Telegram-gombot. A két
felügyelet nélküli végrehajtási ágon — időkorlátos felhatalmazás alatt, illetve
`gate: "audit"` módban — a híd csendben `auto`-ra fokozza vissza, és ezt a
`bridge.log`-ba `PERM-DOWNGRADE` sorként beírja. A jóváhagyó üzenet külön
figyelmeztet, ha a kérés emelt jogosultságot kér.

### Mi történik utána

1. A relay validál. Hibás kérés → `requests/<id>.status` = `rejected`, indoklással.
2. Jó kérés → `pending`, és Telegramra megy egy **összefoglaló csatolmány**
   (mit fog csinálni), alatta **Indítás / Elutasítás** gomb.
3. Jóváhagyás után indul, `status` = `spawned`.
4. Ha 24 órán belül nem érkezik döntés → `expired`, a kérés archiválva.

A jóváhagyó üzeneten az **Indítás** mellett **⏱ +1 óra / +8 óra / +1 nap** is
választható. Ez **felhatalmazás**: amíg tart, az adott agentre érkező
`agent:`-es folytatások és a `reconnect` **jóváhagyás nélkül indulnak** — a
`pending` legfeljebb a végrehajtás idejére villan fel, nem az a jel, amire várni
kell. Új fork és `close` sosem esik bele.

Minden így induló kérésről Telegram-üzenet megy, rajta egy **Visszavonás**
gombbal; a felhatalmazás egyébként magától lejár.

⚠️ **A Desktop oldalán ebből egy dolog következik:** ne arra várj, hogy a
státusz **`pending`** legyen, hanem arra, hogy **végleges** legyen
(`spawned` / `rejected` / `failed` / `expired`). Felhatalmazás mellett a
`pending` csak átmenetileg, a végrehajtás idejére látszik — nem az a jel, amire
várni kell.

### Státusz visszaolvasása

A VM-ből **nincs hálózat**, tehát csak a lemezről tájékozódhatsz:
olvasd a `requests/<id>.status` fájlt.

```json
{ "status": "spawned", "message": "fork kész: <az új agent neve>", "updated_at": "..." }
```

Lehetséges értékek: `pending`, `spawned`, `rejected`, `failed`, `expired`.

### Eredmény visszaírása

Az eredményt továbbra is innen olvasod: **`results/<id>.md`**. Ezt a fájlt a
Mac írja oda — **nem az agent**.

Az agent a saját munkakönyvtárába ír, **kérésenként külön fájlba**
(`.bridge-result-<id>.md`), és a poller emeli át — egy körben az összeset.
A kérésenkénti név azért kell, mert a korábbi fix név egyférőhelyes postaláda
volt: ha az agent két kört futott, mielőtt a publikáló elvitte az elsőt, a
második **felülírta** — az első jelentés nyomtalanul elveszett.

⚠️ **Az eredmény hiánya NEM jelent elakadt munkát.** A jelentés lehet úton
(~30 mp), a frissen írt fájl pedig szándékosan vár egy kört, hogy ne vegyük el
írás közben. Ezen túl az agent egyszerűen még dolgozhat is. A hiányzó fájl
jelentése „még nincs", nem „baj van" — és semmiképp nem ok a feladat újraküldésére. Erre az utasítást a híd magától
hozzáfűzi a feladathoz; **neked nem kell kérned**, és ne is kérd, hogy az agent
közvetlenül a `results/`-be írjon.

⚠️ **Miért így:** a worktree-ben futó agent sandboxa **csak a saját
munkakönyvtárába** enged írni. A `bridge/results/`-be irányított átirányítás
`operation not permitted`-tel elbukik — de a shell **nem áll meg tőle**, így az
agent jóhiszeműen „kész"-t jelenthetne egy soha létre nem jött fájlra, a Desktop
pedig örökké várna. (Mérve 2026-08-11-én, a `dfetch-x` futásában.)

### Az eredmény lehet kérdés is

**A hídon indított agent nem kérdezhet vissza.** A sessionjét senki nem olvassa,
és az `AskUserQuestion` eszköz is le van tiltva neki. Ha olyan döntéshez ér,
amit nem hozhat meg egyedül, azt az utasítása szerint **az eredménybe írja**, és
befejezi a kört.

Ezért az eredmény nem mindig „kész" — lehet, hogy lehetőségeket sorol fel és
döntést kér. Ilyenkor olvasd el, dönts (vagy tedd fel a kérdést a felhasználónak
a saját beszélgetésedben — **egyedül ott van ember**), és a választ **folytatásként**
(`agent:`) küldd vissza, megnevezve a döntést. Ne indíts rá új forkot: a kérdező
agentnél már ott van a teljes kontextus.

Fordítva is igaz: ha a kérdés részletkérdés és van ésszerű alapértelmezés, az
agent utasítása az, hogy **döntse el maga** és a jelentésben mondja el, mit
választott — tehát ne várj kérdést minden apróságnál.

### Takarítás

A VM-ből **nem tudsz törölni** (`rm` tiltott). Ne is próbáld: a feldolgozott
kéréseket a Mac-oldali **poller** archiválja az `archive/` alá (a jóváhagyás,
elutasítás vagy lejárat után). ⚠️ Amelyik kérés felhatalmazás alapján vagy
`gate: "audit"` módban indult, az nem megy át a pollernek ezen az ágán: a `.json`
a `requests/` alatt marad. Ugyanígy marad ott a jóváhagyott, de **elbukott**
indítású kérés is — a poller csak sikeres végrehajtás után archivál. Ez szándékos — a `.status` akkor is a végleges
állapotot mutatja —, de takarításkor számíts rá.
