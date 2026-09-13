# Development workflow

**🇭🇺 [Magyar változat](#magyar-változat)**

Since `v1.0.0` this repository follows ordinary open-source practice: expressive
commits, semantic versioning, a CHANGELOG entry behind every release.

## Versioning — [SemVer](https://semver.org/)

| change | version |
|---|---|
| backwards-compatible bug fix | **PATCH** — `1.0.1` |
| new, backwards-compatible capability | **MINOR** — `1.1.0` |
| breaking change (an existing call behaves differently) | **MAJOR** — `2.0.0` |

⚠️ **"Breaking" is judged from the caller's side.** If a field of a bridge
request disappears, means something else, or a status starts meaning something
else, that is breaking — even if the code got nicer in the process. Changing the
meaning of `spawned` was exactly such a case: the Desktop reads it as success.

## Commit messages — [Conventional Commits](https://www.conventionalcommits.org/)

```
<type>(<scope>): <what it does, imperative mood>

<why — the symptom and the measurement, not a retelling of the code>

Co-Authored-By: …
```

Types: `fix`, `feat`, `docs`, `test`, `refactor`, `chore`, `perf`.
Scope: the component (`bridge`, `fork`, `spawner`, `watchdog`, `tests`).

**The body is what matters.** The "what" is readable from the diff; the "why" is
not. When a fix has a live incident behind it, the **symptom, the measurement and
the date** belong there — several fixes in this repository stayed correct because
the next reader understood which measurement produced them. For example, *"of a
1796-character prompt only 774 arrived, starting mid-word"* says more than *"we
send it in chunks"*.

## Branches

- `main` — always green (CI), always releasable
- work on `fix/<short-name>` or `feat/<short-name>`, via PR, squash-merged
- ⚠️ **Never `amend`/`rebase`/`reset` on `main` while an agent is running.**
  Amending a root commit creates a new parentless commit, which orphans the
  worktree branches of running agents: `refusing to merge unrelated histories`.
  This cost a full regression round on 2026-08-31.

## Release

1. `CHANGELOG.md` — a new section with the version and the date, split into
   *Fixed* / *Added*, written from the user's point of view
2. update the test count in the CHANGELOG and in `README.md`
3. `git tag -a vX.Y.Z -m "…"` on the commit being released, then
   `git push origin vX.Y.Z`
4. `gh release create vX.Y.Z --notes-file <the CHANGELOG section>`

## Testing

`./tests/smoke.sh` — also runs in CI on every push.

⚠️ **A new assertion is not believable without a mutation check.** Break the code
on purpose and see whether it actually fails. In this repository a fresh
assertion has been green while measuring nothing several times over:

- the pattern matched the **comment**, not the line of code
- `grep -qv X` means *"there is a line without X"* — not that none contain it
- `jq -e` treats the **empty string** as true as well
- the test measured the logic's **own copy** inside the test file, not the real code
- the example name was **made up**, while the live system sends a prefixed form

For what can only be measured live there is `tests/REGRESSION-RUN.md` — the smoke
test covers what is measurable in isolation, the regression covers what is only
measurable while running.

## Bilingual documentation

Every document meant to be **read** is bilingual: **English first, then a
`## Magyar változat` section** with the same content — `README.md`,
`CHANGELOG.md`, `CONTRIBUTING.md`, `ROADMAP.md`, `TODO.md`, `DEVELOPMENT.md`,
`bridge-README.md`. A pull request that adds a section in only one language is
incomplete.

The same applies to Telegram: user-facing text does not go into the call sites
but into the `BRIDGE_MSG` catalogue in `bin/_bridge-lib.sh`, fetched through
`t <key>` (see the `lang` setting).

⚠️ **The exception is prompt material, and it is deliberate.** The slash-command
files (`new-agent.md`, `close-agent.md`, `kill-agent.md`, `kill-all-exit.md`,
`fork.md`), `desktop-skill/agent-bridge/SKILL.md` and the two regression runbooks
are not read by a person — they are loaded into an agent's context as
instructions. Doubling them would double that context and give the agent two
copies of every rule to choose between. They stay in one language; translate one
if the audience changes, do not duplicate it.

---

## Magyar változat

Ez a repó `v1.0.0` óta a szokásos nyílt forrású gyakorlatot követi: beszédes
commitok, szemantikus verziózás, minden kiadás mögött CHANGELOG-bejegyzés.

### Verziózás — [SemVer](https://semver.org/lang/hu/)

| változás | verzió |
|---|---|
| visszafelé kompatibilis hibajavítás | **PATCH** — `1.0.1` |
| új, visszafelé kompatibilis képesség | **MINOR** — `1.1.0` |
| törő változás (meglévő hívás máshogy viselkedik) | **MAJOR** — `2.0.0` |

⚠️ **A „törő" a hívó szemszögéből értendő.** Ha egy híd-kérés mezője eltűnik,
más értéket jelent, vagy egy státusz mást kezd jelenteni, az törő — akkor is, ha
a kód szebb lett tőle. A `spawned` jelentésének megváltoztatása például ilyen
volt: a Desktop sikerként olvassa.

### Commit-üzenetek — [Conventional Commits](https://www.conventionalcommits.org/)

```
<típus>(<hatókör>): <mit csinál, felszólító módban>

<miért — a tünet és a mérés, ne a kód átmesélése>

Co-Authored-By: …
```

Típusok: `fix`, `feat`, `docs`, `test`, `refactor`, `chore`, `perf`.
Hatókör: a komponens (`bridge`, `fork`, `spawner`, `watchdog`, `tests`).

**A törzs a fontos.** A „mit" kiolvasható a diffből; a „miért" nem. Ha egy
javítás mögött éles hiba áll, oda tartozik a **tünet, a mérés és a dátum** —
ebben a repóban több javítás azért maradt helyes, mert a következő olvasó
megértette, milyen mérésből született. Például: *„egy 1796 karakteres promptból
774 érkezett meg, szóközépen kezdve"* többet mond, mint *„darabolva küldjük"*.

### Ágak

- `main` — mindig zöld (CI), mindig kiadható
- munka: `fix/<rövid-név>` vagy `feat/<rövid-név>` ágon, PR-rel, squash-merge-dzsel
- ⚠️ **`main`-en soha `amend`/`rebase`/`reset`, amíg agent fut.** Egy
  gyökér-commit amendje szülő nélküli új commitot hoz létre, amitől a futó
  agentek worktree-ágai árvává válnak: `refusing to merge unrelated histories`.
  Ez egy teljes regressziós kört buktatott el 2026-08-31-én.

### Kiadás

1. `CHANGELOG.md` — új szakasz a verzióval és a dátummal, *Javítva* / *Hozzáadva*
   bontásban, a felhasználó szemszögéből
2. a teszt-darabszám frissítése a CHANGELOG-ban és a `README.md`-ben
3. `git tag -a vX.Y.Z -m "…"` a kiadandó commitra, majd `git push origin vX.Y.Z`
4. `gh release create vX.Y.Z --notes-file <a CHANGELOG szakasza>`

### Tesztelés

`./tests/smoke.sh` — minden pusholásnál CI-ben is fut.

⚠️ **Új állítás mutációs próba nélkül nem hihető.** Rontsd el szándékosan a
kódot, és nézd meg, tényleg elbukik-e. Ebben a repóban többször fordult elő,
hogy egy friss állítás üresjáratban volt zöld:

- a minta a **kommentre** illeszkedett, nem a kódsorra
- a `grep -qv X` azt jelenti, hogy *„van sor X nélkül"* — nem azt, hogy egyik
  sem tartalmazza
- a `jq -e` az **üres sztringet** is igaznak veszi
- a teszt a logika **saját másolatát** mérte a tesztfájlban, nem a valódi kódot
- a példa-név **kitalált** volt, miközben élesben prefixelt alak érkezik

Az élesben mérhető dolgokra ott a `tests/REGRESSION-RUN.md` — a füst-teszt azt
fedi, ami izoláltan mérhető, a regresszió azt, ami csak futás közben.

### Kétnyelvű dokumentáció

Minden **olvasásra** szánt dokumentum kétnyelvű: **elöl az angol, alul egy
`## Magyar változat` szakasz** ugyanazzal a tartalommal — `README.md`,
`CHANGELOG.md`, `CONTRIBUTING.md`, `ROADMAP.md`, `TODO.md`, `DEVELOPMENT.md`,
`bridge-README.md`. Az a pull request, amelyik csak az egyik nyelven ad hozzá
szakaszt, hiányos.

Ugyanez áll a Telegramra: a felhasználónak szóló szöveg nem a hívás helyére
kerül, hanem a `bin/_bridge-lib.sh` `BRIDGE_MSG` katalógusába, és onnan jön a
`t <kulcs>` hívással (lásd a `lang` beállítást).

⚠️ **A kivétel a prompt-anyag, és ez szándékos.** A slash-parancs fájlokat
(`new-agent.md`, `close-agent.md`, `kill-agent.md`, `kill-all-exit.md`,
`fork.md`), a `desktop-skill/agent-bridge/SKILL.md`-t és a két regressziós
forgatókönyvet nem ember olvassa — egy agent kontextusába töltődnek be
utasításként. A duplázás megduplázná ezt a kontextust, és az agent minden
szabályból két példány közül választhatna. Ezek egynyelvűek maradnak: ha változik
a közönség, fordítsd le az egyiket, de ne duplázd.
