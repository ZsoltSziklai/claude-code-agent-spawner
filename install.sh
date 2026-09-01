#!/bin/zsh
# install.sh - installs the agent-spawner system
# Run from the bundle directory: zsh install.sh
emulate -L zsh
setopt err_exit nounset pipefail

BUNDLE_DIR="${0:A:h}"   # zsh: absolute path of directory containing this script
QUEUE_DIR="$HOME/.claude/agent-queue"
PLIST_LABEL="local.agent-spawner"
PLIST_DST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
PLIST_TEMPLATE="$BUNDLE_DIR/${PLIST_LABEL}.plist.template"
WATCHDOG_LABEL="local.mac-main-watchdog"
WATCHDOG_PLIST="$HOME/Library/LaunchAgents/${WATCHDOG_LABEL}.plist"
WATCHDOG_TEMPLATE="$BUNDLE_DIR/${WATCHDOG_LABEL}.plist.template"
CMD_DIR="$HOME/.claude/commands"

echo "==> Bundle: $BUNDLE_DIR"

# Boot out + remove launchd labels from earlier installs (pre-local.* naming scheme)
for legacy in "hu.$(whoami).agent-spawner" "hu.$(whoami).mac-main-watchdog"; do
  launchctl bootout "gui/$(id -u)/$legacy" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/${legacy}.plist"
done

echo "==> Checking dependencies"
for bin in jq tmux claude uuidgen; do
  if ! command -v "$bin" >/dev/null; then
    print -u2 "ERROR: '$bin' not found in PATH. Install it first."
    exit 1
  fi
  echo "  ok: $(command -v "$bin")"
done

echo "==> Creating queue directories"
mkdir -p "$QUEUE_DIR"/{new,processing,done,failed,bin,live}
mkdir -p "$HOME/.claude/commands"
mkdir -p "$HOME/Library/LaunchAgents"

echo "==> Installing claude-agent-spawner"
install -m 755 "$BUNDLE_DIR/claude-agent-spawner" "$QUEUE_DIR/bin/claude-agent-spawner"
# clean up old name from any previous install
rm -f "$QUEUE_DIR/bin/spawn-agent.sh"

echo "==> Installing start.sh (source-dir-independent path for the watchdog)"
install -m 755 "$BUNDLE_DIR/start.sh" "$QUEUE_DIR/start.sh"


echo "==> Installing action scripts (bin/*)"
# Minden reguláris fájl a bin/-ből — nem csak a *.sh, mert a fork-agent
# kiterjesztés nélküli (parancsként hívjuk).
for s in "$BUNDLE_DIR"/bin/*(.N); do
  install -m 755 "$s" "$QUEUE_DIR/bin/$(basename "$s")"
done

echo "==> Installing slash commands (/new-agent, /kill-agent, /close-agent, /kill-all-exit, /fork)"
install -m 644 "$BUNDLE_DIR/new-agent.md"      "$CMD_DIR/new-agent.md"
install -m 644 "$BUNDLE_DIR/kill-agent.md"     "$CMD_DIR/kill-agent.md"
install -m 644 "$BUNDLE_DIR/close-agent.md"    "$CMD_DIR/close-agent.md"
install -m 644 "$BUNDLE_DIR/kill-all-exit.md"  "$CMD_DIR/kill-all-exit.md"
install -m 644 "$BUNDLE_DIR/fork.md"           "$CMD_DIR/fork.md"
# clean up old name from any previous install
rm -f "$CMD_DIR/spawn-agent.md"

echo "==> Installing launchd plist (template -> $PLIST_DST)"
sed "s|__HOME__|$HOME|g" "$PLIST_TEMPLATE" > "$PLIST_DST"
chmod 644 "$PLIST_DST"

echo "==> Reloading launchd agent"
# A `bootout` ASZINKRON: a szolgaltatas nem feltetlenul tunt el, mire a rogton
# utana jovo `bootstrap` lefut, es olyankor a bootstrap NEMAN elbukik. 2026-08-29:
# a telepites igy lotte ki a `bridge-poller`-t — a plist kiirodott, a szolgaltatas
# viszont nem toltodott be, es a Telegram-gombnyomas orakon at nem jutott sehova.
# A tunet nem latszott, mert a bootstrap kilepesi kodjat senki nem nezte.
#
# Ezert: megvarjuk a tenyleges kilepest, ujraprobalunk, es a vegen ELLENORIZZUK,
# hogy a szolgaltatas tenyleg betoltodott. Ha nem, HANGOSAN szolunk.
bootstrap_service() {                  # $1 = label, $2 = plist utvonal
  local label="$1" plist="$2" i
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  for i in 1 2 3 4 5; do
    launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1 || break
    sleep 1
  done
  for i in 1 2 3; do
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && break
    sleep 1
  done
  launchctl enable "gui/$(id -u)/${label}" 2>/dev/null || true
  if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
    echo "    ✓ $label betöltve"
  else
    echo "    ✗ $label NEM töltődött be — kézzel: launchctl bootstrap gui/$(id -u) $plist" >&2
    FAILED_SERVICES="${FAILED_SERVICES:-} $label"
  fi
}

bootstrap_service "${PLIST_LABEL}" "$PLIST_DST"

echo "==> Setting up the Desktop bridge"
BRIDGE_DIR="$HOME/ClaudeProjects/bridge"
mkdir -p "$BRIDGE_DIR"/{requests,results,archive}
install -m 644 "$BUNDLE_DIR/bridge-README.md" "$BRIDGE_DIR/README.md"
install -m 644 "$BUNDLE_DIR/bridge-allow.json.example" "$QUEUE_DIR/bridge-allow.json.example"
if [[ ! -e "$QUEUE_DIR/bridge-allow.json" ]]; then
  # Szándékosan NEM töltjük ki: a Telegram user-id személyes adat, nem való a
  # (publikus) repóba. Kitöltetlen config = zárt kapu, nem indul semmi.
  install -m 600 "$BUNDLE_DIR/bridge-allow.json.example" "$QUEUE_DIR/bridge-allow.json"
  echo "    !! $QUEUE_DIR/bridge-allow.json kitöltetlen — a híd addig nem indít semmit"
fi
for L in local.bridge-relay local.bridge-poller; do
  P="$HOME/Library/LaunchAgents/${L}.plist"
  sed "s|__HOME__|$HOME|g" "$BUNDLE_DIR/${L}.plist.template" > "$P"
  chmod 644 "$P"
  bootstrap_service "${L}" "$P"
done

echo "==> Installing watchdog plist (template -> $WATCHDOG_PLIST)"
sed "s|__HOME__|$HOME|g" "$WATCHDOG_TEMPLATE" > "$WATCHDOG_PLIST"
chmod 644 "$WATCHDOG_PLIST"
bootstrap_service "${WATCHDOG_LABEL}" "$WATCHDOG_PLIST"

echo ""
echo "==> Installed. Quick smoke test:"
echo ""
cat <<EOF
  # 1. Trigger a test spawn (will start a real Remote Control session named 'test-spawn'):
  jq -n --arg name "test-spawn" \\
        --arg prompt "Say hello and tell me what time it is." \\
        '{name:\$name, prompt:\$prompt}' \\
        > "$QUEUE_DIR/new/\$(uuidgen).json"

  # 2. Watch the log:
  tail -f "$QUEUE_DIR/spawner.log"

  # 3. Check the spawned tmux session:
  tmux ls | grep agent-

  # 4. Open the Claude mobile app, Code tab - 'test-spawn' should appear.

  # 5. Clean up the test session when done:
  tmux kill-session -t agent-test-spawn


==> Start the main command-center session:
    zsh "$BUNDLE_DIR/start.sh"

==> Inside any 'claude --remote-control' session you can then type:
    /new-agent      - queue a new background Remote Control session
    /close-agent    - close + merge OR drop worktree, then kill
    /kill-agent     - just kill (no merge, no questions)
    /kill-all-exit  - kill ALL agents + exit this session
    /fork           - fork THIS session into a child (fresh by default; --summary/--inherit to pass context)
EOF

# ⚠️ EZ A BLOKK A HEREDOCBA SZORULT (2026-08-31-ig): hianyzo lezaras miatt a
# `cat <<EOF` lenyelte, es a figyelmeztetes SZOVEGKENT irodott ki kod helyett.
# Vagyis a "nem indult el minden szolgaltatas" riasztas SOHA nem szolalt meg,
# es a `set -u` a heredocban levo ${FAILED_SERVICES}-re a telepito vegen
# hibara futott. Azert nem tunt fel, mert a telepito kimenetet /dev/null-ba
# iranyitottam — ugyanaz a hiba, amit 2026-08-29-en mar egyszer elkovettem.
if [[ -n "${FAILED_SERVICES:-}" ]]; then
  echo "" >&2
  echo "⚠️  NEM MINDEN SZOLGÁLTATÁS INDULT EL:${FAILED_SERVICES}" >&2
  echo "    A híd ezek nélkül NEM teljes — poller nélkül a Telegram-gomb nem csinál semmit." >&2
fi
