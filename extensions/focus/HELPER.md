# focus-daemon

The Swift half of Focus ([PLAN.md](PLAN.md), build step 1). Sources in `helper/`,
compiled to `assets/focus-daemon` (committed). No Dock icon, no UI yet.

## Files

All in `~/.raycast/focus/` (gitignored as `/focus/`; `FOCUS_DIR` overrides the folder):

| File | What |
|---|---|
| `focus.sock` | Unix socket, mode 0600. |
| `config.json` | Settings. Created with defaults if missing; re-read on every request; never rewritten by the helper. |
| `focus.db` | sqlite (WAL). Schema from PLAN.md; `pragma user_version` is the schema version (1). |
| `focus.lock` | `flock` held by the running instance (holds its pid). |
| `daemon.log` | stderr of the daemon; rotated to `daemon.log.1` past 1 MB. |

## Running it

- `focus-daemon` or `focus-daemon serve`: starts the daemon unless one answers, and returns once it listens.
- `focus-daemon <cmd>` or `focus-daemon '<json>'`: sends one request, starting the daemon first if needed, prints the reply line. Exit 0 when `ok` is true, 1 when false, 2 when the daemon could not be reached.
- The daemon is spawned in its own session with TCC responsibility disclaimed, so the Calendar prompt and the grant belong to `focus-daemon` (identifier `com.c-wenlong.focus-daemon`), whatever launched it (Raycast, a shell). TCC records the grant by binary path and signature: an ad-hoc build asks again after every rebuild and at every new path (Raycast's copy of the extension is a new path). `FOCUS_SIGN_IDENTITY` makes the signature stable across rebuilds.
- `FOCUS_FOREGROUND=1 focus-daemon serve` runs the server in the terminal (no disclaim; debugging only).
- `FOCUS_DEBUG=1` at launch enables `debug*` fixture commands used by the live check (create and delete calendars and events whose title starts with "Focus test"). Never set it in the extension.
- Kill with `pkill -x focus-daemon`, never `pkill -f`. A killed daemon leaves a stale socket; the next launch removes it.

## Protocol

One request per connection: a JSON object on one line, answered by one JSON line.
Success is `{"ok": true, ...}`, failure `{"ok": false, "error": "message", ...}`.
Times on the wire are ISO 8601 with the local offset (`2026-09-27T14:10:00+08:00`);
sqlite stores UTC.

| Request | Reply fields |
|---|---|
| `ping` | `version` ("0.1.0"), `pid`, `calendarAccess` |
| `calendars` | `calendars: [{id, title, account, color, writable}]`, every EventKit calendar; `account` is the source title, `color` `#RRGGBB` or null |
| `today` | `events: [{id, title, calendarId, calendarTitle, start, end, remainingSeconds}]`: today's (local midnight to midnight) non-all-day events from `startableCalendars` ending more than 60 s from now, sorted by start; overlapping events all listed |
| `status` | `session`: null or a session (below) |
| `start {eventId, start?}` | `session`. Runs until the event's planned end. |
| `startAdhoc {goal, durationSeconds, calendarId, profile?}` | `session`. `durationSeconds` 60 to 86400; planned start is now. |
| `finish {rating?, note?, reason?}` | `session` (finished), `logEventId` (string or null), `logPending` (bool). `rating` 1 to 5, `reason` "timer" or "manual" (default). |
| `pending` | `waiting: [{sessionId, goal, endedAt, logCalendarId, logCalendarName, reason}]` |
| `retryPending` | `written`, `adopted`, `stillWaiting` |
| `movePending {calendarId}` | `moved`, `written`, `adopted`, `stillWaiting` |
| `quit` | `{ok: true}`, then the daemon exits |

A session is `{id, goal, state, startedAt, plannedEnd, calendarId, profile, sourceEventId}`,
`state` being "running" or "paused" (step 2) while open. A finished session has
`state: "finished"` plus `endedAt, endReason, rating, note, logCalendarId, logCalendarName, logEventId`.

Details the client should know:

- `id` in `today` is EventKit's `eventIdentifier`, which every occurrence of a recurring event shares. Key list rows on `id` plus `start`, and pass `start` back in `start` to name the occurrence; without it the earliest startable occurrence today is used.
- `start` refuses: an event not on today's calendar, an all-day event, an ended event, one with 60 s or less left, and any start while a session is open. That last error also carries `session` (the open one).
- Calendar commands (`calendars`, `today`, `start`, `movePending`) fail without full access; the reply carries `calendarAccess` ("notDetermined", "denied", "restricted", "writeOnly") and the error says what to do. `startAdhoc`, `finish`, `status` and `pending` work without access; the log event waits.
- `movePending` refuses a missing or read-only calendar, and stores `"<title> (<account>)"` as the name.
- `finish` stores `logCalendarId` and `logCalendarName` from config at that moment; when config has an id but no name, the name is looked up in EventKit.

## Log event and recovery

Finish closes the sqlite row first, then writes the event (title = goal, real start
and end, no alarms) to the row's `log_calendar_id` and stores `log_event_id`. The
description is built by `LogText.description`:

```
Source: Work, event 7F3C...        (ad hoc: "Source: ad hoc, filed under Work")
Focused: 43 min of 48 min
Pauses: 1, 5 min in total
Blocked attempts: 3 (youtube.com 2, x.com 1), 1 snoozed
Rating: ★★★★☆                      (or "none")
Note: Shipped the draft            (line omitted without a note)
Ended: manually                    (or "when the timer ran out", ", after extending N min")

focus-session: 12
```

Every field is squashed onto one line, so only the last line can be a marker.
At launch, when access is granted, on every request after a grant made in System
Settings, and every 30 seconds (with the running session's heartbeat), each
finished, non-abandoned row with no `log_event_id` goes through `Recovery.resolve`:
a missing calendar keeps waiting; an event in that calendar within a day of the
session whose notes carry the marker line is adopted; a failed search keeps
waiting; a read-only calendar keeps waiting; otherwise the event is created.
Rows are never re-pointed except by `movePending`.

## Build and test

- `scripts/build-helper.sh` (`npm run build-helper`): `swiftc -O` with `-framework EventKit`, `helper/Info.plist` embedded as `__TEXT,__info_plist`, then `codesign` with identifier `com.c-wenlong.focus-daemon` (ad-hoc unless `FOCUS_SIGN_IDENTITY` is set).
- `scripts/test-helper.sh` (`npm run test-helper`): compiles every helper file except `main.swift` and `EventKitBackend.swift` with `test/helper/main.swift` and runs it. Rules, log text, recovery, config, protocol, sqlite and all commands over a fake calendar. Prints "all passed".
