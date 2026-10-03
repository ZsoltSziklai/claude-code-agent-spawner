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
)

# Érvényes-e a modell-megadás? A `[1m]` context-utótagot MINDEN megadáson
# engedjük — aliason is. 2026-10-03-án MIND A 13 kombinációra lemérve működik
# (`opus[1m]`, `haiku[1m]`, `claude-fable-5[1m]`, `claude-haiku-4-5[1m]` is).
# Korábban csak az Opus/Sonnet rögzített azonosítóin volt engedve, ami
# indokolatlanul szűk volt: a `/fork --model 'opus[1m]'` érvényes kérést utasított
# el. Ezért a levágás MINDKÉT lista ellenőrzése ELŐTT történik.
agent_model_valid() {
  local m="${1-}"
  [[ -n "$m" ]] || return 1
  m="${m%\[1m\]}"
  [[ -n "${CLAUDE_AGENT_MODEL_ALIASES[(r)$m]-}" ]] && return 0
  [[ -n "${CLAUDE_AGENT_MODEL_IDS[(r)$m]-}" ]]
}
