# Fejlesztési prompt — claude-code-agent-spawner

Ez a dokumentum egy önálló, copy-paste-elhető prompt Claude Code (vagy bármilyen másik LLM-alapú coding agent) számára. Aki ezt elolvassa, képes legyen a rendszer **magját** — a queue-t, a spawnert, a watchdogokat és a slash-parancsokat — a nulláról újraimplementálni a saját platformján.

**Hatókör:** a Desktop-híd (relay, poller, felhatalmazások, beragadás-észlelés — nagyjából 1200 sor) és a `fork-agent` belseje **nincs** benne. Azokhoz a `bridge-README.md` és a `desktop-skill/agent-bridge/SKILL.md` a kiindulás.

> ⚠️ **Ha ez a dokumentum és a kód ellentmond, a KÓD az igazság.** Ez a leírás
> újraimplementálási recept, nem specifikáció — a `bin/` és a `claude-agent-spawner`
> mindig frissebb. Több pontján (cwd-kezelés, permission-módok, modell-lista) a
> repó tudatosan szigorúbb annál, ami itt szerepelt korábban; a lentiek már a
> javított viselkedést írják le.

---

## 0. TL;DR a feladatról

Építs egy **queue-alapú háttér-agent orchestrator**-t [Claude Code](https://claude.com/claude-code)-hoz. Lehetővé teszi, hogy a felhasználó több párhuzamos Claude Code session-t indítson a háttérben — terminálból, futó agent-ből, vagy a Claude mobil app-ból (Code tab). Egy állandóan futó "command-center" session-re csatlakozhat a mobilról, és onnan slash command-okkal indít új háttér agenteket.

Két háttérszolgáltatás fut a rendszeren:

1. **Queue spawner** — egy mappa-figyelő file watcher. Amikor JSON spec fájl kerül a queue `new/` almappájába, elindít belőle egy önálló `claude` CLI session-t saját terminál-multiplexer ablakban (tmux / screen / ConPTY), opcionálisan saját git worktree-ben.
2. **Watchdog** — periodikusan ellenőrzi, hogy a command-center session él-e. Ha leállt, újraindítja.

A `claude --remote-control <name>` flag-gel indított session-ök megjelennek a mobil Claude app Code tabján — onnan vezérelhetők. Ehhez full claude.ai login kell (a long-lived `CLAUDE_CODE_OAUTH_TOKEN` env var ezt **letiltja**, ezért a spawner unset-eli).

---

## 1. Magas szintű architektúra

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

## 2. Komponensek

### 2.1. Queue spawner (`claude-agent-spawner`)

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

### 2.2. Watchdog

Periodikus task (pl. 5 percenként):

1. Megnézi: él-e a command-center terminál-multiplexer session. ⚠️ Ennek a neve **nem** `agent-` prefixes: a referencia-implementációban a parancsközpont `mac-main`, a gyerekek `agent-<név>`. A `tmux ls | grep ^agent-` így pontosan a gyerekeket adja, a parancsközpontot nem — több szkript épít erre.
2. Ha nem él → indítsd újra (`start.sh` ekvivalens).

Tartalmazhat további egészségellenőrzéseket is (pl. queue spawner alive, queue size sane, stb.).

### 2.3. Command-center session (`start.sh`)

Egy script ami indítja a "fő" `claude --remote-control` session-t a háttérben. Ennek a session-nek **rögzített név**-e van (pl. `mac-main`, `linux-main`, vagy felhasználói config alapján). A mobil app erre kapcsolódik.

A session indító prompt-ja a slash command help banner-t adja vissza a felhasználó első üzenetére — így mobilon azonnal látszik a parancs-paletta.

### 2.4. Slash command-ok

A Claude Code slash command-ok markdown fájlok `~/.claude/commands/` alatt. A spawner bundle **ötöt** szállít:

- **`/new-agent`** — chat-question alapú wizard ami szekvenciálisan végigkérdezi a mezőket szabad-szöveges válaszokkal (név, cwd, prompt, model, effort, permission, worktree), majd a végén kiír egy JSON spec-et a queue `new/` mappájába. Az `opus` választása után feltételes al-kérdés jön a verzióra (Opus 5 / 4.8 / 4.7) és context-re (default / `[1m]`) — ez a szekvenciális chat-flow miatt lehetséges, batched pickerrel nem lenne. A Step 0 "Default vs Egyéni" az egyetlen hely ahol `AskUserQuestion` picker fut.
- **`/close-agent`** — futó agent rendezett lezárása. Worktree mode-nál külön megkérdezi: merge vagy drop.
- **`/kill-agent`** — listából kiválasztott agent(ek) azonnali killje (tmux kill-session, worktree drop ha volt).
- **`/kill-all-exit`** — minden agent kill + a jelenlegi session is kilép.
- **`/fork`** — az AKTUÁLIS session elágaztatása egy gyerek-agentbe, ami örökli a beszélgetést.

A markdown fájlok formátuma: YAML frontmatter (`description:`) + szabad szöveg instrukcióval Claude-nak. Lásd a meglévő `new-agent.md` / `close-agent.md` fájlokat példának.

---

## 3. Platform-specifikus implementáció

### 3.1. macOS

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

### 3.2. Linux

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

### 3.3. Windows

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

### 3.4. Platform-abstrakció a kódban

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

## 4. JSON spec formátum

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

### Mezők és validáció

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

### Queue állapotok (file system mint state machine)

```
~/.claude/agent-queue/
├── new/          ← drop ide → spawner felkapja
├── processing/   ← spawner éppen dolgozik rajta (race-safe atomic mv)
├── done/         ← sikeresen elindítva; <uuid>.json + <uuid>.result
└── failed/       ← hibás spec; <uuid>.json + <uuid>.reason
```

A `processing/` lépés race-condition védelem több párhuzamos watcher esetén — `mv` filerendszeri szinten atomic.

---

## 5. Slash command részletek

A `/new-agent` slash command implementáció kulcsa a lépésenkénti kérdezés. A referencia-implementáció a **mezőket chat-kérdésekkel** kérdezi (picker csak a legelső, „Default vagy Egyéni" választásnál fut), és az utolsó paraméter után azonnal, megerősítés nélkül írja a specet a queue-ba. Egyetlen kivétel, ahol vissza KELL kérdezni: ha a megadott cwd nem létezik.

### 5.1. Kérdezés

Két mód, és a választás az egyetlen hely, ahol picker (`AskUserQuestion`) fut:
- **Default** — minden mezőre alapértelmezett érték, azonnali queue.
- **Egyéni** — 7 lépés (név, cwd, prompt, model, effort, permission, worktree), **chat-kérdésekkel**, szabad-szöveges válaszokkal.

Miért chat-kérdés és nem picker: a szekvenciális folyam megengedi a **feltételes al-kérdést** — az `opus` választása után jön a verzió (Opus 5 / 4.8 / 4.7), majd a context (`default` / `[1m]`). Egy batchelt pickerrel ez nem lenne lehetséges, mert a következő kérdést az előző válasza határozza meg.

Az enum mezőknél a felismerhetetlen választ **chat-ben kérdezd vissza**, ne találgass — a spawner fehérlistája úgyis elutasítaná, csak épp a `failed/` mappában, ahol a felhasználó nem nézi.

### 5.2. Worktree edge case

A `claude --worktree` flag-nél **explicit `=<name>` szintaxist** kell használni:

```bash
# JÓ:
claude --remote-control foo --worktree=foo <prompt>
# ROSSZ — a prompt lesz a worktree neve, mert positional!
claude --remote-control foo --worktree foo <prompt>
```

### 5.3. CWD allowlist

Csak `~/ClaudeProjects` alatti útvonal engedélyezett. A felhasználó **relatív** útvonalat ad meg (a `ClaudeProjects` gyökérhez képest); abszolút vagy `~/` kezdetű input → reject + re-prompt.

A spawner is védi magát: ha mégis abszolút path jönne a JSON-ban, ami `~/ClaudeProjects`-en kívül van → `failed/`.

---

## 6. Watchdog részletei

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

## 7. Kritikus gotchas

1. **`CLAUDE_CODE_OAUTH_TOKEN` unset kötelező** a spawner script elején. A long-lived token inference-only auth, a Remote Control feature-t **csendben letiltja**. A spawnolt agent még fut, de nem jelenik meg a mobil Code tabján. Ezt **nehéz debug-olni**, ha nem tudod.

2. **Full claude.ai login a host gépen.** A `claude /login` browser flow-ját végig kell csinálni. A spawnolt session-ök ennek a login-nak az auth-jával futnak. Ha a login lejár (~30 nap), az új spawnok némán halnak meg. Erre érdemes monitoringot tenni (lásd ROADMAP "Token expiry detect").

3. **Az `--worktree` positional arg parser quirk-je** — explicit `=` kell, lásd 5.2.

4. **Tmux session név uniqueness** — `agent-<name>` ütközésnél a referencia-implementáció **auto-suffixet** ad (`-2` … `-99`), lásd 2.1/5. ⚠️ Aminek viszont ára van: a kill-kaszkád prefix-szel matchel (`^NAME$|^NAME-`), tehát a `foo` kilövése a `foo-2`-t is elviszi. Ha ezt nem akarod, a duplikált nevet utasítsd el — de akkor mondd is meg a felhasználónak, ne csak a `failed/`-be ejtsd.

5. **Atomic mv** csak ugyanazon a filesystem-en garantált. A queue mind a 4 mappáját ugyanazon a partíción tartsd.

6. **A spawner script ne futtasson nehéz munkát** a watcher esemény-callback-jében — csak iteráljon a `new/`-en és spawnoljon. Ha lassú a spawn, a launchd / systemd nem fog tudni új eseményre reagálni időben (vagy fog, de queue-zódnak — nem optimális).

---

## 8. Implementációs sorrend (ajánlott)

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

## 9. Tesztelés

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

## 10. Done definition

A projekt akkor kész, ha:

- [ ] Friss gépen `install.sh` (vagy `.ps1`) lefutása után, egyetlen `/new-agent Default` futtatás működő háttér agentet eredményez ami megjelenik a mobil app-ban.
- [ ] Az 5 slash command mind elérhető és hibatűrően működik (próbálj törölt agenttel `/close-agent`-et, üres queue-val `/kill-all-exit`-et, stb.).
- [ ] A watchdog újraindítja a command-center session-t ha kill-eled.
- [ ] Hibás JSON spec a `failed/` mappába kerül érthető `.reason` fájllal.
- [ ] Race condition-test: két párhuzamos spawner futás ugyanarra a spec-re — pontosan egy spawn történik.
- [ ] A user `CLAUDE_AGENT_NAME` env változó alapján prefixelt nevű spec-eket küld, a parent-child naming végigkövethető.
- [ ] Dokumentáció: README + telepítés + `claude /login` setup magyarázva.

---

## 11. Referenciák

- A meglévő macOS implementáció: ez a repó (https://github.com/ZsoltSziklai/claude-code-agent-spawner)
- Claude Code dokumentáció: https://docs.claude.com/en/docs/claude-code
- Remote Control feature: a `claude --remote-control <name>` flag (full claude.ai login kell)
- tmux dokumentáció: https://github.com/tmux/tmux/wiki
- systemd path units: https://www.freedesktop.org/software/systemd/man/systemd.path.html
- launchd WatchPaths: https://www.launchd.info/
- Windows FileSystemWatcher: https://learn.microsoft.com/en-us/dotnet/api/system.io.filesystemwatcher

---

**A kezdéshez:** olvasd el a meglévő `claude-agent-spawner` script-et és a `new-agent.md` slash command-ot — ezek a legértékesebb referenciák. A többi (Linux, Windows port) ezek mintájára épül a 3. szakaszban leírt platform-specifikumokkal.
