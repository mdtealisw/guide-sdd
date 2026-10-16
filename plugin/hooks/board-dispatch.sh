#!/usr/bin/env sh
# GUIDE SDD stage board - PreToolUse (Agent|Task). Hands the hook input to the vendored spine's
# board/hook.mjs, which moves the item named by a `Board: <KEY>` brief line to its persona's stage.
# A no-op (exit 0, no output) when node, the spine's board or the board file is missing. Never blocks.
root="${CLAUDE_PROJECT_DIR:-.}"
hook="$root/sdd/board/hook.mjs"
[ -f "$hook" ] || hook="$root/board/hook.mjs"
[ -f "$hook" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0
node "$hook" || true
exit 0
