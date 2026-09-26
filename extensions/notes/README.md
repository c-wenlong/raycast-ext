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

## Storage

Plain `.md` files in the folder set in preferences, default `~/.raycast/notes`.
That folder is gitignored at the repo root. Pins are kept in Raycast
LocalStorage so the files stay untouched.

Naming:

- Daily note: `2026-09-26.md`
- Regular note: `2026-09-26 1400 - project-ideas.md`

## Development

```bash
npm install
npm run dev
```

`npm run build` type-checks, `npm run lint` runs ESLint and Prettier.
