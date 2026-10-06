# Focus: plan

Status: built. All four steps of the build order are merged (2026-09-28):
the helper, Focus Today, Focus Settings, the session logic and its menu bar
countdown and end sheet, blocking (engine, app block window, loopback block
page, Chrome and Dia tab watcher), the Ad-hoc Session form and Focus Stats.
The daemon reports version 0.3.0. Known operational facts: macOS asks for
Calendar access and for Automation access to each browser once per binary
path (Raycast's copy is a path of its own), and while an Automation prompt
is pending every Apple Event to that browser times out. Written 2026-09-27 from an interview with Kai.
This file is the spec for the extension that will live in this folder. Update
it when a decision changes; the code follows the file, not the other way round.

## What it is

A Raycast extension plus a native Swift helper that turns calendar events into
focus sessions. It lists today's events from chosen calendars, starts a session
with app and website blocking, keeps the timer in the menu bar, asks for a
rating and a note at the end, logs everything to a local sqlite database, and
writes the actual time as a new event in the session's own calendar (or in
one log calendar for everything, when Kai sets one).

It replaces Raycast Focus so that nothing breaks if Raycast moves Focus into
the paid tier. The Raycast deeplink stays available as an optional extra.

## Decisions from the interview

| Question | Decision |
|---|---|
| Which events are startable | Only events from calendars picked in a settings page that lists every calendar Calendar.app knows about, and only while their planned end is more than one minute away. Events that already ended today are not listed; to focus on one anyway, start an ad-hoc session with its title. |
| What "start" does | Our own blocking and UI, built in the Swift helper. Optionally also fire `raycast://focus/start` so the two can run side by side during migration. |
| Where actual time goes | A new event in the session's own calendar: the calendar an ad-hoc session is filed under, or the calendar the source event lives in, so the actual block sits next to the planned one. Settings has an optional override, "Log Calendar", that sends every session's event to one calendar instead. The planned event is never edited. (Changed 2026-09-28; it was always the log calendar Kai picked, and a session finished with none picked waited.) |
| When the log event is written | Only at the end. A running or abandoned session leaves no trace on the calendar. |
| Session length from an event | Until the planned end of the event. Starting at 14:10 on a 14:00 to 15:00 event gives 50 minutes. |
| Ad-hoc sessions | Yes. A goal, a length, and a calendar to file the session under for stats. |
| How a session ends | The timer runs out and a sheet asks Extend or Finish, or Kai stops it manually at any time. |
| What the log records | Start, end, source event, pauses and resumes, every blocked attempt, the end reason, a 5-star rating and a one-line note. |
| Blocking configuration | Built-in categories (social, gaming, and the rest below) on by default, a default profile per startable calendar, and an allowlist mode. |
| What a block looks like | Like Raycast Focus: a dark block page saying "<host> has been blocked", one "Snooze for 3 minutes" button, and the footer "End your focus session to access this page". Snoozes are logged. Apps get the same page as a native window over the spot the app's window had, not the whole screen (changed 2026-10-04; it was full screen). |
| Overlapping events | Both are listed in Focus Today; Kai picks, and the session runs until the planned end of the one picked. |
| Paused past planned end | A paused calendar session goes straight to the end sheet when its planned end passes, same as a running one. An ad-hoc session's pause stops its clock instead, so it never passes its end while paused. (Changed 2026-09-28; it was every session.) |
| What pause means | A calendar session (it has a source event) takes a break inside the event: the end stays at the event's end and the countdown keeps falling. An ad-hoc session asked for a length, so pause stops the clock: the time left holds while paused and the planned end (with any extension) moves later by the pause on resume. Timed pauses resume the same way. (Kai, 2026-09-28.) |
| Browsers | Chrome and Dia for now. Both expose tab URLs over AppleScript (checked on this Mac: Dia's dictionary has `active tab`, `URL`, `title`). |
| Calendar access | EventKit through Calendar.app, which already syncs the Google account (41 CalDAV calendars found in `Calendar.sqlitedb` on 2026-09-27). No OAuth, works offline, one permission prompt. |
| Surfaces in v1 | Countdown (floating panel by default, or the menu bar or the notch), block page (a tab for sites, a card over the app's window for apps), stats view, end-of-session sheet. |
| Where it lives | `extensions/focus/` in this repo. Data in `~/.raycast/focus/` (gitignored). Helper pattern copied from `extensions/notes`. |

## Parts

| Part | Where | Job |
|---|---|---|
| Raycast commands | `extensions/focus/src/` | Focus Today (startable events), Ad-hoc Session (form), Focus Stats (list and detail), Focus Settings (form that writes `config.json`). Thin: they talk to the helper over its socket. |
| Helper `focus-daemon` | `extensions/focus/helper/`, compiled to `assets/focus-daemon` | Long-running, single instance over a unix socket like `notes-panel`. Owns EventKit, the session state machine, the timer, the menu bar item, the blocker, the overlay, the end sheet, and sqlite. |
| Config | `~/.raycast/focus/config.json` | Startable calendars, the optional log calendar override, per-calendar default profile, profiles and categories, browsers, whether to also fire the Raycast deeplink. |
| Database | `~/.raycast/focus/focus.db` | Sessions, pauses, blocked attempts. Only the helper opens it (sqlite3 C API); native Node modules do not load in Raycast, so the stats view asks the helper over the socket. |

Raycast's own menu bar commands refresh on an interval, so the per-second
countdown lives in the helper's `NSStatusItem`, not in a Raycast command.

## Session lifecycle

```
idle ──start(event | ad hoc)──▶ running ◀──resume── paused
                                  │  ▲              ▲
                                  │  └────pause─────┘
                                  ├── timer ends ──▶ ending (sheet: Extend +5/+10/+15/+25 or Finish)
                                  ├── manual stop ─▶ ending (same sheet)
                                  └── helper dies ─▶ abandoned (marked on next launch)
paused ── planned end passes ──▶ ending (calendar sessions only; the deadline is checked every second while paused too)
paused ── resume ──────────────▶ running (ad hoc: the planned end moves later by the pause)
paused ── manual stop ─────────▶ ending
ending ──Finish (rating, note)──▶ finished: sqlite row closed, log event written
```

Rules:

- Blocking is on while running and off while paused. Pauses are logged with
  their length; "focused minutes" excludes them.
- A calendar session's pause is a break inside the event: the planned end
  stays put and the countdown keeps falling. An ad-hoc session's pause stops
  the clock: the time left holds, and closing the pause (resume, stop,
  finish) moves the planned end, and any extended end, later by its length.
  An extension during an ad-hoc pause adds to that end. (Kai, 2026-09-28.)
- Extend keeps the same session and the same log row; the log event's end
  time is whatever the real end was.
- The end sheet keeps blocking on until Kai answers, so the timer running out
  does not silently unblock everything.
- An abandoned session (Mac slept through it, helper quit) gets `end = last
  heartbeat`, `end_reason = abandoned`, no rating, and no calendar event.
  The helper writes a heartbeat to sqlite every 30 seconds for this.
- If Kai starts a session while one is running, the current one goes to the
  end sheet first.
- A calendar session still paused when its planned end passes goes to the
  end sheet at that moment, exactly as if it had been running. A paused
  ad-hoc session never reaches the end sheet by time.
- Focus Today lists every startable event whose planned end is still ahead,
  overlapping ones included; the session length follows the event picked.
- Decided while building step 2a (2026-09-27):
  - Reaching the end sheet from paused closes the pause at the planned end
    (at the stop for a manual stop): the sheet keeps blocking on, so that
    time is not paused. Extend from the sheet returns to running, not paused.
  - Extend from the end sheet counts from now when the planned end is already
    behind: the new end is `max(planned end, now) + extension`. The log's
    "after extending N min" is the sum asked for.
  - The extended end is stored in a new column `extended_end` (schema 2);
    `planned_end` keeps the planned end. Since 2026-09-28 it also carries an
    ad-hoc session's closed pauses (no new column: it already held "the end
    the timer runs to"), while `extended_seconds` stays the extensions asked
    for. A restart mid-pause rebuilds the frozen time left from it and the
    open pause row. An open row at the end sheet carries
    its `end_reason` ("timer" or "manual") so a quick restart brings the sheet
    back; Finish records that reason unless the client names one.
  - Abandoned means a heartbeat more than 90 s old at launch (three missed
    30 s beats). A Mac that sleeps with the helper alive is not abandoned: on
    wake the timer finds the deadline passed and shows the end sheet.

## Blocking

- The block page mirrors Raycast Focus (screenshot from Kai on 2026-09-27):
  a dark page with the extension icon, "<host> has been blocked", one button
  "Snooze for 3 minutes", and the footer "End your focus session to access
  this page". The helper serves it from an HTTP server bound to 127.0.0.1
  only, on a random port (`/blocked?host=…&redirect=…&token=…`), so the
  button can call the helper back (`POST /snooze` with the same host and
  token) and then continue to the original URL. Nothing leaves the machine.
- Authorisation: the helper mints a random 32-byte token per session and
  puts it in every block page URL it navigates a tab to. `/snooze` grants
  nothing without a token that matches the running session; a wrong or
  missing token, a different session's token, or a `GET` gets 403 and is
  logged. The token dies with the session, so a page or process that learned
  it cannot snooze a later session.
- Encoding: `host`, `redirect` and `token` are percent-encoded as query
  components on the way in. On the way out the host is HTML-escaped before it
  is written into the page, and `redirect` is followed only if it parses as an
  absolute `http` or `https` URL; anything else drops to a blank page. The
  same escaping applies to the native window (which just sets a label, so
  markup is not interpreted there).
- Snooze allows that host or app for the configured snooze length, logged as
  a `blocked_attempts` row with `outcome = snoozed`; when it ends the normal
  rule applies again. The length is a setting, default 180 seconds like
  Raycast, and the button label reads "Snooze for N minutes" (or "N seconds"
  under a minute) from that setting, never a fixed "3".
- Apps: the helper observes `NSWorkspace.didActivateApplicationNotification`.
  When a blocked app comes forward it is hidden (`NSRunningApplication.hide`)
  and the same block page opens as a native window showing the app name
  instead of a host, as a card where the app's front window was (at least
  480 × 400, inside the screen's visible frame), so the rest of the desktop
  stays usable; the whole screen only when that window is unknown. Snooze
  unhides the app, Escape or clicking outside just closes the page. Whenever blocking turns on (session start,
  resume, extend, profile change) the helper applies the same rule to
  `NSWorkspace.shared.frontmostApplication` at once and polls both browsers
  immediately, so an app or tab that was already in front is blocked without
  waiting for a switch.
- Sites: every two seconds the helper asks Chrome and Dia for the active tab
  URL over AppleScript (one Automation permission prompt per browser). A
  blocked host gets the tab navigated to the block page with the original
  URL as `redirect`; the attempt is logged with the host.
- Matching is by host suffix (`youtube.com` also blocks `m.youtube.com`) and
  by bundle id for apps.
- Allowlist mode inverts a profile: everything not listed is blocked, with
  Raycast, Finder, the helper itself and System Settings always allowed.
- Not in scope: DNS or hosts-file blocking (needs sudo), Screen Time APIs
  (Apple only grants the entitlement to App Store apps), other browsers.

- Decided while building step 3 (2026-09-28):
  - The profile shape in `config.json` is `{mode, categories, apps, hosts}`
    per name (HELPER.md "Blocking"); a missing or malformed `profiles`, or an
    unknown profile name, gives `default`, and without a `default` of its own
    config gets the built-in one (every category, blocklist).
  - The always-allowed set also holds the password prompt
    (`com.apple.SecurityAgent`), notification alerts, the Dock and the menu
    extras, so an allowlist never hides a system prompt.
  - "Clicking outside" the native page means clicking anywhere off its
    button, since the page covers the screen; switching to another app
    closes it too. The page sits below the menu bar and the Dock.
  - A snooze that runs out re-checks the frontmost app, so a snoozed app
    that is still in front is hidden again.
  - Categories are fixed in code for now (`Categories.swift`); editing them
    in Settings is step 4.
- Decided while building step 4, settings half (2026-09-28):
  - Settings edits which categories a profile uses, not what a category
    contains: the six category lists stay in `Categories.swift`, and the TS
    side mirrors only their ids, titles and order (a test reads the Swift
    file to keep the two in step).
  - Manage Profiles saves each profile change straight to `config.json`;
    the Settings form never writes `profiles`, so neither side can overwrite
    the other's unsaved edits. Renaming or deleting a profile rewrites
    `calendarProfiles` in the same write (deleted means back to default).
  - `calendarProfiles` only keeps selected startable calendars whose profile
    is not "default".
  - Host lines must already be bare hosts (lowercase, no scheme, path, port,
    wildcard or spaces); the error names the fix ("Write youtube.com (no
    scheme)"). A leading `www.` is dropped on save, as the helper does.
  - Ad-hoc Session remembers the last calendar used in Raycast LocalStorage.

Built-in categories, each a list of bundle ids and hosts that Kai can edit in
Settings. All on by default in the default profile:

| Category | Starts with |
|---|---|
| Social | Instagram, X, Threads, Reddit, TikTok, Facebook, LinkedIn feed |
| Messaging | WhatsApp, Telegram, Discord, Messages, Slack |
| Gaming | Steam, Epic, Battle.net, chess.com, lichess |
| Entertainment | YouTube, Netflix, Twitch, Disney+, Spotify web |
| News | HN, Reddit front page, news sites |
| Shopping | Amazon, Shopee, Lazada, Carousell |

A profile is a named set of categories plus extra apps and hosts, or an
allowlist. Each startable calendar has a default profile; ad-hoc sessions pick
one in the form.

## Log event

Where it goes (Kai, 2026-09-28: "The calendar you choose is where the event
goes."), one rule:

1. If `logCalendarId` is set in config, every session's event goes there.
   This is the optional override, "Log everything to one calendar instead";
   it was the only behaviour before this date.
2. Otherwise the event goes to the session's own calendar: for an ad-hoc
   session the calendar picked in the form, for a calendar session the
   calendar the source event lives in (so the actual block sits next to the
   planned one).
3. A session filed under no calendar (`none`) is never written, as before.

So the stats bucket and the destination are the same calendar unless the
override is on. A calendar session on a read-only (subscribed) calendar
cannot take the event: it waits with the reason "read-only", and "Move
waiting sessions" is the way out. Rows that finished before this change with
no log calendar set (then they waited with "no log calendar was chosen") are
healed by recovery: on each pass a waiting row with no destination and a
calendar that EventKit has gets its destination from the rule above, then is
written like any other; a row filed under something that is not a calendar
keeps waiting, saying "calendar … is not in Calendar.app".

Written once, at Finish, to that calendar:

- Title: the source event's title, or the ad-hoc goal.
- Start and end: real start and real end (pauses included in the span).
- Description: source calendar and event id, focused minutes, pauses, blocked
  attempts, rating as five characters (★★★★☆), the note.
- Colour and alerts: none.

Order and recovery, so a session is never lost and never logged twice:

1. Finish first closes the sqlite row: `ended_at`, `end_reason`, `rating`,
   `note`, and `log_calendar_id` set by the rule above at that moment. From
   here the session is finished even if everything after fails, and its
   destination calendar is fixed: changing the setting later only affects
   later sessions.
2. The helper then creates the log event in `log_calendar_id`. Its description
   carries the line `focus-session: <sqlite id>` and the row gets
   `log_event_id` once the save returns.
3. On launch and every 30 seconds (a timer that exists from step 1; the step 2
   heartbeat rides on the same tick) the helper looks for finished rows with a
   null `log_event_id`. For each one it first searches that row's
   `log_calendar_id` over the session's span for an event whose description
   carries the session id and adopts it if found (the save succeeded but the
   id was never stored); otherwise it creates the event there. Failures are
   logged and retried on the next tick, so a calendar outage delays the log
   event but cannot duplicate it.
4. If EventKit no longer has a calendar with that `log_calendar_id`, or has it
   but cannot write to it, the row keeps waiting: the helper never re-points a
   session on its own, because a calendar that vanished from EventKit (account
   removed from Calendar.app) may still hold the saved event on Google and
   come back later. The stats view shows "N sessions waiting for <calendar
   name>" using the `log_calendar_name` stored on the row at Finish, since
   the calendar itself may no longer be there to ask, and offers "Move
   waiting sessions": to the override when one is set, otherwise a choice of
   the writable calendars. It rewrites both `log_calendar_id` and
   `log_calendar_name` to the new destination and lets step 3 run there, so
   any later waiting message names the calendar the session is actually
   bound for.
   Kai takes that step knowingly; if the old calendar returns afterwards, the
   `focus-session: <id>` line in both descriptions makes the duplicate easy to
   find and remove.

Duplicate calendars (the same Google calendar reachable through two accounts
shows twice in Calendar.app) are listed with their account name in Settings so
the right one can be picked.

## Database

```sql
create table sessions (
  id integer primary key,
  source_event_id text,        -- EKEvent identifier, null for ad hoc
  calendar_id text not null,   -- EKCalendar identifier used for stats
  goal text not null,
  profile text not null,
  planned_start text, planned_end text,   -- ISO 8601; ad hoc stores now and now + duration
  started_at text not null,
  ended_at text,
  end_reason text,             -- timer, manual, abandoned; on an open row: at the end sheet, and why
  extended_seconds integer not null default 0,
  extended_end text,           -- the end the timer runs to when not planned_end: extensions, plus an ad-hoc session's closed pauses (schema 2)
  rating integer,              -- 1 to 5
  note text,
  log_calendar_id text,        -- EKCalendar the log event was (or will be) written to, fixed at Finish
  log_calendar_name text,      -- its title and account at Finish, for messages once the calendar is gone
  log_event_id text,           -- EKEvent identifier of the written log event
  last_heartbeat text not null
);
create table pauses (
  id integer primary key, session_id integer not null references sessions(id),
  paused_at text not null, resumed_at text
);
create table blocked_attempts (
  id integer primary key, session_id integer not null references sessions(id),
  at text not null, kind text not null,   -- app, site
  target text not null,                   -- bundle id or host
  outcome text not null                   -- blocked, snoozed
);
```

Focused minutes for a session = (ended_at - started_at) - sum(pauses).

## Stats view

A Raycast List with a Detail pane, data from the helper over the socket:

- Today and this week: focused minutes, sessions, average rating.
- Per calendar: focused minutes this week, as a bar chart rendered to SVG by
  the helper and shown as an image in the Detail markdown.
- Recent sessions: goal, calendar, span, focused minutes, rating, blocked
  attempts, note.

Decided while building step 4, stats half (2026-09-28):

- The chart is focused time per day over the window (last 7 days by
  default), one column per day; the per-calendar split is a table in the
  same Detail and its own "By calendar" section, which reads better than a
  second chart in a Raycast pane.
- Days are local calendar days; a session across midnight splits its
  focused time between the two days, and counts as a session in both.
- Ad-hoc sessions filed under something that is not a calendar are grouped
  as "Ad hoc". Without Calendar access titles fall back to the stored log
  calendar name, else "Unknown calendar". No schema change: titles are looked
  up when stats are asked for.
- Blocked attempts in stats count every `blocked_attempts` row, snoozes
  included, as the log event's description does.

## Build order

Each step is its own PR through the normal loop, with tests before the window.

| Step | Delivers | Tests |
|---|---|---|
| 1 | Helper skeleton: socket, EventKit read of today's events for chosen calendars, sqlite schema, log event write with the recovery loop above running on its 30-second tick from day one. Focus Settings with its calendar half (startable calendars, log calendar) so the step can be configured; Focus Today lists and starts a session with no timer UI yet. | Duration rule (until planned end), past-event filter, sqlite round trip, log event description text, adopt-or-create recovery. |
| 2 | Timer, menu bar countdown, pause and resume, end sheet with rating and note, heartbeat and abandoned recovery, optional Raycast deeplink. | Session state machine as a pure Swift type in `Session.swift`, tested like `ListEditing.swift`. |
| 3 | Blocker: loopback block page with Snooze, app hide plus the native block window, frontmost check on every blocking start, Chrome and Dia tab polling, categories, profiles, per-calendar defaults, allowlist mode. | Host and bundle matching, allowlist inversion, always-allowed set, snooze expiry. |
| 4 | Focus Settings second half (profiles, categories, browsers, snooze length, Raycast deeplink toggle), Ad-hoc Session form, Stats view with SVG chart. | Stats aggregation over fixture rows. |

Estimate: four to six working days, most of it in step 3.

## Countdown panel (2026-09-28)

Kai asked for Raycast Focus's floating countdown. Decided while building it:

- The countdown shows in a floating panel by default (`countdownDisplay`
  `"panel"`), or in the menu bar (`"menuBar"`); never both. Focus Settings has
  a "Countdown" field, the panel's "…" menu has Move to Menu Bar, and the menu
  bar item's menu has Move to Floating Panel. The helper writes only this key
  and `panelPosition` to `config.json`, keeping every other key.
- The panel floats above every window and space, at the top centre of the
  screen with the key window by default (where the end card shows; Kai
  asked for it there on 2026-09-28, it was the top right before), and moves only by its drag handle;
  the place is saved and reset from the "…" menu. It hides at the end sheet.
- Hover shows Pause (a menu: 1, 2, 5, 10 minutes or indefinitely), Complete
  (the end sheet, as Stop), "…" (Edit opens Focus Today; Cancel finishes the
  session at once with no rating, note or sheet; Move to Menu Bar; Reset
  Panel Position) and the handle.
- A timed pause is UI state in the helper's presenter, not a session field:
  the session is paused as usual and resumed by the presenter when the time
  is up, unless it was resumed or ended first. A helper restart during a
  timed pause leaves it paused until Resume.
- Whenever a session reaches the end card (the timer runs out, or Complete
  or Stop is pressed; Cancel skips the card), a sound plays and the screen
  edges glow green for 2.5 s (2026-09-28, Kai: Finish felt silent).
- Liquid glass (2026-09-28, Kai: "this liquid glass look ... prioritise the
  liquid glass look, then the dynamic background"). The pill is a slab of
  dark green glass: on macOS 26 a clear `NSGlassEffectView` behind it, with
  the green painted on top rather than set as the glass's `tintColor`,
  because AppKit greys a glass tint in a window that is not key and this
  panel never is (checked on screen: the same tint is green in a key window
  and grey in ours). The clear style over the regular one because the
  regular one is a nearly opaque dark frost in dark mode, so the desktop
  does not show through. The rim, top highlight, sheen and bottom shade are
  drawn by the panel, over the pill and the hover row. Before macOS 26 the
  HUD blur stays, with a denser tint.
- Smooth sweep (2026-09-28, Kai: "the meter fills up one section at a
  time; I'd like the meter to move smoothly, and the speed would be
  inversely proportional to the time allocated"): the fill moves on with
  the wall clock between the once-a-second updates at 1 / total per second.
  It keeps moving while a calendar session is paused, because that pause
  does not move the planned end and the digits keep counting down; freezing
  it would leave it behind the digits and jump at resume. While an ad-hoc
  session is paused the digits hold and the reported end moves on with the
  clock, so the fill freezes with the digits and the length leaves the
  pauses out; at the resume it carries on from where it froze (2026-09-29,
  a review leftover: it used to edge forward during the pause).
- Lava lamp (2026-09-28, the second half of that ask): soft pale-green
  blobs drift slowly inside the pill so it looks alive. They are drawn in
  the glass's content, over the tint and under the sweep, text and edges,
  not behind the glass: macOS 26's glass paints over sibling views behind
  it (checked on screen), so "under glass" comes from the edges drawn on
  top. CoreAnimation only; the lamp freezes while the panel is hidden,
  while the session is paused (and dims), and under Reduce Motion.

## Notch countdown (2026-09-29)

Kai: "Let's add the notch for the focus session ... try to replicate what
HeyClicky already does." Decided while building it:

- A third display, `countdownDisplay: "notch"`, alongside the panel and the
  menu bar; one shows at a time. Settings' Countdown field lists "Notch";
  the panel's "…" and the menu bar item's menu gain Move to Notch; the
  island's "…" has Move to Floating Panel and Move to Menu Bar.
- The look copies HeyClicky, measured on this MacBook: a pure black island
  one point taller than the menu bar, flaring into the top edge, rounded
  bottom corners, content left and right of the notch, dropping into a
  taller card on hover. HeyClicky's collapsed island is 256 × 33 with a
  status badge on the left; its card is 440 × 478, black at the top easing
  to `#1C1C1B`. It opens after about 0.6 s of rest, grows in about 0.3 s
  with a small spring, and folds back about 0.1 s after the pointer leaves,
  in about 0.3 s. It shows nothing at all when it has nothing to say.
- Ours: the time on the left, a progress ring on the right (⏸ in it while
  paused), 305 × 33 on this Mac; the card holds exactly the floating panel's
  content (pill, then Pause, Complete, "…"; no drag handle, the island does
  not move) and opens after 0.5 s of rest, over 0.25 s eased, closing 0.15 s
  after the pointer leaves. No glass inside the card: the window server's
  glass would show the desktop through the black, so the pill's dark green
  tint is painted.
- Hidden while idle and while the end card shows: the card hangs right
  under the island and already says "Time's up"; the island comes back on
  an extend.
- An ad-hoc pause freezes the fill (its planned end moves on while paused),
  and the island resumes from there; the floating panel does the same, from
  one shared `PanelSweep` that reads `pauseStopsClock` from the daemon
  (2026-09-29; the island first guessed it from the digits).
- HeyClicky and the island share the notch and the level; while a session
  runs ours covers HeyClicky's and keeps its card from opening. Kai picks
  one; nothing tries to dodge the other.
## End card (2026-09-28)

Kai asked for the end sheet to replace the completion banner, float for
about 5 seconds and fade out, stay while hovered, and count as Finish with
no rating or note when left alone. Decided while building it:

- No banner. The end sheet is the card: it shows at once for every way a
  session reaches it (timer, paused past the end, Complete or Stop, a
  helper restart at the sheet), top centre of the main screen 12 pt below
  the menu bar, above the glow. There was no saved sheet position, so top
  centre is used for every case.
- It is compact, like a notification that may be ignored: about 360 by
  128 pt, the banner's type (14 pt semibold goal over 13 pt grey status),
  stars and note on one row, extend and Finish as small pills on the next.
  Every control still works (stars, note, extend, Finish, 1 to 5, Return).
- Left alone it stays opaque for 1 s, then fades slowly and linearly to
  clear over 5 s, and at 6 s finishes the session as Finish would with
  nothing filled in (no rating, no note). Kai asked for a slow fade over 5 s
  rather than a hold and a one-second cliff, then for the 1 s lag first so
  it is not abrupt. Hovering holds it at full opacity; leaving starts the
  1 s hold and the fade again.
- Using it (a click anywhere on it, a star, 1 to 5, typing a note, Extend,
  Finish, Return) cancels the auto-finish; it then waits for Finish or Extend as before, with
  blocking on. Keys in its first 0.8 s are swallowed and do not count.
- The same session's card back after an extend keeps its stars and note, and
  its auto-finish sends them (as Finish would) rather than dropping them.
- The countdown, hover and "used" flag are presenter state, not session
  state; a helper restart at the sheet shows a fresh card with a fresh 6 s.

## Open questions

None. The three from the first draft (block page behaviour, overlapping
events, paused past planned end) were answered on 2026-09-27 and folded into
the decisions table.

## Shared notch with Notes (2026-10-06)

Notes's window can attach to the menu bar or the notch (`notesPanelAttachment`
in its defaults, picked in its ⌘K palette), and while both helpers sit at
the notch they share it: Notes draws the island and the Focus controls,
Focus owns the session, the lease and the end card. Decided while building
it:

- The daemon keeps a lease in memory only (`NotchBridge.swift`): a UUID
  owner plus an expiry 3 seconds past the last claim or renew. While a
  claim is live and `countdownDisplay` is "notch", `UIPresenter` hides only
  its own island — never the menu bar item, the floating panel or the end
  card — driven by `SessionPresenter.setNotchHosted`, which Core's publish
  updates before each view. The tick and every bridge request expire dead
  claims, so a crashed or quit host hands the notch back within seconds; a
  restarted daemon has no lease and a restarted host reclaims.
- Claims are owner-scoped and non-stealing: a different owner cannot
  claim, renew or release a live one, and anything off the notch display
  clears the claim and reports `claimed: false`. A display switch away
  from the notch restores the native island the same way.
- `notchBridge` is status/claim/renew/release; `notchAction` carries
  pause, resume, stop (Complete, which reaches the normal end card) and
  extend through the ordinary `change` path, validated against the lease,
  the display and the current session id first, so stale controls never
  mutate. The `session` snapshot mirrors `SessionView` verbatim and is
  null unless the session is running or paused.
- Notes renews at 1 Hz only while its notch UI is healthy, claims after it
  has laid out its window, and falls back to floating — never covering
  Focus — when the daemon is incompatible or was lost mid-claim, probing
  in the background until the shared notch is safe again. A daemon that
  does not exist is simply a Notes-only notch.
- Hover stays Focus-like: resting 0.5 s on the collapsed strip opens it
  (the Focus tab when a session is shared), a hover-opened card can close
  0.15 s after the pointer leaves, and any click, tab pick or shortcut
  pins it until an explicit close. The end card is still Focus's: it
  appears above the shared window because it already sits at a higher
  level.
