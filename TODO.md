# TODO — agent-spawner

**🇭🇺 [Magyar változat](#magyar-változat)**

The earlier big TODO batch (default vs custom, the cwd flow, the prompt picker, the move to chat questions, the cascading kill, kill-all-exit, and so on) is **all implemented** in v1. Only the open items are here.

## Git convention — DECIDED 2026-08-31

**Normal, stacked commits during development. Squash ONCE, at publication**, when no agent is running.

**Why we no longer amend.** Until then the repository was kept as a single, continuously `--amend`ed root commit. Amending a root commit creates a **new parentless commit**, so worktrees branched off the earlier base become **orphans**: `git: fatal: refusing to merge unrelated histories`. Step G5 of the 2026-08-31 regression round failed on exactly this — eight amends went onto `main` that day, and the agent branch that forked at 15:40 could no longer be merged after the 16:19 amend.

This is not test-specific: it **ruins every close with a merge code** if anyone amends in the meantime — and precisely those rounds that stop for a fix, because the fix itself orphans the running branches.

At publication: `git reset --soft <root>` plus one commit while **not a single agent is running**, then the `v1.0.0` tag on that.

## Open

- **Versioning: the article's publication is the freezing point.** The public repository is deliberately ONE commit today, so the `v1.0.0` tag moves along with every fix. This is acceptable only while the LinkedIn article is not out and nobody references the release. **As soon as the article appears**, the `v1.0.0` tag and the release belonging to it freeze: from then on every change is a new commit and **`v1.0.1`** (and onwards), without force-pushes and tag moves. (Fable AUDIT6, 2026-08-29.)

  **The agreed workflow after the freezing point** (2026-08-30):
  - fixes go onto a **feature branch**, and from there into `main` via a **pull request**
  - open the PR **early, as a draft if need be**: CI today runs only on `main` and on PRs (`branches: [main]`, `pull_request`), so a bare branch push **does not start a test run**
  - close the PR with a **squash merge**: `main` then gets one commit per topic, without a force-push — this is what gives back the clean history we have now
  - **short-lived branches**, one per topic; a long "fixes" branch drifts, and the merge gets harder the longer it lives
  - version number: a bug fix → a patch (`v1.0.1`), **a new capability** → a minor (`v1.1.0`). The `requested_by` gate, passing `permission_mode` through and the `resume` field, for instance, are minor rather than patch.
  - `main` is **append-only** from here on: the tidy look comes from the squash merge, not from rewriting history

- **done/ retention** — `~/.claude/agent-queue/done/` grows without limit (2026-07-27: 66 files / 264 KB — slow, but with no ceiling). A weekly cron deleting entries older than 7 days.
- **failed/ readability** — the `.json` and the `.reason` are separate files; they should be combed into one.
- **Token expiry detection** — the Mac claude.ai login expires → spawned sessions die; watch for it and warn.
- **Per-spec budget cap** — an optional `max_budget_usd` field in the spec JSON → a `--max-budget-usd` flag when starting `claude` (this flag has no effect outside `--print` mode today, but future versions may act on it).
- **Bridge health check** — the watchdog looks at whether the *process* is running, not at whether the Remote Control bridge is alive. With a dropped bridge the session does not show as connected on the phone, while as far as the watchdog is concerned everything is fine. (2026-07-27: starting and stopping a second `--remote-control mac-main` instance under the same name took the original's bridge with it.)

  **BLOCKED — there is no reliable local signal.** Measured through on 2026-07-27, with a live A/B (mac-main's bridge dead, two agents' bridges alive):

  | candidate signal | result |
  |---|---|
  | scraping `/rc active` from the status line | **unstable** — 3 measurements, 3 results (`/rc active` / `/rc` / nothing), even for the definitely-live agent; the pane only refreshes on a redraw |
  | `lsof -nP -p <pid> -i` | macOS does not allow access to other processes' sockets → 0 hits for all three processes, the live ones included |
  | `~/.claude/sessions/<pid>.json` | there **is** a `bridgeSessionId` even in the session with the dead bridge; `updatedAt` follows activity, not the bridge (an idle but live session: unchanged for 17 minutes) |
  | `bridge-session` records in the transcript | there is no heartbeat cadence; both the dead and the live one sit repeating, with an identical `lastSequenceNum` |

  **2026-08-08 — a second, independent sighting, followed through.** The `mac-main-dcred-store-20260808` fork disappeared from the mobile Code tab while the process and the tmux session were **alive**: the user could step back in with `tmux attach`, then closed it with `exit`. Proof that this was not a dead session: `remain-on-exit` is **`off`** (there is no tmux config either), so the pane would vanish when the command exited. So: **the process is alive, the bridge is dead, and from the outside this is only visible on the phone.**

  ⚠️ **It has two consequences, and the second is a bug in its own right:**
  1. The user believes the agent is gone — while it keeps running.
  2. If they close it by hand (`exit` or `tmux kill-session`), that **does not go through close-tree**: the worktree, the branch and the `bridge-spawned.json` entry are left untidied. That is how an empty worktree and branch were left behind after cred-store.

  Building a health check on these is **worse than the gap we have**: a false positive would kill a live session. Until there is a supported query (a CLI command or a state file showing the cloud-side connection), manual restarting is what remains.

  **✅ 2026-08-09 — the mitigation IS BUILT AND PROVEN.** `reconnect` brought the `mac-main-web-dsrv-tree-20260807` agent back to the mobile Code tab live. Measured: a new pid, an **unchanged session id** (the conversation survived). ⚠️ `bridgeSessionId` does NOT change — it belongs to the session, not to the connection — so it is unusable as a success criterion; the phone remains the only reliable signal.

  **Mitigation instead of detection — and this one can be built:** an `action: reconnect` into the bridge that restarts a named agent's session with `--resume`, thereby registering a new bridge. The user notices the trouble on the phone (the only reliable signal) and brings it back with one request — with full context, because it continues the same session. The machinery exists: the not-running branch of `continue_agent` does exactly this.

  **On point 2 specifically:** every round, the poller sees which registered agents are not running. If the worktree next to such an agent is empty (0 commits, 0 modifications), it can be cleaned up; if there is work in it, it has to be flagged, not deleted. The recurrence is already prevented by the guard in `start.sh` (no second instance under the same name) — from the cause, not the symptom.

## Done — previously on this list

- **Detecting a stalled agent** *(2026-08-24)* — prevention (an instruction plus disabling `AskUserQuestion`) is **LLM-dependent**: the agent can still stop with a question in prose. So every round the poller checks whether there is a **bridge-started** agent that has been **idle** for N minutes (`stall_minutes`, default 15) and **still has no report** for its request — neither published nor in its working directory. When there is, a Telegram message goes out with a **🔔 Remind** button, which sends the "you cannot ask back, write it into the report" reminder into the session.

  It speaks **once** per request (a `.stalled` map in the state file), otherwise it would repeat every 30 seconds. A new request for the same agent can flag it again.

  **The first live run found one immediately:** `mac-main-ddata-sync-202608` had been idle **since 2026-08-14 16:03**, and there was no result file for the `data-sync-20260814` request — it had been standing for ten days, and nothing had said a word about it.

  Two small things that surfaced along the way: "idle for 14016 minutes" is unreadable (hence `bridge_dur_human`), and the `nu:` branch has to go **before** the `pending` guard just like `rv:` — the button carries the id of an already `spawned` request.

- **A bridge agent cannot ask back** *(2026-08-22)* — an agent started over the bridge asked a yes/no question in its own session ("Which one would you like?") and **stopped there, waiting for an answer**. But the task had not come from a human; it came from the Desktop over the bridge: nobody reads that session, so **by construction** the answer could never have arrived. The work sat half-finished on disk while both sides waited for the other.

  **A two-layer solution, because the instruction alone is not enough** — the failure was a question asked in prose, not a tool call:
  1. **The instruction** (`augment_task`): at the end of every bridge task we state that there is nobody to ask; if a decision is needed it has to be written into the report (the question plus the options plus a recommendation), and the round has to be finished — the sender answers with a **new continuation request**, so the decision passes through the approval gate as well. This **also affects continuations**, where the spawn flags are no longer reachable.
  2. **A machine lock** (`fork-agent --no-ask` → `--disallowed-tools AskUserQuestion`): we take the asking tool away too. **Only the bridge passes** the flag; on a manual `/fork` asking is legitimate, so it is not the default.

  The instruction also spells out the **converse mistake**: on a detail question where there is a sensible default, it should decide for itself and say so in the report — otherwise it would bounce back every trifle.

  The other half of the round is in the docs: the Desktop has to know that **the result may be a question**, and that it has to be answered as a continuation (not with a new fork, because the agent that asked already has the context).

- **Time-boxed standing approval** *(2026-08-15)* — every continuation asked for its own button press, even though that is the lowest-risk operation (a message to an **already approved, already running** agent). The approval message now also offers **⏱ +1 hour / +8 hours / +1 day**; while it lasts, `continue` and `reconnect` requests for that agent start without a button press.

  **Scope — deliberately narrow.** The grant is tied to **one specific agent**, not global. **A new fork and `close` never fall under it**: a fork starts new work, and `close` cascades, deleting a branch and a worktree, irreversibly — which is why the time-window buttons do not even appear on a `close` request.

  Every request started this way sends a Telegram message with a **Revoke** button. The expiry is stored in epoch and checked **at use** — `bridge_grant_prune` runs only so the state file does not put on weight, not for correctness.

  ⚠️ **Two traps that had to be worked around during the implementation:**
  1. **`callback_data` is 64 bytes.** The revoke button therefore carries the *request's* id (≤48 → 51 bytes), not the agent name (the validator allows up to 64 → `rv:` + 64 = **67**, which would blow up). Measured live: 51 bytes per button, and Telegram accepted all 5.
  2. **The `rv:` branch went BEFORE the `pending` guard.** The revoke button carries the id of an already `spawned` request, so the "stale button press" branch would have swallowed it silently.

  At an automatic start `set_status` happens **before the execution**: the relay is WatchPaths-triggered and does not have the poller's single-instance lock — without this a second trigger seeing the `new` status would start the same thing again.

- **The buttons come off an expired/closed request** *(2026-08-13)* — the approval message's buttons stayed clickable after the decision. On 2026-08-13 three `Reject` presses arrived for a request that had **expired 36 hours earlier**; the poller refused them correctly (`No longer pending: expired`), but only with a popup bubble that is easy to miss — which is why the user pressed again.

  From now on every final transition (**started / rejected / failed / expired**) **rewrites the message in place** and takes the buttons off it by omitting `reply_markup`. The button-press branches use the callback's own `.message.message_id`, so **messages from before the change** can be tidied up too; for the expiry — where there is no button press — the relay stores the `message_id` when sending, into the `.messages` map of `bridge-state.json`. A stale button press now also shows up in the chat (`STALE-PRESS` in the log), not only in a bubble. If the rewrite fails (a deleted message), a separate message goes out — the fact of the rejection cannot be left unsaid.

- **One source for the restore parameters** *(2026-08-11)* — the model lived in **two places**: in the `done/<uuid>.json` spec and in the `live/<name>.json` registry. The watchdog read from **`live/`**, so when the spec switched to `claude-opus-5`, the restart **quietly came back with the old `claude-opus-4-8[1m]`** — the bug only surfaced from `ps`'s argv.

  The new division of roles: **`live/` says WHICH agent has to be kept alive** (plus the `restore_attempts` runtime state), and **the parameters come from the spec**. The `live/` value stays a fallback, so that a cleaned-up spec (the planned `done/` retention) does not render an agent unrestartable. Two new lib functions: `spec_or_live_field()` and `spec_live_divergences()` — the latter **logs the divergence** every round (`DIVERG <name> <field> live=… spec=… — the spec wins`), because the essence of the original bug was the silence, not the drift itself.

- **Poller: a timeout plus single-instance running** *(2026-08-11)* — `tg_call`'s curl timeout was **25 s** while the poller's `StartInterval` was **30 s**: after a stuck query 5 s were left until the next start. Measured: 5 × `curl: (28) Operation timed out after 25s` in `bridge.stderr.log` (in the early hours of 08-09 and 08-10) — these produced the `WARN getUpdates failed` lines. New: `BRIDGE_HTTP_MAX_TIME=20` + `BRIDGE_HTTP_CONNECT_TIMEOUT=10`.

  ⚠️ **There was a graver, latent bug behind the timeout as well.** `execute_request` (a close, a fork, a resume) can take longer than the 30-second interval. Two overlapping pollers **would get the same `callback_query`** — `updates_offset` is only persisted at the *end* of a run — and the `[[ "$st" != "pending" ]]` guard would let both through too, because the `spawned` status is also only written **after** `execute_request`. A classic TOCTOU: **a close could run twice**. The fix: an atomic `mkdir` lock (there is no `flock(1)` on macOS) with orphaned-lock detection (`kill -0` on the recorded pid).

  The **relay deliberately gets no lock**: it is WatchPaths-triggered, and exiting because of a lock would *drop* a trigger, and that request would never start. The poller runs again in 30 s anyway — there a skipped round is free.

- **Watchdog + spawner log rotation** *(2026-07-27)* — `rotate_log()` in `bin/_agent-lib.sh`: above the limit `log` → `log.1` → `.2` → `.3`, with the oldest discarded; called once per run. Env: `CLAUDE_AGENT_LOG_MAX` (default 1 MiB), `CLAUDE_AGENT_LOG_KEEP` (default 3). By then `watchdog.log` was 794 KB / 18,881 lines, and kept growing every 5 minutes. It became an internal rotation rather than `newsyslog.d`, because that would write under `/etc` and need sudo.
- **Watcher → main callback** — after every successful spawn the spawner writes `done/<uuid>.result`: `started_at`, `tmux_session`, `remote_session_name`, `cwd`, `model`, `effort`, `permission_mode`. (This file fills the role instead of the planned `callback.json`.)

---

## Magyar változat

A korábbi nagy TODO-batch (default vs egyéni, cwd flow, prompt picker, chat-question átállás, kaszkád kill, kill-all-exit, etc.) **mind megvalósítva** a v1-be. Itt csak a függő dolgok.

### Git-konvenció — DÖNTVE 2026-08-31

**Fejlesztés közben normál, egymásra épülő commitok. Squash EGYSZER, a
publikáláskor**, amikor nem fut agent.

**Miért nem amendelünk többé.** A repót addig egyetlen, folyamatosan
`--amend`-elt gyökér-commitként tartottuk. Egy gyökér-commit amendje **szülő
nélküli új commitot** hoz létre, ezért a korábbi alapról leágazott worktree-k
**árvává** válnak: `git: fatal: refusing to merge unrelated histories`. A
2026-08-31-i regressziós kör G5 lépése pontosan ezen bukott el — aznap nyolc
amend ment a `main`-re, és a 15:40-kor leágazott agent-ág a 16:19-es amend után
már nem volt beolvasztható.

Ez nem teszt-specifikus: **minden merge kódú lezárást elront**, ha közben bárki
amendel — és pont azokat a köröket, amelyek megállnak egy javításért, mert maga
a javítás orphanolja a futó ágakat.

Publikáláskor: `git reset --soft <gyökér>` + egy commit, amíg **egyetlen agent
sem fut**, majd a `v1.0.0` tag arra.

### Nyitott

- **Verziózás: a cikk megjelenése a fagyáspont.** A publikus repó ma szándékosan
  EGY commit, és a `v1.0.0` tag ezért minden javításkor odébb mozdul. Ez csak
  addig fér bele, amíg a LinkedIn-cikk nincs kint és a release-t senki nem
  hivatkozza. **Amint a cikk megjelenik**, a `v1.0.0` tag és a hozzá tartozó
  release befagy: onnantól minden változás új commit és **`v1.0.1`** (majd
  tovább), force-push és tag-mozgatás nélkül. (Fable AUDIT6, 2026-08-29.)

  **A megbeszélt munkamenet a fagyáspont után** (2026-08-30):
  - a javítások **feature branchre** mennek, onnan **pull requesttel** a `main`-be
  - a PR-t **korán nyisd meg, akár draftként**: a CI ma csak `main`-re és PR-re
    fut (`branches: [main]`, `pull_request`), tehát egy csupasz branch-push
    **nem indít tesztet**
  - a PR-t **squash-merge**-dzsel zárd: a `main`-en így egy commit lesz témánként,
    force-push nélkül — ez adja vissza a mostani tiszta history-t
  - **rövid életű branchek**, témánként egy; egy hosszú „javítások" ág elsodródik
    és a merge annál nehezebb
  - verziószám: hibajavítás → patch (`v1.0.1`), **új képesség** → minor
    (`v1.1.0`). A `requested_by` kapu, a `permission_mode` átengedése és a
    `resume` mező például minor, nem patch.
  - a `main` innentől **append-only**: a látvány a squash-merge-ből jön, nem a
    history átírásából

- **Done/ retention** — `~/.claude/agent-queue/done/` korlátlanul nő (2026-07-27: 66 fájl / 264 KB — lassú, de nincs plafon). Heti cron amiben 7 napnál régebbi entry-k törlése.
- **failed/ olvashatóság** — a `.json` és a `.reason` külön fájl; egybe kéne fésülni.
- **Token expiry detect** — a Mac claude.ai login lejár → a spawnolt session-ök meghalnak; figyelni és figyelmeztetni.
- **Per-spec budget cap** — opcionális `max_budget_usd` mező a spec JSON-ban → `--max-budget-usd` flag a `claude` indításnál (most ez a flag nem-`--print` módban nem hat, de jövőbeli verziókban hathat).
- **Bridge-health check** — a watchdog azt nézi, fut-e a *folyamat*, nem azt, hogy él-e a Remote Control bridge. Leszakadt bridge-dzsel a session a telefonon nem látszik connected-ként, a watchdog szerint viszont minden rendben. (2026-07-27: egy második, azonos nevű `--remote-control mac-main` példány indítása és leállítása elvitte az eredeti bridge-ét.)

  **BLOKKOLT — nincs megbízható lokális jel.** 2026-07-27-én végigmérve, élő A/B-vel (mac-main bridge halott, két agent bridge él):

  | jelölt jel | eredmény |
  |---|---|
  | státuszsor `/rc active` kaparása | **instabil** — 3 mérés, 3 eredmény (`/rc active` / `/rc` / semmi), a biztosan élő agentre is; a pane csak újrarajzoláskor frissül |
  | `lsof -nP -p <pid> -i` | macOS nem enged más process socketjeibe → 0 találat mindhárom folyamatra, az élőkre is |
  | `~/.claude/sessions/<pid>.json` | **van** `bridgeSessionId` a halott bridge-ű sessionben is; az `updatedAt` aktivitást követ, nem bridge-et (idle+élő session: 17 percig nem mozdult) |
  | transcript `bridge-session` rekordok | nincs heartbeat-kadencia; a halott és az élő is ismétlődő, azonos `lastSequenceNum`-mal áll |

  **2026-08-08 — második, független észlelés, végigkövetve.** A
  `mac-main-dcred-store-20260808` fork eltűnt a mobil Code tabról, miközben a
  folyamat és a tmux session **élt**: a felhasználó `tmux attach`-csal vissza
  tudott lépni, majd `exit`-tel zárta le. Bizonyíték, hogy nem halott sessionről
  volt szó: a `remain-on-exit` **`off`** (nincs tmux config sem), tehát a pane a
  parancs kilépésekor eltűnne. Tehát: **process él, bridge halott, és ez kívülről
  csak a telefonon látszik.**

  ⚠️ **Két következménye van, és a második önálló hiba:**
  1. A felhasználó azt hiszi, az agent megszűnt — pedig fut tovább.
  2. Ha kézzel (`exit` vagy `tmux kill-session`) zárja le, az **nem megy át a
     close-tree-n**: a worktree, az ág és a `bridge-spawned.json` bejegyzés
     takarítatlanul marad. Így maradt a cred-store után üres worktree és ág.

  Ezekre health-checket építeni **rosszabb a mostani résnél**: egy téves pozitív élő sessiont ölne. Amíg nincs támogatott lekérdezés (CLI-parancs vagy állapotfájl, ami a felhő-oldali kapcsolatot mutatja), marad a kézi újraindítás.

  **✅ 2026-08-09 — az enyhítés MEGÉPÜLT ÉS IGAZOLVA.** A `reconnect` élesben
  visszahozta a `mac-main-web-dsrv-tree-20260807` agentet a mobil
  Code tabra. Mérés: új pid, **változatlan session id** (a beszélgetés megmaradt).
  ⚠️ A `bridgeSessionId` NEM változik — az a sessionhöz kötődik, nem a
  kapcsolathoz —, tehát sikerkritériumnak alkalmatlan; a telefon marad az
  egyetlen megbízható jel.

  **Észlelés helyett enyhítés — ez viszont építhető:** `action: reconnect` a
  hídba, ami egy megnevezett agent sessionjét `--resume`-mal újraindítja, és
  ezzel új bridge-et regisztrál. A felhasználó a telefonon veszi észre a bajt
  (ez az egyetlen megbízható jel), és egy kéréssel visszahozza — teljes
  kontextussal, mert ugyanazt a sessiont folytatja. A gépezet megvan: a
  `continue_agent` nem-futó ága pontosan ezt csinálja.

  **A 2. pontra külön:** a poller minden körben látja, mely nyilvántartott agent
  nem fut. Ha egy ilyen mellett üres a worktree (0 commit, 0 módosítás), az
  eltakarítható; ha van benne munka, jelezni kell, nem törölni. A
  megismétlődést a `start.sh` guardja (azonos néven nincs második példány) már megakadályozza — az ok, nem a tünet felől.

### Kész — korábban ezen a listán volt

- **Beragadt agent észlelése** *(2026-08-24)* — a megelőzés (utasítás + `AskUserQuestion` tiltás) **LLM-függő**: az agent prózában akkor is megállhat kérdéssel. Ezért a poller minden körben megnézi, van-e olyan **híd által indított** agent, amelyik **tétlen** N perce (`stall_minutes`, alap 15) és a hozzá tartozó kérésre **még nincs jelentése** — sem publikálva, sem a munkakönyvtárában. Ilyenkor Telegram-üzenet megy, rajta **🔔 Emlékeztetem** gombbal, ami a session-be beküldi a „nem tudsz visszakérdezni, írd a jelentésbe" emlékeztetőt.

  Kérésenként **egyszer** szól (`.stalled` térkép az állapotfájlban), különben 30 másodpercenként ismételne. Új kérés ugyanarra az agentre újra jelezhet.

  **Az első éles futás azonnal talált egyet:** a `mac-main-ddata-sync-202608` **2026-08-14 16:03 óta** tétlen, a `data-sync-20260814` kéréshez pedig nincs eredményfájl — tíz napja állt, és erről addig semmi nem szólt.

  Két apróság, ami menet közben derült ki: a „14016 perce tétlen" olvashatatlan (innen a `bridge_dur_human`), és a `nu:` ág ugyanúgy a `pending`-őr **elé** kell, mint az `rv:` — a gomb egy már `spawned` kérés id-jét viszi.

- **A híd-agent nem kérdezhet vissza** *(2026-08-22)* — egy hídon indított agent a saját sessionjében tett fel eldöntendő kérdést („Melyiket szeretnéd?") és **ott állt meg, válaszra várva**. A feladatot viszont nem ember adta, hanem a Desktop a hídon át: azt a sessiont senki nem olvassa, tehát a válasz **konstrukció szerint** soha nem érkezhetett volna meg. A munka félkészen ült a lemezen, miközben mindkét fél a másikra várt.

  **Két rétegű megoldás, mert az utasítás önmagában nem elég** — a hiba prózában feltett kérdés volt, nem eszközhívás:
  1. **Utasítás** (`augment_task`): minden híd-feladat végén kimondjuk, hogy nincs kihez visszakérdezni; ha döntés kell, azt a jelentésbe kell írni (kérdés + lehetőségek + javaslat), és be kell fejezni a kört — a küldő egy **új folytatás-kéréssel** válaszol, így a döntés is átmegy a jóváhagyási kapun. Ez a **folytatásokra is hat**, ahol a spawn-kapcsolókhoz már nem nyúlhatunk.
  2. **Gépi zár** (`fork-agent --no-ask` → `--disallowed-tools AskUserQuestion`): a kérdező eszközt el is vesszük. A kapcsolót **csak a híd adja át**; kézi `/fork`-nál a kérdezés jogos, ezért nem alapértelmezés.

  Az utasítás külön kimondja a **fordított hibát** is: részletkérdésnél, ahol van ésszerű alapértelmezés, döntsön maga és a jelentésben mondja el — különben minden apróságot visszapattintana.

  A kör másik fele a doksiban: a Desktopnak tudnia kell, hogy **az eredmény lehet kérdés is**, és azt folytatásként kell megválaszolnia (nem új forkkal, mert a kérdezőnél már ott a kontextus).

- **Időkorlátos állandó jóváhagyás** *(2026-08-15)* — minden folytatás külön gombnyomást kért, pedig az a legkisebb kockázatú művelet (üzenet egy **már engedélyezett, már futó** agentnek). A jóváhagyó üzeneten mostantól **⏱ +1 óra / +8 óra / +1 nap** is választható; amíg tart, az adott agentre érkező `continue` és `reconnect` kérések gombnyomás nélkül indulnak.

  **Hatókör — szándékosan szűk.** A felhatalmazás **egy konkrét agenthez** kötődik, nem globális. **Új fork és `close` sosem esik bele**: a fork új munkát kezd, a `close` pedig kaszkádol, ágat és worktree-t töröl, visszafordíthatatlan — ezért az időablakos gombok a `close`-kérésen meg sem jelennek.

  Minden így induló kérésről Telegram-üzenet megy, rajta **Visszavonás** gombbal. A lejárat epoch-ban tárolva, **használatkor** ellenőrizve — a `bridge_grant_prune` csak azért fut, hogy az állapotfájl ne hízzon, nem a helyességhez kell.

  ⚠️ **Két csapda, amit a megvalósítás közben kellett megkerülni:**
  1. **A `callback_data` 64 bájt.** A visszavonó gomb ezért a *kérés* id-jét viszi (≤48 → 51 bájt), nem az agentnevet (a validator 64-ig enged → `rv:` + 64 = **67**, ami elszállna). Élesben mérve: 51 bájt/gomb, a Telegram mind az 5-öt elfogadta.
  2. **A `rv:` ág a `pending`-őr ELÉ került.** A visszavonó gomb egy már `spawned` kérés id-jét viszi, tehát az „elavult gombnyomás" ág némán elnyelte volna.

  A `set_status` az auto-indításnál **a végrehajtás előtt** történik: a relay WatchPaths-triggerelt, és nincs rajta a poller egypéldányos lockja — enélkül egy második trigger a `new` státuszt látva újra elindítaná ugyanazt.

- **Lejárt/lezárt kérés gombjai lekerülnek** *(2026-08-13)* — a jóváhagyó üzenet gombjai a döntés után is kattinthatóak maradtak. 2026-08-13: egy **36 órája lejárt** kérésre három `Elutasítás`-nyomás érkezett; a poller helyesen visszautasította (`Már nem függőben: expired`), de csak egy felugró buborékkal, ami könnyen elsiklik — ezért nyomta a felhasználó újra.

  Mostantól minden végleges átmenet (**elindítva / elutasítva / sikertelen / lejárt**) **helyben átírja** a gombos üzenetet, és a `reply_markup` elhagyásával leveszi róla a gombokat. A gombnyomásos ágak a callback saját `.message.message_id`-jét használják, így a **változás előtti üzenetek is** rendbe tehetők; a lejárathoz — ahol nincs gombnyomás — a relay küldéskor eltárolja a `message_id`-t a `bridge-state.json` `.messages` térképébe. Egy elavult gombnyomás ezentúl a chatben is megjelenik (`STALE-PRESS` a naplóban), nem csak buborékban. Ha az átírás nem sikerül (törölt üzenet), külön üzenet megy — az elutasítás ténye nem maradhat el.

- **Egy forrás a visszaállítási paramétereknek** *(2026-08-11)* — a modell **két helyen** élt: a `done/<uuid>.json` specben és a `live/<név>.json` nyilvántartásban. A watchdog a **`live/`-ból** olvasott, ezért amikor a spec `claude-opus-5`-re váltott, az újraindítás **csendben a régi `claude-opus-4-8[1m]`-mel jött vissza** — a hiba csak az `ps` argv-jéből derült ki.

  Új szereposztás: a **`live/` azt mondja meg, MELYIK agentet kell életben tartani** (+ a `restore_attempts` futásidejű állapotot), a **paraméterek a specből** jönnek. A `live/` érték fallback marad, hogy egy kitakarított spec (tervezett `done/` retention) ne tegye újraindításra képtelenné az agentet. Két új lib-függvény: `spec_or_live_field()` és `spec_live_divergences()` — az utóbbi minden körben **naplózza az eltérést** (`DIVERG <név> <mező> live=… spec=… — a spec nyer`), mert az eredeti hiba lényege a némaság volt, nem maga az elcsúszás.

- **Poller: időkorlát + egypéldányos futás** *(2026-08-11)* — a `tg_call` curl-időkorlátja **25 mp** volt, a poller `StartInterval`-ja **30 mp**: egy beragadt lekérdezés után 5 mp maradt a következő indításig. Mérve: 5 db `curl: (28) Operation timed out after 25s` a `bridge.stderr.log`-ban (08-09, 08-10 hajnalán) — ezek adták a `WARN getUpdates sikertelen` sorokat. Új: `BRIDGE_HTTP_MAX_TIME=20` + `BRIDGE_HTTP_CONNECT_TIMEOUT=10`.

  ⚠️ **A timeout mögött egy súlyosabb, latens hiba is volt.** Az `execute_request` (lezárás, fork, resume) a 30 mp-es intervallumnál tovább is tarthat. Két átfedő poller **ugyanazt a `callback_query`-t kapná meg** — az `updates_offset` csak a futás *végén* perzisztálódik —, és a `[[ "$st" != "pending" ]]` guard is átengedné mindkettőt, mert a `spawned` státusz szintén csak az `execute_request` **után** íródik. Klasszikus TOCTOU: **egy lezárás kétszer futhatna le**. Fix: atomi `mkdir`-lock (macOS-en nincs `flock(1)`) elárvult-lock felismeréssel (`kill -0` a rögzített pid-re).

  A **relay szándékosan nem kap lockot**: az WatchPaths-triggerelt, a lock miatti kilépés egy triggert *eldobna*, és az a kérés soha nem indulna el. A poller 30 mp múlva úgyis újra fut — ott a kihagyás ingyen van.

- **Watchdog + spawner logrotálás** *(2026-07-27)* — `rotate_log()` a `bin/_agent-lib.sh`-ban: a limit felett `log` → `log.1` → `.2` → `.3`, a legrégebbi eldobva; futásonként egyszer hívva. Env: `CLAUDE_AGENT_LOG_MAX` (default 1 MiB), `CLAUDE_AGENT_LOG_KEEP` (default 3). A `watchdog.log` addigra 794 KB / 18 881 sor volt, és 5 percenként nőtt tovább. Belső rotáció lett, nem `newsyslog.d`, mert az `/etc` alá írna és sudo kellene hozzá.
- **Watcher → main callback** — a spawner minden sikeres spawn után ír `done/<uuid>.result`-ot: `started_at`, `tmux_session`, `remote_session_name`, `cwd`, `model`, `effort`, `permission_mode`. (A tervezett `callback.json` helyett ez a fájl tölti be a szerepet.)
