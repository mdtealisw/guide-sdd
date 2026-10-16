#!/usr/bin/env node
// PreToolUse hook (Agent|Task): when a persona is dispatched with a `Board: <KEY>` line in its brief,
// move that item's board stage (board.dispatch in gates.config.json; default qa->5, engineer->6,
// validation->7), so personas never touch the board. Wired by the GUIDE plugin (hooks/board-dispatch.sh)
// or by hand in .claude/settings.json.
//
// Never blocks or denies: no permissionDecision is ever emitted and the process always exits 0. Board
// off, any other agent type, no Board: line, an unknown key or a lock timeout is a silent no-op.
import { readFileSync, existsSync } from 'node:fs';
import { loadContext, run } from './board.mjs';

function main() {
  let input;
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { return; }
  if (!input || (input.tool_name !== 'Agent' && input.tool_name !== 'Task')) return;
  const ti = input.tool_input || {};
  const type = String(ti.subagent_type || '');
  const ctx = loadContext({ config: process.env.BOARD_CONFIG || undefined, root: process.env.CLAUDE_PROJECT_DIR || undefined });
  const stage = Object.hasOwn(ctx.dispatch, type) ? String(ctx.dispatch[type]) : null;
  if (!stage || !ctx.board || !existsSync(ctx.board)) return;
  const m = /^\s*Board:\s*(\S+)\s*$/m.exec(String(ti.prompt || ''));
  if (!m) return;
  const label = type.length <= 3 ? type.toUpperCase() : type.charAt(0).toUpperCase() + type.slice(1);
  const out = run('stage', [m[1], stage, `${label} dispatched`], ctx);
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: `board: ${out}` } }) + '\n');
}

try { main(); } catch { /* never block a dispatch */ }
process.exit(0);
