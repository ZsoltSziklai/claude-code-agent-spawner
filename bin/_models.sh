#!/bin/zsh
# _models.sh — a modell-fehérlista EGYETLEN forrása.
#
# ⚠️⚠️ EZ A FÁJL AZÉRT LÉTEZIK, MERT A LISTA HÁROMSZOR VOLT MEG.
# A spawner, a híd és a `fork-agent` külön-külön tartotta ugyanazt a `case`-et, és
# ez többször szétcsúszott. 2026-08-26: csak a spawner kapta meg a Claude 5
# családot, ezért egy híd-kérés vagy `/fork` a TÉNYLEGESEN használt
# `claude-opus-5`-tel elutasításra került. A „három listának egyeznie kell"
# komment nem akadályozta meg — a negyedik szétcsúszást az egyetlen forrás
# akadályozza meg, nem a figyelmeztetés.
#
# Mellékhatás-mentes: csak tömböket és egy függvényt definiál, hogy bárhonnan
# source-olható legyen a betöltési sorrend megzavarása nélkül.

# Alias = „a család legfrissebb modellje". A CLI súgója szerint ezek nem avulnak.
typeset -ga CLAUDE_AGENT_MODEL_ALIASES=(opus sonnet haiku fable)

# Rögzített azonosítók. ⚠️ Csak OLYAN kerüljön ide, amit MÉRTÜNK: a bináris
# `strings`-je sok olyan id-t is tartalmaz, amihez a fiók nem fér hozzá (pl.
# `claude-fable-5-mythos-5` — 2026-10-03-án elutasítva: `unrecognized_model`).
# A próba: `claude --model <id> --permission-mode plan --print 'ok'`.
typeset -ga CLAUDE_AGENT_MODEL_IDS=(
  claude-opus-5-5 claude-sonnet-5-5 claude-fable-5-1       # 2026-10-03, mérve
  claude-opus-5 claude-sonnet-5 claude-fable-5 claude-haiku-4-5
  claude-opus-4-8 claude-opus-4-7
  claude-sonnet-4-5                                        # 2026-10-03, mérve
)

# Érvényes-e a modell-megadás? A `[1m]` context-utótagot MINDEN megadáson
# engedjük — aliason is. 2026-10-03-án MIND A 13 kombinációra lemérve működik
# (`opus[1m]`, `haiku[1m]`, `claude-fable-5[1m]`, `claude-haiku-4-5[1m]` is).
# Korábban csak az Opus/Sonnet rögzített azonosítóin volt engedve, ami
# indokolatlanul szűk volt: a `/fork --model 'opus[1m]'` érvényes kérést utasított
# el. Ezért a levágás MINDKÉT lista ellenőrzése ELŐTT történik.
agent_model_valid() {
  # ⚠️ `localoptions extended_glob`: a lenti datum-minta `(#b)`/`(#c8)` szintaxisa
  # EXTENDED_GLOB-ot igenyel, ami nem alapertelmezes. Enelkul a minta csendben nem
  # illeszkedik, es a fuggveny ERVENYES azonositot utasit el — a sajat tesztemben
  # csak azert mukodott, mert ott kezzel bekapcsoltam. A `localoptions` miatt a
  # hivo shell beallitasa valtozatlan marad.
  setopt localoptions extended_glob
  local m="${1-}"
  [[ -n "$m" ]] || return 1
  m="${m%\[1m\]}"
  [[ -n "${CLAUDE_AGENT_MODEL_ALIASES[(r)$m]-}" ]] && return 0
  [[ -n "${CLAUDE_AGENT_MODEL_IDS[(r)$m]-}" ]] && return 0
  # DATUMOZOTT ALAK: <fehérlistás azonosító>-<YYYYMMDD>[-vN]
  # Egy mero protokoll nem hasznalhat aliast (az sodrodik) es gyakran a napra
  # pontos azonositot irja elo — pl. `claude-haiku-4-5-20251001`. Enelkul a
  # fehérlista ervenyes, meresre alkalmas azonositot utasitott el.
  #
  # ⚠️ A DATUM-RESZT NEM MI IGAZOLJUK, es ez szandekos: a `claude-opus-5-5-20251001`
  # (kitalalt datum) a CLI-nel `unrecognized_model` — a fehérlista dolga a
  # ELIRAS-szures (a CSALAD legyen ismert), a letezes kerdeseben a CLI a hatosag.
  # Egy kitalalt datum tehat atmegy itt, es a spawnnal bukik el, a `failed/`-be
  # kerulve. Ezt vallaljuk: a masik iranyban (egyenkenti felsorolas) minden uj
  # datumnal kodot kellene irni, es a protokoll addig all.
  if [[ "$m" == (#b)(*)-([0-9](#c8))(|-v[0-9]##) ]]; then
    [[ -n "${CLAUDE_AGENT_MODEL_IDS[(r)${match[1]}]-}" ]] && return 0
  fi
  return 1
}

# Tamogatja-e a modell az AUTO jogosultsagi modot?
#
# ⚠️⚠️ A HAIKU NEM. A CLI ilyenkor CSENDBEN MANUAL modra valt: "auto mode
# unavailable for this model" -> "⏸ manual mode on" (merve 2026-10-04, CLI 2.1.289,
# eldobhato sessionnel; ugyanabban a probaban az Opus 5.5 "auto mode on"-t adott).
# A manual mod minden eszkozhasznalat elott engedelyt ker — egy hidon vagy
# kiserletben inditott agentnel ezt SENKI nem olvassa, tehat az elso eszkozhivasnal
# OROKRE megall. Egy kiserlet futtatoja vette eszre; a tervezett 290 Haiku-fork
# mindegyike elakadt volna.
# A szabaly a CLI `FK()` fuggvenyet tukrozi: haiku, claude-opus-4-6,
# claude-sonnet-4-6 -> nem. Ha a CLI valtoztat rajta, itt kell kovetni.
agent_model_supports_auto() {        # $1 = modell
  local m="${1-}"; m="${m%\[1m\]}"
  [[ "$m" == *haiku* ]] && return 1
  [[ "$m" == claude-opus-4-6* || "$m" == claude-sonnet-4-6* ]] && return 1
  return 0
}

# Indithato-e ez a modell ebben a modban? NEM valtunk csendben modot (a CLI mar
# megteszi, es pont az a baj): az ellentmondasos kombinaciot ELUTASITJUK, es
# megmondjuk, mit valasszon a hivo.
agent_perm_check() {                 # $1 = modell, $2 = jogosultsagi mod -> rc + uzenet stderr-re
  if [[ "${2-}" == auto ]] && ! agent_model_supports_auto "${1-}"; then
    print -u2 "a(z) ${1} modell nem támogatja az auto módot: a CLI ilyenkor manual módra vált, ami felügyelet nélkül az első engedélykérésnél örökre megáll. Add meg kifejezetten a jogosultsági módot — felügyelet nélküli futáshoz a dontAsk ajánlott (amit nem engedtél, azt elutasítja, ahelyett hogy várna); ha te válaszolsz a kérdésekre, manual."
    return 1
  fi
  return 0
}
