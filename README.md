# raycast-ext

Personal Raycast extensions. The development checkout lives at `~/.raycast`.
Three extensions, each in its own folder under `extensions/` with its own
README, `package.json` and (where it has one) a native helper committed
under `assets/`.

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
commands need the `lid` and `caff` scripts in `~/.local/bin` (provided by the
owner's dotfiles, not this repo) and the `lid-sleep` sudoers rule.

## Data

By default the notes live in `notes/` and Focus's sqlite database, config
and socket in `focus/`, both at the repo root and gitignored. Notes' folder
setting can point elsewhere; another folder inside the checkout would need
its own ignore rule. Focus's location is fixed for the extension.

## Security model

Built for one trusted user on one Mac. The helpers talk over unix sockets
under `~/.raycast/` and `~/Library/Application Support/` guarded only by
file permissions, with no socket authentication: any process running as
the same user can drive them (open files in the notes window, trash the
open note, move or delete focus sessions and their calendar events, quit
the daemon). Focus's block page also listens on `127.0.0.1` at a random
port; its state-changing POST is gated by a per-session token plus Host
and Origin checks. `FOCUS_DEBUG=1` enables test commands that create and
delete `Focus test*` calendars and events, plus commands that simulate a
block and press its Snooze. There is no multi-user or sandbox threat
model. Install only where that is acceptable.

## Working on it

[AGENTS.md](AGENTS.md) holds the rules for agents and humans alike: layout,
build and test commands, how changes are verified, the review loop, and the
product decisions already made. Read it before changing anything.
