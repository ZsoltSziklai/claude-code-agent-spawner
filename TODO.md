# TODO — agent-spawner

A korábbi nagy TODO-batch (default vs egyéni, cwd flow, prompt picker, chat-question átállás, kaszkád kill, kill-all-exit, etc.) **mind megvalósítva** a v1-be. Itt csak a függő dolgok.

## Git-konvenció — DÖNTVE 2026-08-31

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

## Nyitott

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

## Kész — korábban ezen a listán volt

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
