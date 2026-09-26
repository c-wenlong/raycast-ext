# Notes

Local markdown notes and tasks in Raycast, with no note limit. Forked from
[Noteman](https://github.com/raycast/extensions/tree/main/extensions/noteman)
(MIT, by samuel_oldmark_se).

## Commands

- **Browse Notes**: search titles and contents, pinned section on top, open task
  count per note. `⌘⇧P` pin, `⌘E` edit, `⌘O` open with another app, `⌃X` trash.
- **Quick Capture**: append to today's daily note, add a task to today's note,
  create a new note, or append to an existing one.
- **Tasks**: every `- [ ]` line across all notes, grouped by note. Enter toggles
  done, `⌘O` opens the note, `⌘N` adds a task to today's note. Filter open,
  done or all from the dropdown.
- **New Note**: title plus body.
- **Open Today's Note**: `YYYY-MM-DD.md`.

## Floating window

**Toggle Notes Window** opens an always-on-top editor over the same files,
the way the Raycast Notes window works. Bind it to `⌥⌘N` in Raycast
Settings → Extensions → Notes (and clear the same hotkey on Raycast Notes).
`⌘⇧F` in Browse Notes opens the selected note there.

Inside the window:

| Keys | Action |
|---|---|
| `⌘K` | action palette: type to filter, `↑` `↓` to move, `↩` to run |
| `⌘[` / `⌘]` | previous / next note, in last-edit order as of when the window was shown |
| `⌘N` | new note (the `#` heading becomes the title and filename) |
| `⌘D` | duplicate note |
| `⌘↩` | toggle the task on the current line, or click the `[ ]` box |
| `⌘F` | find in note |
| `⇧⌘C` | copy the note's markdown |
| `⌃X` | move the note to the Trash |
| `⌘P` | jump to Browse Notes in Raycast |
| `⌘+` / `⌘-` / `⌘0` | zoom in, out, reset (shown in a "Zoomed to 120%" bubble, remembered) |
| `⌘M` | minimise the window |
| `⌘W` or `Esc` | hide |
| `⌘B` / `⌘I` / `⇧⌘S` / `⌘E` | bold / italic / strikethrough / inline code; again to remove |
| `⌘L` | link the selection, caret between the `()` |
| `⌥⌘1` / `⌥⌘2` / `⌥⌘3` | heading 1 / 2 / 3; again to remove |
| `⇧⌘B` | quote the line |
| `⇧⌘7` / `⇧⌘8` / `⇧⌘9` | numbered / bullet / task item |
| `⌥⌘C` | wrap the lines in a code block, or unwrap the block the caret is in |
| `[]` then `Space` | start a task, `- [ ] ` |
| `1. ` | start a numbered list; `↩` and `⇥` renumber it as you go |
| `↩` in a list | continue the list; on an empty item, end it (a nested one steps out first) |
| `⇥` / `⇧⇥` in a list | nest / unnest the item with everything under it |
| `⌫` right after a marker | remove the marker (a nested item steps out first) |
| ```` ``` ```` then `↩` or `Space` | open a code block and add its closing fence |
| paste a URL over a selection | turn the selection into `[text](url)` |
| `⌘Z` / `⇧⌘Z` | undo / redo; each typing rule and formatting key is one step |

The file stays raw markdown, but the window never shows the markers:
headings, bold, italic, strike, code, quotes, links, list markers and task
boxes are styled in place and the `#`, `**`, `_`, backticks and `- ` are
collapsed. The caret skips over them, Backspace and Delete look through
them to the styled text, and a pair left empty disappears, so styled text
is removed by removing the text. Edits save 0.4s after you stop typing, and
the window reloads a note that another program changes.

The window is a native helper, `helper/main.swift`, compiled into
`assets/notes-panel` with `npm run build-helper`. The first launch keeps
running as a small server on a unix socket; later launches forward their
command to it.

## Storage

Plain `.md` files in the folder set in preferences, default `~/.raycast/notes`.
This repo is checked out at `~/.raycast`, so `/notes/` in the root
`.gitignore` covers the default folder. Point the preference at another
folder inside the repo and those files will be tracked. Pins are kept in
Raycast LocalStorage so the files stay untouched.

Naming:

- Daily note: `2026-09-26.md`
- Regular note: `2026-09-26 1400 - project-ideas.md`

## Development

```bash
npm install
npm run dev
```

`npm run build` type-checks, `npm run lint` runs ESLint and Prettier, and
`npm test` runs the library tests in `test/` against a stubbed `@raycast/api`.
