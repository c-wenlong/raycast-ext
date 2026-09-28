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
  (Rating and Note)" (`⌘⇧F`), the fallback for the helper's native end sheet.
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
  "Also start Raycast Focus", and a summary line per profile. Saving writes
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

## Where data lives

Everything is in `~/.raycast/focus/` (gitignored at the repo root as `/focus/`):

| File | Written by | What |
|---|---|---|
| `config.json` | Focus Settings | startable calendars, log calendar id and name, and the step 4 keys (profiles, browsers, snooze length, Raycast deeplink). Unknown keys are kept on save; writes go through a temp file and a rename. |
| `focus.sock` | the helper | the socket the commands talk to: one JSON request line, one JSON reply line. |
| `focus.db` | the helper | sqlite log of sessions, pauses and blocked attempts. |

The commands launch the helper (`assets/focus-daemon`) on first use if nothing
answers on the socket.

## Status: step 3 (engine)

While a session runs (and while its end sheet waits) the helper blocks apps
from the session's profile: a blocked app is hidden and a native block page
with one Snooze button takes its place. Profiles and the six built-in
categories are in `config.json` (see [HELPER.md](HELPER.md) "Blocking"); the
site half (block page for Chrome and Dia tabs) arrives in its own PR.

## Status: step 2

PLAN step 1 and the session half of step 2: the helper runs the timer,
pause, resume, extend and stop, keeps a heartbeat, marks a session abandoned
when the helper died with it open, and can fire the Raycast Focus deeplink.
The menu bar countdown and the native end sheet arrive with the step 2 UI PR;
until then Focus Today's Finish form
([src/components/FinishSessionForm.tsx](src/components/FinishSessionForm.tsx))
is the way to finish. Ad-hoc sessions and the rest of Settings arrived in step
4 (see Commands above).

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
