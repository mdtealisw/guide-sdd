# Stage board

> Optional, bundled capability (Mode B). A sprint board whose columns are GUIDE's stages, so it answers
> "whose turn is it" — which items wait on the PO's spec approval, which are with QA, the Engineer or
> Validation — and which session owns each item. Rules for a project: `project-details.md#CL-12`
> (board) and `#CL-13` (teams). Mode A projects use the tracker's own board; `board_check` then reports
> "not configured".

## What it is

- **Store:** `board.file` (e.g. `docs/memory/board.json`), in git. One line per sprint item, fixed key
  order, sorted by key, LF — diffs and merges stay line-local:
  `{"k":"DEMO-12","order":3,"stage":"5","team":"alpha","state":"QA red on 2 clauses","lane":"","flag":"","addedAt":0,"doneAt":0}`
- **The backlog stays the item store** (`foldCheck.backlogRoot`). The board holds only membership, stage,
  team and a one-line note; titles and bodies are read from the backlog, so there is nothing to sync.
- **Every write** takes `board.json.lock` (created exclusively; 3 s to acquire, stale after 10 s),
  re-reads, mutates, writes a temp file and renames it. CLI, page and hook share that one writer.
- **Node ≥ 18, built-ins only**, for the CLI, server and hook. The gate (`gates/board_check.*`) is
  sh/ps1 like every gate, so `run_all` gains no dependency.

## Set up (once)

1. In `sdd/gates/gates.config.json`, set `board.file`; check `foldCheck.backlogRoot` points at the
   backlog. Optional: `board.title`, `board.store.closed` (a single-file backlog's completed file),
   `board.meta` + `board.epics` (epic/size per key; the page then shows epics and points).
2. `node sdd/board/board.mjs init` — creates the empty board; commit it.
3. Copy `sdd/commands/board.md` into `.claude/commands/` (the plugin ships it as the `board` skill).
4. Start the live view (below) and bind its URL and the rules in `project-details.md#CL-12`/`#CL-13`.

## CLI — `node sdd/board/board.mjs <verb>`

One verb per call, one line of output per item (token-cheap by design).

| Verb | Does |
|---|---|
| `init` | Create the empty board file. |
| `get <team\|all\|none> [--col <id>]` | Open items by order: `KEY S5 QA \| title \| note`, plus `!SHIPPED-IN-BACKLOG` / `!NOT-IN-BACKLOG`. |
| `add <KEY> [team]` | Refused unless `KEY` is an open backlog item. |
| `stage <KEY> <todo\|0..7\|4b\|done> [note]` | Set the exact stage; the note becomes `state`. |
| `note` / `flag` / `lane` / `order` / `assign` / `remove` | One field each; `flag` with no text clears. |
| `done <KEY> <note>` | **Close the backlog item AND mark the board item done, in one run** — the two cannot diverge. |
| `done-board <KEY>` | Board only, for an item already closed in the backlog. |
| `check [--fix]` | Drift: board item not in the backlog, shipped-but-open, done-but-open. `--fix` marks shipped items done. |
| `team-add <name>` / `team-remove <id>` / `prune <days>` | Teams; drop done items older than `days` (retention is the project's call). |
| `meta <KEY> <EPIC> <SIZE> [st] [--title ..]` | Upsert `board.meta`. |
| `snapshot [file]` | A read-only single-file copy (state embedded) for viewing away from the box. |

Flags: `--config <gates.config.json>`, `--board <file>`, `--root <project root>`.

## Stages and columns

- Stage ids come from `PROCESS.md`'s Stage Index at run time, between `todo` and `done`: a spine change
  to the stages reaches every board.
- `board.stageLabels` names them; `board.columns` groups them (default below). A stage no column claims
  lands in an "Other" column. Each card shows its exact stage (`S5 QA`).
- "Blocked / needs PO" is a card flag, not a column: blocked work stays where it is in the flow.

| Column | Stages | Who acts next |
|---|---|---|
| To Do | `todo` | — |
| Triage | 0 | Orchestrator |
| Design & Spec | 1, 2, 3 | PO approval |
| Test plan & QA | 4, 4b, 5 | QA |
| Engineer | 6 | Engineer |
| Validate & Ship | 7 | Validation |
| Done | `done` | — |

Who moves the stage:
- the orchestrator sets 0–4b as it runs them (`/board stage`);
- **5, 6 and 7 move by themselves** when the orchestrator dispatches the QA, Engineer or Validation persona
  with a `Board: <KEY>` line in the brief (below);
- personas never touch the board; the orchestrator records their result line with `/board note`;
- `/board done` closes the item at ship (`#CL-4`).

## The backlog the board reads

`foldCheck.backlogRoot` (or `board.store.root`):

- **A directory** (the spine layout, `#CL-1`): one file per item. Key = the first unit-id in the file
  name; title = its first heading; **closed = a `shipped:` line** (`#CL-4`; a line starting `SHIPPED `
  counts too). `done` appends `shipped: <note> <date>`.
- **A file:** one item per row — a `##`–`####` heading or a top-level `- ` bullet led by the unit-id
  (after any `*`, `_`, `[`, `(`): `## DEMO-12 Title`, `- **[DEMO-12]** Title`. A bullet row runs over its
  indented lines; a heading row to the next heading or row. Closed = a `shipped:` line in the row, or the
  row sits in `board.store.closed`. `done` moves the row there (line endings kept) when it is set, else
  appends an indented `shipped:` line.

`board_check` and `fold_check` read the same layouts.

## Dispatch hook (stages 5–7)

`board/hook.mjs`, a PreToolUse hook on `Agent|Task`:
- reads one `Board: <KEY>` line from the dispatch prompt;
- maps the agent's `subagent_type` through `board.dispatch` (default `qa`→5, `engineer`→6, `validation`→7);
- sets the stage through the locked writer and returns `board: KEY -> S5 QA` as context;
- never blocks or denies: any other agent, no `Board:` line, an unknown key, board off or no node is a
  silent no-op.

- **GUIDE plugin:** wired already (`hooks/board-dispatch.sh`).
- **By hand** (`.claude/settings.json`):
  `{"hooks":{"PreToolUse":[{"matcher":"Agent|Task","hooks":[{"type":"command","command":"node sdd/board/hook.mjs"}]}]}}`

## Live view — a standing site, no Claude Code session needed

- `serve.mjs` serves the page, `/api/state`, `/api/op` (the CLI's own functions; never `done` — a ship goes
  through a session) and `/api/events` (server-sent events; directory watches plus a 2 s mtime poll).
- The page: stage columns, team chips (a team's filter *is* its board; `#alpha` deep-links), swimlanes by
  team, drag-and-drop between columns, an issue drawer with a stage select, and a backlog tab.
- It binds 127.0.0.1 and refuses a request whose Host is not loopback or an allowed name (`--allow-host`,
  `BOARD_ALLOWED_HOSTS`), against DNS rebinding.

| Host | One step |
|---|---|
| **Docker** | `docker compose -f sdd/board/compose.yml up -d` → http://127.0.0.1:8780. Stock `node:22-alpine`, repo bind-mounted, restarts with the box. Linux: `BOARD_UID=$(id -u) BOARD_GID=$(id -g)` so writes keep your ownership. |
| **IIS** | Elevated Windows PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass -File sdd\board\iis-setup.ps1` (`-SiteName`, `-Port`, `-SitePath`; `-Remove` undoes it). Needs the .NET Hosting Bundle (ASP.NET Core Module v2) and node. The app pool gets modify on exactly the directories `board.mjs paths` names. |
| **Direct / service** | `node sdd/board/serve.mjs [--port 8780]` under systemd, launchd or a scheduled task (`BOARD_SUPERVISED=1` lets it exit for a restart when its code changes). |

- A supervised server (IIS, Docker, `BOARD_SUPERVISED=1`) exits when `serve.mjs`/`board.mjs` change, so
  the supervisor restarts it on the new code; a changed `board.html` reloads open pages.
- Port: `--port` > `PORT` / `ASPNETCORE_PORT` > 8780. Beyond loopback: a proxy in front, its host allowed.

## Teams (several orchestrator sessions on one box)

Optional; `box-roles.md` §"Teams". A team is one concurrent orchestrator session (Alpha, Beta…):
`board.json` `teams`, `board.mjs team-add <name>`. A session takes its team from the PO's start prompt
("you are Alpha"); with none, it handles unassigned work only. A team works only items whose `team` is
its id, in board order, and never claims or reassigns another team's items; the PO assigns.

## Windows notes

- A single-file `fs.watch` dies when the file is replaced by rename: the server watches directories, and
  polls mtimes every 2 s as well (bind mounts may deliver no events at all).
- node under an IIS app pool identity fails with `EPERM lstat` on the user profile unless started with
  `--preserve-symlinks --preserve-symlinks-main` (the generated `web.config` does).
- Use `127.0.0.1`, not `localhost`, in links: `localhost` may resolve to IPv6 first.
