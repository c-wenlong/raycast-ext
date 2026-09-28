# Focus

Calendar-driven focus sessions for Raycast. Today's events from calendars you
choose become sessions you can start; when a session finishes, its actual time
is written as a new event in a log calendar of your choice. A native helper,
`focus-daemon`, owns Calendar access, the session state and the log; the
Raycast commands are thin clients that talk to it over a unix socket.

The full spec, including what later steps add (timer and menu bar countdown,
end-of-session sheet, app and site blocking, stats), is
[PLAN.md](PLAN.md).

## Commands

- **Focus Today**: today's events from the startable calendars whose planned
  end is more than a minute away, in a **Now** section (already started) and a
  **Later** section, each row with its calendar, time range and the minutes a
  session started now would run. `↩` starts a session that runs until the
  event's planned end. The open session sits on top under **Running** with
  its state (running, paused, or ending at the end sheet), the time left and
  the time paused, and actions Pause or Resume (`⌘⇧P`), Extend by 5, 10, 15
  or 25 minutes (`⌘E`), Stop (`⌘⇧S`, goes to the end sheet), and "Finish
  (Rating and Note)" (`⌘⇧F`), the fallback for the helper's native end sheet,
  and Discard Session (`⌃X`, no confirmation): the session ends with no
  rating and is deleted, and no log event is written for it.
  The row also shows the session's blocking profile and its mode ("default ·
  blocklist"; blocking is off while paused).
  Starting another event while a session is open sends that one to the end
  sheet first. Sessions whose log event could
  not be written yet are listed under **Waiting for log calendar**, with Retry
  and "Move Waiting Sessions to <current log calendar>". `⌘R` refreshes,
  `⌘,` opens Focus Settings.
- **Focus Settings**: pick the startable calendars and the log calendar.
  Every calendar Calendar.app knows about is listed as `title (account)`, so a
  calendar reachable through two accounts can be told apart; only writable
  calendars can be the log calendar. Below them: a blocking profile for each
  selected startable calendar (default "default"), the snooze length (1, 3, 5
  or 10 minutes), the browsers whose tabs are watched (Google Chrome, Dia),
  "Also start Raycast Focus", a summary line per profile, and Countdown
  (Floating panel or Menu bar). Saving writes
  `config.json` (unknown keys kept) and applies to the next session.
  **Manage Profiles** (`⌘⇧P`) lists the profiles with Edit, Add (`⌘N`) and
  Delete (`⌃X`; "default" can be edited, never deleted or renamed). A profile
  is a mode (blocklist or allowlist), any of the six built-in categories
  (Social, Messaging, Gaming, Entertainment, News, Shopping), extra bundle ids
  and extra hosts, one per line. Profile changes are saved at once; renaming
  or deleting one updates the calendars that used it, and a running session
  picks a change up within seconds.
- **Ad-hoc Session**: start a session with no calendar event: a goal, a
  length (15, 25, 45, 60 or 90 minutes, or custom minutes from 1 to 1440), a
  calendar to file it under (the last one used is preselected), and a
  blocking profile (the calendar's default is preselected). Starting while a
  session is open sends that one to the end sheet, and the toast says so.

- **Focus Stats**: a list with a detail pane. **Overview** has Today and Last
  7 days with focused time (pauses excluded) and the session count; their
  detail shows the helper's bar chart of focused time per day
  (`~/.raycast/focus/stats/week.svg`) and a per-calendar table. **By
  calendar** lists each calendar's focused time this week (ad-hoc sessions
  not filed under a calendar count as "Ad hoc"). **Recent sessions** shows
  the last 20 with calendar, span, focused time, rating, blocked attempts and
  the note in the detail ("Copy Goal"). Sessions whose log event is still
  waiting get the same Retry and Move actions as Focus Today. Every recent
  and waiting session has Delete Session (`⌃X`, no confirmation, as in
  Notes): the session and its pauses and blocked attempts are deleted, and
  so is its calendar event while that still carries the session's marker;
  the toast says whether the event went. `⌘R` refreshes.

## Where data lives

Everything is in `~/.raycast/focus/` (gitignored at the repo root as `/focus/`):

| File | Written by | What |
|---|---|---|
| `config.json` | Focus Settings | startable calendars, log calendar id and name, and the step 4 keys (profiles, browsers, snooze length, Raycast deeplink). Unknown keys are kept on save; writes go through a temp file and a rename. |
| `focus.sock` | the helper | the socket the commands talk to: one JSON request line, one JSON reply line. |
| `focus.db` | the helper | sqlite log of sessions, pauses and blocked attempts. |
| `stats/week.svg` | the helper | the Focus Stats chart, rewritten on every `stats` request. |

The commands launch the helper (`assets/focus-daemon`) on first use if nothing
answers on the socket.

## Status: built

All four steps of [PLAN.md](PLAN.md) are merged (2026-09-28). While a session
runs (and while its end sheet waits) the helper blocks apps and sites from the
session's profile: a blocked app is hidden behind a native block page with one
Snooze button, and a blocked host in Chrome or Dia is sent to the same page
served on loopback. A floating panel shows the countdown (or the menu bar,
per the Countdown setting; see "Countdown" below); the native end sheet
takes the rating and note. Focus Today's Finish form
([src/components/FinishSessionForm.tsx](src/components/FinishSessionForm.tsx))
stays as a headless fallback. macOS asks once per binary path for Calendar
access and for Automation access to each browser.

## Countdown

While a session runs, a small pill floats over every window at the top right
of the screen you are working on: the time left in a chip that fills green as
the session goes, and the goal. Hover it for Pause (1, 2, 5 or 10 minutes, or
until Resume), Complete (goes to the end sheet), "…" (Edit opens Focus Today,
Cancel ends the session with no rating, Move to Menu Bar, Reset Panel
Position) and a handle to drag it; where you leave it is remembered. When the
timer runs out a sound plays and the screen edges glow green, and the end
card (a compact notification with the rating, note, Extend and Finish)
shows top centre at once. The card also shows for Complete and Stop. It
stays for a second, fades out slowly over the next 5 seconds and then
finishes the session with no rating or note; hovering it holds it, and
clicking it or typing a note keeps it until you press Finish or Extend.
Focus Settings' Countdown field (or the menu bar item's "Move to Floating
Panel") switches between the panel and the menu bar.

## Development

```bash
npm install
npm run dev
```

- `npm run build` type-checks and builds, `npm run lint` runs ESLint and
  Prettier (`npm run fix-lint` reformats).
- `npm test` runs the TypeScript tests (`npm run test-ts`: `test/lib.test.ts`
  bundled with esbuild against the stub in `test/raycast-stub.js`) and then
  the helper's tests (`npm run test-helper`). `npm run build-helper` rebuilds
  `assets/focus-daemon`; see [HELPER.md](HELPER.md) for the helper side.
- `npm run fake-daemon` starts [test/fake-daemon.js](test/fake-daemon.js), a
  node stand-in for the helper that answers every command with fixture
  calendars and events (relative to the current time) and keeps a session in
  memory. It listens on `~/.raycast/focus/focus.sock` by default
  (`-- --socket <path>` for another one, `-- --no-waiting` to start without a
  waiting session), reads `config.json` next to the socket, and refuses to
  start if something already answers there, so it never shadows a running
  helper. Use it to drive the commands without Calendar access; stop the real
  helper first. The tests use it too.
