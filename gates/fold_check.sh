#!/usr/bin/env bash
# fold_check — every clause changed in this ship carries a resolving provenance pin.
#
# Generic, MODE-BLIND gate (works identically for Mode A external tracker and Mode B
# on-disk backlog). Enforces the fold-on-ship invariant at ship time: every spec clause
# touched by this change is pinned (§X per <unit-id>, YYYY-MM-DD) and the unit-id resolves.
#
# Resolution of <unit-id>:
#   * Mode B (default): under foldCheck.backlogRoot, a file or dir named <unit-id>*, or a
#     heading / anchor (id=, name=, {#..}) naming the unit inside any file. backlogRoot may
#     also name a single backlog file (one heading per item).
#   * Mode A: if foldCheck.resolveCmd is set ({unit} substituted) it is run; exit 0 = resolves.
#   * Neither a resolver nor backlogRoot on disk -> "syntactically valid unit-id" + a NOTE.
#
# A clause is its DEFINITION SPAN: from the line that defines it (an id="X.N" / name= /
# {#X.N} anchor, or a Markdown heading / list / table / bold line that starts with the id)
# up to the next definition or heading. A clause-id merely cited in prose defines nothing.
# A clause is checked when its span overlaps a line changed since baseRef (git diff -U0),
# and one pin anywhere in the span covers it. A shard with no definitions at all falls
# back to every clause-id line (pin on it or the next line), with a NOTE.
#
# FAIL CLOSED if git present but base unresolvable (exit 2). git-absent -> all clauses of
# all shards + NOTE. Exit 0 PASS, 1 FAIL, 2 config/usage error.
#
# --strict: when a resolver IS configured (foldCheck.resolveCmd) but ERRORS or returns
# non-zero, treat the unit as UNRESOLVED (FAIL) instead of degrading to "syntactic pin +
# NOTE". CI MUST run with --strict so an offline/broken resolver cannot fail open. Without
# --strict the degrade-with-NOTE convenience is kept (local/offline). The "no resolver
# configured at all" syntactic-only path is unchanged in both modes.
#
# Usage:  sh gates/fold_check.sh [--config gates/gates.config.json] [--base <ref>] [--strict]

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/_common.sh"

GATE=fold_check
require_jq "$GATE"

CFG="gates/gates.config.json"
BASE=""
STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CFG="$2"; shift 2 ;;
    --config=*) CFG="${1#--config=}"; shift ;;
    --base) BASE="$2"; shift 2 ;;
    --base=*) BASE="${1#--base=}"; shift ;;
    --strict) STRICT=1; shift ;;
    *) BASE="$1"; shift ;;
  esac
done

[ -f "$CFG" ] || { echo "FAIL $GATE: cannot read config $CFG: no such file"; exit 2; }

[ -n "$BASE" ] || BASE=$(read_cfg "$CFG" '.baseRef' 'main')

GIT_OK=0
command -v git >/dev/null 2>&1 && GIT_OK=1

# base_state: git missing -> 'absent'; else base must resolve or FAIL CLOSED (exit 2).
if [ "$GIT_OK" = 1 ]; then
  git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 || {
    echo "FAIL $GATE: baseRef '$BASE' does not resolve - set baseRef to the ship base."
    exit 2
  }
fi

SPEC_GLOB=$(read_cfg "$CFG" '.paths.spec' 'spec/**/*.body.md')
CLAUSE_RAW=$(read_cfg "$CFG" '.clauseIdRegex' '\b[A-Z]{2,}\.\d+\b')
CLAUSE_RE=$(to_awk_ere "$CLAUSE_RAW")          # awk: \b stripped, boundary via wmatch
CLAUSE_WB=$(had_word_boundary "$CLAUSE_RAW")
UNIT_RE=$(to_awk_ere "$(read_cfg "$CFG" '.unitIdRegex' '\b[A-Z]+-\d+\b')")
# pin: \bper\s+(<unit>)\s*,\s*\d{4}-\d{2}-\d{2}  (leading \b dropped for awk; 'per' is
# preceded by '(' or whitespace in real pins, so the boundary is implied by context).
PIN_RE="per[[:space:]]+(${UNIT_RE})[[:space:]]*,[[:space:]]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"

# All spec shards (normalised, forward-slashed).
ALL_SHARDS=$(expand_globs "$SPEC_GLOB")

# changed_lines: "<path>\t<line>" for every new-side line changed vs base (git diff -U0).
# A pure deletion marks the lines on both sides of the cut. Git absent -> ALL.
chg_lines() {
  git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$@" 2>/dev/null \
    | awk '
      /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); sub(/^"/, "", f); sub(/"$/, "", f)
                   if (f == "/dev/null") f = ""; else sub(/^b\//, "", f); next }
      /^@@ / && f != "" {
        if (!match($0, /\+[0-9]+(,[0-9]+)?/)) next
        h = substr($0, RSTART + 1, RLENGTH - 1); n = split(h, a, ",")
        c = a[1] + 0; d = (n > 1) ? a[2] + 0 : 1
        if (d == 0) { print f "\t" c; print f "\t" (c + 1) }
        else for (k = c; k < c + d; k++) print f "\t" k
      }'
  return 0
}

ALLMODE=0
if [ "$GIT_OK" = 0 ]; then
  echo "NOTE $GATE: git unavailable - checking ALL spec shards."
  ALLMODE=1
else
  if git diff --quiet --no-ext-diff "$BASE...HEAD" >/dev/null 2>&1 || [ $? -eq 1 ]; then
    CHG=$(chg_lines "$BASE...HEAD")
  elif git diff --quiet --no-ext-diff "$BASE" >/dev/null 2>&1 || [ $? -eq 1 ]; then
    CHG=$(chg_lines "$BASE")
  else
    echo "NOTE $GATE: git unavailable - checking ALL spec shards."
    ALLMODE=1
  fi
fi

if [ "$ALLMODE" = 1 ]; then
  FILES="$ALL_SHARDS"
else
  # intersect changed files with all shards (POSIX sh: no process substitution)
  FILES=$(printf '%s\n' "$CHG" | cut -f1 | sed '/^$/d' | sort -u \
    | awk -v t="$ALL_SHARDS" 'BEGIN { n = split(t, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") s[a[i]] = 1 } NF && ($0 in s)')
fi

FILES=$(printf '%s\n' "$FILES" | sed '/^$/d' | sort -u)
if [ -z "$FILES" ]; then
  echo "PASS $GATE: no spec shards changed this ship."
  exit 0
fi

N_FILES=$(printf '%s\n' "$FILES" | sed '/^$/d' | wc -l | tr -d ' ')

# Scan each changed shard: find clause definitions and their spans; a span that overlaps a
# changed line needs a pin somewhere in it. Emit UNPIN / UNIT (newest pin's unit) / FALLBACK.
WORK=$(printf '%s\n' "$FILES" | while IFS= read -r f; do
  [ -z "$f" ] && continue
  if [ "$ALLMODE" = 1 ]; then
    CL="ALL"
  else
    CL=$(printf '%s\n' "$CHG" | awk -F '\t' -v f="$f" '$1 == f { printf ",%s", $2 } END { printf "," }')
  fi
  awk -v clause="$CLAUSE_RE" -v wb="$CLAUSE_WB" -v pin="$PIN_RE" -v file="$f" -v changed="$CL" -v SQ="'" '
  function isword(c) { return (c ~ /[A-Za-z0-9_]/) }
  # boundary-aware match (awk lacks \b); sets WSTART/WLEN.
  function wmatch(s, re, off,   tail, base, ms, me, before, after) {
    base = off
    while (1) {
      tail = substr(s, base)
      if (!match(tail, re)) { WSTART = 0; WLEN = 0; return 0 }
      ms = base + RSTART - 1; me = ms + RLENGTH - 1
      if (wb != 1) { WSTART = ms; WLEN = RLENGTH; return WSTART }
      before = (ms > 1) ? substr(s, ms - 1, 1) : ""
      after  = (me < length(s)) ? substr(s, me + 1, 1) : ""
      if ((before == "" || !isword(before)) && (after == "" || !isword(after))) {
        WSTART = ms; WLEN = RLENGTH; return WSTART
      }
      base = ms + 1
      if (base > length(s)) { WSTART = 0; WLEN = 0; return 0 }
    }
  }
  function addid(v) { if (v != "" && !((" " v " ") in seenid)) { seenid[" " v " "] = 1; ids = ids (ids == "" ? "" : " ") v } }
  function isclause(v) { return match(v, "^(" clause ")$") }
  # defs(line): space-separated clause-ids this line DEFINES (anchors, then a leading id).
  function defs(line,   rest, seg, v, pre, after, nx) {
    ids = ""; delete seenid
    rest = line
    while (match(rest, "(id|name)[ \t]*=[ \t]*(\"[^\"]*\"|" SQ "[^" SQ "]*" SQ ")")) {
      seg = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
      v = seg; sub("^(id|name)[ \t]*=[ \t]*", "", v); v = substr(v, 2, length(v) - 2)
      if (isclause(v)) addid(v)
    }
    rest = line
    while (match(rest, /\{#[^} \t]+\}/)) {
      v = substr(rest, RSTART + 2, RLENGTH - 3); rest = substr(rest, RSTART + RLENGTH)
      if (isclause(v)) addid(v)
    }
    match(line, /^[ \t]*(#+[ \t]+|[-*+][ \t]+|[0-9]+[.)][ \t]+|[|][ \t]*)?[*_]*/)
    pre = substr(line, 1, RLENGTH); after = substr(line, RLENGTH + 1)
    if (match(after, "^(" clause ")")) {
      v = substr(after, 1, RLENGTH); nx = substr(after, RLENGTH + 1, 1)
      if (wb != 1 || ((pre == "" || !isword(substr(pre, length(pre), 1))) && (nx == "" || !isword(nx)))) addid(v)
    }
    return ids
  }
  function heading(line) { return (line ~ /^[ \t]*#+[ \t]/ || line ~ /<[hH][1-6][ \t>]/) }
  { lines[NR] = $0 }
  END {
    nd = 0
    for (i = 1; i <= NR; i++) { d = defs(lines[i]); if (d != "") { nd++; dl[nd] = i; di[nd] = d } }
    fb = 0
    if (nd == 0) {
      for (i = 1; i <= NR; i++) {
        d = ""; delete seenid; ids = ""; off = 1
        while (wmatch(lines[i], clause, off) > 0) { addid(substr(lines[i], WSTART, WLEN)); off = WSTART + (WLEN > 0 ? WLEN : 1) }
        if (ids != "") { nd++; dl[nd] = i; di[nd] = ids; fb = 1 }
      }
      if (fb) print "FALLBACK\t" file
    }
    for (k = 1; k <= nd; k++) {
      s = dl[k]
      if (fb) e = (s + 1 <= NR) ? s + 1 : NR
      else {
        e = (k < nd) ? dl[k + 1] - 1 : NR
        for (j = s + 1; j <= e; j++) if (heading(lines[j])) { e = j - 1; break }
      }
      touched = (changed == "ALL")
      for (j = s; j <= e && !touched; j++) if (index(changed, "," j ",")) touched = 1
      if (!touched) continue
      text = ""
      for (j = s; j <= e; j++) text = text (j > s ? " " : "") lines[j]
      best = ""; bunit = ""; rest = text
      while (match(rest, pin)) {
        seg = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        dt = substr(seg, length(seg) - 9)
        u = seg; sub(/^per[[:space:]]+/, "", u); sub(/[[:space:]]*,.*$/, "", u)
        if (best == "" || dt >= best) { best = dt; bunit = u }
      }
      n = split(di[k], idl, " ")
      for (m = 1; m <= n; m++) {
        if (bunit != "") print "UNIT\t" bunit
        else if (!(idl[m] in reported)) { reported[idl[m]] = 1; print "UNPIN\t" file "\t" idl[m] }
      }
    }
  }' "$f"
done)

printf '%s\n' "$WORK" | grep '^FALLBACK' | cut -f2 | while IFS= read -r f; do
  echo "NOTE $GATE: no clause definitions in $f - each clause-id line needs a pin on it or the next line."
done
UNPINNED=$(printf '%s\n' "$WORK" | grep '^UNPIN' || true)
SEEN_UNITS=$(printf '%s\n' "$WORK" | grep '^UNIT' | cut -f2 | sort -u | sed '/^$/d')

# Resolve each seen unit-id.
RESOLVE_CMD=$(read_cfg "$CFG" '.foldCheck.resolveCmd' '')
BACKLOG_ROOT=$(read_cfg "$CFG" '.foldCheck.backlogRoot' 'backlog')

# names_unit <unit> <path>: some file at/under <path> has a heading or anchor naming <unit>.
names_unit() {
  find "$2" -type f -exec awk -v u="$1" -v SQ="'" '
    function hasword(s,   off, p, b, a) {
      off = 0
      while ((p = index(substr(s, off + 1), u)) > 0) {
        p += off; b = (p > 1) ? substr(s, p - 1, 1) : ""; a = substr(s, p + length(u), 1)
        if (b !~ /[A-Za-z0-9_]/ && a !~ /[A-Za-z0-9_]/) return 1
        off = p
      }
      return 0
    }
    (/^[ \t]*#+[ \t]/ && hasword($0)) ||
    index($0, "id=\"" u "\"") || index($0, "id=" SQ u SQ) ||
    index($0, "name=\"" u "\"") || index($0, "name=" SQ u SQ) ||
    index($0, "{#" u "}") { print "HIT"; exit }' {} + 2>/dev/null | grep -q HIT
}

UNRESOLVED=""
if [ -n "$SEEN_UNITS" ]; then
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    if [ -n "$RESOLVE_CMD" ]; then
      cmd=$(printf '%s' "$RESOLVE_CMD" | sed "s/{unit}/$unit/g")
      if sh -c "$cmd" >/dev/null 2>&1; then
        :
      elif [ "$STRICT" = 1 ]; then
        # Strict: a configured resolver that errors / returns non-zero is UNRESOLVED.
        echo "FAIL $GATE: resolveCmd errored for $unit - strict mode treats this as unresolved."
        UNRESOLVED="$UNRESOLVED$unit	resolveCmd did not resolve it
"
      else
        # Non-strict: degrade to the syntactic pin + NOTE (local/offline convenience).
        echo "NOTE $GATE: resolveCmd failed for $unit - accepting syntactic pin."
      fi
    elif [ -d "$BACKLOG_ROOT" ]; then
      # Mode B: a file/dir named <unit>* directly under backlogRoot, or a heading/anchor in a file.
      if ls -d "$BACKLOG_ROOT/$unit"* >/dev/null 2>&1 || names_unit "$unit" "$BACKLOG_ROOT"; then
        :
      else
        UNRESOLVED="$UNRESOLVED$unit	no $BACKLOG_ROOT/$unit* file and no heading or anchor naming it under $BACKLOG_ROOT/
"
      fi
    elif [ -f "$BACKLOG_ROOT" ]; then
      # Mode B, single-file backlog: a heading/anchor naming the unit inside backlogRoot.
      if names_unit "$unit" "$BACKLOG_ROOT"; then
        :
      else
        UNRESOLVED="$UNRESOLVED$unit	no heading or anchor naming it in $BACKLOG_ROOT
"
      fi
    else
      echo "NOTE $GATE: no resolver and no $BACKLOG_ROOT/ - accepting syntactic pin for $unit."
    fi
  done <<EOF
$SEEN_UNITS
EOF
fi

UNRESOLVED=$(printf '%s' "$UNRESOLVED" | sed '/^$/d')

N_UNPIN=$(printf '%s\n' "$UNPINNED" | sed '/^$/d' | grep -c . || true)
N_UNRES=$(printf '%s\n' "$UNRESOLVED" | sed '/^$/d' | grep -c . || true)

if [ "$N_UNPIN" -eq 0 ] && [ "$N_UNRES" -eq 0 ]; then
  echo "PASS $GATE: $N_FILES changed shard(s); all changed clauses pinned and resolved."
  exit 0
fi

echo "FAIL $GATE: $N_UNPIN unpinned clause(s), $N_UNRES unresolved unit(s)."
printf '%s\n' "$UNPINNED" | sed '/^$/d' | while IFS="$(printf '\t')" read -r _tag file cid; do
  echo "  UNPINNED $cid  in $file  (add: (§... per <unit-id>, YYYY-MM-DD))"
done
printf '%s\n' "$UNRESOLVED" | sed '/^$/d' | while IFS="$(printf '\t')" read -r unit why; do
  echo "  UNRESOLVED-UNIT $unit  ($why)"
done
exit 1
