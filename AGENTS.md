# Agent instructions: raycast-ext

Kai's Raycast extensions and helper scripts, checked out at `~/.raycast`.
The global rules in `~/.quiver/AGENTS.md` apply on top of this file (PR
loop, response style, subagent tiers); this file holds what is specific
to this repo.

## Layout

| Path | What |
|---|---|
| `extensions/notes/` | The Notes extension: local markdown notes, tasks and the floating notes window. Almost all work happens here. |
| `extensions/notes/src/` | Raycast commands (TypeScript, `@raycast/api`) and `src/lib/` (notes, tasks, pins, panel launcher). |
| `extensions/notes/helper/` | The native floating window: a Swift AppKit `NSPanel` compiled into `assets/notes-panel`. |
| `extensions/notes/test/` | `lib.test.ts` (TS, stubbed `@raycast/api`), `list-editing/` (pure text rules), `text-view/` (headless `NSTextView` harness), `panel-render/` (offscreen render tool, unreliable for chrome on macOS 26). |
| `extensions/color-filter/`, `extensions/lid-control/` | Small script extensions. |
| `scripts/` | Shell helpers (`toggle-lid-sleep.sh`). |
| `notes/` | The default notes folder. Gitignored (`/notes/`); never commit it. |

## Build and test

Run from `extensions/notes`:

- `npm run build-helper`: compiles `helper/*.swift` into `assets/notes-panel`. The binary is committed; rebuild and commit it with every helper change (it conflicts on every rebase, take either side and rebuild).
- `npm test`: runs `lib.test.ts`, the ListEditing tests and the view harness. All three must be green before a push. Counts grow; the harness prints "all passed".
- `npm run build` (`ray build`) and `npm run lint` (ESLint and Prettier; `npm run fix-lint` reformats) for the TypeScript side.
- Top-level statements only compile in a file named `main.swift`, so each harness has its own `main.swift`. The two test suites compile an explicit list of helper files (see `package.json`; add a new helper file to `test-view` when the view needs it). Only `render-panel` concatenates a trimmed `helper/main.swift` (everything above `MARK: - Entry point`) with its own.
- `node_modules` is ignored without a trailing slash so a symlink in a worktree stays untracked. Worktrees for parallel agents: `git worktree add -b <branch> <dir> main`, then symlink `~/.raycast/extensions/notes/node_modules` into the worktree.

## The floating window (helper)

- Raw markdown is the model. `Markdown.apply(to:)` styles the text storage in place on every change; markers (`#`, `>`, `>>`, `**`, `_`, backticks, `- `, `[ ]`) stay in the file but are hidden: clear colour plus a kern that cancels the glyph advance, tagged `Markdown.hiddenRun` with a role (`open`, `close`, `line`). `NoteTextView` keeps the caret out of hidden runs, looks through them on Backspace and Delete, and grows selections to whole pairs.
- Pure editing rules live in `ListEditing.swift` (lists, tasks, fences, quotes, callouts, wrap keys, prefixes) and are tested in `test/list-editing`. Put logic there first; the view only wires keys to rules.
- Blocks: code blocks are one component (fence lines hidden, caret never rests on them, `CodeBlocks.swift` overlays language and copy controls); quotes draw a bar, callouts (`>> `) an outlined box, both by `TaskBoxLayoutManager` from `drawBackground`. Boxed blocks span the text column and inset their text by `Markdown.blockPad`.
- Layout matches Raycast Notes at 15pt: 28pt line pitch, a 22pt column per list level, `#1A1A1A` canvas, translucent header and footer with a fade, selection hugging the text in the accent colour.
- Titles: `Titles.firstLine` (Swift) and `firstLineTitle` (TS) must stay mirrors. A generated filename (`YYYY-MM-DD HHmm - slug.md`) is renamed on save to follow the title; Browse Notes reconciles pins to the new path.
- Single instance over a unix socket; later launches forward their command. Commands: `toggle`, `show`, `hide`, `new`, `open <path>`, `format`, `--dir <folder>`.

## Verifying changes

- Tests first, then the real window. Launch it with `open "raycast://extensions/c-wenlong/notes/toggleNotesWindow"` (Raycast copies the dev build) or run `assets/notes-panel open ~/.raycast/notes/<file>.md --dir ~/.raycast/notes` directly for a specific note (`open` takes a full path; `--dir` only sets the folder the window lists).
- Capture the live window with `screencapture -l <windowID> -x -o out.png`; get the id from `CGWindowListCopyWindowInfo` filtered on owner `notes-panel`. Measure pixels with Python and Pillow rather than eyeballing. The offscreen `render-panel` tool misrenders the chrome on macOS 26; do not trust it for header, footer or fades.
- Kill the helper with `pkill -x notes-panel`, never `pkill -f` (it matches the shell running it). Launching, killing and socket access need the sandbox off.
- Hover and right-click behaviour needs screen takeover approval; say so rather than claiming it was exercised.

## Review loop

- Greptile reviews every PR (check name "Greptile Review"); there is no other CI. It usually posts within five minutes of a push and often skips follow-up pushes; after eight quiet minutes with green checks and no open threads, merge.
- Reply on every thread and resolve it with the thread id from the GraphQL query (never a guessed id). Reply bodies end with `_🤖 Addressed by [Claude Code](https://claude.com/claude-code)_`.
- Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; PR bodies have What / Why / Checks and end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Squash-merge with `gh pr merge N --squash --delete-branch`, then sync `main` and rebuild the helper in any open branch.

## Product decisions already made

- Raycast stays; this replaces Raycast Notes (five-note cap) with files in `~/.raycast/notes`.
- Markers are never shown and never editable, even on the caret line.
- Trash needs no confirmation (the Trash keeps the note).
- A quote is `> ` and a callout `>> `, followed by a space or the end of the line; `>text` is plain text so the renderer and the editing rules agree.
- An opening fence with no closing fence is literal text; the Enter and Space rules add the closing fence.
- The `/` menu opens at a line start or after a space; a pick removes the query and formats the line as one undo step.
