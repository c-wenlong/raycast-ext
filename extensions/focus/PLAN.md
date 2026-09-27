# Focus: plan

Status: planned, no code yet. Written 2026-09-27 from an interview with Kai.
This file is the spec for the extension that will live in this folder. Update
it when a decision changes; the code follows the file, not the other way round.

## What it is

A Raycast extension plus a native Swift helper that turns calendar events into
focus sessions. It lists today's events from chosen calendars, starts a session
with app and website blocking, keeps the timer in the menu bar, asks for a
rating and a note at the end, logs everything to a local sqlite database, and
writes the actual time as a new event in a log calendar of Kai's choosing.

It replaces Raycast Focus so that nothing breaks if Raycast moves Focus into
the paid tier. The Raycast deeplink stays available as an optional extra.

## Decisions from the interview

| Question | Decision |
|---|---|
| Which events are startable | Only events from calendars picked in a settings page that lists every calendar Calendar.app knows about, and only while their planned end is more than one minute away. Events that already ended today are not listed; to focus on one anyway, start an ad-hoc session with its title. |
| What "start" does | Our own blocking and UI, built in the Swift helper. Optionally also fire `raycast://focus/start` so the two can run side by side during migration. |
| Where actual time goes | A new event in a log calendar Kai picks from the same calendar list. The planned event is never edited. |
| When the log event is written | Only at the end. A running or abandoned session leaves no trace on the calendar. |
| Session length from an event | Until the planned end of the event. Starting at 14:10 on a 14:00 to 15:00 event gives 50 minutes. |
| Ad-hoc sessions | Yes. A goal, a length, and a calendar to file the session under for stats. |
| How a session ends | The timer runs out and a sheet asks Extend or Finish, or Kai stops it manually at any time. |
| What the log records | Start, end, source event, pauses and resumes, every blocked attempt, the end reason, a 5-star rating and a one-line note. |
| Blocking configuration | Built-in categories (social, gaming, and the rest below) on by default, a default profile per startable calendar, and an allowlist mode. No bypass countdown. |
| Browsers | Chrome and Dia for now. Both expose tab URLs over AppleScript (checked on this Mac: Dia's dictionary has `active tab`, `URL`, `title`). |
| Calendar access | EventKit through Calendar.app, which already syncs the Google account (41 CalDAV calendars found in `Calendar.sqlitedb` on 2026-09-27). No OAuth, works offline, one permission prompt. |
| Surfaces in v1 | Menu bar countdown, full-screen block overlay, stats view, end-of-session sheet. |
| Where it lives | `extensions/focus/` in this repo. Data in `~/.raycast/focus/` (gitignored). Helper pattern copied from `extensions/notes`. |

## Parts

| Part | Where | Job |
|---|---|---|
| Raycast commands | `extensions/focus/src/` | Focus Today (startable events), Ad-hoc Session (form), Focus Stats (list and detail), Focus Settings (form that writes `config.json`). Thin: they talk to the helper over its socket. |
| Helper `focus-daemon` | `extensions/focus/helper/`, compiled to `assets/focus-daemon` | Long-running, single instance over a unix socket like `notes-panel`. Owns EventKit, the session state machine, the timer, the menu bar item, the blocker, the overlay, the end sheet, and sqlite. |
| Config | `~/.raycast/focus/config.json` | Startable calendars, log calendar, per-calendar default profile, profiles and categories, browsers, whether to also fire the Raycast deeplink. |
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
ending ──Finish (rating, note)──▶ finished: sqlite row closed, log event written
```

Rules:

- Blocking is on while running and off while paused. Pauses are logged with
  their length; "focused minutes" excludes them.
- Extend keeps the same session and the same log row; the log event's end
  time is whatever the real end was.
- The end sheet keeps blocking on until Kai answers, so the timer running out
  does not silently unblock everything.
- An abandoned session (Mac slept through it, helper quit) gets `end = last
  heartbeat`, `end_reason = abandoned`, no rating, and no calendar event.
  The helper writes a heartbeat to sqlite every 30 seconds for this.
- If Kai starts a session while one is running, the current one goes to the
  end sheet first.

## Blocking

- Apps: the helper observes `NSWorkspace.didActivateApplicationNotification`.
  When a blocked app comes forward it is hidden (`NSRunningApplication.hide`)
  and the overlay shows for three seconds with the goal and time left.
  Whenever blocking turns on (session start, resume, extend, profile change)
  the helper applies the same rule to `NSWorkspace.shared.frontmostApplication`
  at once and polls both browsers immediately, so an app or tab that was
  already in front is blocked without waiting for a switch.
- Sites: every two seconds the helper asks Chrome and Dia for the active tab
  URL over AppleScript (one Automation permission prompt per browser). A
  blocked host gets the tab navigated to a bundled "blocked" page that shows
  the goal and time left; the attempt is logged with the host.
- Matching is by host suffix (`youtube.com` also blocks `m.youtube.com`) and
  by bundle id for apps.
- Allowlist mode inverts a profile: everything not listed is blocked, with
  Raycast, Finder, the helper itself and System Settings always allowed.
- Not in scope: DNS or hosts-file blocking (needs sudo), Screen Time APIs
  (Apple only grants the entitlement to App Store apps), other browsers.

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

Written once, at Finish, to the chosen log calendar:

- Title: the source event's title, or the ad-hoc goal.
- Start and end: real start and real end (pauses included in the span).
- Description: source calendar and event id, focused minutes, pauses, blocked
  attempts, rating as five characters (★★★★☆), the note.
- Colour and alerts: none.

Order and recovery, so a session is never lost and never logged twice:

1. Finish first closes the sqlite row: `ended_at`, `end_reason`, `rating`,
   `note`, and `log_calendar_id` set to the log calendar chosen at that
   moment. From here the session is finished even if everything after fails,
   and its destination calendar is fixed: changing the setting later only
   affects later sessions.
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
  planned_start text, planned_end text,   -- ISO 8601, null for ad hoc
  started_at text not null,
  ended_at text,
  end_reason text,             -- timer, manual, abandoned
  extended_seconds integer not null default 0,
  rating integer,              -- 1 to 5
  note text,
  log_calendar_id text,        -- EKCalendar the log event was (or will be) written to, fixed at Finish
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
  target text not null                    -- bundle id or host
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

## Build order

Each step is its own PR through the normal loop, with tests before the window.

| Step | Delivers | Tests |
|---|---|---|
| 1 | Helper skeleton: socket, EventKit read of today's events for chosen calendars, sqlite schema, log event write with the recovery loop above running on its 30-second tick from day one. Focus Settings with its calendar half (startable calendars, log calendar) so the step can be configured; Focus Today lists and starts a session with no timer UI yet. | Duration rule (until planned end), past-event filter, sqlite round trip, log event description text, adopt-or-create recovery. |
| 2 | Timer, menu bar countdown, pause and resume, end sheet with rating and note, heartbeat and abandoned recovery, optional Raycast deeplink. | Session state machine as a pure Swift type in `Session.swift`, tested like `ListEditing.swift`. |
| 3 | Blocker: app hide plus overlay, frontmost check on every blocking start, Chrome and Dia tab polling, categories, profiles, per-calendar defaults, allowlist mode. | Host and bundle matching, allowlist inversion, always-allowed set. |
| 4 | Focus Settings second half (profiles, categories, browsers, Raycast deeplink toggle), Ad-hoc Session form, Stats view with SVG chart. | Stats aggregation over fixture rows. |

Estimate: four to six working days, most of it in step 3.

## Open questions

- Should the overlay stay up until the blocked app is closed, or three seconds
  as planned above?
- What happens when two startable events overlap: list both, or prefer the one
  that started later?
- Should a paused session that stays paused past the planned end go straight to
  the end sheet?
