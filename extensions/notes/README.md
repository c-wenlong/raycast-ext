# Notes

Local markdown notes and tasks in Raycast, with no note limit. Forked from
[Noteman](https://github.com/raycast/extensions/tree/main/extensions/noteman)
(MIT, by samuel_oldmark_se).

## Commands

- **Toggle Notes Window**: the floating editor below; where writing happens.
- **Browse Notes**: search titles and contents, pinned section on top, open task
  count per note. `⌘⇧P` pin, `⌘E` edit, `⌘O` open with another app, `⌃X` trash.
  Its action panel also has New Note, Quick Capture (append to today's note,
  add a task, create or append to a note) and Open Today's Note.
- **Tasks**: every `- [ ]` line across all notes, grouped by note. Enter toggles
  done, `⌘O` opens the note, `⌘N` adds a task to today's note. Filter open,
  done or all from the dropdown.

Today's note is `YYYY-MM-DD.md`; the window's ⌘K palette opens it too.

## Floating window

**Toggle Notes Window** opens an always-on-top editor over the same files,
the way the Raycast Notes window works. Bind it to `⌥⌘N` in Raycast
Settings → Extensions → Notes (and clear the same hotkey on Raycast Notes).
`⌘⇧F` in Browse Notes opens the selected note there.

Inside the window:

| Keys | Action |
|---|---|
| `⌘K` | action palette (New Note, Open Today's Note, Duplicate, Browse, zoom…): type to filter, `↑` `↓` to move, `↩` to run |
| `/` at a line start or after a space | block menu under the caret: Text, Heading 1 to 4, bulleted, numbered and to-do lists, quote, toggle, callout, code block; type to filter, `↑` `↓`, `↩` to apply, `Esc` to keep the slash |
| `:` and two letters, as in `:cla` | emoji picker under the caret, searched by GitHub/Slack shortcode (about 780 common emoji, built in): type to filter, `↑` `↓`, `↩` to insert the emoji in place of `:cla`, `Esc` or a space to keep the text. A closing colon on an exact name (`:clap:`) converts at once (`⌘Z` gives the name back). Only at a line start or after a space or punctuation, so `10:30`, `key:value` and `std::string` stay text, as does anything in code or a link address |
| `⌘[` / `⌘]` | previous / next note, in last-edit order as of when the window was shown |
| `⌘N` | new note (its first line, markdown stripped, becomes the title and filename) |
| `⌘D` | duplicate note |
| `⌘↩` | toggle the task on the current line, or click the `[ ]` box |
| `⌘F` | find in note |
| `⇧⌘C` | copy the note's markdown |
| `⌃X` | move the note to the Trash (no confirmation; restore it from the Trash) |
| `⌘P` | jump to Browse Notes in Raycast |
| `⌘+` / `⌘-` / `⌘0` | zoom in, out, reset (shown in a "Zoomed to 120%" bubble, remembered) |
| `⌘M` | minimise the window |
| `⌘W` or `Esc` | hide |
| `⌘B` / `⌘I` / `⇧⌘S` / `⌘E` | bold / italic / strikethrough / inline code; again with the caret or selection inside to remove |
| `⌘L` | link the selection, caret between the `()` |
| `[[` | link to another note: a picker of the folder's notes by title, most recently edited first; type to filter, `↩` inserts `[Title](file%20name.md)` in place of `[[query`, `Esc` keeps the text. Clicking such a link opens that note in the window |
| hover or right-click a link | hovering an `http(s)` link shows a bubble with the address, Open, Edit and Copy; right-clicking any link gives Copy, Open and Edit, and for a `[text](url)` link Remove Link too. Edit opens a small form for text and address |
| `⌥⌘1` to `⌥⌘4` | heading 1 to 4; again to remove |
| `\| ` or `⇧⌘B` | quote the line (`\| text` in the file); `↩` continues the quote, `↩` on an empty quote line ends it |
| `> ` | toggle (`> text`): a chevron left of the title collapses or expands the lines indented under it; `↩` at the end of the title opens a child line (on a collapsed toggle, a new toggle after the hidden children), `↩` on an empty title or empty child steps out |
| `/callout` | callout (`!> text`): the lines sit in an outlined box; `↩` continues it, `↩` on an empty line ends it |
| `#`, `>` or `\|` then `Space` on a marked line | markers stack at the start of the text: `## ` on a heading changes its level, `> ` and `# ` combine into a heading toggle, a quote can hold a heading or a toggle, and `\| ` turns a heading or toggle into a plain quote. In the file they are always `\| `, `> `, `# ` in that order |
| `⌫` at the start of a marked line | take off one marker, innermost first (heading, toggle, quote), keeping the text; on a toggle's child, step out one level |
| `⇧⌘7` / `⇧⌘8` / `⇧⌘9` | numbered / bullet / task item |
| `⌥⌘C` | wrap the lines in a code block, or unwrap the block the caret is in |
| `[]` then `Space` | start a task, `- [ ] ` |
| `->` `=>` `<-` `--` `>=` `<=` `...` | typed, they become `→` `⇒` `←` `–` `≥` `≤` `…`, one character in the file; `⌘Z` right after gives back what you typed. A symbol can finish the next one: `-->` gives `→`, `<->` `↔`, `<=>` `⇔`. Dashes at a line start stay dashes so `---` makes a divider; code spans, code blocks, link addresses and pastes are left alone |
| `---`, `***` or `___` on its own line | a divider: a thin line across the window, the characters hidden; `⌫` or `Delete` on it, or `⌫` at the start of the line after it, removes it in one keystroke |
| `1. ` | start a numbered list; `↩` and `⇥` renumber it as you go |
| `↩` in a list | continue the list; on an empty item, end it (a nested one steps out first) |
| `⇥` / `⇧⇥` in a list | nest / unnest the item with everything under it |
| `⌫` right after a marker | remove the marker (a nested item steps out first) |
| ```` ``` ```` then `↩` or `Space` | open a code block and add its closing fence |
| `@today`, `@tomorrow` or `@yesterday` then `Space`, `↩`, `⇥` or punctuation | the word becomes the local date, `2026-10-05`, keeping what you typed after it; `⌘Z` right after gives the word back. Only at the start of a word (not in `kai@today.com`), never in code or a link address; pasted text is left alone |
| paste a URL over a selection | turn the selection into `[text](url)` |
| `⌘Z` / `⇧⌘Z` | undo / redo; each typing rule and formatting key is one step |

The file stays raw markdown, but the window never shows the markers:
headings, bold, italic, strike, code, quotes, toggles, callouts, links, list
markers, task boxes and dividers are styled in place and the `#`, `|`, `>`, `!>`, `**`,
`_`, backticks and `- ` are collapsed (a quote shows as a bar down its left,
spanning its lines). A marker forms only with the space after it: `|text`,
`>text` or a lone `#` stay plain text. A toggle's collapsed state lives only
in the window, per note, until the helper quits; the file never changes. The
caret skips over markers and hidden children, Backspace and Delete look through
them to the styled text, and a pair left empty disappears, so styled text
is removed by removing the text. A date standing on its own (`2026-10-05`,
also in brackets or before punctuation) sits on a faint accent chip; one
glued to other text (`2026-10-05.md`, `x-2026-10-05`), followed by a time
(`2026-10-05 1008`, as in generated filenames) or in code or a link address
stays plain. Edits save 0.4s after you stop typing, and
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
- Regular note: `2026-09-26 1400 - project-ideas.md`; the slug follows the
  note's first line (markdown stripped) and is renamed on save when that
  line changes. Pins follow the rename.

## Development

```bash
npm install
npm run dev
```

`npm run build` type-checks, `npm run lint` runs ESLint and Prettier, and
`npm test` runs three suites: the library tests in `test/lib.test.ts`
against a stubbed `@raycast/api`, the pure editing rules in
`test/list-editing`, and the headless text view harness in
`test/text-view`. `npm run build-helper` rebuilds the window binary
(`assets/notes-panel`, committed) after any change under `helper/`.
See the root `AGENTS.md` for how the window is verified live.
