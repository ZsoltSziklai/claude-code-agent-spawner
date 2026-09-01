#!/bin/zsh
# merge-sessions.sh — join two Claude Code session transcripts into one
# resumable session, so a restart doesn't cut the history in half.
#
#   merge-sessions.sh <older-session-id> <newer-session-id> [project-dir] [out-id]
#
# A transcript is JSONL: one record per line, conversation records linked by
# uuid/parentUuid, every record tagged with sessionId. Merging = concatenate
# older+newer, stamp every record with ONE new sessionId, and re-point the
# newer transcript's root record at the older transcript's chain tail.
#
# The inputs are never modified — the result is a NEW <out-id>.jsonl next to
# them, so the originals stay resumable if anything looks off.
#
# Caveat, deliberately not hidden: this is not an operation Claude Code itself
# offers. Conversation records merge cleanly (they are a plain linked list),
# but bookkeeping records (file-history-snapshot, attachment, queue-operation)
# reference per-session state that cannot be made coherent across the join.
# They are carried over as-is. Verify the merged session before relying on it.
emulate -L zsh
setopt err_exit nounset pipefail

OLD_ID="${1:?usage: $0 <older-session-id> <newer-session-id> [project-dir] [out-id]}"
NEW_ID="${2:?usage: $0 <older-session-id> <newer-session-id> [project-dir] [out-id]}"
PROJ="${3:-$HOME/.claude/projects/-Users-$(whoami)-ClaudeProjects}"
OUT_ID="${4:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"

OLD_F="$PROJ/$OLD_ID.jsonl"
NEW_F="$PROJ/$NEW_ID.jsonl"
OUT_F="$PROJ/$OUT_ID.jsonl"

for f in "$OLD_F" "$NEW_F"; do
  [[ -r "$f" ]] || { print -u2 "ERROR: not readable: $f"; exit 1; }
done
[[ -e "$OUT_F" ]] && { print -u2 "ERROR: output already exists: $OUT_F"; exit 1; }

# Chain tail of the older transcript = last conversation record in file order.
LINK=$(jq -r 'select(.uuid and (.type == "user" or .type == "assistant")) | .uuid' "$OLD_F" | tail -1)
[[ -n "$LINK" ]] || { print -u2 "ERROR: no conversation records in $OLD_F"; exit 1; }

TMP="$OUT_F.partial"
trap 'rm -f "$TMP"' EXIT

# 1) older transcript — restamp sessionId only.
jq -c --arg sid "$OUT_ID" '.sessionId = $sid' "$OLD_F" > "$TMP"

# 2) newer transcript — restamp sessionId, and re-point ONLY its first root
#    conversation record (parentUuid == null) at the older chain tail. Later
#    roots, if any, are sidechains and must keep their own structure.
jq -c -s --arg sid "$OUT_ID" --arg link "$LINK" '
  [ .[] | .sessionId = $sid ] as $rows
  | ( $rows
      | map(.parentUuid == null and (.type == "user" or .type == "assistant"))
      | index(true) ) as $root
  | [ $rows
      | to_entries[]
      | if .key == $root then (.value | .parentUuid = $link) else .value end ]
  | .[]
' "$NEW_F" >> "$TMP"

# ---- validation: refuse to hand back a transcript we cannot vouch for ------
old_n=$(wc -l < "$OLD_F"); new_n=$(wc -l < "$NEW_F"); out_n=$(wc -l < "$TMP")
(( out_n == old_n + new_n )) \
  || { print -u2 "ERROR: line count $out_n != $old_n + $new_n"; exit 1; }

parse_n=$(jq -c . "$TMP" 2>/dev/null | wc -l)
(( parse_n == out_n )) \
  || { print -u2 "ERROR: only $parse_n/$out_n lines parse as JSON"; exit 1; }

stray=$(jq -r --arg sid "$OUT_ID" 'select(.sessionId != null and .sessionId != $sid) | .sessionId' "$TMP" | wc -l)
(( stray == 0 )) \
  || { print -u2 "ERROR: $stray records still carry a foreign sessionId"; exit 1; }

roots=$(jq -r 'select(.parentUuid == null and (.type == "user" or .type == "assistant")) | .uuid' "$TMP" | wc -l)
(( roots == 1 )) \
  || { print -u2 "ERROR: expected exactly 1 conversation root, found $roots"; exit 1; }

# The re-pointed record must reference a uuid that actually exists upstream.
jq -e --arg link "$LINK" 'select(.uuid == $link)' "$TMP" >/dev/null \
  || { print -u2 "ERROR: link target $LINK missing from merged transcript"; exit 1; }

mv "$TMP" "$OUT_F"
trap - EXIT

print "merged   : $OLD_ID + $NEW_ID"
print "linked   : newer root -> $LINK"
print "records  : $old_n + $new_n = $out_n"
print "output   : $OUT_F"
print "resume   : claude --resume $OUT_ID"
