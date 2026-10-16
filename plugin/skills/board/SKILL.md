---
name: board
description: GUIDE SDD stage board - get <team> | add <KEY> [team] | stage <KEY> <todo|0..7|4b|done> [note] | assign <KEY> <team|none> | done <KEY> <note> | check [--fix] | snapshot. One node sdd/board/board.mjs call per verb.
argument-hint: "get alpha | add DEMO-12 alpha | stage DEMO-12 5 QA red | done DEMO-12 <repo> <sha> | check --fix"
disable-model-invocation: true
---

# /board — the GUIDE stage board (sprint membership, stage, team)

Usage: `/board <verb> [args]` — arguments: $ARGUMENTS

The board is `board.file` in `sdd/gates/gates.config.json`; the backlog stays the item store (rules:
`sdd/board/README.md`, `project-details.md#CL-12`/`#CL-13`). Each verb is ONE
`node sdd/board/board.mjs …` call: no reading of `board.json`, no extra queries, no narration. Never
hand-edit `board.json`.

| Verb | Recipe |
|---|---|
| `get <team\|all\|none> [--col <id>]` | `node sdd/board/board.mjs get …` — open items in order: `KEY S5 QA \| title \| note` |
| `add <KEY> [team]` | `node sdd/board/board.mjs add <KEY> [team]`. Refused = not an open backlog item: file it first. |
| `stage <KEY> <s> [note]` | `node sdd/board/board.mjs stage <KEY> <todo\|0..7\|4b\|done> [note]`. Also `note`, `flag`, `lane`, `order`, `remove`. |
| `assign <KEY> <team\|none>` | `node sdd/board/board.mjs assign …`. A team assigns only on the PO's word (`#CL-13`). |
| `done <KEY> <note>` | `node sdd/board/board.mjs done <KEY> "<repo> <sha>"` — closes the backlog item AND marks the board item done; then commit the backlog + board hunks. |
| `check [--fix]` | `node sdd/board/board.mjs check` (`--fix` marks board-open-but-shipped items done; run any other printed fix). |
| `snapshot` | `node sdd/board/board.mjs snapshot` — a read-only single-file copy; print its path. |
| `serve` | The live board is a standing site (`#CL-12` names its URL); never start a server from a session. |

Print the script's output lines as the answer; nothing else.
