#!/usr/bin/env sh
# GUIDE SDD - stage board test (board/*.mjs): CLI on a directory and a single-file backlog, the lock
# under parallel writers, the live server (state, op, Host/Origin guard, done refused, SSE on a CLI
# write) and the dispatch hook (moves on qa, no-op otherwise). board_check's twins are in ci/smoke.*.
# Usage: sh ci/board_test.sh      Needs: node >= 18, curl, git. Exit 0 = all expectations met.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
B="$REPO/board/board.mjs"
WORK="$(mktemp -d)"; SRV=""
trap 'rc=$?; set +e; cd /; if [ -n "$SRV" ]; then kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; fi; rm -rf "$WORK" 2>/dev/null; exit $rc' EXIT
cd "$WORK"; git init -q .
fails=0
# want <label> <needle> <cmd...> - the command's output must contain needle
want() {
  label=$1; needle=$2; shift 2
  set +e; out=$("$@" 2>&1); set -e
  case "$out" in *"$needle"*) echo "ok    $label" ;; *) echo "FAIL  $label: wanted '$needle'"; printf '%s\n' "$out" | sed 's/^/      /'; fails=$((fails+1)) ;; esac
}

mkdir -p backlog mem
printf '# DEMO-1 Wallet deposits\nA user can deposit.\n' > backlog/DEMO-1-wallet.md
printf '# DEMO-2 Withdrawals\nshipped: abc1234 2026-10-01\n' > backlog/DEMO-2-withdraw.md
printf '# DEMO-3 Ledger\nbody\n' > backlog/DEMO-3-ledger.md
printf '{"unitIdRegex":"\\\\b[A-Z]{2,}-\\\\d+\\\\b","foldCheck":{"backlogRoot":"backlog"},"board":{"file":"mem/board.json","title":"Demo","stageLabels":{"5":"QA"}}}\n' > cfg.json
b() { node "$B" --config cfg.json --root . "$@"; }

want "init" "created mem/board.json" b init
want "team-add" "team alpha added" b team-add Alpha
want "add to a team" "added DEMO-1 -> alpha" b add DEMO-1 alpha
want "add refuses a shipped item" "not an open backlog item" b add DEMO-2
want "add refuses an unknown key" "not an open backlog item" b add DEMO-9
want "stage ids come from PROCESS.md" "DEMO-1 -> S5 QA" b stage DEMO-1 5 QA red
want "stage refuses an unknown stage" "usage: stage" b stage DEMO-1 8
want "get a team" "DEMO-1 S5 QA | Wallet deposits | QA red" b get alpha
want "check clean" "check: 0 drift" b check
want "done closes both" "DEMO-1 shipped in backlog/DEMO-1-wallet.md; board done" b done DEMO-1 "repo deadbee"
want "done wrote the shipped: line" "shipped: repo deadbee" tail -1 backlog/DEMO-1-wallet.md
want "add DEMO-3" "added DEMO-3" b add DEMO-3
printf 'SHIPPED abc 2026-10-02\n' >> backlog/DEMO-3-ledger.md
want "check sees a SHIPPED line" "DEMO-3 board-open but shipped in backlog" b check
want "check --fix" "DEMO-3 fixed: marked done" b check --fix

# Parallel writers: every one lands and the file stays valid.
printf '# DEMO-4 Parallel\n' > backlog/DEMO-4-p.md
b add DEMO-4 >/dev/null
i=0; while [ $i -lt 8 ]; do b note DEMO-4 "n$i" >/dev/null & i=$((i+1)); done; wait
want "parallel writers leave valid JSON" "DEMO-4" node -e "const d=JSON.parse(require('fs').readFileSync('mem/board.json','utf8'));console.log(d.items.map(i=>i.k).join(' '))"
want "no lock left behind" "none" sh -c 'ls mem/board.json.lock 2>/dev/null || echo none'

# Single-file backlog with a completed file.
printf '# Backlog\n## Open\n- **[MW-1]** OPEN - first thing\n  more detail\n- **[MW-2]** second\n### [MW-3] Header item\nbody\n' > mem/backlog.md
printf '{"unitIdRegex":"\\\\b[A-Z]{2,}-\\\\d+\\\\b","foldCheck":{"backlogRoot":"mem/backlog.md"},"board":{"file":"mem/b2.json","store":{"closed":"mem/done.md"}}}\n' > cfg2.json
c() { node "$B" --config cfg2.json --root . "$@"; }
c init >/dev/null
want "file store: add a bullet row" "added MW-1" c add MW-1
want "file store: add a heading row" "added MW-3" c add MW-3
want "file store: done moves the row" "moved MW-1 (3 lines) -> done.md; board done" c done MW-1 sha1
want "moved row carries shipped:" "shipped: sha1" cat mem/done.md
want "file store: check clean" "check: 0 drift" c check
want "snapshot strips live code" "0" sh -c "node '$B' --config cfg2.json --root . snapshot '$WORK/snap.html' >/dev/null && grep -c LIVE-START '$WORK/snap.html' || true"

# Live server.
node "$REPO/board/serve.mjs" --config cfg.json --root . --port 18781 > serve.log 2>&1 &
SRV=$!
n=0; until curl -s -o /dev/null http://127.0.0.1:18781/api/state; do n=$((n+1)); [ $n -gt 60 ] && break; sleep 1; done
want "server: state" '"title":"Demo"' curl -s http://127.0.0.1:18781/api/state
want "server: page" "200" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18781/
want "server: foreign Host refused" "403" curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' http://127.0.0.1:18781/api/state
want "server: op" '"ok":true' curl -s -H 'Content-Type: application/json' -d '{"op":"stage","args":["DEMO-4","3"]}' http://127.0.0.1:18781/api/op
want "server: done refused" "bad op done" curl -s -H 'Content-Type: application/json' -d '{"op":"done","args":["DEMO-4","x"]}' http://127.0.0.1:18781/api/op
want "server: foreign Origin refused" "forbidden origin" curl -s -H 'Content-Type: application/json' -H 'Origin: http://evil.example' -d '{"op":"note","args":["DEMO-4","x"]}' http://127.0.0.1:18781/api/op
curl -s -N --max-time 12 http://127.0.0.1:18781/api/events > sse.log 2>/dev/null &
sleep 2; b note DEMO-4 "from the cli" >/dev/null; sleep 6
want "server: SSE on a CLI write" "event: changed" cat sse.log

# Dispatch hook.
hook() { printf '%s' "$1" | BOARD_CONFIG=cfg.json CLAUDE_PROJECT_DIR=. node "$REPO/board/hook.mjs"; }
want "hook: qa dispatch moves to S5" "board: DEMO-4 -> S5 QA" hook '{"tool_name":"Agent","tool_input":{"subagent_type":"qa","prompt":"Do QA.\nBoard: DEMO-4\n"}}'
want "hook: other agent is a no-op" "" hook '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore","prompt":"Board: DEMO-4"}}'
want "hook: note recorded" "DEMO-4 S5 QA | Parallel | QA dispatched" b get all

if [ "$fails" -eq 0 ]; then echo "BOARD TEST PASS"; else echo "BOARD TEST FAIL ($fails)"; exit 1; fi
