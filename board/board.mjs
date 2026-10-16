// GUIDE SDD stage board: CLI + shared module (serve.mjs and hook.mjs import the same functions).
// Store: board.json (sprint membership, GUIDE stage, team, one-line note), path from gates.config.json
// `board.file`. Items stay in the Mode B backlog (`foldCheck.backlogRoot`): titles and bodies are read
// from it, so there is nothing to sync. Stage ids come from PROCESS.md's Stage Index. Local files only,
// no network. Node >= 18, built-ins only.   node sdd/board/board.mjs help
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const HERE = path.dirname(fileURLToPath(import.meta.url));
const SPINE = path.resolve(HERE, '..');
const DAY = 86400000;
const J = JSON.stringify;
const fail = (msg) => { throw new Error(msg); };
const clip = (s, n) => (s.length > n ? s.slice(0, n) : s);
const flat = (s) => s.replace(/\s+/g, ' ').trim();
const eolOf = (t) => (t.includes('\r\n') ? '\r\n' : '\n');
const today = () => new Date().toISOString().slice(0, 10);
export const SIZES = { S: 1, M: 3, L: 8, XL: 20 };
const BL_STATES = ['r', 'p', 'e', 'k', 'f']; // Ready, Needs PO, Eyeball, Parked, In flight (meta.json)

// ---- config ---------------------------------------------------------------------------------

const DEFAULT_COLUMNS = [
  { id: 'todo', label: 'To Do', stages: ['todo'], actor: '-', defaultStage: 'todo' },
  { id: 'triage', label: 'Triage', stages: ['0'], actor: 'Orchestrator', defaultStage: '0' },
  { id: 'spec', label: 'Design & Spec', stages: ['1', '2', '3'], actor: 'PO approval', defaultStage: '3' },
  { id: 'qa', label: 'Test plan & QA', stages: ['4', '4b', '5'], actor: 'QA', defaultStage: '4' },
  { id: 'eng', label: 'Engineer', stages: ['6'], actor: 'Engineer', defaultStage: '6' },
  { id: 'ship', label: 'Validate & Ship', stages: ['7'], actor: 'Validation', defaultStage: '7' },
  { id: 'done', label: 'Done', stages: ['done'], actor: '-', defaultStage: 'done' },
];
const DEFAULT_DISPATCH = { qa: '5', engineer: '6', validation: '7' };

function findGitTop(start) {
  for (let d = start; ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, '.git'))) return d;
    if (path.dirname(d) === d) return null;
  }
}

// Loads gates.config.json and resolves every board path against the project root (config projectRoot,
// relative to the spine dir > git top-level > spine dir), the same rule as run_all.
export function loadContext(opts = {}) {
  const cfgPath = opts.config ? path.resolve(opts.config) : path.join(SPINE, 'gates', 'gates.config.json');
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch (e) {
    if (opts.config) fail(`cannot read config ${cfgPath}: ${e.message}`);
  }
  const root = opts.root ? path.resolve(opts.root)
    : cfg.projectRoot ? path.resolve(SPINE, cfg.projectRoot) : findGitTop(SPINE) || SPINE;
  const b = cfg.board || {};
  const rel = (p) => (p ? path.resolve(root, p) : null);
  const store = b.store || {};
  const fc = cfg.foldCheck || {};
  const ctx = {
    root, cfgPath, cfg,
    board: opts.board ? path.resolve(opts.board) : rel(b.file),
    storeRoot: rel(store.root || fc.backlogRoot || 'backlog'),
    closedFile: rel(store.closed),
    meta: rel(b.meta),
    title: b.title || path.basename(root),
    epics: Array.isArray(b.epics) ? b.epics : [],
    dispatch: b.dispatch || DEFAULT_DISPATCH,
    unitRe: new RegExp(cfg.unitIdRegex || '\\b[A-Z]{2,}-\\d+\\b'),
    stageLabels: b.stageLabels || {},
    columnsCfg: Array.isArray(b.columns) && b.columns.length ? b.columns : DEFAULT_COLUMNS,
    processMd: path.join(SPINE, 'PROCESS.md'),
  };
  ctx.stages = loadStages(ctx);
  ctx.stageIds = ctx.stages.map((s) => s.id);
  ctx.columns = buildColumns(ctx);
  return ctx;
}

// Stage ids from the PROCESS.md Stage Index (`| 0 | Triage / right-size | ...`), bracketed by todo/done.
// Label: board.stageLabels[id], else the stage name cut at " / ", " (" or " + ".
export function loadStages(ctx) {
  let rows = [];
  try {
    const t = fs.readFileSync(ctx.processMd, 'utf8');
    const at = t.indexOf('## Stage Index');
    if (at >= 0) {
      for (const l of t.slice(at).split(/\r?\n/).slice(1)) {
        if (l.startsWith('## ')) break;
        const m = /^\|\s*([0-9][0-9a-z]*)\s*\|\s*([^|]+?)\s*\|/.exec(l);
        if (m) rows.push([m[1], m[2]]);
      }
    }
  } catch { /* fallback below */ }
  if (!rows.length) rows = [['0', 'Triage'], ['1', 'Design'], ['2', 'Recon'], ['3', 'Spec'], ['4', 'Test plan'], ['4b', 'Build plan'], ['5', 'QA'], ['6', 'Engineer'], ['7', 'Ship']];
  const cut = (n) => n.split(/ \/ | \(| \+ /)[0].trim();
  const lab = (id, n) => ctx.stageLabels[id] || n;
  return [{ id: 'todo', label: lab('todo', 'To Do') }, ...rows.map(([id, n]) => ({ id, label: lab(id, cut(n)) })), { id: 'done', label: lab('done', 'Done') }];
}

// Columns from board.columns (or the default grouping); a stage no column claims gets an "Other" column.
function buildColumns(ctx) {
  const cols = ctx.columnsCfg.map((c) => {
    const stages = (c.stages || []).map(String).filter((s) => ctx.stageIds.includes(s));
    return { id: String(c.id), label: String(c.label || c.id), stages, actor: String(c.actor || '-'), defaultStage: stages.includes(String(c.defaultStage)) ? String(c.defaultStage) : stages[0] };
  }).filter((c) => c.stages.length);
  const claimed = new Set(cols.flatMap((c) => c.stages));
  const orphan = ctx.stageIds.filter((s) => !claimed.has(s));
  if (orphan.length) cols.splice(cols.length - 1, 0, { id: 'other', label: 'Other', stages: orphan, actor: '-', defaultStage: orphan[0] });
  return cols;
}

export const stageText = (ctx, s) => (s === 'todo' || s === 'done' ? s : `S${s} ${(ctx.stages.find((x) => x.id === s) || {}).label || ''}`.trim());

// ---- item store (Mode B backlog) ------------------------------------------------------------
// Directory (the spine layout, #CL-1): one file per item, key = the first unit-id in the file name,
// title = its first heading, closed = a `shipped:` line (#CL-4).
// File: one item per row - a `##`-`####` heading or a top-level `- ` bullet led by the unit-id (after
// any `*`, `_`, `[`, `(`). A bullet row runs over its indented lines; a heading row to the next heading
// or row. Closed = a `shipped:` line in the row, or the row sits in board.store.closed.
// gates/board_check.{sh,ps1} apply the same rules.

const SHIPPED_RE = /^\s*[-*]?\s*shipped[:\s]/i;

function rowStartRe(ctx) {
  return new RegExp(`^(#{2,4}[ \\t]+|-[ \\t]+)[*_\\[( \\t]*(${ctx.unitRe.source})`);
}

export function parseRows(ctx, text) {
  const lines = text.split(/\r?\n/);
  const re = rowStartRe(ctx);
  const rows = [];
  let cur = null;
  const close = (i) => { if (cur) { cur.end = i; rows.push(cur); cur = null; } };
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    const m = re.exec(l);
    if (m) {
      close(i);
      const km = ctx.unitRe.exec(l.slice(m[1].length));
      cur = { k: km[0], kind: m[1].startsWith('#') ? 'header' : 'bullet', start: i, head: l.slice(m[1].length), body: '', shipped: false };
    } else if (/^#/.test(l)) {
      close(i);
    } else if (cur) {
      if (cur.kind === 'bullet' && !/^\s+\S/.test(l)) close(i);
      else { cur.body += ' ' + l; if (SHIPPED_RE.test(l)) cur.shipped = true; }
    }
  }
  close(lines.length);
  return { lines, rows };
}

function titleOf(ctx, head) {
  let h = head.replace(/\*\*/g, '');
  const at = h.indexOf(' · ');
  if (at >= 0) return clip(flat(h.slice(at + 3)), 140);
  const km = ctx.unitRe.exec(h);
  if (km) h = h.slice(km.index + km[0].length);
  h = h.replace(/^[\])\s:.—-]+/u, '').replace(/^(OPEN|STUB|PARKED|DONE|READY)\b\s*(—\s*[A-Z ]+?\s*)?/, '').replace(/^[^\p{L}\p{N}]+/u, '');
  const dash = h.indexOf(' — ');
  return clip(flat(dash > 0 ? h.slice(0, dash) : h), 140);
}

function readMeta(ctx) { try { return ctx.meta ? JSON.parse(fs.readFileSync(ctx.meta, 'utf8')) : {}; } catch { return {}; } }

function dirItems(ctx) {
  const out = [];
  let names = [];
  try { names = fs.readdirSync(ctx.storeRoot).filter((n) => n.endsWith('.md')).sort(); } catch { return out; }
  const seen = new Set();
  for (const n of names) {
    const km = ctx.unitRe.exec(n);
    if (!km || seen.has(km[0])) continue;
    seen.add(km[0]);
    const f = path.join(ctx.storeRoot, n);
    const text = fs.readFileSync(f, 'utf8');
    const lines = text.split(/\r?\n/);
    const h = lines.find((l) => /^#{1,6}\s/.test(l));
    const body = lines.filter((l) => !/^#/.test(l)).join(' ');
    out.push({ k: km[0], file: f, head: h ? h.replace(/^#+\s*/, '') : n.replace(/\.md$/, ''), body, shipped: lines.some((l) => SHIPPED_RE.test(l)) });
  }
  return out;
}

// All store items: [{k, title, body, date, open}], first occurrence of a key wins.
export function storeItems(ctx) {
  const items = [];
  const seen = new Set();
  const push = (k, head, body, open) => {
    if (seen.has(k)) return;
    seen.add(k);
    items.push({ k, title: titleOf(ctx, head) || k, body: clip(flat(body), 300), date: (/\d{4}-\d{2}-\d{2}/.exec(head) || [''])[0], open });
  };
  let st = null;
  try { st = fs.statSync(ctx.storeRoot); } catch { fail(`no backlog at ${ctx.storeRoot} (board.store.root / foldCheck.backlogRoot)`); }
  if (st.isDirectory()) {
    for (const r of dirItems(ctx)) push(r.k, r.head, r.body, !r.shipped);
  } else {
    for (const r of parseRows(ctx, fs.readFileSync(ctx.storeRoot, 'utf8')).rows) push(r.k, r.head, r.body, !r.shipped);
    if (ctx.closedFile && fs.existsSync(ctx.closedFile)) {
      for (const r of parseRows(ctx, fs.readFileSync(ctx.closedFile, 'utf8')).rows) push(r.k, r.head, r.body, false);
    }
  }
  return items;
}

export function buildCatalog(ctx) {
  const meta = readMeta(ctx);
  const all = storeItems(ctx);
  const items = all.filter((i) => i.open).map((i) => {
    const m = meta[i.k] || {};
    return { k: i.k, t: m.t || i.title, s: i.body, e: m.e || '', f: m.f || '', st: m.st || 'r', d: i.date };
  });
  return { builtAt: Date.now(), items, shipped: all.filter((i) => !i.open).map((i) => i.k), hasMeta: Object.keys(meta).length > 0 };
}

// Close an item in the store. Directory: append `shipped: <note> <date>` to its file. File: move the row
// to board.store.closed when set (line endings preserved), else append an indented `shipped:` line.
function closeItem(ctx, k, note) {
  const stamp = `shipped: ${note} ${today()}`;
  if (fs.statSync(ctx.storeRoot).isDirectory()) {
    const r = dirItems(ctx).find((x) => x.k === k);
    if (!r || r.shipped) fail(`${k} not an open backlog item`);
    let t = fs.readFileSync(r.file, 'utf8');
    const eol = eolOf(t);
    if (t && !t.endsWith('\n')) t += eol;
    fs.writeFileSync(r.file, t + stamp + eol);
    return `${k} shipped in ${path.relative(ctx.root, r.file).replace(/\\/g, '/')}`;
  }
  const bp = ctx.storeRoot;
  const btxt = fs.readFileSync(bp, 'utf8');
  const beol = eolOf(btxt);
  const { lines, rows } = parseRows(ctx, btxt);
  const row = rows.find((r) => r.k === k && !r.shipped);
  if (!row) fail(`${k} not an open backlog row`);
  let end = row.end;
  while (end > row.start + 1 && lines[end - 1].trim() === '') end--;
  if (!ctx.closedFile) {
    lines.splice(end, 0, (row.kind === 'bullet' ? '  ' : '') + stamp);
    fs.writeFileSync(bp, lines.join(beol));
    return `${k} shipped in ${path.basename(bp)}`;
  }
  const block = lines.slice(row.start, end);
  block.push((row.kind === 'bullet' ? '  ' : '') + stamp);
  const rest = lines.slice(0, row.start).concat(lines.slice(end));
  let ctxt = fs.existsSync(ctx.closedFile) ? fs.readFileSync(ctx.closedFile, 'utf8') : '';
  const ceol = ctxt ? eolOf(ctxt) : beol;
  if (ctxt && !ctxt.endsWith('\n')) ctxt += ceol;
  // Closed file first: a failure between the two writes leaves the row in both files (check reports it), never lost.
  fs.writeFileSync(ctx.closedFile, ctxt + block.join(ceol) + ceol);
  fs.writeFileSync(bp, rest.join(beol));
  return `moved ${k} (${block.length} lines) -> ${path.basename(ctx.closedFile)}`;
}

// ---- board.json -----------------------------------------------------------------------------

const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function normTeam(t) { return { id: String(t.id), name: String(t.name || t.id), order: Number(t.order) || 0, hue: Number(t.hue) || 0 }; }
function normItem(ctx, i) {
  return {
    k: String(i.k), order: Number(i.order) || 0, stage: ctx.stageIds.includes(String(i.stage)) ? String(i.stage) : 'todo',
    team: i.team || '', state: i.state || '', lane: i.lane || '', flag: i.flag || '',
    addedAt: Number(i.addedAt) || 0, doneAt: Number(i.doneAt) || 0,
  };
}

// The ONE serializer: teams by order, items by key, fixed key order, one entry per line, LF.
export function serialize(ctx, state) {
  const teams = state.teams.map(normTeam).sort((a, b) => a.order - b.order || (a.id < b.id ? -1 : 1));
  const items = state.items.map((i) => normItem(ctx, i)).sort((a, b) => (a.k < b.k ? -1 : a.k > b.k ? 1 : 0));
  const tl = teams.map((t) => J({ id: t.id, name: t.name, order: t.order, hue: t.hue }));
  const il = items.map((i) => J({ k: i.k, order: i.order, stage: i.stage, team: i.team, state: i.state, lane: i.lane, flag: i.flag, addedAt: i.addedAt, doneAt: i.doneAt }));
  return '{\n"teams": [\n' + tl.join(',\n') + '\n],\n"items": [\n' + il.join(',\n') + '\n]\n}\n';
}

function needBoard(ctx) { if (!ctx.board) fail('board is off: set board.file in gates.config.json, then run: node sdd/board/board.mjs init'); return ctx.board; }

export function readBoard(ctx) {
  const f = needBoard(ctx);
  if (!fs.existsSync(f)) fail(`no board file ${f} - run: node sdd/board/board.mjs init`);
  const d = JSON.parse(fs.readFileSync(f, 'utf8'));
  return { teams: (d.teams || []).map(normTeam), items: (d.items || []).map((i) => normItem(ctx, i)) };
}

function writeBoardFile(ctx, f, state) {
  const tmp = `${f}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, serialize(ctx, state));
  for (let n = 0; ; n++) {
    try { fs.renameSync(tmp, f); return; } catch (e) {
      if (n >= 20) { try { fs.unlinkSync(tmp); } catch { /* ignore */ } throw e; }
      sleepSync(15);
    }
  }
}

// Exclusive lock file beside the board: 3 s to acquire, a lock older than 10 s is stale.
function lockBoard(f) {
  const lock = f + '.lock';
  const t0 = Date.now();
  let fd = null;
  for (;;) {
    try { fd = fs.openSync(lock, 'wx'); break; } catch (e) {
      if (e.code !== 'EEXIST' && e.code !== 'EPERM' && e.code !== 'EACCES') throw e;
      try { if (Date.now() - fs.statSync(lock).mtimeMs > 10000) { fs.unlinkSync(lock); continue; } } catch { /* raced */ }
      if (Date.now() - t0 > 3000) fail('board is locked (another writer); retry');
      sleepSync(10 + Math.floor(Math.random() * 25));
    }
  }
  return () => {
    try { fs.closeSync(fd); } catch { /* ignore */ }
    try { fs.unlinkSync(lock); } catch { /* ignore */ }
  };
}

// Lock, re-read, mutate (fn mutates state and returns the result), write tmp + rename, release.
export function withBoard(ctx, fn) {
  const f = needBoard(ctx);
  const release = lockBoard(f);
  try {
    const state = readBoard(ctx);
    const before = serialize(ctx, state);
    const res = fn(state);
    if (serialize(ctx, state) !== before) writeBoardFile(ctx, f, state);
    return res;
  } finally {
    release();
  }
}

const maxOrder = (st) => st.items.reduce((a, i) => Math.max(a, i.order), 0);
const findItem = (st, k) => st.items.find((i) => i.k === k) || fail(`${k} not on the board`);
const openKeys = (ctx) => new Set(storeItems(ctx).filter((i) => i.open).map((i) => i.k));
const checkTeam = (st, team) => { if (team && !st.teams.some((t) => t.id === team)) fail(`unknown team ${team}`); };
const teamArg = (t) => (t === 'none' ? '' : t || '');
const markDone = (d) => { d.stage = 'done'; d.doneAt = Date.now(); d.state = 'shipped'; };

// The full state the page and the server need.
export function getState(ctx) {
  const b = readBoard(ctx);
  const c = buildCatalog(ctx);
  return {
    title: ctx.title, teams: b.teams, items: b.items, columns: ctx.columns, stages: ctx.stages,
    epics: ctx.epics, sizes: SIZES, hasMeta: c.hasMeta, catalog: c.items, shipped: c.shipped, builtAt: c.builtAt,
  };
}

// ---- commands -------------------------------------------------------------------------------

export const OPS = {
  init(ctx) {
    const f = needBoard(ctx);
    if (fs.existsSync(f)) return `board exists: ${path.relative(ctx.root, f).replace(/\\/g, '/')}`;
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, serialize(ctx, { teams: [], items: [] }), { flag: 'wx' });
    return `created ${path.relative(ctx.root, f).replace(/\\/g, '/')}`;
  },
  get(ctx, [team], flags = {}) {
    if (!team) fail('usage: get <team|all|none> [--col <column id>]');
    const col = flags.col ? ctx.columns.find((c) => c.id === flags.col) || fail(`unknown column ${flags.col}; one of ${ctx.columns.map((c) => c.id).join(' ')}`) : null;
    const b = readBoard(ctx);
    const cat = buildCatalog(ctx);
    const titles = new Map(cat.items.map((i) => [i.k, i.t]));
    const shipped = new Set(cat.shipped);
    const sel = b.items.filter((d) => (col ? col.stages.includes(d.stage) : d.stage !== 'done') && (team === 'all' || (team === 'none' ? !d.team : d.team === team)))
      .sort((x, y) => x.order - y.order);
    if (!sel.length) return `no ${col ? col.id + ' ' : 'open '}items for ${team}`;
    return sel.map((d) => {
      let line = `${d.k} ${stageText(ctx, d.stage)} | ${clip(titles.get(d.k) || '?', 70)} | ${clip(d.state, 50)}`;
      if (shipped.has(d.k) && d.stage !== 'done') line += ' !SHIPPED-IN-BACKLOG';
      else if (!titles.has(d.k) && !shipped.has(d.k)) line += ' !NOT-IN-BACKLOG';
      return line;
    }).join('\n');
  },
  add(ctx, [k, team]) {
    if (!k) fail('usage: add <KEY> [team]');
    const open = openKeys(ctx);
    return withBoard(ctx, (st) => {
      const t = teamArg(team);
      checkTeam(st, t);
      const ex = st.items.find((i) => i.k === k);
      if (ex) { if (team !== undefined) ex.team = t; return `${k} already on board${team !== undefined ? `; team=${t || 'none'}` : ''}`; }
      if (!open.has(k)) fail(`${k} not an open backlog item - file it first`);
      st.items.push({ k, order: maxOrder(st) + 1, stage: 'todo', team: t, state: 'queued', lane: '', flag: '', addedAt: Date.now(), doneAt: 0 });
      return `added ${k}${t ? ` -> ${t}` : ''}`;
    });
  },
  stage(ctx, [k, s, ...note]) {
    if (!k || !ctx.stageIds.includes(s)) fail(`usage: stage <KEY> <${ctx.stageIds.join('|')}> [note...]`);
    return withBoard(ctx, (st) => {
      const d = findItem(st, k);
      d.stage = s;
      d.doneAt = s === 'done' ? Date.now() : 0;
      if (note.length) d.state = note.join(' ');
      return `${k} -> ${stageText(ctx, s)}`;
    });
  },
  note(ctx, [k, ...text]) {
    if (!k || !text.length) fail('usage: note <KEY> <text...>');
    return withBoard(ctx, (st) => { findItem(st, k).state = text.join(' '); return `${k} note set`; });
  },
  flag(ctx, [k, ...text]) {
    if (!k) fail('usage: flag <KEY> [text...]');
    return withBoard(ctx, (st) => { const d = findItem(st, k); d.flag = text.join(' '); return `${k} ${d.flag ? 'flagged' : 'flag cleared'}`; });
  },
  lane(ctx, [k, ...text]) {
    if (!k || !text.length) fail('usage: lane <KEY> <text...>');
    return withBoard(ctx, (st) => { findItem(st, k).lane = text.join(' '); return `${k} lane set`; });
  },
  assign(ctx, [k, team]) {
    if (!k || !team) fail('usage: assign <KEY> <team|none>');
    return withBoard(ctx, (st) => { const t = teamArg(team); checkTeam(st, t); findItem(st, k).team = t; return `${k} -> team ${t || 'none'}`; });
  },
  remove(ctx, [k]) {
    if (!k) fail('usage: remove <KEY>');
    return withBoard(ctx, (st) => { findItem(st, k); st.items = st.items.filter((i) => i.k !== k); return `removed ${k}`; });
  },
  order(ctx, [k, n]) {
    if (!k || n === undefined || !Number.isFinite(Number(n))) fail('usage: order <KEY> <n>');
    return withBoard(ctx, (st) => { findItem(st, k).order = Number(n); return `${k} order ${Number(n)}`; });
  },
  // Close the backlog item AND mark the board item done in one run, so the two cannot diverge.
  done(ctx, [k, ...note]) {
    if (!k || !note.length) fail('usage: done <KEY> <note...>  (e.g. the ship SHA)');
    readBoard(ctx);
    const msg = closeItem(ctx, k, note.join(' '));
    withBoard(ctx, (st) => {
      let d = st.items.find((i) => i.k === k);
      if (!d) { d = { k, order: maxOrder(st) + 1, team: '', flag: '', addedAt: Date.now() }; st.items.push(d); }
      markDone(d); d.lane = note.join(' ');
    });
    return msg + '; board done';
  },
  'done-board'(ctx, [k]) {
    if (!k) fail('usage: done-board <KEY>');
    if (openKeys(ctx).has(k)) fail(`${k} is still an open backlog item; use: done ${k} "<note>"`);
    return withBoard(ctx, (st) => { markDone(findItem(st, k)); return `${k} -> done`; });
  },
  check(ctx, [], flags = {}) {
    const b = readBoard(ctx);
    const all = storeItems(ctx);
    const open = new Set(all.filter((i) => i.open).map((i) => i.k));
    const shipped = new Set(all.filter((i) => !i.open).map((i) => i.k));
    const out = [];
    const fixKeys = [];
    for (const d of b.items) {
      const isDone = d.stage === 'done';
      if (!isDone && shipped.has(d.k)) {
        if (flags.fix) fixKeys.push(d.k);
        else out.push(`${d.k} board-open but shipped in backlog -> run: board.mjs check --fix`);
      } else if (!open.has(d.k) && !shipped.has(d.k)) out.push(`${d.k} on board but not in backlog -> run: board.mjs remove ${d.k}`);
      else if (isDone && open.has(d.k)) out.push(`${d.k} board-done but backlog item still open -> run: board.mjs done ${d.k} "<note>"`);
    }
    if (fixKeys.length) {
      withBoard(ctx, (st) => { for (const k of fixKeys) { const d = st.items.find((i) => i.k === k); if (d && d.stage !== 'done') markDone(d); } });
      for (const k of fixKeys) out.push(`${k} fixed: marked done`);
    }
    out.push(`check: ${out.length - fixKeys.length} drift${fixKeys.length ? `, ${fixKeys.length} fixed` : ''}`);
    return out.join('\n');
  },
  'team-add'(ctx, name) {
    const nm = name.join(' ').trim();
    const id = nm.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    if (!id) fail('usage: team-add <name>');
    return withBoard(ctx, (st) => {
      if (st.teams.some((t) => t.id === id)) fail(`team ${id} already exists`);
      const order = st.teams.reduce((a, t) => Math.max(a, t.order), 0) + 1;
      st.teams.push({ id, name: nm, order, hue: (order * 67 + 190) % 360 });
      return `team ${id} added`;
    });
  },
  'team-remove'(ctx, [id]) {
    if (!id) fail('usage: team-remove <id>');
    return withBoard(ctx, (st) => {
      if (!st.teams.some((t) => t.id === id)) fail(`unknown team ${id}`);
      st.teams = st.teams.filter((t) => t.id !== id);
      let n = 0;
      for (const i of st.items) if (i.team === id) { i.team = ''; n++; }
      return `team ${id} removed${n ? `; ${n} item(s) unassigned` : ''}`;
    });
  },
  prune(ctx, [days]) {
    const n = Number(days);
    if (days === undefined || !Number.isFinite(n) || n < 0) fail('usage: prune <days>  (drops done items older than that; the project sets its retention)');
    return withBoard(ctx, (st) => {
      const cut = Date.now() - n * DAY;
      const before = st.items.length;
      st.items = st.items.filter((i) => !(i.stage === 'done' && i.doneAt > 0 && i.doneAt < cut));
      return `pruned ${before - st.items.length} done item(s) older than ${n}d`;
    });
  },
  meta(ctx, [k, e, f, st = 'r'], flags = {}) {
    if (!ctx.meta) fail('meta is off: set board.meta in gates.config.json');
    if (!k || !ctx.unitRe.test(k)) fail('usage: meta <KEY> <EPIC> <SIZE> [st] [--title ".."]');
    const epicIds = ctx.epics.map((x) => x.id);
    if (epicIds.length && !epicIds.includes(e)) fail(`epic must be one of ${epicIds.join(' ')}`);
    if (!SIZES[f]) fail(`size must be one of ${Object.keys(SIZES).join(' ')}`);
    if (!BL_STATES.includes(st)) fail(`st must be one of ${BL_STATES.join(' ')}`);
    const meta = readMeta(ctx);
    const v = { e, f, st };
    if (flags.title) v.t = flags.title; else if (meta[k] && meta[k].t) v.t = meta[k].t;
    meta[k] = v;
    fs.writeFileSync(ctx.meta, '{\n' + Object.keys(meta).sort().map((x) => J(x) + ':' + J(meta[x])).join(',\n') + '\n}\n');
    return `meta ${k} ok`;
  },
  // Read-only single-file copy (state embedded, live code stripped) for viewing away from the box.
  snapshot(ctx, [out]) {
    const st = getState(ctx);
    st.snapshotAt = Date.now();
    const html = fs.readFileSync(path.join(HERE, 'board.html'), 'utf8');
    const json = J(st).replace(/</g, '\\u003c');
    const page = html.replace(/\/\*LIVE-START\*\/[\s\S]*?\/\*LIVE-END\*\//g, '').replace('<!--snapshot-->', () => `<script id="snapshot" type="application/json">${json}</script>`);
    const file = out ? path.resolve(out) : path.join(os.tmpdir(), 'guide-board-snapshot.html');
    fs.writeFileSync(file, page);
    return file;
  },
  // Paths the live server reads and writes (iis-setup.ps1 grants exactly these).
  paths(ctx) {
    const write = new Set([path.dirname(needBoard(ctx))]);
    let st = null;
    try { st = fs.statSync(ctx.storeRoot); } catch { /* reported by check */ }
    write.add(st && st.isDirectory() ? ctx.storeRoot : path.dirname(ctx.storeRoot));
    if (ctx.closedFile) write.add(path.dirname(ctx.closedFile));
    if (ctx.meta) write.add(path.dirname(ctx.meta));
    return J({ read: [SPINE], write: [...write] });
  },
};

const HELP = [
  'init — create the empty board file (board.file in gates.config.json)',
  'get <team|all|none> [--col <column id>] — open items in order: KEY S5 QA | title | note',
  'add <KEY> [team] | remove <KEY> | order <KEY> <n>',
  'stage <KEY> <todo|0..7|4b|done> [note] | note <KEY> <text> | flag <KEY> [text] | lane <KEY> <text>',
  'assign <KEY> <team|none> | team-add <name> | team-remove <id>',
  'done <KEY> <note> — close the backlog item AND mark the board item done | done-board <KEY> — board only',
  'check [--fix] — drift between board and backlog | prune <days>',
  'meta <KEY> <EPIC> <SIZE> [st] [--title ".."] — epic/size/title per key (board.meta)',
  'snapshot [file] — write a read-only single-file copy, print its path',
  'flags: --config <gates.config.json> | --board <file> | --root <project root>',
].join('\n');

export function run(cmd, args, ctx, flags = {}) {
  if (cmd === 'help' || cmd === undefined) return HELP;
  const fn = OPS[cmd];
  if (!fn) fail(`unknown command ${cmd}; try help`);
  return fn(ctx, args, flags);
}

function main(argv) {
  const opts = {};
  const flags = {};
  const a = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--config') opts.config = argv[++i];
    else if (argv[i] === '--board') opts.board = argv[++i];
    else if (argv[i] === '--root') opts.root = argv[++i];
    else if (argv[i] === '--title') flags.title = argv[++i];
    else if (argv[i] === '--fix') flags.fix = true;
    else if (argv[i] === '--col') flags.col = argv[++i];
    else a.push(argv[i]);
  }
  const [cmd, ...r] = a;
  const out = run(cmd, r, loadContext(opts), flags);
  if (out) console.log(out);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); } catch (e) { console.log(`error: ${e.message}`); process.exitCode = 1; }
}
