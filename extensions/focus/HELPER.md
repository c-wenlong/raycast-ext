# focus-daemon

The Swift half of Focus ([PLAN.md](PLAN.md), build steps 1 to 3 and the stats half of 4). Sources in `helper/`,
compiled to `assets/focus-daemon` (committed). No Dock icon. The session logic
(timer, pause, extend, end sheet state, recovery) is in `Session.swift` and
`Core.swift`; the countdown (floating panel or menu bar) and the end sheet draw it through the
`SessionPresenter` protocol in `Presenter.swift`.

## Files

All in `~/.raycast/focus/` (gitignored as `/focus/`; `FOCUS_DIR` overrides the folder):

| File | What |
|---|---|
| `focus.sock` | Unix socket, mode 0600. |
| `config.json` | Settings. Created with defaults if missing; re-read on every request. The helper writes only `countdownDisplay` and `panelPosition` (see "Countdown panel"), through `ConfigFile.update`, which keeps every other key and replaces the file atomically; a file that does not parse is never written. |
| `focus.db` | sqlite (WAL). Schema from PLAN.md; `pragma user_version` is the schema version (2: adds `sessions.extended_end`). |
| `focus.lock` | `flock` held by the running instance (holds its pid). |
| `daemon.log` | stderr of the daemon; rotated to `daemon.log.1` past 1 MB. |

## Running it

- `focus-daemon` or `focus-daemon serve`: starts the daemon unless one answers, and returns once it listens.
- `focus-daemon <cmd>` or `focus-daemon '<json>'`: sends one request, starting the daemon first if needed, prints the reply line. Exit 0 when `ok` is true, 1 when false, 2 when the daemon could not be reached.
- The daemon is spawned in its own session with TCC responsibility disclaimed, so the Calendar prompt and the grant belong to `focus-daemon` (identifier `com.c-wenlong.focus-daemon`), whatever launched it (Raycast, a shell). TCC records the grant by binary path and signature: an ad-hoc build asks again after every rebuild and at every new path (Raycast's copy of the extension is a new path). The build signs with Kai's Apple Development identity when it is in the keychain (ad hoc otherwise, or `FOCUS_SIGN_IDENTITY` to choose), so on this Mac the grants survive rebuilds and Raycast's copy.
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
| `stats {days?}` | `today`, `week` (`{focusedSeconds, sessions, averageRating}`), `perCalendar: [{calendarId, calendarTitle, focusedSeconds, sessions}]`, `days: [{date, focusedSeconds}]`, `recent: [{id, goal, calendarTitle, startedAt, endedAt, focusedSeconds, rating, note, endReason, blockedAttempts, snoozes, logPending}]`, `waiting: [{sessionId, goal, logCalendarName, endedAt}]`, `chartPath`. `days` 1 to 90, default 7. See "Stats" below. |
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

## Countdown panel and completion

`UIPresenter.swift` owns both countdown displays and shows exactly one, per
`countdownDisplay` in `config.json` (`"panel"`, the default, or `"menuBar"`;
anything else is the panel). It re-reads the file whenever its modification
time, size or inode changes, so a switch in Focus Settings shows within a
second. Core is unchanged: everything below lives behind `SessionPresenter`.

- **Floating panel** (`FloatingPanel.swift`): a borderless non-activating
  `NSPanel` that never becomes key, on every space and over full-screen apps,
  one level above `.floating` (so the block window, which is `.floating`,
  never covers it; the end sheet is above both). Shown while a session is
  running or paused; hidden at the end sheet.
  Idle it is a 34 pt pill: a 22 pt chip (radius 8) with the time in 13 pt
  monospaced digits, then the goal in 13 pt semibold (cut at 220 pt). The
  chip fills green from the left with `1 - remaining / (plannedEnd - start)`,
  so an extension lowers the fill; digits over the green are drawn white.
  Paused shows a pause glyph before the digits, a dimmer chip and fill.
  Canvas `white 0.115 @ 93 %` over a HUD blur, 1 px border `white 10 %`,
  radius 14.
- **Hover**: a tracking area plus a 10 Hz pointer check while the panel shows
  (entered and exited events are not guaranteed for a background app's
  non-activating panel; each crossing counts once). Entering swaps the pill
  for the 40 pt controls row: Pause (Resume while paused; one width for
  both), Complete, "…" and a six-dot drag handle. Their glyphs are circled
  SF Symbols in 16 pt (`pause.circle`, `play.circle`, `checkmark.circle`,
  `ellipsis.circle`) in the secondary grey, as Raycast draws them. Leaving waits 150 ms. The
  window resizes over 0.15 s (`setFrame(_:display:animate:)`) while the two
  rows cross-fade. It keeps its top edge, and its right edge when its middle
  is on the right half of its screen (left edge otherwise).
- **Pause** opens a menu: 1, 2, 5, 10 minutes, Indefinitely. A timed pause
  calls `presenterPause()` and arms a timer in UIPresenter that calls
  `presenterResume()` when it fires, only if that session is still paused.
  The timer is dropped once the session shows as not paused after having
  shown paused (resumed from the panel, the menu bar or the socket; stopped;
  finished), for another session or idle, or when the pause never shows up
  within 3 s (refused). Core stays untouched: the timer is UI state, and a
  daemon restart during a timed pause leaves the session paused until Resume.
- **Complete** calls `presenterStop()` (the end sheet asks for the rating).
  **"…"**: Edit opens `raycast://extensions/c-wenlong/focus/focusToday`;
  Cancel calls `presenterFinish(rating: nil, note: nil)` (finished at once,
  reason "manual", no sheet); Move to Menu Bar writes
  `countdownDisplay: "menuBar"` and switches at once; Reset Panel Position
  writes `panelPosition: null` and moves the panel to the default place. The
  menu bar item's menu gains "Move to Floating Panel", the reverse.
- **Position**: only the handle drags the panel (`isMovableByWindowBackground`
  is off). 0.4 s after a drag ends, the idle pill's top-left is written as
  `panelPosition: {x, y}` in whole points, AppKit global coordinates (y up,
  origin at the bottom left of the main display). The default place is the
  top right of `NSScreen.main` (the screen with the key window), 12 pt below
  the visible frame's top and from its right edge. A saved place is used only
  if the pill lies fully inside some screen vertically and at least 40 pt
  across; otherwise, and when its screen goes away mid-session, the default.
  A restored or dropped panel then slides just far enough that the pill and
  the wider, taller controls row both fit in the visible frame (below the
  menu bar, clear of the Dock) of the screen it overlaps most.
- **Completion** (`Completion.swift`): when `showEndSheet` gets a session
  whose timer ran out (`EndSheet.headline` reads "Time's up") and this UI saw
  that session running or paused, it plays `NSSound(named: "Glass")` and
  orders a click-through `.screenSaver` window over every screen with a soft
  green vignette (`#2ECC71` at 85 % right at the edge, easing to nothing
  170 pt in, its inner boundary rounded to about 120 pt at the corners; nested
  fills so the corners have no seams). The glow fades in over 0.3 s, fades
  out from 1.8 s and is ordered out at 2.5 s. It is drawn once per screen
  size at half resolution and shown as layer contents (`GlowImageView`):
  drawn at full resolution it held the main thread about 1.5 s on a
  2560 × 1440 screen plus the laptop, which ate the fade-in. The end card
  shows at the same moment (no banner, no delay). A manual stop, Cancel, and
  a daemon restarted at the end sheet skip the sound and glow. The completion
  also plays on the menu bar display.
- **End card** (`EndSheet.swift`, timer and hover in `UIPresenter`): every
  `showEndSheet` (timer ran out, planned end passed while paused, Complete,
  Stop, a restart at the sheet) shows the card at once, top centre of the
  main screen (the first of `screens()`, the glow's rule), 12 pt below the
  visible frame's top, one level above the glow (`.screenSaver + 1`). It is
  a compact borderless panel, 360 pt wide and about 128 tall, radius 16,
  the floating panel's canvas and HUD blur and a window shadow: the goal
  (14 pt semibold) over "Time's up" or "Stopped · N min focused" (13 pt
  grey), the completion banner's type; five 18 pt stars with the note field
  (13 pt, "Add a note") beside them; +5/+10/+15/+25 min as 26 pt bordered
  boxes (12 pt) and Finish as a light pill with a ↩ keycap on the row
  below; 12 pt padding. It is non-activating but becomes key so 1 to 5,
  Return and typing reach it. There is no saved sheet position, so every
  case uses top centre. Left alone it lives 5 s
  (`EndSheet.autoFinishAfter`), fading from alpha 1 to 0 over all of it in
  one linear animation started when it appears (`NSAnimationContext` live,
  60 steps a second on the scheduler headless); `update` never touches the
  fade. Then `EndSheet.finish()`, the same as pressing Finish with nothing
  filled in: `presenterFinish(rating: nil, note: nil)`, reason from the
  session. The one case with something filled in is the same session's
  card back after an extend, which keeps its stars and note; its
  auto-finish sends them, as Finish would. **Hover** (a tracking area on the
  content view plus a 10 Hz poll of the pointer on the scheduler, like the
  panel; each crossing counts once) stops the countdown and snaps the card
  back to alpha 1; leaving starts the whole 5 s fade again from opaque. **Using it** (a star
  click, 1 to 5, Tab or any printable key on the card, any key or text change
  in the note field) cancels the auto-finish for good; the card then waits
  for Finish or Extend, as before. Keys in the first 0.8 s
  (`keyboardGrace`) are swallowed and do not count, so typing meant for
  another app neither answers nor keeps the card. Escape does nothing. A
  refresh of the card already up keeps its countdown; hiding it (answered,
  extended or finished elsewhere, dismissed) drops the countdown and the
  poll. `NullPresenter` is unchanged.

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

## Stats

Build step 4, stats half (`Stats.swift`, pure; `Chart.swift`, pure; the `stats` case in `Core.swift`).

- The window is the last `days` local days, today included: local midnight `days - 1` days ago to the next local midnight, from `Calendar.current`, so a DST day is 23 or 25 hours. `week` covers the window, `today` its last day, `days` every day of it oldest first (zero-filled, `date` is the local `YYYY-MM-DD`).
- Focused seconds = (ended_at − started_at) − closed pauses, never negative (an open pause on a closed row runs to the end), the same number as the log event's "Focused" line. Inside a window only the part of the session and of its pauses in the window counts, so a session across midnight splits between the two days.
- A session belongs to a window (its `sessions`, `averageRating` and calendar row) when it started in it, or started before it and was still going when it began. A running session is left out everywhere; an abandoned one counts (it has no rating). `averageRating` is the mean of the rated sessions to two decimals, null when none is rated.
- `perCalendar` is sorted by focused seconds, most first (ties by title). Titles come from EventKit when access is granted. An ad-hoc session filed under an id that is not a calendar (empty, or unknown to EventKit with access) is counted under `calendarId` "adhoc", title "Ad hoc". Without access (or for an event calendar that is gone) a session filed under its log calendar shows the stored `log_calendar_name`, anything else "Unknown calendar".
- `recent` is the last 20 finished or abandoned sessions by end, newest first. `blockedAttempts` counts every `blocked_attempts` row (snoozes included, as the log event does), `snoozes` the snoozed ones; `logPending` is a finished, non-abandoned row with no log event yet. `waiting` is `pending` without the reason.
- Every `stats` call writes the chart of `days` to `<focus dir>/stats/week.svg` (folder mode 0700, atomic write; `<focus dir>` is the folder of `config.json`) and returns its absolute path as `chartPath`, or null (and a log line) if it could not be written; the numbers still come back.
- The chart (`Chart.svg`): 640 × 264 (24 px of canvas above the heading so the image clears the line above it in the Detail), canvas `#1A1A1A`, one column per day in the accent `#E85C54` (at most 24 px wide, 4 px rounded top, square foot), a 2 px grey stub for a day with nothing, so there is exactly one `<rect>` per day. A heading and the total on top, hairline gridlines with minute ticks (steps from 5 min to a day, at most four), a value on each column up to 7 days, weekday labels ("Today" for the last) up to 14 days, a date on every few days beyond. Type is 13 to 17 px because Raycast's Detail shows the chart at about two thirds size (checked in the live window: the text, grid and rounded columns all render there, so no PNG is needed). `font-family="-apple-system, Helvetica, sans-serif"`, no script, no external reference, all text escaped.

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

- `scripts/build-helper.sh` (`npm run build-helper`): `swiftc -O` with `-framework EventKit`, `helper/Info.plist` embedded as `__TEXT,__info_plist`, then `codesign` with identifier `com.c-wenlong.focus-daemon`, signed with Kai's Apple Development identity when the keychain has it and ad hoc otherwise; `FOCUS_SIGN_IDENTITY` overrides, and an override missing from the keychain fails the build.
- `scripts/test-helper.sh` (`npm run test-helper`): typechecks the whole helper, then compiles the logic files (no `main.swift`, `EventKitBackend.swift` or UI files) with `test/helper/main.swift` and runs it. Rules, log text, recovery, config, protocol, sqlite and its migration, the session state machine (every transition and refusal), the deeplink URL, stats aggregation over fixture rows (midnight and DST days, pauses, clamps, abandoned and running sessions, calendar buckets, averages) and the chart markup, and all commands over a fake calendar and a recording presenter, `stats` end to end included: pause, resume, extend, stop, finish, the timer reaching the deadline, UI delegate calls, and abandoned versus resumed launch recovery. Blocking: host and app matching, allowlist inversion, the always-allowed set, loopback, categories and their union, profile parsing (malformed, unknown names), and the engine over a fake workspace and a fake site blocker (on and off per state, tokens, snooze expiry, wrong tokens, attempts in sqlite, `blocking` and `snooze`). Prints "all passed".
- `scripts/test-ui.sh` (`npm run test-ui`): the menu bar, the floating panel, the end sheet, the completion and the block window, headless (title, snooze labels, Snooze, Escape and a click), plus the app blocker wired to a real engine. The panel and completion run on a fake scheduler, a fake sound, fixed screens and a `config.json` in a temp folder: chip fill for running, paused and extended sessions, hover in and out with the 150 ms delay, the Pause menu and timed pauses (fired, cancelled by Resume anywhere, refused, other session), Complete, Cancel, Edit, Move to Menu Bar and back (config written, other keys kept), dragging, the saved position and its fallbacks, Reset, the completion (sound, glow, the card at once, no banner) plus every case that skips it, and the end card: its compact layout (360 wide, stars and note on one row, extend and Finish on the next, labels fitting), top centre of the given screen above the glow, alpha falling from the start (about 0.5 at 2.5 s, 0.2 at 4 s) and never raised by `update`, `presenterFinish(nil, nil)` and alpha 0 at 5 s, hover (poll and tracking area) resetting the 5 s, a star click, a digit, a typed character, a key in the note, Extend and Finish each cancelling it, keys in the grace period not counting, a refresh keeping the countdown, manual stop, paused past the end, a restart at the sheet, and extended or finished elsewhere. `scripts/test-ui.sh <folder>` also writes `sheet.png`, `card-0s.png`, `card-2.5s.png` (alpha 0.5), `card-over-glow.png`, `menubar-*.png`, `panel-*.png`, `glow.png` and `block.png` there.
- `FOCUS_UI_DEMO=1 FOCUS_FOREGROUND=1 FOCUS_DIR=<folder> focus-daemon serve` runs the UI on a fake session (no Calendar access is asked for): `FOCUS_UI_DEMO_SECONDS` (length), `FOCUS_UI_DEMO_SHEET_AFTER` (when it ends as if the timer ran out, default 20), `FOCUS_UI_DEMO_COMPLETE=1` (play the completion with the card), `FOCUS_UI_DEMO_HOVER=<from>-<to>` (seconds after the card shows: the poll sees the pointer over the card in that window and far away otherwise; real tracking-area crossings are only logged), `FOCUS_UI_DEMO_CAPTURE=<folder>` (every 0.5 s, write what the live panel and glow draw, plus `state.txt`; menus are logged and closed after 2 s; while the card shows, every 0.25 s `card-<ms>.png` at its alpha, `screen-<ms>.png` with the glow and the card where they are, and a line in `card.txt`). For a shell without Screen Recording. `FOCUS_DIR` must be short: the socket path has a length limit.

## Site blocking (block page and tab watcher)
For HELPER.md (step 3, site half): `BlockPage.swift` (HTML, pure), `BlockServer.swift` (loopback
HTTP), `BrowserWatch.swift` (AppleScript), `SiteBlocking.swift` (factory), `Blocking.swift` (interface).

## Wiring

- `engine.siteBlocker = makeSiteBlocker(log: log)` in `main.swift`. The engine calls
  `start(policy: self)` when blocking turns on, `pollNow()` right after, `stop()` when it turns off.
- The server starts on the first `start` and stays up; `stop` only stops polling. Policy held weakly.
- `Info.plist` needs `NSAppleEventsUsageDescription` (for example "Focus reads the address of the
  front tab in Chrome and Dia to block distracting sites."), or macOS may refuse the Automation
  prompt for focus-daemon.

## HTTP (127.0.0.1, random port, one request per connection)

| Request | Answer |
|---|---|
| `GET /blocked?host=&redirect=&token=` | 200 block page; 400 without `host`. `token` is only echoed into the form. |
| `POST /snooze` form `host, token, redirect` | `policy.snooze` true: 303 to `redirect` if it is an absolute http(s) URL with a host, else 303 `/blank`. False, no token, or an `Origin` other than ours or `null`: 403 "Not allowed". |
| `GET /snooze` (any non-POST) | 403 |
| `GET /blank` | 200 empty dark page |
| `GET /health` | 200 `ok` |
| other | 404; a known path with the wrong method 405 |

- Every request must carry `Host: 127.0.0.1:<port>` (or `localhost:<port>`), else 400 (DNS rebinding).
- Over 16 KB, malformed, chunked, or two `Content-Length`: 400. Reading gives up after 5 s. At most
  32 connections at once. Refusals are logged (request values escaped, cut at 200 characters).
- Every response: `Connection: close`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`,
  `X-Content-Type-Options: nosniff`, and a CSP of `default-src 'none'; style-src 'unsafe-inline'`
  (no script can run; the page has none). Chrome sends `Origin: null` on the Snooze POST because of
  the referrer policy, so `null` is accepted; the token is the real check.
- Page URLs: each value percent-encoded with `urlQueryAllowed` minus `& = + ? / # %`; the server
  decodes `+` as a space. Every value written into HTML is escaped (`& < > " '`).

## Tab watcher

- Every 2 s while started (a `DispatchSourceTimer` on its own queue), and at once on `start` and
  `pollNow`. Skips everything when `policy.token` is "". For each bundle id in `policy.browsers`
  (validated as letters, digits, dots, hyphens) that is running: read the active tab URL of the
  front window, take the host (lowercased, no port, brackets or trailing dot), skip non-http(s),
  loopback names and the block page itself, and if `isBlocked(host:)` set the tab to the block
  page (only if it still shows the URL read) and call `recordBlocked(host:)`.
- A tab showing the block page is never recorded again. Going Back to the site is a new attempt.
  The same URL read again within 4 s of a redirect is sent again but not recorded again.
- AppleScript runs in `/usr/bin/osascript` (killed after 6 s), not `NSAppleScript`, which is
  main-thread only and could stall the menu bar for up to two minutes on a hung browser. URLs go
  in as arguments, never into the script source.
- Automation permission: `AEDeterminePermissionToAutomateTarget` without prompting first. Not asked
  yet: one prompt per browser, each on its own thread; that browser is skipped until it is answered (TCC makes even the
  silent check wait while a prompt is up) and the others keep being polled. Denied (-1743) and
  other script errors are logged once per browser until it works again; -1728 (no window) is quiet.

## Tests

`scripts/test-site.sh` (the lead adds `test-site` to package.json): page escaping and labels, URL
round trips, parsing, HTTP over a real listener with a fake policy, host extraction, osascript
argument passing, and the watcher over a fake browser. `scripts/test-site.sh --demo 60` runs the
real server and watcher blocking example.com in Chrome and Dia for a live check.

Automation permission is probed with the real tab read run without a
watchdog on a thread of its own, so the first poll of each browser shows
the macOS prompt once and waits for the answer (up to 15 minutes); a grant
is cached, a denial is re-probed after a minute, and an undecided probe
backs off for 30 seconds. The in-process check
`AEDeterminePermissionToAutomateTarget` is not used: inside the daemon it
never returned. While a prompt is pending, macOS holds every Apple Event to
that browser, so other tools' reads time out (-1712) until it is answered.

## No calendar

An ad-hoc session started with `calendarId: "none"` (`Rules.noCalendar`) is
filed under no calendar: stats count it under "Ad hoc", `finish` replies
`logSkipped: true` with `logPending: false`, the row keeps `log_skipped = 1`
(schema 3) and `log_calendar_id` null, and no log event is ever written or
waited for. The session view's calendar title reads "No calendar".
