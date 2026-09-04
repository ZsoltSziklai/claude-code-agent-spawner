# Regressziós futtatás — egy menetben

Ez a **végrehajtható** változat. A háttér és a „miért" a `REGRESSION.md`-ben van;
itt csak az van, amit sorban csinálni kell.

> ## ⛔️ FUTÁS KÖZBEN A `main`-HEZ NE NYÚLJ
>
> 2026-08-31: a G5 kaszkádos lezárása `refusing to merge unrelated histories`
> hibával állt meg. Az ok nem a lezárásban volt: a repót aznap **nyolcszor**
> `--amend`-eltük, és egy gyökér-commit amendje **új, szülő nélküli commitot**
> hoz létre. A futó agentek worktree-i a RÉGI alapról ágaztak le, ami ezzel
> **árvává** vált — merge-elni utána elvi lehetetlenség.
>
> **Ez minden olyan kört elbuktat, amelyik megáll egy javításért** — mert maga a
> javítás orphanolja a futó agentek ágait. A `close-tree` helyesen viselkedik:
> nem nyúl a `main`-hez, megtartja az ágat és a munkát, és hibával kilép.
>
> Amíg agent fut: se `amend`, se `rebase`, se `reset` a `main`-en. Javítás után
> a kört **a fork lépésétől** kell újraindítani, hogy friss alapú ág legyen.

> ## ⛔️ MEGÁLLÁSI SZABÁLY
>
> **Az első eltérésnél a futás VÉGE.** Nincs „feljegyzem és megyek tovább".
>
> - a végrehajtó **azonnal megáll**, és **semmit nem takarít el** — se agentet
>   nem zár le, se fájlt nem töröl, se kérést nem ír újra
> - **menti az átiratát**, hogy utólag végig lehessen nézni, mi történt
> - jelenti, **melyik lépésnél** és **mit** látott
>
> ### Az elindított agentet FIGYELNI kell
>
> Aki elindított egy agentet, **figyeli is**. Ha az agent **5 percen belül nem
> jelent** (nincs `bridge/results/<kérés-id>.md`), az **bukás** — nem lassulás,
> nem türelmi kérdés.
>
> Ilyenkor **ne nudge-olj, ne indítsd újra, ne segíts neki**. Egy beragadt agent
> a lelet maga; ha kisegítjük, pont azt tüntetjük el, amit mérni akartunk.
>
> A hibás állapot a bizonyíték. A javítás és a takarítás **utána** történik,
> nem a futás közben.
>
> **A teszt csak akkor sikeres, ha elejétől a végéig lefutott.** Egy „11-ből 9
> rendben" nem részsiker, hanem bukás.

**Felállás:** egy Cowork (Desktop) session vezeti az egészet. A saját blokkjait
maga futtatja, a CLI-blokkokhoz pedig **a hídon indít egy CLI-agentet**, ami
ebből a fájlból olvassa a lépéseit. Te a gombokat nyomod és figyelsz.

---

## Amit TE csinálsz

1. Nyiss egy Cowork sessiont, és illeszd be neki a **Kezdő prompt** szakaszt.
2. Nyomkodd a Telegram-gombokat a **Gombnyomás-térkép** szerint.
3. A megjelölt helyeken **nézd meg, mi van az üzeneten** — három ponton olyat
   kell látnod, ami a naplóból nem derül ki.

**Nagyságrend:** ~15 gombnyomás, ~60–90 perc.

**Modellválasztás.** A teszt-agentek feladata triviális (hozz létre egy fájlt,
commitold, jelents), ezért `sonnet` + `effort: low` — gyorsabb, olcsóbb, és
**kevesebbet improvizál**, ami mérésnél előny. **Egy kivétel:** a CLI-kört vezető
`regF1` agent `opus`-on fut, mert eljárást olvas, több lépést hajt végre, agenteket
indít és kiértékel — ott egy tévedés hamis bukást okozna, és a félrediagnózis
drágább, mint a megspórolt token.

## AUTOMATIZÁLT MÓD — gombnyomás nélkül

A kör ~15 gombnyomást igényelt egy embertől, 90 percen át. Ez automatizálható
**a Telegram megkerülése nélkül**: a poller egy fájlból olvasott jóváhagyást
ugyanolyan `callback_query`-vé alakít, mint amit a Telegram küld, és onnan a
**teljes meglévő kódút fut változatlanul**.

### Bekapcsolás

```bash
mkdir -p ~/.claude/agent-queue/test-callbacks
```

Amíg ez a könyvtár létezik, a csatorna él. Törléssel kikapcsol.

### Gombnyomás helyett

```bash
print 'ok:<kérés-id>' > ~/.claude/agent-queue/test-callbacks/$(uuidgen)
```

A `data` ugyanaz, ami a valódi gombon van: `ok:` indítás, `no:` elutasítás,
`g1:` / `g8:` / `gd:` felhatalmazás (1 óra / 8 óra / 1 nap), `rv:` visszavonás,
`qa:` / `qn:` queue-kapu, `s8:` / `sd:` / `sw:` némítás, `nu:` emlékeztető.

### Lépésenkénti térkép — mit írj a fájlba

| lépés | amit írsz | megjegyzés |
|---|---|---|
| A blokk | **semmit** | gomb nélkül kell elutasításra kerülniük |
| b1, b2 | `ok:regB1-…`, `ok:regB2-…` | |
| **b3** | **`g1:regB3-…`** | ez a `⏱ +1 óra`, NEM az `ok:` |
| **b4** | **semmit** | magától kell indulnia — ez a lépés lényege |
| **b5** | **`rv:regB3-…`** | ⚠️ a **B3** id-je, nem a b4-é — lásd lentebb |
| b6…f1 | `ok:<id>` | |
| G2 (queue-kapu) | `qa:<spec-UUID>` | a `gated/` alatti fájl neve, kiterjesztés nélkül |
| G3 (elutasítás) | `qn:<spec-UUID>` | |

⚠️ **A visszavonás csapdája.** A `rv:` gomb annak a kérésnek az id-jét viszi,
amelyik **a felhatalmazást adta** — nem azét, amelyik utána automatikusan
elindult. A b5-nél tehát `rv:regB3-…` kell. Ha a b4 id-jét írod, a poller
„ez a felhatalmazás már nem él" választ ad, a b6 gomb nélkül indul, és a teszt
elbukik — zavaros indoklással.

⚠️ **A queue-kapu id-je UUID, nem beszédes név.** A `qa:` / `qn:` gomb a spec
azonosítóját viszi (`qa:8C58A834-…`). A teszt-volt ellenőrzése ilyenkor a
`gated/<uuid>.json` **`name` mezőjéből** történik: annak kell `reg`-gel
kezdődnie. Éles nevű kapuzott kérésre ez a csatorna sem ad jóváhagyást.

### Négy korlát, amit tudni kell

1. **Csak `reg`-előtagú kérés-id** fogadható el — éles kérésre ez sem tud
   jóváhagyást gyártani (`SYNTHETIC-DENY` a naplóba).
2. Az `action` fehérlistázott.
3. Minden ilyen esemény **`SYNTHETIC-CALLBACK`** sorral a naplóba kerül.
4. A fájl **egyszer használatos** — felhasználáskor törlődik.

### A vizuális ellenőrzések (D2, E1) mostantól programból mérhetők

A gombos üzenet szövege lemezre kerül:
`bridge/requests/<id>.button.txt`

Így a figyelmeztetések megléte **állítható**, nem szemrevételezendő:

```bash
grep -q 'átirat' bridge/requests/regD2-....button.txt          # átirat-törlés
grep -q 'eldob'  bridge/requests/regD2-....button.txt          # munka eldobása
grep -q 'KORLÁTLAN JOGOSULTSÁGOT KÉR' bridge/requests/regE1-....button.txt
```

⚠️ **Ez az ellenőrzés KÖTELEZŐ, nem opcionális.** Az emberi gombnyomás értelme
épp az volt, hogy valaki *lássa* a figyelmeztetést. Ha automatizáljuk a
jóváhagyást, de nem állítjuk a szöveget, akkor a védelmet töröltük el, nem
automatizáltuk.

## Mit fogsz látni a Telegramon

A végrehajtó agent **minden lépésnél megmondja, mi a dolgod**, ezért ezt a
táblázatot nem kell fejből tudnod — akkor nézd meg, ha ellenőrizni akarod, hogy
amit kér, az stimmel-e.

| lépés | mit nyomj | mit NÉZZ MEG az üzeneten |
|---|---|---|
| A blokk (11 kérés) | **semmit** | nem szabad gombot kapnod |
| B1–B2 | `▶️ Indítás` | |
| B3 | **`⏱ +1 óra`** | |
| B4 | **semmit** | magától kell indulnia |
| B5 | **`🚫 Visszavonás`** | |
| B6–B8 | `▶️ Indítás` | B6-nak megint gombot kell kérnie |
| C1–C2 | `▶️ Indítás` | |
| D1 | `▶️ Indítás` | |
| D2 | `▶️ Indítás` | ⚠️ **két figyelmeztetés a gombok fölött**: átirat-törlés + munka eldobása |
| E1 | `▶️ Indítás` | ⚠️ **`KORLÁTLAN JOGOSULTSÁGOT KÉR`** a gombok fölött |
| F1 (CLI-agent indítása) | `▶️ Indítás` | |
| CLI-kör G2/G3 | `▶️ Indítás` / `✖️ Elutasítás` | a CLI-agent kéri; a vezető agent szól, mikor |
| Z1 (CLI-agent lezárása) | `▶️ Indítás` | |
| bármikor: `🔔 Emlékeztetem` | **SOHA ne nyomd** | ha ez megjelenik, egy agent beragadt → a teszt elbukott |
| bármikor: `🔕 8 óra / 1 nap / 1 hét` | csak NEM-teszt agenten | az éles, hosszan futó agentjeid nem a teszt részei |

---

## `<UTOTAG>` — a menet azonosítója

A runbook minden kérés-id-je és agent-neve `-<UTOTAG>`-ra végződik. **Ezt a
futás elején egyetlen értékre kell cserélni** (pl. `-20260901k`), és onnantól
mindenhol ugyanazt kell használni — a Desktop-blokkokban és a CLI-körben
egyaránt.

⚠️ **Miért nem fix.** A híd a **duplikált kérés-id-t némán eldobja**. Egy
korábbi menetből maradt `regG6-hidrol-…` id újrahasználva azt eredményezi, hogy
a lépés se el nem indul, se hibát nem ad — zavaros, nehezen diagnosztizálható
bukás. 2026-09-01-én a végrehajtó ezt észrevette és szólt, de erre nem szabad
építeni: a runbook maga ne legyen hibaforrás.

A `f1` feladatszövege **adja át a menet utótagját** a CLI-agentnek, hogy a
CLI-kör is ugyanazt használja.

## Kezdő prompt — ezt illeszd a Coworkbe

```
Regressziós tesztet vezetsz az agent-bridge-en. Zsolt figyeli a futást és ő
nyomja a Telegram-gombokat. A te feladatod NEM csak a lépések végrehajtása,
hanem hogy VÉGIG PONTOSAN TUDASSD VELE, hol tartunk és mi a dolga.

╔══════════════════════════════════════════════════════════════════════╗
║ KOMMUNIKÁCIÓS PROTOKOLL — ez a legfontosabb szabály, kivétel nincs   ║
╚══════════════════════════════════════════════════════════════════════╝

Minden lépés HÁROM részből áll. Ne told össze őket, ne szaladj előre, és
soha ne csinálj két lépést egy körben.

① BEJELENTÉS — MIELŐTT bármit kiírnál:

   „<id> — <mit mér ez a teszt, egy mondatban>
    Az én dolgom: <amit te csinálsz>
    A te dolgod: <NINCS — csak figyelj> VAGY <pontosan mit kell tennie>"

   Ha a te dolgod NINCS, ezt MONDD IS KI. Zsolt csak akkor megy a
   Telegramra, ha kifejezetten kéred — ne hagyd bizonytalanságban.

② VÉGREHAJTÁS

   Írd ki a kérést. Ha a lépéshez GOMBNYOMÁS kell, a kiírás UTÁN AZONNAL
   tedd fel a menüs kérdést (lásd lentebb) — ne várakozz némán.

③ EREDMÉNY + TOVÁBBENGEDÉS

   „<id>: MEGFELELT — <mit láttál: státusz, üzenet lényege>"
   vagy
   „<id>: ELTÉRÉS — <mit vártál> / <mit láttál>"  → és itt MEGÁLLSZ.

   Megfelelt esetén menüs kérdés: mehet-e a következő.

╔══════════════════════════════════════════════════════════════════════╗
║ A MENÜS KÉRDÉSEK — mindig menü, soha szabad szöveg                  ║
╚══════════════════════════════════════════════════════════════════════╝

Minden visszakérdezés AskUserQuestion (menü). Ne kérj szabad szöveges
választ. Három sablon van:

A) GOMBNYOMÁS-KÉRÉS — amikor Zsoltnak a Telegramra kell mennie:

   Kérdés: „<id> — menj a Telegramra. Ezt fogod látni: <az üzenet első
            sora / a lényege>. Nyomd meg: <PONTOS GOMBFELIRAT>."
   Opciók:
     1. „Megnyomtam”
     2. „Más gombokat látok” (ha ezt választja: kérd el, MIT lát, és állj meg)
     3. „Nem jött üzenet”     (ha ezt választja: ez ELTÉRÉS, állj meg)
     4. „Állj”

B) MEGFIGYELÉS — amikor nem elég megnyomni, meg is kell NÉZNI valamit:

   Kérdés: „<id> — a gombok FÖLÖTT mit látsz?”
   Opciók a várt tartalomra szabva (lásd D2 és E1 lentebb).
   Ezt a kérdést a gombnyomás ELŐTT tedd fel — utána az üzenet már
   nem feltétlenül ugyanaz.

C) TOVÁBBENGEDÉS — minden lépés végén:

   Kérdés: „<id>: <eredmény egy sorban>. Mehet a következő (<következő id>)?”
   Opciók: „Mehet” / „Várj, megnézek valamit” / „Állj”

╔══════════════════════════════════════════════════════════════════════╗
║ MEGÁLLÁSI SZABÁLY                                                    ║
╚══════════════════════════════════════════════════════════════════════╝

⛔️ ELTÉRÉSNÉL AZONNAL ÁLLJ MEG. Ne menj tovább, ne próbálkozz újra, ne
javíts, és NE TAKARÍTS: hagyj mindent pontosan úgy, ahogy van — futó
agenteket, worktree-ket, fájlokat, kéréseket. A hibás állapot a bizonyíték.
Mentsd el az átiratodat, és jelentsd: melyik lépésnél, mit vártál, mit
láttál, és a `message` mezőt szó szerint. Ezután NE csinálj semmit.

⏱ AZ ELINDÍTOTT AGENTRE 5 PERC. Ha egy `spawned` kérésre 5 percen belül
nincs `bridge/results/<kérés-id>.md`, az BUKÁS. Ne nudge-olj, ne indítsd
újra. A beragadt agent a lelet — ha kisegíted, eltünteted a bizonyítékot.

A GOMBRA viszont türelmesen várj: Zsolt lehet, hogy épp mást csinál. A
gombnyomásra nincs időkorlát, csak az agent munkájára.

╔══════════════════════════════════════════════════════════════════════╗
║ EGYÉB SZABÁLYOK                                                      ║
╚══════════════════════════════════════════════════════════════════════╝

- Egyszerre EGY kérést írj ki, és várd meg a VÉGLEGES státuszt
  (spawned / rejected / failed). A `pending` átmeneti, elvillanhat.
- A létrejött agentek NEVÉT jegyezd fel — a későbbi lépések arra hivatkoznak.
- A végén — CSAK ha végig lefutott — EGY táblázatot adj: teszt-id | státusz |
  megfelelt-e. Részleges futás = bukás, nem részsiker.
- BUKÁSKOR a jelentésed: (1) meddig jutottál — az utolsó SIKERES lépés,
  (2) melyik lépésen buktál el és mit vártál, (3) mit láttál helyette —
  státusz és `message` szó szerint, (4) hogy mentetted az átiratodat.

═══════════════════════════════════════════════════════════════════════
 A BLOKK — határok. EGYETLEN bejelentés az egész blokkra.
═══════════════════════════════════════════════════════════════════════

Bejelentés: „A blokk (regA01–regA11) — 11 érvénytelen kérés. Ezeknek
gomb NÉLKÜL kell elutasításra kerülniük. Az én dolgom: egyesével kiírom
és ellenőrzöm, hogy mind `rejected`. A te dolgod: NINCS — a Telegramra
NEM kell menned. Ha bármelyikre gombot kapsz, az ELTÉRÉS, szólj."

Írd ki egyesével, mindegyikre várd meg a `rejected`-et, és jegyezd fel a
`message`-t. A blokk végén EGY összesítő sor + továbbengedés-kérdés.

a01 {"parent":"nincs-ilyen-szulo","task":"x"}
a02 {"agent":"idegen-agent-NINCSILYEN","task":"x"}
a03 {"parent":"mac-main","task":"x","cwd":"/etc"}
a04 {"parent":"mac-main","task":"<ismételd az 'ÁÁÁÁ' szót ~5000-szer, hogy 8192 BÁJTNÁL hosszabb legyen>"}
a05 {"parent":"mac-main","agent":"mac-main","task":"x"}
a06 {"task":"x"}
a07 {"parent":"mac-main","task":"x","model":"gpt-9"}
a08 {"parent":"mac-main","task":"x","effort":"turbo"}
a09 {"parent":"mac-main","task":"x","permission_mode":"root"}
a10 {"parent":"mac-main","task":"x","resume":"gyors"}
a11 {"parent":"mac-main","task":""}

═══════════════════════════════════════════════════════════════════════
 B BLOKK — egy agent teljes életútja. MINDEN LÉPÉS KÜLÖN BEJELENTÉS.
═══════════════════════════════════════════════════════════════════════

b1 regB1-inditas-<UTOTAG>
   Mit mér: elindul-e egy agent jóváhagyás után.
   Zsolt dolga: Telegram → `▶️ Indítás`
{"parent":"mac-main","task":"REG B1. Ne csinálj semmit, csak írd a jelentésedbe: B1-OK. Fejezd be a kört.","model":"sonnet","effort":"low","worktree":false,"cwd":"temp","resume":"none"}
   → JEGYEZD FEL a nevét: B-AGENT

b2 regB2-folytatas-<UTOTAG>
   Mit mér: a folytatás is jóváhagyáshoz kötött-e.
   Zsolt dolga: Telegram → `▶️ Indítás`
{"agent":"<B-AGENT>","task":"REG B2. Írd a jelentésedbe: B2-OK."}

b3 regB3-felhatalmazas-<UTOTAG>
   Mit mér: az időkorlátos felhatalmazás megadható-e.
   Zsolt dolga: Telegram → ⚠️ NEM az „Indítás”, hanem `⏱ +1 óra`
   A menüs kérdésben EZT a gombfeliratot írd ki, mert itt könnyű elvéteni.
{"agent":"<B-AGENT>","task":"REG B3. Írd a jelentésedbe: B3-OK."}

b4 regB4-auto-<UTOTAG>
   Mit mér: a felhatalmazás tényleg megspórolja-e a gombot. EZ A LÉPÉS LÉNYEGE.
   Zsolt dolga: NINCS. Mondd is ki: „a Telegramra NEM kell menned; ha mégis
   gombot kapsz, az ELTÉRÉS."
   VÁRT: `spawned` GOMBNYOMÁS NÉLKÜL, másodperceken belül.
   Az eredményben MONDD MEG, kellett-e gomb, és mennyi idő telt el.
{"agent":"<B-AGENT>","task":"REG B4. Írd a jelentésedbe: B4-OK."}

b5 NEM írsz kérést.
   Zsolt dolga: Telegram → a b4-es indítási értesítésen `🚫 Visszavonás`
   Menüs kérdés: megnyomta-e. Amíg nem jelzi, ne menj tovább.

b6 regB6-visszavonas-utan-<UTOTAG>
   Mit mér: a visszavonás után újra kapuz-e. EZ A LÉPÉS LÉNYEGE.
   Zsolt dolga: Telegram → `▶️ Indítás` — de CSAK ha jön gomb.
   VÁRT: MEGINT gombot kér. Ha gomb nélkül indul, az ELTÉRÉS.
{"agent":"<B-AGENT>","task":"REG B6. Írd a jelentésedbe: B6-OK."}

b7 regB7-reconnect-<UTOTAG>   Zsolt dolga: `▶️ Indítás`
{"action":"reconnect","agent":"<B-AGENT>"}

b8 regB8-zaras-<UTOTAG>       Zsolt dolga: `▶️ Indítás`
{"action":"close","agent":"<B-AGENT>","code":"nowt","context":"keep"}

═══════════════════════════════════════════════════════════════════════
 C BLOKK — merge valódi commit-tal
═══════════════════════════════════════════════════════════════════════

c1 regC1-merge-<UTOTAG>        Zsolt dolga: `▶️ Indítás`
{"parent":"mac-main","task":"REG C1. A saját munkakönyvtáradban hozd létre a temp/reg-c1.txt fájlt ezzel: C1-OK. Add hozzá a githez és commitold 'reg c1' üzenettel. Utána írd a jelentésedbe: C1-COMMITOLVA és a commit rövid hashét.","model":"sonnet","effort":"low","worktree":true,"resume":"none"}
   → JEGYEZD FEL: C-AGENT és a hash

c2 regC2-zaras-merge-<UTOTAG>  Zsolt dolga: `▶️ Indítás`
   Mit mér: a commit tényleg átkerül-e a main-be.
   Az eredményben írd meg, hogy a hash rajta van-e a main-en.
{"action":"close","agent":"<C-AGENT>","code":"merge","context":"keep"}

═══════════════════════════════════════════════════════════════════════
 D BLOKK — drop + átirat törlése (visszafordíthatatlan)
═══════════════════════════════════════════════════════════════════════

d1 regD1-eldobando-<UTOTAG>    Zsolt dolga: `▶️ Indítás`
{"parent":"mac-main","task":"REG D1. Ne csinálj semmit, csak írd a jelentésedbe: D1-OK.","model":"sonnet","effort":"low","worktree":true,"resume":"none"}
   → JEGYEZD FEL: D-AGENT

d2 regD2-zaras-torles-<UTOTAG>
   ⚠️ MEGFIGYELÉSES LÉPÉS — a kérdést a gombnyomás ELŐTT tedd fel.
   Menüs kérdés: „A gombok FÖLÖTT két figyelmeztetésnek kell állnia:
   az átirat törléséről ÉS a munka eldobásáról. Mit látsz?”
   Opciók: „Mindkettő ott van” / „Csak az egyik” / „Egyik sem” / „Állj”
   Csak ha „mindkettő”, akkor kérd a `▶️ Indítás`-t.
{"action":"close","agent":"<D-AGENT>","code":"drop","context":"keep","transcript":"delete"}

═══════════════════════════════════════════════════════════════════════
 E BLOKK — emelt jogosultság
═══════════════════════════════════════════════════════════════════════

e1 regE1-emeltjog-<UTOTAG>
   ⚠️ MEGFIGYELÉSES LÉPÉS — a kérdést a gombnyomás ELŐTT tedd fel.
   Menüs kérdés: „A gombok FÖLÖTT ott a `⚠️ KORLÁTLAN JOGOSULTSÁGOT KÉR`
   figyelmeztetés?”  Opciók: „Ott van” / „Nincs ott” / „Állj”
   Csak ha „ott van”, akkor kérd a `▶️ Indítás`-t.
{"parent":"mac-main","task":"REG E1. Ne csinálj semmit, csak írd a jelentésedbe: E1-OK.","model":"sonnet","effort":"low","permission_mode":"bypassPermissions","worktree":true,"resume":"none"}
   → JEGYEZD FEL: E-AGENT

e2 regE2-zaras-<UTOTAG>        Zsolt dolga: `▶️ Indítás`
{"action":"close","agent":"<E-AGENT>","code":"drop","context":"keep"}

═══════════════════════════════════════════════════════════════════════
 F BLOKK — a CLI-kör. ITT TE LESZEL ZSOLT SZEME.
═══════════════════════════════════════════════════════════════════════

Bejelentés: „Most egy CLI-agentet indítok, ami a saját gépén futtatja a
G1–G9 lépéseket. Ez alatt ŐK kérnek gombokat, nem én — de én szólok,
melyik jön, és mit kell nyomnod. Ne menj a Telegramra magadtól."

f1 regF1-cliteszt-<UTOTAG>     Zsolt dolga: `▶️ Indítás`
{"parent":"mac-main","worktree":false,"cwd":"claude-code-agent-spawner","resume":"none","effort":"high","task":"CLI REGRESSZIÓS KÖR. Olvasd el a tests/REGRESSION-RUN.md fájlt a munkakönyvtáradban, és hajtsd végre PONTOSAN a 'CLI-KÖR' szakaszát, az ott leírt sorrendben. A jelentésedbe a szakasz végén kért táblázatot írd. Semmi mást ne csinálj."}
   → JEGYEZD FEL: CLI-AGENT

⚠️ **AMIT A VEZETŐ SESSION NEM LÁT.** A G2 és G3 lépés **kapuzott** kérése a
`~/.claude/agent-queue/gated/` alatt él, NEM a hídon. Felhőből futó Cowork
sessionből ez a könyvtár **nem csatolható** (a hozzáférés-kérés elutasításra
kerül) — 2026-09-01-én mérve. Ezen a két lépésen tehát **az ember az egyetlen
érzékelő**: a Telegram-üzenet az egyetlen jel, hogy a kapu megszólalt.

Ne ígérd, hogy figyeled — mondd meg Zsoltnak, hogy a G2/G3-nál ő lát, te nem.
A híd-kéréseket (G6, G7) viszont látod, azokra érvényes az időkorlát.

⚠️ EZUTÁN NE MARADJ NÉMÁN. A CLI-agent kérései is a hídon mennek, tehát
LÁTOD ŐKET a gépen. Amíg a CLI-agent dolgozik, 30 másodpercenként nézd:

   ls ~/.claude/agent-queue/bridge/requests/
   tail -5 ~/.claude/agent-queue/bridge.log

Amikor új `reg G*` kérés jelenik meg `pending` státusszal, AZONNAL szólj
Zsoltnak a gombnyomás-sablonnal: melyik lépés, mit fog látni, mit nyomjon.
A G3-nál `✖️ Elutasítás` kell, nem indítás — ezt külön hangsúlyozd.

Ha 5 percig nincs se új kérés, se jelentés a CLI-agenttől: BUKÁS.

z1 regZ1-clizaras-<UTOTAG>     Zsolt dolga: `▶️ Indítás`
   Csak akkor, ha a CLI-agent jelentése MEGJÖTT és megfelelt.
{"action":"close","agent":"<CLI-AGENT>","code":"drop","context":"keep"}

═══════════════════════════════════════════════════════════════════════
 VÉGE
═══════════════════════════════════════════════════════════════════════

Összefoglaló táblázat, és külön mondd meg:
- a b4 kellett-e gombnyomás (és mennyi idő alatt indult)
- a b6 kért-e gombot
- a d2-n és e1-en ott voltak-e a figyelmeztetések
- a CLI-agent jelentése megjött-e, és mit tartalmazott
```

---

## CLI-KÖR

*(Ezt a szakaszt a hídon indított CLI-agent olvassa és hajtja végre.)*

Te egy CLI-agent vagy a Mac-en, a `claude-code-agent-spawner` könyvtárban.
**Nincs kitől visszakérdezned** — a döntéseket a lentiek szerint hozd meg.

⏱ **IDŐKORLÁT:** minden elindított agentet figyelj. Ha **5 percen belül** nem
készül el a munkája (a várt fájl/commit, illetve híd-kérésnél a jelentés), az
**BUKÁS**. Ne nudge-olj, ne indítsd újra, ne segíts neki — a beragadt agent a
lelet. Jelentsd, melyik agentre, meddig vártál, és mi hiányzott.

⛔️ **MEGÁLLÁSI SZABÁLY:** az első eltérésnél **azonnal állj meg**. Ne javíts, ne
próbálkozz újra, és **ne takaríts** — hagyj mindent úgy, ahogy van. A jelentésedbe
írd meg: melyik lépésnél, mit vártál, mit láttál, és a pontos hibaüzenetet.
Ezután fejezd be a kört. A hibás állapot a bizonyíték; a javítás és a takarítás
a parancsközpont dolga.

⚠️ **Kimondott kivétel:** normál munkában TILOS közvetlenül spec-JSON-t írni a
`new/` alá vagy a `fork-agent`-et hívni — a `/new-agent` és a `/fork` a tesztelt
út. **Ebben a tesztben mégis a bináris hívása a helyes**, mert a varázsló
kérdezne, neked pedig nincs kitől választ kapnod. A paramétereket ez a fájl
rögzíti, tehát a varázsló kérdés-válasza már megtörtént. Ez a kivétel **csak
erre a tesztre** szól.

Minden lépés után írj egy sort a naplódba, hogy hol tartasz.

### G1 — `/new-agent` út, felhasználói indítás (nincs kapu)

```bash
UUID=$(uuidgen)
jq -n --arg n "mac-main-regG1-<UTOTAG>" --arg p "mac-main" \
      --arg c "$HOME/ClaudeProjects/temp" \
      --arg pr "REG G1. A munkakönyvtáradban hozd létre a reg-g1.txt fájlt ezzel: G1-OK. Fejezd be a kört." \
  '{name:$n,parent:$p,cwd:$c,prompt:$pr,model:"sonnet",effort:"low",permission_mode:"auto",brief:true,worktree:false,create_cwd:false}' \
  > ~/.claude/agent-queue/new/$UUID.json
sleep 10; tmux has-session -t agent-mac-main-regG1-<UTOTAG> && echo INDULT || echo NEM
```
**VÁRT:** `INDULT`, gombnyomás nélkül, és a `gated/` üres marad.

### G2 — ugyanez `requested_by`-jal (KAPU, jóváhagyás)

Ugyanaz, de a JSON-ba tedd bele: `requested_by: "<a saját session-neved>"`,
és a név legyen `mac-main-regG2-<UTOTAG>`.

⚠️ **A feladatában más fájlnév szerepeljen: `reg-g2.txt`, `G2-OK` tartalommal.**
Eddig mindkettő ugyanazt a `reg-g1.txt`-t írta, ezért **fájlból nem lehetett
megkülönböztetni, melyik futott le**. A kapu működését a `gated/` napló
bizonyítja, de a fájl legyen független bizonyíték.

**VÁRT:** NEM indul el; a spec a `~/.claude/agent-queue/gated/` alá kerül, és a
`spawner.log`-ban `GATED` sor van. **Szólj a jelentésedben, hogy Zsoltnak
`▶️ Indítás`-t kell nyomnia**, majd várd meg, amíg elindul (max 10 perc).

### G3 — ugyanez, de ELUTASÍTVA

Ugyanaz, `mac-main-regG3-<UTOTAG>` névvel. **Szólj, hogy Zsolt ezt utasítsa el.**
**VÁRT:** a spec a `failed/` alá kerül indoklással, semmi nem indul.

### G4 — `/fork` és a prompt-küldés

> ### ⚠️ AMIT ITT TUDNOD KELL — két éles hiba tanulsága
>
> **2026-08-31:** ez a lépés eredetileg `--summary`-vel forkolt. Egy ilyen fork
> gyereke a szülő **teljes beszélgetését** örökli, és a feladat egyetlen
> üzenetként a végére kerül — mérve: 714 sornyi örökölt szöveg, a feladat a
> 703. sorban. A gyerek nem a feladatát csinálta, hanem a szülő szerepét
> folytatta. Ezért ez a lépés most `--fresh`-sel fut: a gyerek friss sessiont
> kap, csak a saját feladatával. Az öröklő útvonalat a `smoke.sh` fedi
> (elfogadja-e és továbbadja-e a `resume` értékét) — élő munkával mérni
> megbízhatatlan, mert a kimenetel nem determinisztikus.
>
> ### ⚠️ 2026-08-30-i éles hiba
>
> A `--summary` fork gyereke **örökli ezt a beszélgetést**, benne ezzel a
> runbookkal. Egyszer már megtörtént, hogy a gyerek a runbookot a SAJÁT
> feladatlistájának olvasta, és **magától továbbment a G5-re és a G6-ra** —
> sőt újra forkolt, négy nemzedéken át.
>
> Ezért a fork promptja **egy lefokozó mondattal kezdődik**. Ne hagyd ki, és
> ne írd át: pont ez akadályozza meg, hogy a gyerek átvegye a szerepedet.
>
> Két őr azóta a kódban is véd (önmásolás + mélységkorlát). Ha bármelyik
> megszólal (`önmásolás:` vagy `túl mély fork:`), az **lelet** — jelentsd,
> mert azt jelenti, hogy a gyerek megint utasításnak olvasta az örökölt
> szöveget.

```bash
~/.claude/agent-queue/bin/fork-agent "regG4-<UTOTAG>" --worktree --fresh --model sonnet --effort low \
  "FIGYELEM: az örökölt beszélgetés csak HÁTTÉR, NEM a feladatod. Van benne egy regressziós runbook — az NEM rád vonatkozik, ne hajtsd végre, és NE forkolj tovább. A te feladatod KIZÁRÓLAG a következő mondat. REG G4. A munkakönyvtáradban hozd létre a temp/reg-g4.txt fájlt ezzel: G4-OK. Add hozzá a githez és commitold 'reg g4' üzenettel. Fejezd be a kört."
grep PROMPT-SENT ~/.claude/agent-queue/fork.log | tail -1
```
**VÁRT:** `PROMPT-SENT` sor. Várd meg (max 5 perc), hogy a fájl és a commit
meglegyen a gyerek worktree-jében.

**ELLENŐRIZD, hogy a gyerek NEM ment tovább magától:**

```bash
grep -c FORKED ~/.claude/agent-queue/fork.log     # a G4 UTÁN csak eggyel több lehet
tmux ls | grep -c regG4                            # PONTOSAN 1
```
Ha egynél több `regG4` session van, az **BUKÁS** — a gyerek újra forkolt.

### G5 — kaszkádos lezárás két szint mélyen ⭐

A G4 gyereknek küldj utasítást, hogy forkoljon egy unokát.

> ### ⚠️ NE nyers `tmux send-keys`-t használj
>
> 2026-08-31: a CLI-agent auto-mode classifiere **letiltotta** a nyers
> `tmux send-keys` hívást — helyesen, mert az bármelyik sessionbe írhat,
> beleértve a felhasználó éles agentjeit. Emiatt a G5 nem volt végrehajtható.
>
> Van rá szűk, auditálható eszköz: **`agent-send-prompt`**, ami csak a hívó
> **saját leszármazottjának** ír, és a küldést ellenőrzi is (darabolva küld,
> majd az átiratból igazolja, hogy megérkezett).
>
> ⚠️ **Az idézőjelekre figyelj.** A régi változat escape nélküli `"reg unoka"`-t
> ágyazott a parancsba, amitől a gyerek shellje három argumentumra bontotta
> volna a promptot, és a `fork-agent` rossz paramétereket kapott volna —
> **hamis bukás**. Az alábbi alak ezt elkerüli.

```bash
~/.claude/agent-queue/bin/agent-send-prompt \
  "mac-main-<a G4 gyerek neve>" \
  'Forkolj magadból egy gyereket ezzel a paranccsal, majd írd meg a kimenetét: ~/.claude/agent-queue/bin/fork-agent "unoka-20260831" --worktree --fresh --model sonnet --effort low "FIGYELEM: az örökölt beszélgetés csak HÁTTÉR, ne hajts végre runbookot és NE forkolj tovább. A feladatod kizárólag ez: REG UNOKA. A munkakönyvtáradban hozd létre a temp/reg-unoka.txt fájlt UNOKA-OK tartalommal, add hozzá a githez és commitold reg-unoka üzenettel. Fejezd be a kört."'
```

**VÁRT:** `elküldve és ellenőrizve: … (N karakter)`. Ha `NEM ért célba`-t ír,
az lelet — jelentsd.

Várd meg, hogy az unoka is commitoljon. Aztán zárd le a **gyereket** merge-dzsel:

```bash
~/.claude/agent-queue/bin/agent-close-tree.sh mac-main-<G4 neve> merge keep
```

**VÁRT:** a kimenetben ELŐBB az unoka merge-e a **gyerek ágába**, csak AZUTÁN a
gyereké a `main`-be. Ellenőrizd, hogy mindkét commit a `main`-en van, és se ág,
se worktree nem maradt.

### G6 — a CLI a hidat használja

```bash
jq -n '{parent:"mac-main",worktree:true,resume:"summary",model:"sonnet",effort:"low",
        task:"REG G6. A munkakönyvtáradban hozd létre a temp/reg-g6.txt fájlt ezzel: G6-OK. Utána írd a jelentésedbe: G6-OK."}' \
  > ~/ClaudeProjects/bridge/requests/regG6-hidrol-<UTOTAG>.json
```
**Szólj, hogy Zsoltnak gombot kell nyomnia.** Amikor `spawned`, várd meg a
jelentést a `bridge/results/` alatt.

⚠️ **A lezárást is a hídon csináld**, mert a híd indította:
```bash
jq -n --arg a "<a G6 agent neve>" '{action:"close",agent:$a,code:"drop",context:"keep"}' \
  > ~/ClaudeProjects/bridge/requests/regG7-hidzaras-<UTOTAG>.json
```

### G8 — határok (ingyenes, nem indul semmi)

Írj **öt** specet a `new/` alá, mind hibás, és nézd meg a `failed/*.reason`-t.

| # | spec | várt indok |
|---|---|---|
| a | `cwd: ~/ClaudeProjects/nincs-ilyen-<UTOTAG>`, `create_cwd:false` | **nem létezik** |
| b | `cwd: ~/nincs-ilyen-<UTOTAG>` (a gyökéren KÍVÜL) | `cwd outside allowed root` |
| c | `cwd: /etc` | `cwd outside allowed root` |
| d | `model:"gpt-9"` | `invalid model` |
| e | `effort:"turbo"` | `invalid effort` |

⚠️ **Az (a) és a (b) NEM ugyanaz, és ez eddig összecsúszott.** A 2026-09-01-i
menetben a „nem létező cwd" a `$HOME` alá került, ezért a **gyökér-ellenőrzésen**
bukott el — egy lépéssel korábban, mint amit mérni akartunk. A „létezik-e" ág
így **egyetlen menetben sem volt lefedve**. Az (a) esetnek a `~/ClaudeProjects`
**alá** kell esnie, hogy a gyökér-ellenőrzés átengedje.

⚠️ A `worktree:true` a `~/ClaudeProjects` alatti könyvtárban **érvényes** (az
git-repón belül van) — azt NE mérd határsértésként, mert agentet indítanál.

### G9 — NINCS takarítás

**Ne takaríts.** A futó agenteket, worktree-ket, ágakat és fájlokat hagyd
pontosan úgy, ahogy vannak — akkor is, ha minden sikerült. A takarítás a
parancsközpont dolga, a futás kiértékelése után.

### A jelentésed

Táblázat: lépés | eredmény | megfelelt-e | eltérésnél a pontos üzenet.

Bukásnál: MEDDIG jutottál (utolsó sikeres lépés), MELYIK lépésen buktál el, mit
vártál, mit láttál — és időtúllépésnél: melyik agent, hány percig, mi hiányzott.
Külön mondd meg: a G2 kapuzott-e, a G3 elutasítás után indult-e valami, a G5
kaszkád sorrendje helyes volt-e, és a G6 lezárása után kiürült-e a
`bridge-spawned` nyilvántartás.

---

## Ellenőrző parancsok (Zsoltnak, futás közben)

```bash
Q=~/.claude/agent-queue
tail -20 "$Q/bridge.log"                   # a körök
grep PROMPT-SENT "$Q/fork.log" | tail -3   # a fork feladata elment-e
ls "$Q/gated"                              # kapuzott kérés vár-e
jq -r 'keys[]?' "$Q/bridge-spawned.json"   # a híd nyilvántartása
tmux ls | grep '^agent-'
git -C ~/ClaudeProjects worktree list
# ⚠️ A CLI-kör G4/G5 lépése a claude-code-agent-spawner repóban dolgozik, ami
# KÜLÖN git-repó. 2026-08-31-en a vezető session a ClaudeProjects ágai közt
# kereste a G4 ágát, nem találta, és majdnem hamis bukást írt. Mindkettőt nézd:
git -C ~/ClaudeProjects/claude-code-agent-spawner worktree list
```

## Utána

A `REGRESSION.md` csapdalistáját érdemes átfutni: a `spawned` nem jelent munkát,
a napló kora számít, és egy negatív teszt rossz okból is lehet zöld.
