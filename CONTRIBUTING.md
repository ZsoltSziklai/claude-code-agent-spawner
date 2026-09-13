# Fejlesztési munkafolyamat

Ez a repó `v1.0.0` óta a szokásos nyílt forrású gyakorlatot követi: beszédes
commitok, szemantikus verziózás, minden kiadás mögött CHANGELOG-bejegyzés.

## Verziózás — [SemVer](https://semver.org/lang/hu/)

| változás | verzió |
|---|---|
| visszafelé kompatibilis hibajavítás | **PATCH** — `1.0.1` |
| új, visszafelé kompatibilis képesség | **MINOR** — `1.1.0` |
| törő változás (meglévő hívás máshogy viselkedik) | **MAJOR** — `2.0.0` |

⚠️ **A „törő" a hívó szemszögéből értendő.** Ha egy híd-kérés mezője eltűnik,
más értéket jelent, vagy egy státusz mást kezd jelenteni, az törő — akkor is, ha
a kód szebb lett tőle. A `spawned` jelentésének megváltoztatása például ilyen
volt: a Desktop sikerként olvassa.

## Commit-üzenetek — [Conventional Commits](https://www.conventionalcommits.org/)

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

## Ágak

- `main` — mindig zöld (CI), mindig kiadható
- munka: `fix/<rövid-név>` vagy `feat/<rövid-név>` ágon, PR-rel, squash-merge-dzsel
- ⚠️ **`main`-en soha `amend`/`rebase`/`reset`, amíg agent fut.** Egy
  gyökér-commit amendje szülő nélküli új commitot hoz létre, amitől a futó
  agentek worktree-ágai árvává válnak: `refusing to merge unrelated histories`.
  Ez egy teljes regressziós kört buktatott el 2026-08-31-én.

## Kiadás

1. `CHANGELOG.md` — új szakasz a verzióval és a dátummal, *Javítva* / *Hozzáadva*
   bontásban, a felhasználó szemszögéből
2. a teszt-darabszám frissítése a CHANGELOG-ban és a `README.md`-ben
3. `git tag -a vX.Y.Z -m "…"` a kiadandó commitra, majd `git push origin vX.Y.Z`
4. `gh release create vX.Y.Z --notes-file <a CHANGELOG szakasza>`

## Tesztelés

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
