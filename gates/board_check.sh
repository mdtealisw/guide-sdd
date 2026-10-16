#!/usr/bin/env sh
# board_check - the stage board (board.file) and the Mode B backlog agree.
#
# The backlog is the item store; the board holds only sprint membership, GUIDE stage and owner
# (board/README.md). Drift = a board item that is not in the backlog, an open board item whose backlog
# item is shipped, or a done board item whose backlog item is still open. board/board.mjs `done` closes
# both in one run; this gate catches every other path (a hand edit, a renumbered row, a lost write).
#
# Backlog (foldCheck.backlogRoot, or board.store.root): a DIRECTORY holds one file per item - key = the
# first unit-id in the file name, closed = a `shipped:` line. A FILE holds one item per row - a ##-####
# heading or a top-level "- " bullet led by the unit-id (after any * _ [ ( ); a bullet runs over its
# indented lines, a heading to the next heading or row; closed = a `shipped:` line in the row, or the
# row sits in board.store.closed. The first occurrence of a key wins. Same rules as board.mjs.
#
# --ship <KEY>: also require KEY on the board as done AND closed in the backlog (the record-ship step).
#
# OPTIONAL: board.file unset PASSes with "not configured" (Mode A: the tracker is the board).
# Exit 0 PASS, 1 FAIL (drift), 2 config error.
# Usage:  sh gates/board_check.sh [--config gates/gates.config.json] [--ship <KEY>]

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/_common.sh"

GATE=board_check
require_jq "$GATE"

CFG="gates/gates.config.json"
SHIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CFG="$2"; shift 2 ;;
    --config=*) CFG="${1#--config=}"; shift ;;
    --ship) SHIP="$2"; shift 2 ;;
    --ship=*) SHIP="${1#--ship=}"; shift ;;
    *) echo "FAIL $GATE: unknown argument $1"; exit 2 ;;
  esac
done

[ -f "$CFG" ] || { echo "FAIL $GATE: cannot read config $CFG: no such file"; exit 2; }

BOARD=$(read_cfg "$CFG" '.board.file' '')
if [ -z "$BOARD" ]; then
  echo "PASS $GATE: not configured (board.file unset)."
  exit 0
fi
[ -f "$BOARD" ] || { echo "FAIL $GATE: board.file $BOARD does not exist - run: node sdd/board/board.mjs init"; exit 2; }

ROOT=$(read_cfg "$CFG" '.board.store.root' '')
[ -n "$ROOT" ] || ROOT=$(read_cfg "$CFG" '.foldCheck.backlogRoot' 'backlog')
CLOSED=$(read_cfg "$CFG" '.board.store.closed' '')
UNIT_RAW=$(read_cfg "$CFG" '.unitIdRegex' '\b[A-Z]{2,}-\d+\b')
check_regex "$GATE" unitIdRegex "$UNIT_RAW" || exit 2
UNIT_RE=$(to_awk_ere "$UNIT_RAW")
UNIT_WB=$(had_word_boundary "$UNIT_RAW")

BOARD_ITEMS=$(jq -r '.items[]? | "\(.k)\t\(.stage)"' "$BOARD" 2>/dev/null) || { echo "FAIL $GATE: $BOARD is not valid board JSON"; exit 2; }

# store_rows <mode> <file...>: "<key>\topen|closed" per item. mode=name keys a file by its name and
# closes it on a shipped: line; mode=rows parses rows; mode=closedrows marks every row closed.
store_rows() {
  mode=$1; shift
  awk -v mode="$mode" -v unit="$UNIT_RE" -v wb="$UNIT_WB" '
  function isword(c) { return (c ~ /[A-Za-z0-9_]/) }
  # first boundary-aware match of unit in s; sets K, returns its start (0 = none).
  function umatch(s,   base, tail, ms, me, b, a) {
    base = 1
    while (1) {
      tail = substr(s, base)
      if (!match(tail, unit)) return 0
      ms = base + RSTART - 1; me = ms + RLENGTH - 1
      b = (ms > 1) ? substr(s, ms - 1, 1) : ""; a = (me < length(s)) ? substr(s, me + 1, 1) : ""
      if (wb != 1 || ((b == "" || !isword(b)) && (a == "" || !isword(a)))) { K = substr(s, ms, RLENGTH); return ms }
      base = ms + 1
      if (base > length(s)) return 0
    }
  }
  function emit() { if (cur != "") print cur "\t" ((shipped || mode == "closedrows") ? "closed" : "open"); cur = ""; shipped = 0 }
  FNR == 1 {
    if (mode == "name") {
      emit()
      n = FILENAME; sub(/^.*\//, "", n)
      if (umatch(n)) cur = K
    } else emit()
  }
  {
    line = $0; sub(/\r$/, "", line)
    if (mode == "name") { if (tolower(line) ~ /^[ \t]*[-*]?[ \t]*shipped[: \t]/) shipped = 1; next }
    if (match(line, /^(##|###|####|-)[ \t]+[*_[( \t]*/)) {
      lead = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1)
      if (umatch(rest) == 1 && (wb != 1 || lead == "" || !isword(substr(lead, length(lead), 1)))) {
        emit(); cur = K; kind = (substr(line, 1, 1) == "#") ? "h" : "b"; next
      }
    }
    if (line ~ /^#/) { emit(); next }
    if (cur != "") {
      if (kind == "b" && line !~ /^[ \t]+[^ \t]/) { emit(); next }
      if (tolower(line) ~ /^[ \t]*[-*]?[ \t]*shipped[: \t]/) shipped = 1
    }
  }
  END { emit() }' "$@"
}

if [ -d "$ROOT" ]; then
  set -- "$ROOT"/*.md
  if [ -f "$1" ]; then STORE=$(store_rows name "$@"); else STORE=""; fi
elif [ -f "$ROOT" ]; then
  STORE=$(store_rows rows "$ROOT")
  if [ -n "$CLOSED" ] && [ -f "$CLOSED" ]; then STORE="$STORE
$(store_rows closedrows "$CLOSED")"; fi
else
  echo "FAIL $GATE: no backlog at $ROOT (board.store.root / foldCheck.backlogRoot)"; exit 2
fi
STORE=$(printf '%s\n' "$STORE" | awk -F '\t' 'NF == 2 && !seen[$1]++')

DRIFT=$(printf '%s\n' "$BOARD_ITEMS" | awk -F '\t' -v store="$STORE" -v ship="$SHIP" '
  BEGIN { n = split(store, s, "\n"); for (i = 1; i <= n; i++) { split(s[i], f, "\t"); if (f[1] != "") st[f[1]] = f[2] } }
  NF >= 2 {
    k = $1; done = ($2 == "done"); onb[k] = $2
    if (!(k in st)) print k "\ton board but not in the backlog -> board.mjs remove " k
    else if (!done && st[k] == "closed") print k "\tboard-open but shipped in the backlog -> board.mjs check --fix"
    else if (done && st[k] == "open") print k "\tboard-done but the backlog item is still open -> board.mjs done " k " \"<note>\""
  }
  END {
    if (ship == "") exit
    if (!(ship in onb)) print ship "\tshipped item not on the board -> board.mjs done " ship " \"<note>\""
    else if (onb[ship] != "done") print ship "\tshipped item not done on the board (stage " onb[ship] ") -> board.mjs done " ship " \"<note>\""
    if ((ship in st) && st[ship] == "open") print ship "\tshipped item still open in the backlog -> board.mjs done " ship " \"<note>\""
    else if (!(ship in st)) print ship "\tshipped item not in the backlog"
  }' | awk -F '\t' '!seen[$0]++')

N_ITEMS=$(printf '%s\n' "$BOARD_ITEMS" | sed '/^$/d' | wc -l | tr -d ' ')
N_DRIFT=$(printf '%s\n' "$DRIFT" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$N_DRIFT" -eq 0 ]; then
  if [ -n "$SHIP" ]; then echo "PASS $GATE: $N_ITEMS board item(s), no drift; $SHIP done on the board and closed in the backlog."
  else echo "PASS $GATE: $N_ITEMS board item(s), no drift."; fi
  exit 0
fi
echo "FAIL $GATE: $N_DRIFT drift between $BOARD and the backlog."
printf '%s\n' "$DRIFT" | sed '/^$/d' | while IFS="$(printf '\t')" read -r k why; do
  echo "  DRIFT $k  $why"
done
exit 1
