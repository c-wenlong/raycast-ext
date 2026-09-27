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
  event's planned end. A running session sits on top under **Running** with
  a Finish action (rating and a one-line note). Sessions whose log event could
  not be written yet are listed under **Waiting for log calendar**, with Retry
  and "Move Waiting Sessions to <current log calendar>". `⌘R` refreshes,
  `⌘,` opens Focus Settings.
- **Focus Settings**: pick the startable calendars and the log calendar.
  Every calendar Calendar.app knows about is listed as `title (account)`, so a
  calendar reachable through two accounts can be told apart; only writable
  calendars can be the log calendar. Saving writes `config.json`.

## Where data lives

Everything is in `~/.raycast/focus/` (gitignored at the repo root as `/focus/`):

| File | Written by | What |
|---|---|---|
| `config.json` | Focus Settings | startable calendars, log calendar id and name, and the step 4 keys (profiles, browsers, snooze length, Raycast deeplink). Unknown keys are kept on save; writes go through a temp file and a rename. |
| `focus.sock` | the helper | the socket the commands talk to: one JSON request line, one JSON reply line. |
| `focus.db` | the helper | sqlite log of sessions, pauses and blocked attempts. |

The commands launch the helper (`assets/focus-daemon`) on first use if nothing
answers on the socket.

## Status: step 1

This is PLAN step 1. Focus Today lists and starts sessions and Focus
Settings has its calendar half. There is no timer UI yet: the Finish form in
Focus Today stands in for the native end-of-session sheet that arrives in
step 2 ([src/components/FinishSessionForm.tsx](src/components/FinishSessionForm.tsx),
removed then). Ad-hoc sessions, stats and the rest of Settings are step 4;
the client library already has `startAdhoc`.

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
