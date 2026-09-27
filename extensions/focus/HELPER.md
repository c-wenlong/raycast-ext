# focus-daemon

The Swift half of Focus ([PLAN.md](PLAN.md), build steps 1, 2 and the engine half of 3). Sources in `helper/`,
compiled to `assets/focus-daemon` (committed). No Dock icon. The session logic
(timer, pause, extend, end sheet state, recovery) is in `Session.swift` and
`Core.swift`; the menu bar countdown and the end sheet draw it through the
`SessionPresenter` protocol in `Presenter.swift`.

## Files

All in `~/.raycast/focus/` (gitignored as `/focus/`; `FOCUS_DIR` overrides the folder):

| File | What |
|---|---|
| `focus.sock` | Unix socket, mode 0600. |
| `config.json` | Settings. Created with defaults if missing; re-read on every request; never rewritten by the helper. |
| `focus.db` | sqlite (WAL). Schema from PLAN.md; `pragma user_version` is the schema version (2: adds `sessions.extended_end`). |
| `focus.lock` | `flock` held by the running instance (holds its pid). |
| `daemon.log` | stderr of the daemon; rotated to `daemon.log.1` past 1 MB. |

## Running it

- `focus-daemon` or `focus-daemon serve`: starts the daemon unless one answers, and returns once it listens.
- `focus-daemon <cmd>` or `focus-daemon '<json>'`: sends one request, starting the daemon first if needed, prints the reply line. Exit 0 when `ok` is true, 1 when false, 2 when the daemon could not be reached.
- The daemon is spawned in its own session with TCC responsibility disclaimed, so the Calendar prompt and the grant belong to `focus-daemon` (identifier `com.c-wenlong.focus-daemon`), whatever launched it (Raycast, a shell). TCC records the grant by binary path and signature: an ad-hoc build asks again after every rebuild and at every new path (Raycast's copy of the extension is a new path). `FOCUS_SIGN_IDENTITY` makes the signature stable across rebuilds.
- `FOCUS_FOREGROUND=1 focus-daemon serve` runs the server in the terminal (no disclaim; debugging only).
- `FOCUS_DEBUG=1` at launch enables `debug*` commands used by the live checks: calendar fixtures (create and delete calendars and events whose title starts with "Focus test"), `debugBlockApp {bundleId}` (hands a running app to the blocker as if it had just come forward: macOS refuses to activate another app from a background shell), `debugBlockWindow {path}` (writes the block window as the daemon draws it to a PNG and returns `visible`, `key`, `appActive`, `title`, `button`, `frame`; `screencapture` needs Screen Recording, which a shell may lack) and `debugPressSnooze` (presses the window's Snooze). Never set it in the extension.
- Kill with `pkill -x focus-daemon`, never `pkill -f`. A killed daemon leaves a stale socket; the next launch removes it.

## Protocol

One request per connection: a JSON object on one line, answered by one JSON line.
Success is `{"ok": true, ...}`, failure `{"ok": false, "error": "message", ...}`.
Times on the wire are ISO 8601 with the local offset (`2026-09-27T14:10:00+08:00`);
sqlite stores UTC.

| Request | Reply fields |
|---|---|
| `ping` | `version` ("0.3.0"), `pid`, `calendarAccess` |
| `calendars` | `calendars: [{id, title, account, color, writable}]`, every EventKit calendar; `account` is the source title, `color` `#RRGGBB` or null |
| `today` | `events: [{id, title, calendarId, calendarTitle, start, end, remainingSeconds}]`: today's (local midnight to midnight) non-all-day events from `startableCalendars` ending more than 60 s from now, sorted by start; overlapping events all listed |
| `status` | `session`: null or the open session (below) |
| `start {eventId, start?}` | `session`. Runs until the event's planned end. |
| `startAdhoc {goal, durationSeconds, calendarId, profile?}` | `session`. `durationSeconds` 60 to 86400; planned start is now. |
| `pause` | `session`, now paused. Only from running. |
| `resume` | `session`, now running. Only from paused. |
| `extend {seconds}` | `session`. `seconds` 60 to 86400, from running, paused or ending; ending returns to running (same session, same row). |
| `stop` | `session`, now ending (the end sheet shows). Only from running or paused. |
| `finish {rating?, note?, reason?}` | `session` (finished), `logEventId` (string or null), `logPending` (bool). From running, paused or ending. `rating` 1 to 5; `reason` "timer" or "manual", default: why the session reached the end sheet, or "manual" if it never did. |
| `pending` | `waiting: [{sessionId, goal, endedAt, logCalendarId, logCalendarName, reason}]` |
| `retryPending` | `written`, `adopted`, `stillWaiting` |
| `movePending {calendarId}` | `moved`, `written`, `adopted`, `stillWaiting` |
| `blocking` | `sessionId` (the open session, or null), `active` (bool: running or at the end sheet), `profile` (name, null when idle), `profileFallbackFrom` (the unknown name asked for, else null), `mode` ("blocklist", "allowlist" or null), `blockedApps`, `blockedHosts` (blocklist mode; sorted), `allowedApps`, `allowedHosts` (allowlist mode), `snoozeSeconds`, `snoozed: [{kind, target, until}]` |
| `snooze {target, kind?}` | `kind` ("app" or "site"), `target` (hosts normalized), `until`. Lets an app (bundle id) or a host (and its subdomains) through for `snoozeSeconds`. Without `kind`: an app the session blocked or the profile lists, else a host the profile blocks, else an app when it reads as a bundle id (`com.`, `net.`, ... with three or more labels), else a host. No token, the socket is local and already trusted. Refused while blocking is off. |
| `quit` | `{ok: true}`, then the daemon exits |

A session is `{id, goal, state, startedAt, plannedEnd, calendarId, profile, sourceEventId, extendedSeconds, pausedSeconds}`.
`plannedEnd` includes extensions. While open, `state` is "running", "paused" or
"ending" (at the end sheet), plus `remainingSeconds` (whole seconds to
`plannedEnd`, 0 while ending) and `endReason` (null, or while ending "timer" or
"manual": what Finish records). A finished session has `state: "finished"` plus
`endedAt, endReason, rating, note, logCalendarId, logCalendarName, logEventId`.

Details the client should know:

- `id` in `today` is EventKit's `eventIdentifier`, which every occurrence of a recurring event shares. Key list rows on `id` plus `start`, and pass `start` back in `start` to name the occurrence; without it the earliest startable occurrence today is used.
- `start` refuses: an event not on today's calendar in one of `startableCalendars`, an all-day event, an ended event, one with 60 s or less left, and any start while a session is open. That last check runs after the others and, per PLAN, sends a running or paused session to the end sheet (as `stop` would); the error says so and carries `session` (the open one, now ending). `startAdhoc` does the same.
- `pause`, `resume`, `extend` and `stop` refuse a state they do not apply to with `ok: false` and a message to show as is: "no session is running", "the session is already paused", "the session is not paused", "the session is at the end sheet; extend or finish it (cannot pause)".
- Every request first checks the deadline, so a command never acts on a session whose planned end passed between two timer ticks.
- Calendar commands (`calendars`, `today`, `start`, `movePending`) fail without full access; the reply carries `calendarAccess` ("notDetermined", "denied", "restricted", "writeOnly") and the error says what to do. `startAdhoc`, `finish`, `status` and `pending` work without access; the log event waits.
- `movePending` refuses a missing or read-only calendar, and stores `"<title> (<account>)"` as the name.
- `finish` stores `logCalendarId` and `logCalendarName` from config at that moment; when config has an id but no name, the name is looked up in EventKit.

## Session timer and the UI

`SessionMachine` (`Session.swift`) is the lifecycle from PLAN.md as a pure value
type: `start`, `pause`, `resume`, `extend`, `stop`, `finish`, `tick` and
`abandon` in, the transition that happened out (`reachedDeadline` when a tick
finds the planned end passed while running or paused). The deadline is wall
clock: pausing does not move it. Reaching the end sheet closes an open pause,
at the planned end for the timer and at the stop for a manual stop, because
blocking is back on while the sheet waits. Extend from the end sheet counts from
now when the planned end is already behind (`max(plannedEnd, now) + seconds`), so
+5 after the sheet waited ten minutes still gives five minutes; `extended_seconds`
adds up what was asked for.

`FocusCore` persists each transition in one transaction before changing memory:
a `pauses` row on pause, `resumed_at` on resume, `extended_seconds` and
`extended_end` on extend, and `end_reason` on the still-open row while it is at
the end sheet ("timer" or "manual"; cleared by an extension, overwritten by
Finish). Everything runs on one serial queue (`FocusCore.queue`: pass the
daemon's work queue in `init(queue:)`, or the core makes its own and every entry
point hops onto it). A 1 Hz `DispatchSourceTimer` on that queue exists only
while a session is open; each tick checks the deadline and calls
`presenter.update`, and the deadline also calls `presenter.showEndSheet`. The 30 s
heartbeat and log recovery tick is unchanged.

The UI is any `SessionPresenter`, set with `core.presenter = ui`, which also
makes the core its delegate and shows the current state at once (the end
sheet too if the session is ending). Presenter calls always arrive on the main
thread; delegate calls (`presenterPause`, `presenterFinish(rating:note:)`, ...)
queue behind socket requests, and a refused one is logged and answered with a
fresh `update`. `SessionView.calendarTitle` is "" until the calendar can be
looked up. Without a UI the core uses a presenter that discards every call
(`NullPresenter`, which records them, is for tests).

Launch recovery (in `FocusCore.init`): an open row whose `last_heartbeat` is
more than 90 s old is closed with `end_reason = abandoned`, `ended_at =
last_heartbeat` (never before the start; an open pause closes there, never
before it began), no rating, no log event, and the sheet is dismissed. A fresher
one (the helper restarted quickly) is resumed as running, paused (an open pause
row) or at the end sheet (`end_reason` set), and the timer carries on.

With `raycastDeeplink` on in config, start also opens
`raycast://focus/start?goal=<goal>&duration=<seconds left>&mode=block` and
finish opens `raycast://focus/complete` (`/usr/bin/open`, not waited on). The goal
is percent-encoded with everything but unreserved characters escaped.

## Blocking

Build step 3, engine half (`Blocking.swift`, `Categories.swift`, `Matching.swift`,
`BlockEngine.swift`, `AppBlocker.swift`, `BlockWindow.swift`). The site half (the
loopback block page and the Chrome and Dia tab watcher) plugs in as
`engine.siteBlocker`, a `SiteBlocker`; `Blocking.swift` is the interface both
halves share.

Profiles live in `config.json` under `profiles`:

```json
"profiles": {
  "default": { "mode": "blocklist", "categories": ["social","messaging","gaming","entertainment","news","shopping"], "apps": [], "hosts": [] },
  "deep":    { "mode": "allowlist", "apps": ["com.microsoft.VSCode"], "hosts": ["github.com"] }
}
```

- Every key of a profile is optional: `mode` defaults to "blocklist", lists to empty. `categories` names the built-in ones in `Categories.swift` (social, messaging, gaming, entertainment, news, shopping); a profile blocks (or, in allowlist mode, allows) the union of its categories' apps and hosts plus its own. Hosts are normalized when read: lowercase, no scheme, `www.`, port or path.
- A missing or malformed `profiles` gives the built-in `default` (every category, blocklist); so does a malformed `default` entry. A malformed other entry is dropped; a list given as anything but an array (`"categories": "social"`) makes its entry malformed. A new `config.json` spells out the built-in default. Problems are logged once.
- `calendarProfiles[calendarId]` names a session's profile (ad hoc: the `profile` field of `startAdhoc`); an unknown name falls back to `default` with a log line.
- Matching (`Matching.swift`, pure): hosts by suffix on label boundaries (`youtube.com` blocks `m.youtube.com`, not `notyoutube.com`), apps by bundle id, case-insensitive. Allowlist mode inverts both; the watched `browsers` are allowed as apps there (their tabs are filtered by host). Never blocked: `localhost`, `127.0.0.1`, `[::1]`, and the apps in `Matching.alwaysAllowedApps` (Raycast, Finder, System Settings, the login window, Spotlight, Control Center, Notification Center, the daemon, plus the password prompt, notification alerts, the Dock and the menu extras).
- `FocusCore.publish` calls `blocker.sessionChanged(view, profileName:)` on the core's queue. Blocking is on while running or ending, off while paused or idle. Turning on mints a 32-byte hex token when the session is new, resolves the profile, checks the frontmost app, then `siteBlocker.start(policy:)` and `pollNow()`. Turning off calls `siteBlocker.stop()` and closes the block window; hidden apps stay hidden. While on, config is re-read at most every 5 s, and a changed profile is applied at once (frontmost check and a poll).
- Snoozes are per target (a bundle id, or a host covering its subdomains) for `snoozeSeconds`, kept through a pause, dropped when the session ends. When one runs out the frontmost app and the tabs are checked again. `snooze(host:token:)` refuses a wrong or missing token and logs it.
- Every blocked and snoozed app or site becomes a `blocked_attempts` row (kind `app` or `site`, outcome `blocked` or `snoozed`), written on the core's queue.
- Apps (`AppBlocker.swift`): on `didActivateApplicationNotification` a blocked app is hidden (again after 0.3 s and 1 s while it still shows, since a launching app can ignore the first hide) and the block window appears. Snooze unhides the app and asks LaunchServices to bring it forward; Escape or a click anywhere off the button closes the page and leaves the app hidden; another app coming forward more than 0.75 s after the page appeared closes it too.
- The block window (`BlockWindow.swift`): a borderless non-activating panel covering the screen with the mouse, at floating level (below the menu bar and the Dock, so the countdown's Stop stays reachable): black with a soft radial glow, the app's icon, "<App> has been blocked" at 28 pt semibold, one bordered button "Snooze for N minutes" (`Matching.snoozeLabel`: seconds under a minute, "2 minutes 30 seconds" for an odd length) and the footer "End your focus session to access this page". The daemon asks to activate when it shows the page so Escape reaches it; macOS can refuse that for a background app, and then a click closes it instead.

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
focus-started: 2026-09-27T06:10:00Z
```

Every field is squashed onto one line, so only the last two lines can be markers.
At launch, when access is granted, on every request after a grant made in System
Settings, and every 30 seconds (with the running session's heartbeat), each
finished, non-abandoned row with no `log_event_id` goes through `Recovery.resolve`:
a missing calendar keeps waiting; an event in that calendar within a week of the
session whose notes carry both marker lines (session id and UTC start) is adopted,
so neither a recreated `focus.db` reusing an id nor an event Kai moved can fool it; a failed search keeps
waiting; a read-only calendar keeps waiting; otherwise the event is created.
Rows are never re-pointed except by `movePending`.

## Build and test

- `scripts/build-helper.sh` (`npm run build-helper`): `swiftc -O` with `-framework EventKit`, `helper/Info.plist` embedded as `__TEXT,__info_plist`, then `codesign` with identifier `com.c-wenlong.focus-daemon` (ad-hoc unless `FOCUS_SIGN_IDENTITY` is set).
- `scripts/test-helper.sh` (`npm run test-helper`): typechecks the whole helper, then compiles the logic files (no `main.swift`, `EventKitBackend.swift` or UI files) with `test/helper/main.swift` and runs it. Rules, log text, recovery, config, protocol, sqlite and its migration, the session state machine (every transition and refusal), the deeplink URL, and all commands over a fake calendar and a recording presenter: pause, resume, extend, stop, finish, the timer reaching the deadline, UI delegate calls, and abandoned versus resumed launch recovery. Blocking: host and app matching, allowlist inversion, the always-allowed set, loopback, categories and their union, profile parsing (malformed, unknown names), and the engine over a fake workspace and a fake site blocker (on and off per state, tokens, snooze expiry, wrong tokens, attempts in sqlite, `blocking` and `snooze`). Prints "all passed".
- `scripts/test-ui.sh` (`npm run test-ui`): the menu bar, the end sheet and the block window, headless (title, snooze labels, Snooze, Escape and a click), plus the app blocker wired to a real engine. `scripts/test-ui.sh <folder>` also writes `sheet.png`, `menubar-*.png` and `block.png` there.
