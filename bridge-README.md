# bridge/ — feladat-letét a Claude Desktopból

Ide teszi le a Desktop agent (Cowork device-bridge) a feladatot; a Mac oldalán
egy launchd watcher veszi fel, Telegramon jóváhagyást kér, és indít egy agentet
a megadott szülőből — a gyerek örökli annak beszélgetését.

## Miért fájl-alapú

A device-bridge **izolált Linux VM**-ben fut: a `/Users/...` nem létezik, nincs
`launchctl`, a hálózat zárva, és `rm` sincs. A csatolt mappába írt fájl viszont
a **valódi lemezre** kerül. Nincs agent-to-agent messaging a felhő-session és a
lokális CLI között — a fájl az egyetlen csatorna.

## Mi érhető el? — `agents.json`

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

## Két kérés-típus

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

## Ha egy agent eltűnt a telefonról, de még fut

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

## Agent lezárása

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

## Kérés letétele

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

### Mikor kérj worktree-t

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

## Mit jelent a `spawned` — és mit nem

A `spawned` státusz azt jelenti, hogy **a feladat bizonyítottan megérkezett** az
agenthez: a híd darabolva küldi, és az agent **átiratából** igazolja vissza,
hogy a szöveg bekerült. Ha nem sikerül, a státusz `failed` lesz, nem `spawned`.

Ez mindkét úton így van — új forknál és folytatásnál egyaránt. ⚠️ Korábban nem
így volt, és két külön alkalommal is hazudott a státusz: a küldő oldalán minden
zöld volt, az agent mégis üresen ült. A ~1KB feletti prompt **eleje** vész el
egyben küldve, a vége pedig elküldetlenül ott marad a beviteli sorban.

**A `spawned` továbbra sem jelenti, hogy a munka megtörtént** — csak azt, hogy a
feladat célba ért. A munkát a jelentés igazolja.

## Üzenet egy leszármazott agentnek — `agent-send-prompt`

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

## A kérés-feldolgozás garanciája

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

## `resume` — mennyit örököljön a gyerek

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

## Fork-korlátok

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

## Mi történik utána

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

## Státusz visszaolvasása

A VM-ből **nincs hálózat**, tehát csak a lemezről tájékozódhatsz:
olvasd a `requests/<id>.status` fájlt.

```json
{ "status": "spawned", "message": "fork kész: <az új agent neve>", "updated_at": "..." }
```

Lehetséges értékek: `pending`, `spawned`, `rejected`, `failed`, `expired`.

## Eredmény visszaírása

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

## Az eredmény lehet kérdés is

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

## Takarítás

A VM-ből **nem tudsz törölni** (`rm` tiltott). Ne is próbáld: a feldolgozott
kéréseket a Mac-oldali **poller** archiválja az `archive/` alá (a jóváhagyás,
elutasítás vagy lejárat után). ⚠️ Amelyik kérés felhatalmazás alapján vagy
`gate: "audit"` módban indult, az nem megy át a pollernek ezen az ágán: a `.json`
a `requests/` alatt marad. Ugyanígy marad ott a jóváhagyott, de **elbukott**
indítású kérés is — a poller csak sikeres végrehajtás után archivál. Ez szándékos — a `.status` akkor is a végleges
állapotot mutatja —, de takarításkor számíts rá.
