# Agent instructions: raycast-ext

Personal Raycast extensions and helper scripts. The development checkout
lives at `~/.raycast`.
The owner's global agent rules apply on top of this file (PR loop,
response style, subagent tiers); this file holds what is specific
to this repo.

## Layout

| Path | What |
|---|---|
| `extensions/notes/` | The Notes extension: local markdown notes, tasks and the floating notes window. Its README is [extensions/notes/README.md](extensions/notes/README.md). |
| `extensions/notes/src/` | The three Raycast commands (Toggle Notes Window, Browse Notes, Tasks; TypeScript, `@raycast/api`), `src/components/` (forms Browse Notes and Tasks open) and `src/lib/` (notes, tasks, pins, panel launcher). Quick Capture, New Note and Open Today's Note were removed as commands on 2026-09-27; the window and Browse Notes cover them. |
| `extensions/notes/helper/` | The native floating window: a Swift AppKit `NSPanel` compiled into `assets/notes-panel`. |
| `extensions/notes/test/` | `lib.test.ts` (TS, stubbed `@raycast/api`), `list-editing/` (pure text rules), `text-view/` (headless `NSTextView` harness), `panel-render/` (offscreen render tool, unreliable for chrome on macOS 26). |
| `extensions/focus/` | The Focus extension (built 2026-09-28, refined since): calendar-driven and ad-hoc focus sessions with app and site blocking, a countdown as a floating glass panel, a menu bar item or a notch island, an end card with rating and note, sqlite logging, stats, and a log event per session. Four commands: Focus Today, Ad-hoc Session, Focus Stats, Focus Settings. The spec and decisions are [extensions/focus/PLAN.md](extensions/focus/PLAN.md); read it before writing any code there and update it when a decision changes. The helper (`focus-daemon`, Swift, committed to `assets/`) is documented in [extensions/focus/HELPER.md](extensions/focus/HELPER.md): protocol, session rules, displays, blocking, build and tests. Its data folder `focus/` at the repo root is gitignored like `notes/`. |
| `extensions/knobs/` | Knobs: five no-view macOS system switches (Set Grayscale via a C helper in `assets/colorfilter`; Toggle Lid Sleep, Lid Sleep Status, Toggle Caffeinate, Caffeinate Status via the `lid` and `caff` scripts in `~/.local/bin`). Merged from the old color-filter and lid-control extensions on 2026-09-29; README in [extensions/knobs/README.md](extensions/knobs/README.md). |
| `notes/` | The default notes folder. Gitignored (`/notes/`); never commit it. |

## Build and test

Dependencies install once at the repo root, not per extension: the root
`package.json` is an npm workspaces root over `extensions/*`, so `npm
install` hoists shared deps into a single root `node_modules` (the per-
extension lockfiles are gone on purpose; `knobs` keeps a real nested
`node_modules` only for its divergent majors like eslint 10 / TS 6).
`ray`'s typecheck probes `./node_modules/.bin/tsc` relative to the
extension dir, which hoisting breaks — `scripts/workspaces-postinstall.sh`
runs on `postinstall` and symlinks any workspace without its own
`node_modules` to the root copy. Never `npm install` inside a single
extension dir: it recreates a private `node_modules` and a stray lockfile.

Focus, from `extensions/focus`: `npm run build-helper` (signed `assets/focus-daemon`, committed), `npm test` (the four suites: TS, helper, UI, site; every one must be green before a push), `npm run build` and `npm run lint`. The committed binary stays ad hoc signed so the dev cert identity is not in git: local builds may carry the owner's Apple Development cert (which keeps the running copy's TCC grants stable), so re-sign the repo file ad hoc before committing — `codesign -f -s - --identifier com.c-wenlong.focus-daemon assets/focus-daemon`. The commands, flags (`FOCUS_DIR`, `FOCUS_DEBUG`, `FOCUS_UI_DEMO`) and what each suite covers are in the "Build and test" and "Tests" sections of [extensions/focus/HELPER.md](extensions/focus/HELPER.md). Knobs has only `build`, `lint` and `build-helper` (`clang`, for `assets/colorfilter`, committed).

Notes, from `extensions/notes`:

- `npm run build-helper`: compiles `helper/*.swift` into `assets/notes-panel`. The binary is committed; rebuild and commit it with every helper change (it conflicts on every rebase, take either side and rebuild).
- `npm test`: runs `lib.test.ts`, the ListEditing tests, the view harness and the attachments suite (`test/attachments`, headless AppKit: settings, notch geometry, the Focus bridge client over a real socket and the attached window). All must be green before a push. Counts grow; the harness prints "all passed".
- `npm run build` (`ray build`) and `npm run lint` (ESLint and Prettier; `npm run fix-lint` reformats) for the TypeScript side.
- Top-level statements only compile in a file named `main.swift`, so each harness has its own `main.swift`. The two test suites compile an explicit list of helper files (see `package.json`; add a new helper file to `test-view` when the view needs it). Only `render-panel` concatenates a trimmed `helper/main.swift` (everything above `MARK: - Entry point`) with its own.
- `node_modules` is ignored without a trailing slash so a symlink in a worktree stays untracked. Worktrees for parallel agents: `git worktree add -b <branch> <dir> main`, then symlink `~/.raycast/extensions/notes/node_modules` into the worktree.

## The floating window (helper)

- Raw markdown is the model. `Markdown.apply(to:)` styles the text storage in place on every change; markers (`#`, `|`, `>`, `!>`, `**`, `_`, backticks, `- `, `[ ]`) stay in the file but are hidden: clear colour plus a kern that cancels the glyph advance, tagged `Markdown.hiddenRun` with a role (`open`, `close`, `line`). `NoteTextView` keeps the caret out of hidden runs, looks through them on Backspace and Delete, and grows selections to whole pairs.
- Inline pickers: `InlinePicker.swift` is the one popup that hangs under the caret (the `/` block menu in `SlashMenu.swift`, the `:` emoji picker over the table in `Emoji.swift`, the `[[` note picker fed by `PanelController.noteLinkTargets`). The "Inline pickers" section of `NoteTextView` holds the shared rules: open on a trigger, filter as you type, close when the caret leaves or nothing matches, and on a pick undo back to before the trigger (it starts its own typing group) and apply the pick's edit as one step. Trigger rules are pure, in `ListEditing`.
- Pure editing rules live in `ListEditing.swift` (lists, tasks, fences, block markers and their stacking, toggles, quotes, callouts, wrap keys, prefixes, whole-marker deletion) and are tested in `test/list-editing`. Put logic there first; the view only wires keys to rules. `ListEditing.blockPrefix` is the one parser of line markers, used by the renderer and the rules alike.
- Blocks: code blocks are one component (fence lines hidden, caret never rests on them, `CodeBlocks.swift` overlays language and copy controls); quotes (`| `) draw a bar, callouts (`!> `) an outlined box, both by `TaskBoxLayoutManager` from `drawBackground`; toggles (`> `) get a chevron in the gutter. A toggle's children are the following lines indented deeper (two spaces per level); collapsing tags them `Markdown.folded`, and `TaskBoxLayoutManager` (its own layout manager delegate) gives them null glyphs and zero-height line fragments, so the text never changes. The collapsed state is the `Markdown.toggleCollapsed` attribute on the `>` (the one attribute `Markdown.apply` keeps), remembered per note path (keyed by title line text and its order among same-titled toggles) in `PanelController` while the helper runs. Boxed blocks span the text column and inset their text by `Markdown.blockPad`.
- Layout matches Raycast Notes at 15pt: 28pt line pitch, a 22pt column per list level (26pt in Mono), `#1A1A1A` canvas in dark mode and near-white in light, translucent header and footer with a fade, selection hugging the text in the accent colour.
- Appearance, font and attachment (`Theme.swift`, gear popover beside ⌘K, persisted next to the zoom): System / Light / Dark sets `NSApp.appearance`, so every child panel follows; Sans Serif / Serif / Mono picks the system font's design for body and headings (`Markdown.font`), code stays monospaced. Every colour is an appearance-aware `NSColor(name:)` provider resolved at draw time (never `withAlphaComponent` on a shared colour, never a stored `cgColor` without resolving it in the view's appearance); the accent is a deeper red in light mode for 4.5:1 text contrast, and `test/text-view` checks the contrast of text, accent, selection and syntax colours in both modes.
- Titles: `Titles.firstLine` (Swift) and `firstLineTitle` (TS) must stay mirrors. A generated filename (`YYYY-MM-DD HHmm <id> - slug.md`, id = 4 lowercase base36 characters unique in the folder) is renamed on save to follow the title; only the slug changes. `NoteNames.swift` and `parseGeneratedFilename` and friends in `src/lib/notes.ts` are mirrors, checked against the shared fixture `test/note-names.json`; a title made from a filename shows the slug, never the stamp or id. When the window renames a note it rewrites link targets to it in every `.md` under the notes folder (`NoteNames.rewriteLinks`; the open note in its buffer); rewritten files get a new modification date on purpose, since Raycast's edit form checks it before saving. On a taken name a new note draws a new id (`clashCandidate`) and a rename keeps its id and suffixes the slug (`renameClashCandidate`); both mirrored. A rename never changes an id, and a rename that would land on the note's own name (its slug, or slug-N while the lower names are other notes') is skipped (`NoteNames.renamed` / `renameTarget`). New ids avoid those in the folder, in the rename log and in its `retiredIDs` (notes deleted from the window or Browse Notes; Finder deletions are not seen). Names from before ids get one at the window's first listing of a folder (`NoteNames.migrateFolder`): each rename is logged first in `.note-renames.jsonl` in that folder, an append-only JSON Lines log (`{"rename":[old,new]}`, `{"retire":id}`, `{"links":"pending"|"done"}`; one O_APPEND write per line, readers fold all lines and skip a half-written one; state follows line order, the last `links` event wins and a `rename` counts as pending), and the run counts as done only when every rename and link rewrite succeeded, else the next listing retries. A stale link opens through that log (then by the id in the logged name, if the note was renamed since; the log is never rewritten), then by id (`NoteLinks.renamedByLog`, `noteWithSameID`); Browse Notes reconciles pins the same way, never by timestamp alone. Daily and hand-named notes are left alone. Tests and live checks use temp folders, never `~/.raycast/notes`.
- Single instance over a unix socket; later launches forward their command. Commands: `toggle`, `show`, `hide`, `new`, `today`, `open <path>`, `format`, `palette`, `appearance-system|light|dark`, `font-sans|serif|mono`, `attachment-floating|menuBar|notch`, `quit`, `--dir <folder>` (a forwarded command also sends its folder, so pass `--dir` to a test instance every time).
- Isolated instances: `NOTES_PANEL_SUPPORT_DIR` moves the socket/support folder, `NOTES_PANEL_DEFAULTS_SUITE` the UserDefaults domain (frame, zoom, theme, attachment), and `NOTES_PANEL_DEBUG=1` adds the `debug-status` command, a JSON line on the socket before the `ok` reply with attachment/expanded/tab/claim state. `FOCUS_DIR` points the Focus bridge at a test daemon. Use all of them plus `--dir` for live checks, and `quit` for teardown.

## Verifying changes

Focus: tests first, then a live check on an isolated daemon (`FOCUS_DIR=/tmp/<short>`, the socket path has a length limit; `FOCUS_FOREGROUND=1`; `FOCUS_UI_DEMO=1` with its capture flags for the displays), capturing windows with `screencapture -l <windowID>` as below. The live daemon keeps its old binary until `quit`; restart it only when `status` shows no session, never by killing it. Kill only your own daemon, by pid. Google CalDAV forbids creating calendars, so live calendar checks use an existing empty one with "Focus test" events. After a merge, refresh the dev registration (`npx ray develop` for about 20 s, then kill that pid; never `pkill -f`).

Notes:

- Tests first, then the real window. Launch it with `open "raycast://extensions/c-wenlong/notes/toggleNotesWindow"` (Raycast copies the dev build) or run `assets/notes-panel open ~/.raycast/notes/<file>.md --dir ~/.raycast/notes` directly for a specific note (`open` takes a full path; `--dir` only sets the folder the window lists).
- Capture the live window with `screencapture -l <windowID> -x -o out.png`; get the id from `CGWindowListCopyWindowInfo` filtered on owner `notes-panel`. Measure pixels with Python and Pillow rather than eyeballing. The offscreen `render-panel` tool misrenders the chrome on macOS 26; do not trust it for header, footer or fades.
- Kill the helper with `pkill -x notes-panel`, never `pkill -f` (it matches the shell running it). Launching, killing and socket access need the sandbox off.
- Hover and right-click behaviour needs screen takeover approval; say so rather than claiming it was exercised.

## Review loop

- Greptile reviews every PR (check name "Greptile Review"); there is no other CI. Its check takes about 1.5 to 6 minutes and its comments land with it, so poll the head commit's check every minute (`gh pr checks`, plus the thread query) and merge one minute after it passes with no open threads. Never wait a fixed eight minutes. Greptile sometimes skips a follow-up push entirely. Only when the head commit has no check run at all (not queued, not in progress) five minutes after the push, the previous commit's run passed, and the thread query shows nothing open, treat that pass as final and merge; a run that has started on the head is always waited for, and an open thread always blocks.
- Reply on every thread and resolve it with the thread id from the GraphQL query (never a guessed id). Reply bodies end with `_🤖 Addressed by [Claude Code](https://claude.com/claude-code)_`.
- Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; PR bodies have What / Why / Checks and end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Squash-merge with `gh pr merge N --squash --delete-branch`, then sync `main` and rebuild the helper in any open branch.

## Product decisions already made

- Raycast stays; this replaces Raycast Notes (five-note cap) with files in `~/.raycast/notes`.
- Markers are never shown and never editable, even on the caret line.
- Trash needs no confirmation (the Trash keeps the note).
- Line markers sit at the start of the line, after any indent, always in the order `| ` (quote), `> ` (toggle), `#`..`#### ` (heading); a callout `!> ` stands alone and has no typing shortcut (the slash menu writes it). Each needs its space: `|text`, `>text` and a bare `#` are plain text, in the renderer and the rules alike.
- Stacking (Space after a marker typed at the text start): headings replace headings; heading and toggle add both ways; inside a quote a heading or toggle can be added, but `| ` on a heading or toggle line replaces them with a plain quote; `| ` on a quote or `> ` on a toggle just consumes the typing. Lists, tasks and fences are separate and do not stack.
- Backspace at a marked line's text start peels one marker, innermost first (heading, toggle, quote). A raw `#`, `>` or `|` must never show through Backspace, Delete or deleting a selection: a marker is removed whole or kept whole, and a join drops the joined line's markers.
- Toggles: collapsed state is in memory only, per note, default open. `↩` on an open title opens a first child; on a collapsed one it adds a sibling toggle after the hidden children; on an empty title it removes the toggle marker.
- An opening fence with no closing fence is literal text; the Enter and Space rules add the closing fence.
- The `/` menu opens at a line start or after a space; a pick removes the query and formats the line as one undo step.
- Typography: typed `->` `=>` `<-` `--` `>=` `<=` `...` become `→` `⇒` `←` `–` `≥` `≤` `…` (the file stores the character), one undo step that leaves the caret after the typed text. Only the characters right before the caret count, so a symbol can finish the next one (`-->` gives `→`, `<->` `↔`, `<=>` `⇔`, `<-->` `↔`; one ⌘Z after a composite gives back all of it, `<->`, never `←>`); `<--` gives `←-`, `....` gives `….`, no em dash. `--` with only whitespace and dashes before it on its line stays literal so `---` types a divider. Never inside fenced blocks, inline code (an odd number of backticks before it on the line), link addresses or right after a hidden marker character, and never on paste.
- Dividers (`---`, `***`, `___` alone on a line, per `ListEditing.rulePattern`, outside code blocks exactly as the styler finds them: `ListEditing.fencePattern`) are a hairline drawn by the layout manager with the characters hidden. Backspace or Delete on one, or Backspace at the start of the line after one, removes it whole; joins and selections never leave raw dashes.
