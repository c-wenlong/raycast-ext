# raycast-ext

Kai's Raycast extensions, checked out at `~/.raycast`. Three extensions, each
in its own folder under `extensions/` with its own README, `package.json` and
(where it has one) a native helper committed under `assets/`.

| Extension | What it does | Commands | Docs |
|---|---|---|---|
| [Notes](extensions/notes/) | Local markdown notes and tasks with no note limit, edited in a native floating window that hides markdown markers and matches Raycast Notes' look. Replaces Raycast Notes. | Toggle Notes Window, Browse Notes, Tasks | [README](extensions/notes/README.md) |
| [Focus](extensions/focus/) | Calendar-driven and ad-hoc focus sessions with app and site blocking, a countdown (floating glass panel, menu bar item or notch island), an end card with rating and note, stats, and a log event written back to the calendar. Replaces Raycast Focus. | Focus Today, Ad-hoc Session, Focus Stats, Focus Settings | [README](extensions/focus/README.md), [PLAN](extensions/focus/PLAN.md), [HELPER](extensions/focus/HELPER.md) |
| [Knobs](extensions/knobs/) | macOS system switches: the grayscale colour filter, sleep with the lid closed, and caffeinate. | Set Grayscale, Toggle Lid Sleep, Lid Sleep Status, Toggle Caffeinate, Caffeinate Status | [README](extensions/knobs/README.md) |

## Installing

Each extension is a development extension: from its folder, `npm install`
then `npm run dev` (or `npx ray develop`) once, and Raycast registers it and
copies its build. Rerun that after pulling a change so Raycast picks it up;
a new icon also needs Raycast restarted, since it caches extension icons.
Focus and Notes start their helpers themselves; Knobs' lid and caffeinate
commands need the `lid` and `caff` scripts in `~/.local/bin` (from Kai's
home-manager config) and the `lid-sleep` sudoers rule.

## Data

By default the notes live in `notes/` and Focus's sqlite database, config
and socket in `focus/`, both at the repo root and gitignored. Notes' folder
setting can point elsewhere; another folder inside the checkout would need
its own ignore rule. Focus's location is fixed for the extension (the
helper's `FOCUS_DIR` is only for isolated test daemons, see HELPER.md).

## Working on it

[AGENTS.md](AGENTS.md) holds the rules for agents and humans alike: layout,
build and test commands, how changes are verified, the review loop, and the
product decisions already made. Read it before changing anything.
