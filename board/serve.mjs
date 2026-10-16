// Live view of the stage board: page + JSON API + server-sent events, reading and writing through the
// same functions as board.mjs. Runs on its own (no Claude Code session needed): directly, as an IIS site
// (iis-setup.ps1) or in Docker (compose.yml). Node >= 18, built-ins only.
//   node sdd/board/serve.mjs [--port 8780] [--host 127.0.0.1] [--allow-host <name>]... [--config <file>]
// Port: --port > PORT / ASPNETCORE_PORT (IIS) > 8780. Requests whose Host is not loopback or an
// --allow-host name (BOARD_ALLOWED_HOSTS, comma-separated) are refused (DNS-rebinding guard).
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { HERE, loadContext, getState, OPS } from './board.mjs';

const opts = {};
let port = Number(process.env.PORT) || Number(process.env.ASPNETCORE_PORT) || 8780;
let host = '127.0.0.1';
const allowed = new Set((process.env.BOARD_ALLOWED_HOSTS || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean));
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--port') port = Number(argv[++i]);
  else if (argv[i] === '--host') host = argv[++i];
  else if (argv[i] === '--allow-host') allowed.add(String(argv[++i]).toLowerCase());
  else if (argv[i] === '--config') opts.config = argv[++i];
  else if (argv[i] === '--board') opts.board = argv[++i];
  else if (argv[i] === '--root') opts.root = argv[++i];
}

let ctx = loadContext(opts);
const ALLOWED_OPS = new Set(['add', 'stage', 'assign', 'remove', 'order', 'note', 'flag', 'team-add']); // never done: a ship goes through a session

function watched() {
  const f = [ctx.board, ctx.storeRoot, ctx.closedFile, ctx.meta, ctx.cfgPath, ctx.processMd].filter(Boolean);
  try { if (fs.statSync(ctx.storeRoot).isDirectory()) for (const n of fs.readdirSync(ctx.storeRoot)) f.push(path.join(ctx.storeRoot, n)); } catch { /* missing store: state reports it */ }
  return f;
}
const mtimes = () => watched().map((f) => { try { return fs.statSync(f).mtimeMs; } catch { return 0; } }).join('|');

let cache = { key: null, body: null };
function stateBody() {
  const key = mtimes();
  if (cache.key !== key) {
    ctx = loadContext(opts); // config edits (columns, labels, teams of paths) apply without a restart
    try { cache = { key, body: JSON.stringify(getState(ctx)) }; } catch (e) { cache = { key, body: JSON.stringify({ error: e.message, title: ctx.title }) }; }
  }
  return cache.body;
}

const hostOk = (h) => {
  const name = String(h || '').toLowerCase().replace(/:\d+$/, '');
  return /^(127\.0\.0\.1|localhost|\[::1\])$/.test(name) || allowed.has(name);
};
const send = (res, code, type, body) => { res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }); res.end(body); };
const json = (res, code, obj) => send(res, code, 'application/json', JSON.stringify(obj));

const clients = new Set();
const emit = (ev) => { for (const c of clients) c.write(`event: ${ev}\ndata: {}\n\n`); };
let deb = null;
let last = mtimes();
const changed = () => { last = mtimes(); clearTimeout(deb); deb = setTimeout(() => emit('changed'), 200); };

const server = http.createServer((req, res) => {
  if (!hostOk(req.headers.host)) return send(res, 403, 'text/plain', 'forbidden host');
  const url = new URL(req.url, 'http://127.0.0.1');
  try {
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return send(res, 200, 'text/html; charset=utf-8', fs.readFileSync(path.join(HERE, 'board.html')));
    if (req.method === 'GET' && url.pathname === '/api/state') return send(res, 200, 'application/json', stateBody());
    if (req.method === 'GET' && url.pathname === '/api/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
      res.write(': connected\n\n');
      clients.add(res);
      req.on('close', () => clients.delete(res));
      return undefined;
    }
    if (req.method === 'POST' && url.pathname === '/api/op') {
      if (!/^application\/json\b/i.test(req.headers['content-type'] || '')) return json(res, 415, { ok: false, message: 'Content-Type must be application/json' });
      if (req.headers.origin) { let oh = ''; try { oh = new URL(req.headers.origin).host; } catch { /* bad origin */ } if (!hostOk(oh)) return json(res, 403, { ok: false, message: 'forbidden origin' }); }
      let size = 0;
      const chunks = [];
      req.on('data', (c) => { size += c.length; if (size > 65536) req.destroy(); else chunks.push(c); });
      req.on('end', () => {
        try {
          const { op, args } = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          if (!ALLOWED_OPS.has(op) || !Array.isArray(args) || !args.every((x) => typeof x === 'string')) return json(res, 400, { ok: false, message: `bad op ${op}` });
          return json(res, 200, { ok: true, message: OPS[op](ctx, args) });
        } catch (e) { return json(res, 400, { ok: false, message: e.message }); }
      });
      return undefined;
    }
    return send(res, 404, 'text/plain', 'not found');
  } catch (e) { return send(res, 500, 'text/plain', e.message); }
});

// Live look: directory watches (a file watch dies when the file is replaced by rename on Windows, and
// bind mounts may deliver no events at all) plus a 2 s mtime poll that covers both.
function watchDirs() {
  for (const d of new Set(watched().map((f) => path.dirname(f)))) {
    try { fs.watch(d, () => changed()).on('error', () => {}); } catch { /* poll covers it */ }
  }
}
watchDirs();
setInterval(() => { const m = mtimes(); if (m !== last) changed(); }, 2000);
setInterval(() => { for (const c of clients) c.write(': ping\n\n'); }, 25000).unref();

// Own code: serve.mjs / board.mjs changed -> exit when a supervisor restarts us (IIS, Docker, systemd:
// BOARD_SUPERVISED=1 or ASPNETCORE_PORT set); board.html changed -> open pages reload.
const CODE = ['serve.mjs', 'board.mjs'];
const PAGE = 'board.html';
const mt = (n) => { try { return fs.statSync(path.join(HERE, n)).mtimeMs; } catch { return 0; } };
const codeStamp = () => CODE.map(mt).join('|');
const supervised = !!(process.env.ASPNETCORE_PORT || process.env.BOARD_SUPERVISED);
let codeLast = codeStamp();
let pageLast = mt(PAGE);
let warned = false;
setInterval(() => {
  if (codeStamp() !== codeLast) {
    codeLast = codeStamp();
    if (supervised) { console.log('board: code changed, exiting for restart'); setTimeout(() => process.exit(0), 300); }
    else if (!warned) { warned = true; console.log('board: code changed - restart the server to pick it up'); }
  }
  if (mt(PAGE) !== pageLast) { pageLast = mt(PAGE); emit('reload'); }
}, 2000);

server.listen(port, host, () => console.log(`board: http://${host === '0.0.0.0' ? '127.0.0.1' : host}:${port}  (${ctx.title})`));
