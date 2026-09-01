# Regressziós teszt — végigjátszható forgatókönyv

A `tests/smoke.sh` azt fedi, ami izoláltan mérhető. **Ez a dokumentum azt fedi,
amit csak élesben lehet:** a Telegram-kaput, a tényleges agent-indítást, a
munkát, a jelentés visszaútját és a lezárást.

> **2026-08-29-i tanulság.** Egyetlen napon **hét** valódi hiba került elő, és
> **egyet sem kódolvasással találtunk meg** — mindegyik csak akkor, amikor
> valaki végigjátszotta. A `spawned` státusz nem jelenti azt, hogy a munka
> megtörtént.

## Mikor futtasd

- kiadás előtt (a `smoke.sh` zöldje nem elég)
- ha a híd, a `fork-agent`, a spawner vagy a lezárás bármelyik ága változott
- ha egy agent „elindult, de nem csinál semmit"

## Munkamegosztás és költség

A **Desktop-blokkokat** a Cowork hajtja végre (a prompt lentebb), a
**CLI-blokkokat** a parancsközpont. A gombokat a tulajdonos nyomja.

| | költség |
|---|---|
| negatív tesztek (A blokk, CLI-határok) | **ingyen** — a validáció elutasítja, nem jön gomb, nem indul agent |
| pozitív tesztek | **egy gombnyomás + egy valódi agent** (token, pénz) |

Ezért: **az enumokat ne élesben mérd.** A modell- és permission-fehérlisták
halmaz-egyezését a `smoke.sh` már fogja. Élesben az **útvonalakat** kell mérni.

Nagyságrend: Desktop-kör ~11 gombnyomás, CLI-kör ~4.

---

## Desktop-kör

Add át a Cowork sessionnek. Szabályok, amiket bele kell írni: egyszerre **egy**
kérés; várd meg a **végleges** státuszt (`spawned` / `rejected` / `failed`) — a
`pending` átmeneti, elvillanhat; a létrejött agentek **nevét jegyezd fel**, a
későbbi lépések arra hivatkoznak; ne improvizálj, ne próbálkozz újra.

### A blokk — határok (gomb NÉLKÜL kell elbukniuk)

Mind `rejected`, a `message`-ben az okkal.

```json
{"parent":"nincs-ilyen-szulo","task":"x"}
{"agent":"idegen-agent","task":"x"}
{"parent":"mac-main","task":"x","cwd":"/etc"}
{"parent":"mac-main","task":"<8192 BÁJTNÁL hosszabb szöveg>"}
{"parent":"mac-main","agent":"mac-main","task":"x"}
{"task":"x"}
{"parent":"mac-main","task":"x","model":"gpt-9"}
{"parent":"mac-main","task":"x","effort":"turbo"}
{"parent":"mac-main","task":"x","permission_mode":"root"}
{"parent":"mac-main","task":"x","resume":"gyors"}
{"parent":"mac-main","task":""}
```

⚠️ **Az érvénytelen `code` / `transcript` értéket LÉTEZŐ, híd-indította agenten
kell mérni.** A „nem a híd indította" őr hamarabb fut, mint az enum-validáció —
nem létező agenttel csak azt méred, és az enum-ellenőrzés teszteletlen marad.

### B blokk — egy agent teljes életútja (worktree nélkül)

Hét gombnyomás, egy agent, sok út.

1. **fork** `{"parent":"mac-main","task":"…","model":"sonnet","effort":"low","worktree":false,"cwd":"temp"}` → jegyezd fel a nevét
2. **folytatás** `{"agent":"<NÉV>","task":"…"}`
3. **folytatás**, de a `⏱ +1 óra` gombot nyomd → felhatalmazás
4. **folytatás** → **gomb nélkül** kell indulnia. *Ez a lépés lényege.*
5. a tulajdonos megnyomja a `🚫 Visszavonás` gombot
6. **folytatás** → **megint gombot kell kérnie**. *Ez a lépés lényege.*
7. **reconnect** `{"action":"reconnect","agent":"<NÉV>"}`
8. **lezárás** `{"action":"close","agent":"<NÉV>","code":"nowt","context":"keep"}`

### C blokk — merge valódi kódváltozással

A gyerek hozzon létre egy fájlt a `temp/` alatt, **commitolja**, majd:
`{"action":"close","agent":"<NÉV>","code":"merge","context":"keep"}`
Ellenőrzés: a commit tényleg a `main`-en van.

### D blokk — drop + átirat törlése (visszafordíthatatlan)

`{"action":"close","agent":"<NÉV>","code":"drop","context":"keep","transcript":"delete"}`

A jóváhagyó üzeneten **a gombok fölött** meg kell jelennie két figyelmeztetésnek
(átirat-törlés, munka eldobása). Ellenőrzés a gépen: a törölt agent
átirat-könyvtára eltűnt, **a szülőé érintetlen**.

### E blokk — emelt jogosultság

`{"parent":"mac-main","task":"…","permission_mode":"bypassPermissions"}`

A gombok fölött meg kell jelennie a `⚠️ KORLÁTLAN JOGOSULTSÁGOT KÉR` blokknak.
Ellenőrzés: a spec **és a futó folyamat** is `bypassPermissions`, és **nincs**
`PERM-DOWNGRADE` sor a naplóban (mert gombnyomás volt).

---

## CLI-kör

A parancsközpontból. **Használd a parancsokat** (`/new-agent`, `/fork`,
`/close-agent`) — ne írj spec-JSON-t közvetlenül a `new/` alá.

### 1. `/new-agent` és a `requested_by` kapu

| | `requested_by` | várt |
|---|---|---|
| felhasználó kérte | üres | azonnal indul, **gomb nélkül** |
| az agent döntött | a saját neve | `gated/` + **gomb**, jóváhagyás után indul |
| ugyanaz, elutasítva | a saját neve | `failed/` + indok, **semmi nem indul** |

### 2. `/fork` a parancsközpontból

`fork-agent "<suffix>" --worktree --summary "<feladat>"`

Ellenőrzés: **`PROMPT-SENT` sor a `fork.log`-ban** — enélkül a feladat nem ment
el. A gyerek dolgozzon és commitoljon. A `live/`-ban **nem** lehet bejegyzése
(a forkokat szándékosan nem élesztjük újra).

### 3. Kaszkádos lezárás két szint mélyen ⭐

Ezt a Desktop **nem tudja felépíteni** (csak fehérlistázott szülőből forkolhat),
és ez mozgatja a legtöbb adatot.

1. gyerek fork saját ággal
2. a **gyerek** forkoljon egy unokát (küldd be neki `send-keys`-szel)
3. mindkettő csináljon valódi commitot
4. a **gyereket** zárd `merge`-dzsel

Várt: a kaszkád **a legmélyebbtől felfelé** megy — az unoka a **gyerek** ágába
olvad, a gyerek a `main`-be. Ellenőrzés: mindkét commit a `main`-en, se ág, se
worktree, se session nem marad.

### 4. A CLI a hidat használja

Írj híd-kérést a `bridge/requests/` alá, pont úgy, ahogy a Desktop. A hídnak
**nem szabad megkülönböztetnie**, ki írta a fájlt.

⚠️ **A lezárást is a hídon csináld** (`action: "close"`). Egy híd-indította
agent CLI-ről lezárva árván hagyja a nyilvántartást, és a küldő nem értesül róla.

### 5. Határok CLI-ről (ingyenes)

Nem létező cwd · engedélyezett gyökéren kívüli cwd · érvénytelen modell /
effort / permission.

⚠️ A `worktree: true` a `~/ClaudeProjects` **alatti** könyvtárban **érvényes**
(az a git-repón belül van) — az nem határsértés. Ha ezt méred, agentet indítasz.

---

## Amit a gép oldaláról ellenőrizz

```bash
Q=~/.claude/agent-queue
grep '<kérés-id>' "$Q/bridge.log"          # a kör: REQUEST → CALLBACK → SPAWNED → RESULT-PUBLISHED
grep 'PROMPT-SENT'  "$Q/fork.log"          # a fork feladata tényleg elment?
grep 'PERM-DOWNGRADE' "$Q/bridge.log"      # emelt jog visszafokozva?
jq -r 'keys[]?' "$Q/bridge-spawned.json"   # a híd nyilvántartása
ls "$Q/gated"                              # agent-indította kérés vár?
git -C ~/ClaudeProjects worktree list      # maradt-e worktree
git -C ~/ClaudeProjects branch --list 'worktree-*'
tmux ls | grep '^agent-'
```

A **spec és a futó folyamat** összevetése (a spec hazudhat, a parancssor nem):

```bash
ps -p <pid> -o args=                       # --model, --permission-mode a valóságban
```

## Csapdák, amikbe 2026-08-29-én belefutottunk

1. **A `spawned` nem jelent munkát.** Hét hibából négy úgy nézett ki, mintha
   sikerült volna. Mindig nézd meg, hogy a **jelentés** megjött-e.
2. **Ha egy agent néma, nézd a pane-ját és a parancssorát**, ne a kódot.
   A fork-hibát öt perc alatt megtalálta a `tmux capture-pane` és a
   `ps -o args`; előtte két rossz diagnózist állítottam kódolvasásból.
3. **A napló kora számít.** Egy `bridge.stderr.log` tele volt hálózati hibával —
   három napos volt. Nézd meg a fájl `mtime`-ját, mielőtt következtetsz.
4. **A teszted rossz okból is lehet zöld.** Ha egy negatív teszt „átmegy",
   ellenőrizd, hogy a *vizsgált* ágon bukott-e el, és nem valami korábbin
   (pl. cwd-ellenőrzés a kapu helyett).
5. **Mutációs próba nélkül egy új teszt nem hihető.** Rontsd el szándékosan a
   kódot, és nézd meg, tényleg elbukik-e. Aznap háromszor derült ki így, hogy
   egy frissen írt állítás üresjáratban zöld.
6. **A csonk a PATH-ban nem elég**, ha a tesztelt szkript maga is exportál
   PATH-t. A `claude-agent-spawner` a saját elején `$HOME/.local/bin`-t tesz
   előre — a csonkot oda kell tenni, és a `HOME`-ot is át kell állítani.
   Enélkül a „izolált" teszt eleven agentet indít.
7. **A `--summary` fork továbbadja az UTASÍTÁSOKAT is.** 2026-08-30: egy
   forkolt gyerek a szülő beszélgetés-összefoglalójában lévő runbookot a SAJÁT
   feladatlistájának olvasta, és újra forkolta ugyanazt — **négy nemzedék**.
   A láncot nem védelem állította meg, hanem véletlen: a név 64 karakteren
   elfogyott. Azóta két őr áll az úton (önmásolás + mélységkorlát), de a
   tanulság általános: **amit a szülő kontextusa tartalmaz, azt a gyerek
   utasításnak olvashatja.** Runbookot ne `--summary` forkkal adj át.
8. **A fork-tesztek `--cwd nincs-ilyen`-nel fussanak.** Egy őr-teszt, ami az őr
   kiiktatásakor végigmegy, ELEVEN agentet indít. Ugyanaznap ez kétszer is
   megtörtént velem (egyszer a kontroll-teszten, egyszer a mutációs próbán).
   A nem létező cwd egy későbbi, olcsó végállomás: az őr így is mérhető.
9. **Takarítás a végén**, tételesen: kérés-fájlok, eredmények, specek,
   worktree-k, ágak, és — külön rákérdezéssel, mert visszafordíthatatlan — a
   teszt-agentek átiratai.
