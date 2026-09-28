#!/usr/bin/env node
// A stand-in for assets/focus-daemon that answers the socket protocol with
// fixture data, so the Raycast commands can be driven without the Swift
// helper or Calendar access. Dev tool only; lib.test.ts uses it too.
//
//   node test/fake-daemon.js [--socket PATH] [--no-waiting]
//
// Default socket: ~/.raycast/focus/focus.sock. It reads config.json next to
// the socket on every request (startable calendars filter `today`; `finish`
// logs to the log calendar override when one is set, else to the session's
// own calendar, as the helper does, and leaves the session waiting when that
// calendar is not in the fake's list or is read-only).
// It refuses to start if something already answers on the socket, so it
// never shadows a real helper. Ctrl-C stops it and removes the socket.
//
// Sessions follow the helper's state machine (helper/Session.swift): running
// and paused go to "ending" when the planned end passes (checked on every
// request) or on stop; pause, resume, extend and stop refuse the states they
// do not apply to with the helper's messages; extend from ending counts from
// now once the deadline is behind and returns to running.
// `blocking` and `snooze` follow the helper too, simplified: the profile's
// own apps and hosts only (no category expansion), snoozes kept per session.
// `stats` aggregates the sessions finished through it (plus a seeded history
// when run by hand) with the helper's rules and writes a plain bar chart to
// stats/week.svg next to the socket.
// `deleteSession` follows the helper: the open session ends with no log
// event and goes; a finished or waiting one goes with its log event, which
// is removed only while its notes carry both marker lines (session id and
// UTC start) and `state.calendarAccess` is "fullAccess" (otherwise the reply
// warns). Log events are kept in `state.calendarEvents` ({id, calendarId,
// sessionId, notes}) so tests can rewrite notes or check what was removed.
// Their notes carry "Rating:" and "Note:" lines, which `updateSession`
// replaces (nothing else) under the same marker and access rules (the reply
// warns when the event is missing, rewritten or out of reach, or has lost its
// Rating line; the history row changes anyway).

const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const MINUTE = 60 * 1000;

const CALENDARS = [
  { id: "cal-work", title: "Work", account: "kai@work.example", color: "#3B82F6", writable: true },
  { id: "cal-work-dup", title: "Work", account: "kai@school.example", color: "#6366F1", writable: false },
  { id: "cal-study", title: "Study", account: "iCloud", color: "#10B981", writable: true },
  { id: "cal-log", title: "Focus Log", account: "Google", color: "#F59E0B", writable: true },
  { id: "cal-holidays", title: "Holidays", account: "Subscribed", color: null, writable: false },
];

// Events relative to `now`: two overlapping ones already started, one later,
// one ending in 30 s (filtered out like the real helper does), one over.
function fixtureEvents(now) {
  const at = (minutes) => new Date(now.getTime() + minutes * MINUTE).toISOString();
  return [
    { id: "ev-review", title: "Review the Focus plan", calendarId: "cal-work", start: at(-10), end: at(50) },
    { id: "ev-pset", title: "CS3230 problem set", calendarId: "cal-study", start: at(-30), end: at(30) },
    { id: "ev-deep", title: "Deep work: focus helper", calendarId: "cal-work", start: at(90), end: at(150) },
    { id: "ev-almost", title: "Almost over", calendarId: "cal-work", start: at(-60), end: new Date(now.getTime() + 30 * 1000).toISOString() },
    { id: "ev-done", title: "Standup", calendarId: "cal-work", start: at(-120), end: at(-105) },
  ];
}

// The helper's destination rule (Rules.logCalendar): the override when set,
// else the session's own calendar; null for a session filed under none.
function logDestination(sessionCalendar, override) {
  if (sessionCalendar === "none") return null;
  if (typeof override === "string" && override) return override;
  return sessionCalendar || null;
}

const calendarName = (calendar) => `${calendar.title} (${calendar.account})`;

function readConfig(configPath) {
  if (!configPath) return {};
  try {
    return JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch {
    return {};
  }
}

function createFakeDaemon(options) {
  const socketPath = options.socketPath;
  const configPath = options.configPath;
  const clock = options.now || (() => new Date());
  const state = {
    session: null,
    nextId: 1,
    requests: [],
    snoozes: [],
    // Finished sessions for `stats`: {id, goal, calendarId, sourceEventId,
    // startedAt, endedAt, pauses: [{start, end}] (ms), rating, note,
    // endReason, blockedAttempts, snoozes, logPending}.
    history: options.seedHistory ? seedHistory(clock()) : [],
    // Log events written by finish and movePending.
    calendarEvents: [],
    calendarAccess: "fullAccess",
    waiting: options.seedWaiting
      ? [
          {
            sessionId: 900,
            goal: "Yesterday's reading",
            endedAt: new Date(clock().getTime() - 20 * 60 * MINUTE).toISOString(),
            logCalendarName: "Old Log (kai@old.example)",
          },
        ]
      : [],
  };

  const calendarTitle = (id) => (CALENDARS.find((c) => c.id === id) || { title: id }).title;

  // The open session lives in `state.session` as the wire shape plus private
  // `_pauses` ({start, end}) and `_ending` (timer | manual | null).
  function openSession(event, now, extra) {
    return {
      id: state.nextId++,
      goal: event.goal,
      state: "running",
      startedAt: now.toISOString(),
      plannedEnd: event.plannedEnd,
      calendarId: event.calendarId,
      profile: event.profile,
      sourceEventId: event.sourceEventId,
      extendedSeconds: 0,
      ...extra,
      _pauses: [],
      _ending: null,
    };
  }

  function closePause(session, at) {
    const last = session._pauses[session._pauses.length - 1];
    if (last && last.end === null) last.end = Math.max(at, last.start);
  }

  function pausedSeconds(session, now) {
    const total = session._pauses.reduce((sum, p) => sum + ((p.end === null ? now : p.end) - p.start), 0);
    return Math.round(total / 1000);
  }

  // Deadline check, as the helper does before every command.
  function advance(now) {
    const session = state.session;
    if (!session || session.state === "ending") return;
    const end = Date.parse(session.plannedEnd);
    if (now.getTime() >= end) {
      closePause(session, end);
      session.state = "ending";
      session._ending = "timer";
    }
  }

  function wire(session, now) {
    if (!session) return null;
    const { _pauses, _ending, ...rest } = session;
    const remaining = Math.floor((Date.parse(session.plannedEnd) - now.getTime()) / 1000);
    return {
      ...rest,
      remainingSeconds: session.state === "ending" ? 0 : Math.max(0, remaining),
      pausedSeconds: pausedSeconds({ _pauses }, now.getTime()),
      endReason: _ending,
    };
  }

  function refuse(action) {
    const session = state.session;
    if (!session) return { ok: false, error: "no session is running" };
    if (session.state === "ending") {
      return { ok: false, error: `the session is at the end sheet; extend or finish it (cannot ${action})` };
    }
    return { ok: false, error: `the session is ${session.state}; cannot ${action}` };
  }

  // A log event whose notes end with the helper's two marker lines.
  function writeLogEvent(item, calendarId) {
    const id = `log-${item.id}`;
    state.calendarEvents.push({ id, calendarId, sessionId: item.id, notes: logNotes(item) });
    item.logEventId = id;
    return id;
  }

  // A shortened LogText.description: the rating and note lines, then the markers.
  function logNotes(item) {
    const lines = ["Source: fake", `Rating: ${stars(item.rating)}`];
    if (item.note) lines.push(`Note: ${item.note}`);
    return [...lines, "", ...markerLines(item.id, item.startedAt)].join("\n");
  }

  // The helper's two marker lines (LogText.marker, LogText.startedLine):
  // the session id and the UTC start in whole seconds.
  function markerLines(sessionId, startedAt) {
    const utc = new Date(startedAt).toISOString().replace(/\.\d{3}Z$/, "Z");
    return [`focus-session: ${sessionId}`, `focus-started: ${utc}`];
  }

  // Returns null when removed, else why the event was kept.
  function removeLogEvent(eventId, sessionId, startedAt) {
    if (state.calendarAccess !== "fullAccess") {
      return `calendar access is ${state.calendarAccess}, so the log event was left in Calendar`;
    }
    const index = state.calendarEvents.findIndex((e) => e.id === eventId);
    if (index < 0) return "the log event was not found in Calendar (deleted already, or its calendar is unavailable)";
    // Both lines, as the helper checks: a reused id with another start is not ours.
    if (!carriesMarkers(state.calendarEvents[index], sessionId, startedAt)) {
      return "the log event's notes no longer carry this session's focus-session marker, so it was left in Calendar";
    }
    state.calendarEvents.splice(index, 1);
    return null;
  }

  function carriesMarkers(event, sessionId, startedAt) {
    const lines = event.notes.split(/\r?\n/).map((line) => line.trim());
    return markerLines(sessionId, startedAt).every((marker) => lines.includes(marker));
  }

  // Returns null when the notes were rewritten, else why they were not.
  function rewriteLogEvent(item) {
    if (state.calendarAccess !== "fullAccess") {
      return `calendar access is ${state.calendarAccess}, so the log event was not updated`;
    }
    const event = state.calendarEvents.find((e) => e.id === item.logEventId);
    if (!event) {
      return "the log event was not found in Calendar (deleted already, or its calendar is unavailable), so it was not updated";
    }
    if (!carriesMarkers(event, item.id, item.startedAt)) {
      return "the log event's notes no longer carry this session's focus-session marker, so it was not updated";
    }
    const rewritten = replacingReview(event.notes, item.rating, item.note);
    if (rewritten === null) {
      return "the log event's notes no longer have the Rating line Focus wrote, so it was not updated";
    }
    event.notes = rewritten;
    return null;
  }

  // LogText.replacingReview: only Focus's Rating line (above the markers)
  // and the Note line below it change; null when that Rating line is gone.
  function replacingReview(notes, rating, note) {
    const lines = notes.split("\n");
    const marker = lines.findIndex((line) => line.trim().startsWith("focus-session: "));
    const index = lines.findIndex(
      (line, i) => (marker < 0 || i < marker) && /^Rating: (none|[★☆]{5})$/.test(line),
    );
    if (index < 0) return null;
    lines[index] = `Rating: ${stars(rating)}`;
    const hasNote = index + 1 < lines.length && lines[index + 1].startsWith("Note: ");
    const noteLine = note ? `Note: ${note}` : null;
    if (hasNote && noteLine) lines[index + 1] = noteLine;
    else if (hasNote) lines.splice(index + 1, 1);
    else if (noteLine) lines.splice(index + 1, 0, noteLine);
    return lines.join("\n");
  }

  const stars = (rating) => (typeof rating === "number" ? "★".repeat(rating) + "☆".repeat(5 - rating) : "none");

  // The helper's updateSession: a field left out keeps its value, null
  // clears it; the open session is refused.
  function updateSession(request) {
    const id = request.sessionId;
    if (id === undefined || id === null) return { ok: false, error: "sessionId is required" };
    if (!Number.isInteger(id)) return { ok: false, error: "sessionId must be a whole number" };
    const item = state.history.find((s) => s.id === id);
    if (!item) {
      if (state.session && state.session.id === id) {
        return { ok: false, error: `session ${id} is still open; finish it before editing it` };
      }
      return { ok: false, error: `no session with id ${id}` };
    }
    let rating = item.rating;
    if ("rating" in request && request.rating !== null) {
      if (!Number.isInteger(request.rating)) return { ok: false, error: "rating must be a whole number" };
      if (request.rating < 1 || request.rating > 5) return { ok: false, error: "rating must be 1 to 5" };
      rating = request.rating;
    } else if ("rating" in request) {
      rating = null;
    }
    let note = item.note;
    if ("note" in request && request.note !== null) {
      if (typeof request.note !== "string") return { ok: false, error: "note must be a string" };
      note = request.note.replace(/\s+/g, " ").trim() || null;
    } else if ("note" in request) {
      note = null;
    }
    item.rating = rating;
    item.note = note;
    const reply = { ok: true, session: historyWire(item), logEventUpdated: false };
    if (item.logEventId) {
      const warning = rewriteLogEvent(item);
      if (warning) reply.warning = warning;
      else reply.logEventUpdated = true;
    }
    return reply;
  }

  // A history row as the helper's finished-session JSON.
  function historyWire(item) {
    return {
      id: item.id,
      goal: item.goal,
      state: "finished",
      startedAt: item.startedAt,
      endedAt: item.endedAt,
      calendarId: item.calendarId,
      sourceEventId: item.sourceEventId,
      endReason: item.endReason,
      rating: item.rating,
      note: item.note,
      logEventId: item.logEventId || null,
      logSkipped: item.logSkipped === true,
    };
  }

  function deleteSession(request) {
    const id = request.sessionId;
    if (id === undefined || id === null) return { ok: false, error: "sessionId is required" };
    if (!Number.isInteger(id)) return { ok: false, error: "sessionId must be a whole number" };
    if (state.session && state.session.id === id) {
      // Ended as Cancel ends it, but nothing is kept or logged.
      state.session = null;
      state.snoozes = [];
      return { ok: true, deleted: true, logEventRemoved: false };
    }
    const index = state.history.findIndex((item) => item.id === id);
    const waitingIndex = state.waiting.findIndex((item) => item.sessionId === id);
    if (index < 0 && waitingIndex < 0) return { ok: false, error: `no session with id ${id}` };
    const item = index >= 0 ? state.history.splice(index, 1)[0] : null;
    if (waitingIndex >= 0) state.waiting.splice(waitingIndex, 1);
    const reply = { ok: true, deleted: true, logEventRemoved: false };
    if (item && item.logEventId) {
      const warning = removeLogEvent(item.logEventId, id, item.startedAt);
      if (warning) reply.warning = warning;
      else reply.logEventRemoved = true;
    }
    return reply;
  }

  function today() {
    const now = clock();
    const config = readConfig(configPath);
    const startable = Array.isArray(config.startableCalendars) ? config.startableCalendars : null;
    return fixtureEvents(now)
      .filter((e) => !startable || startable.includes(e.calendarId))
      .map((e) => ({
        ...e,
        calendarTitle: calendarTitle(e.calendarId),
        remainingSeconds: Math.round((Date.parse(e.end) - now.getTime()) / 1000),
      }))
      .filter((e) => e.remainingSeconds > 60);
  }

  function handle(request) {
    const now = clock();
    advance(now);
    switch (request.cmd) {
      case "ping":
        return { ok: true, version: "fake-1", pid: process.pid };
      case "calendars":
        return { ok: true, calendars: CALENDARS };
      case "today":
        return { ok: true, events: today() };
      case "status":
        return { ok: true, session: wire(state.session, now) };
      case "start": {
        const event = fixtureEvents(now).find((e) => e.id === request.eventId);
        if (!event) return { ok: false, error: `No event ${request.eventId} today.` };
        if (Date.parse(event.end) - now.getTime() <= 60 * 1000) {
          return { ok: false, error: "That event has already ended." };
        }
        if (state.session) return alreadyRunning(now);
        state.session = openSession(
          { goal: event.title, plannedEnd: event.end, calendarId: event.calendarId, profile: "default", sourceEventId: event.id },
          now,
        );
        return { ok: true, session: wire(state.session, now) };
      }
      case "startAdhoc": {
        if (typeof request.goal !== "string" || !request.goal.trim()) {
          return { ok: false, error: "goal is required." };
        }
        if (!Number.isInteger(request.durationSeconds) || request.durationSeconds <= 0) {
          return { ok: false, error: "durationSeconds must be a positive integer." };
        }
        if (state.session) return alreadyRunning(now);
        state.session = openSession(
          {
            goal: request.goal,
            plannedEnd: new Date(now.getTime() + request.durationSeconds * 1000).toISOString(),
            calendarId: request.calendarId,
            profile: request.profile || "default",
            sourceEventId: null,
          },
          now,
        );
        return { ok: true, session: wire(state.session, now) };
      }
      case "pause": {
        const session = state.session;
        if (session && session.state === "paused") return { ok: false, error: "the session is already paused" };
        if (!session || session.state !== "running") return refuse("pause");
        session._pauses.push({ start: now.getTime(), end: null });
        session.state = "paused";
        return { ok: true, session: wire(session, now) };
      }
      case "resume": {
        const session = state.session;
        if (session && session.state === "running") return { ok: false, error: "the session is not paused" };
        if (!session || session.state !== "paused") return refuse("resume");
        closePause(session, now.getTime());
        session.state = "running";
        return { ok: true, session: wire(session, now) };
      }
      case "extend": {
        const seconds = request.seconds;
        if (seconds === undefined || seconds === null) return { ok: false, error: "seconds is required" };
        if (!Number.isInteger(seconds) || seconds < 60 || seconds > 86400) {
          return { ok: false, error: "seconds must be a whole number from 60 to 86400" };
        }
        const session = state.session;
        if (!session) return refuse("extend");
        const from = Math.max(Date.parse(session.plannedEnd), now.getTime());
        session.plannedEnd = new Date(from + seconds * 1000).toISOString();
        session.extendedSeconds += seconds;
        if (session.state === "ending") {
          session.state = "running";
          session._ending = null;
        }
        return { ok: true, session: wire(session, now) };
      }
      case "stop": {
        const session = state.session;
        if (!session || (session.state !== "running" && session.state !== "paused")) return refuse("stop");
        closePause(session, now.getTime());
        session.state = "ending";
        session._ending = "manual";
        return { ok: true, session: wire(session, now) };
      }
      case "finish": {
        if (request.rating !== undefined && !(Number.isInteger(request.rating) && request.rating >= 1 && request.rating <= 5)) {
          return { ok: false, error: "rating must be 1 to 5." };
        }
        if (request.reason !== undefined && request.reason !== "timer" && request.reason !== "manual") {
          return { ok: false, error: 'reason must be "timer" or "manual"' };
        }
        if (!state.session) return { ok: false, error: "no session is running" };
        const open = wire(state.session, now);
        const session = {
          ...open,
          state: "finished",
          endedAt: now.toISOString(),
          endReason: request.reason || state.session._ending || "manual",
          rating: request.rating ?? null,
          note: request.note ?? null,
        };
        delete session.remainingSeconds;
        const pauses = state.session._pauses.map((p) => ({ start: p.start, end: p.end === null ? now.getTime() : p.end }));
        // The fake records no blocked attempts of its own, only snoozes; the
        // helper stores a snooze as an attempt row too, so both count them.
        const snoozed = state.snoozes.length;
        state.session = null;
        state.snoozes = [];
        const config = readConfig(configPath);
        // A session filed under no calendar ("none") is never written to one.
        const skipped = session.calendarId === "none";
        const destinationId = skipped ? null : logDestination(session.calendarId, config.logCalendarId);
        const destination = destinationId ? CALENDARS.find((c) => c.id === destinationId) : undefined;
        const writable = destination !== undefined && destination.writable;
        let destinationName = destination ? calendarName(destination) : null;
        if (destinationId && destinationId === config.logCalendarId && config.logCalendarName) {
          destinationName = config.logCalendarName;
        }
        session.logCalendarId = destinationId;
        session.logCalendarName = destinationName;
        const item = {
          id: session.id,
          goal: session.goal,
          calendarId: session.calendarId,
          sourceEventId: session.sourceEventId,
          startedAt: session.startedAt,
          endedAt: session.endedAt,
          pauses,
          rating: session.rating,
          note: session.note,
          endReason: session.endReason,
          blockedAttempts: snoozed,
          snoozes: snoozed,
          logPending: !writable && !skipped,
          logSkipped: skipped,
          logEventId: null,
        };
        state.history.push(item);
        if (skipped) return { ok: true, session, logEventId: null, logPending: false, logSkipped: true };
        if (!writable) {
          const label = destinationName || destinationId;
          state.waiting.push({
            sessionId: session.id,
            goal: session.goal,
            endedAt: now.toISOString(),
            logCalendarId: destinationId,
            logCalendarName: destinationName,
            reason: !destinationId
              ? "the session has no calendar to log to; move the waiting sessions to a calendar"
              : destination
                ? `calendar ${label} is read-only, so it cannot take the log event; move the waiting sessions to a writable calendar`
                : `calendar ${label} is not in Calendar.app`,
          });
          return { ok: true, session, logEventId: null, logPending: true, logSkipped: false };
        }
        const logEventId = writeLogEvent(item, destination.id);
        return { ok: true, session: { ...session, logEventId }, logEventId, logPending: false, logSkipped: false };
      }
      case "blocking":
        return { ok: true, ...blockingStatus(now) };
      case "snooze": {
        const target = typeof request.target === "string" ? request.target.trim() : "";
        if (!target) return { ok: false, error: "target is required" };
        const session = state.session;
        if (!session || session.state === "paused") {
          return { ok: false, error: "blocking is off: no session is running" };
        }
        const kind = request.kind || (/^(com|net|org|io|app|ru)\.[^.]+\./.test(target) ? "app" : "site");
        const until = new Date(now.getTime() + snoozeSeconds() * 1000).toISOString();
        state.snoozes.push({ kind, target, until });
        return { ok: true, kind, target, until };
      }
      case "stats":
        return stats(request, now);
      case "deleteSession":
        return deleteSession(request);
      case "updateSession":
        return updateSession(request);
      case "pending":
        return { ok: true, waiting: state.waiting };
      case "retryPending": {
        // Waiting sessions stay waiting: the fake's old calendars never return.
        return { ok: true, written: 0, adopted: 0, stillWaiting: state.waiting.length };
      }
      case "movePending": {
        const target = CALENDARS.find((c) => c.id === request.calendarId);
        if (!target || !target.writable) {
          return { ok: false, error: `Calendar ${request.calendarId} is not writable.` };
        }
        const written = state.waiting.length;
        const moved = new Set(state.waiting.map((item) => item.sessionId));
        for (const item of state.history) {
          if (!moved.has(item.id)) continue;
          item.logPending = false;
          writeLogEvent(item, target.id);
        }
        state.waiting = [];
        return { ok: true, written, adopted: 0, stillWaiting: 0 };
      }
      case "quit":
        setImmediate(() => server.close());
        return { ok: true };
      default:
        return { ok: false, error: `Unknown command: ${request.cmd}` };
    }
  }

  // The helper's rules (helper/Stats.swift): local days, focused time split
  // at midnight, pauses subtracted and clamped at zero, running sessions left
  // out, ad-hoc sessions on an unknown calendar grouped as "Ad hoc".
  function stats(request, now) {
    const days = request.days === undefined || request.days === null ? 7 : request.days;
    if (!Number.isInteger(days)) return { ok: false, error: "days must be a whole number" };
    if (days < 1 || days > 90) return { ok: false, error: "days must be 1 to 90" };
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const intervals = [];
    for (let back = days - 1; back >= 0; back--) {
      const start = new Date(today);
      start.setDate(start.getDate() - back);
      const end = new Date(start);
      end.setDate(end.getDate() + 1);
      intervals.push({ start: start.getTime(), end: end.getTime() });
    }
    const window = { start: intervals[0].start, end: intervals[intervals.length - 1].end };
    const overlap = (a, b, w) => Math.max(0, Math.min(b, w ? w.end : b) - Math.max(a, w ? w.start : a));
    const focused = (s, w) => {
      const a = Date.parse(s.startedAt);
      const b = Date.parse(s.endedAt);
      if (!(b > a)) return 0;
      const paused = s.pauses.reduce((sum, p) => {
        const from = Math.max(p.start, a);
        const to = Math.min(p.end, b);
        return to > from ? sum + overlap(from, to, w) : sum;
      }, 0);
      return Math.max(0, Math.round(overlap(a, b, w) / 1000) - Math.round(paused / 1000));
    };
    const belongs = (s, w) => {
      const a = Date.parse(s.startedAt);
      return a >= w.start ? a < w.end : Date.parse(s.endedAt) > w.start;
    };
    const totals = (w) => {
      const members = state.history.filter((s) => belongs(s, w));
      const ratings = members.map((s) => s.rating).filter((r) => typeof r === "number");
      return {
        focusedSeconds: members.reduce((sum, s) => sum + focused(s, w), 0),
        sessions: members.length,
        averageRating: ratings.length ? Math.round((ratings.reduce((x, y) => x + y, 0) / ratings.length) * 100) / 100 : null,
      };
    };
    const bucket = (s) => {
      const known = CALENDARS.find((c) => c.id === s.calendarId);
      if (known) return { calendarId: known.id, calendarTitle: known.title };
      if (!s.sourceEventId) return { calendarId: "adhoc", calendarTitle: "Ad hoc" };
      return { calendarId: s.calendarId, calendarTitle: "Unknown calendar" };
    };
    const byCalendar = new Map();
    for (const s of state.history.filter((item) => belongs(item, window))) {
      const b = bucket(s);
      const row = byCalendar.get(b.calendarId) || { ...b, focusedSeconds: 0, sessions: 0 };
      row.focusedSeconds += focused(s, window);
      row.sessions += 1;
      byCalendar.set(b.calendarId, row);
    }
    const pad = (n) => String(n).padStart(2, "0");
    const dayList = intervals.map((w) => {
      const d = new Date(w.start);
      return {
        date: `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`,
        focusedSeconds: state.history.reduce((sum, s) => sum + focused(s, w), 0),
      };
    });
    const recent = [...state.history]
      .sort((x, y) => Date.parse(y.endedAt) - Date.parse(x.endedAt) || y.id - x.id)
      .slice(0, 20)
      .map((s) => ({
        id: s.id,
        goal: s.goal,
        calendarTitle: bucket(s).calendarTitle,
        startedAt: s.startedAt,
        endedAt: s.endedAt,
        focusedSeconds: focused(s, null),
        rating: s.rating,
        note: s.note,
        endReason: s.endReason,
        blockedAttempts: s.blockedAttempts,
        snoozes: s.snoozes,
        logPending: s.logPending,
        logSkipped: s.logSkipped === true,
      }));
    return {
      ok: true,
      today: totals(intervals[intervals.length - 1]),
      week: totals(window),
      perCalendar: [...byCalendar.values()].sort(
        (x, y) => y.focusedSeconds - x.focusedSeconds || x.calendarTitle.localeCompare(y.calendarTitle),
      ),
      days: dayList,
      recent,
      waiting: state.waiting.map(({ sessionId, goal, logCalendarName, endedAt }) => ({ sessionId, goal, logCalendarName, endedAt })),
      chartPath: writeChart(dayList),
    };
  }

  // A placeholder: one rect per day, scaled to the longest, and a caption
  // saying so. It shows the image path works in the Raycast view; the real
  // chart, with its title, grid and labels, is helper/Chart.swift.
  function writeChart(dayList) {
    if (!socketPath) return null;
    const folder = path.join(path.dirname(socketPath), "stats");
    const file = path.join(folder, "week.svg");
    const max = Math.max(1, ...dayList.map((d) => d.focusedSeconds));
    const slot = 608 / dayList.length;
    const bars = dayList
      .map((d, i) => {
        const h = Math.max(2, (d.focusedSeconds / max) * 180);
        return `<rect x="${(16 + i * slot + (slot - Math.min(24, slot - 2)) / 2).toFixed(1)}" y="${(210 - h).toFixed(1)}" width="${Math.min(24, slot - 2).toFixed(1)}" height="${h.toFixed(1)}" fill="#E85C54"/>`;
      })
      .join("");
    try {
      fs.mkdirSync(folder, { recursive: true });
      fs.writeFileSync(
        file,
        `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="240"><path d="M0 0H640V240H0Z" fill="#1A1A1A"/><text x="16" y="26" font-family="-apple-system, Helvetica, sans-serif" font-size="15" fill="#8C8C8C">fake-daemon placeholder chart</text>${bars}</svg>\n`,
      );
      return file;
    } catch {
      return null;
    }
  }

  function snoozeSeconds() {
    const value = readConfig(configPath).snoozeSeconds;
    return typeof value === "number" && value > 0 ? value : 180;
  }

  function blockingStatus(now) {
    const session = state.session;
    const empty = { blockedApps: [], blockedHosts: [], allowedApps: [], allowedHosts: [] };
    const base = { profileFallbackFrom: null, ...empty, snoozeSeconds: snoozeSeconds(), snoozed: [] };
    if (!session) return { ...base, sessionId: null, active: false, profile: null, mode: null };
    const profiles = readConfig(configPath).profiles || {};
    const known = Object.prototype.hasOwnProperty.call(profiles, session.profile);
    const name = known ? session.profile : "default";
    const spec = profiles[name] || {};
    const mode = spec.mode === "allowlist" ? "allowlist" : "blocklist";
    const apps = Array.isArray(spec.apps) ? [...spec.apps].sort() : [];
    const hosts = Array.isArray(spec.hosts) ? [...spec.hosts].sort() : [];
    return {
      ...base,
      sessionId: session.id,
      active: session.state === "running" || session.state === "ending",
      profile: name,
      profileFallbackFrom: known ? null : session.profile,
      mode,
      ...(mode === "allowlist" ? { allowedApps: apps, allowedHosts: hosts } : { blockedApps: apps, blockedHosts: hosts }),
      snoozed: state.snoozes.filter((snooze) => Date.parse(snooze.until) > now.getTime()),
    };
  }

  // PLAN: starting while a session is open sends that one to the end sheet.
  function alreadyRunning(now) {
    const session = state.session;
    if (session.state === "running" || session.state === "paused") {
      closePause(session, now.getTime());
      session.state = "ending";
      session._ending = "manual";
    }
    return {
      ok: false,
      error: `a session is already running: "${session.goal}" (id ${session.id}); it is at the end sheet, finish or extend it first`,
      session: wire(session, now),
    };
  }

  const server = net.createServer((socket) => {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      let reply;
      try {
        const request = JSON.parse(buffer.slice(0, newline));
        state.requests.push(request);
        reply = handle(request);
      } catch {
        reply = { ok: false, error: "Bad request: not one JSON object." };
      }
      socket.end(`${JSON.stringify(reply)}\n`);
    });
    socket.on("error", () => undefined);
  });

  return {
    state,
    server,
    listen: () =>
      new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(socketPath, () => resolve());
      }),
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

// A week of finished sessions for `npm run fake-daemon`, relative to `now`.
function seedHistory(now) {
  const day = (back, hour, minute) => {
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - back, hour, minute);
    return d.getTime();
  };
  const session = (id, goal, calendarId, back, hour, minutes, extra = {}) => ({
    id,
    goal,
    calendarId,
    sourceEventId: calendarId === "cal-study" || calendarId === "cal-work" ? `ev-${id}` : null,
    startedAt: new Date(day(back, hour, 0)).toISOString(),
    endedAt: new Date(day(back, hour, minutes)).toISOString(),
    pauses: [],
    rating: 4,
    note: null,
    endReason: "timer",
    blockedAttempts: 0,
    snoozes: 0,
    logPending: false,
    ...extra,
  });
  return [
    session(801, "CS3230 problem set", "cal-study", 6, 10, 90, { rating: 5, note: "Finished question 3" }),
    session(802, "Review the Focus plan", "cal-work", 4, 14, 50, { blockedAttempts: 3, snoozes: 1 }),
    session(803, "Inbox zero", "scratch", 3, 9, 25, { rating: 3, endReason: "manual" }),
    session(804, "Deep work: focus helper", "cal-work", 1, 15, 120, {
      pauses: [{ start: day(1, 15, 30), end: day(1, 15, 40) }],
      note: "Stats view",
    }),
    session(805, "Reading", "cal-study", 0, 8, 12, { rating: null, endReason: "abandoned" }),
  ];
}

module.exports = { createFakeDaemon, CALENDARS, fixtureEvents, logDestination };

function answers(socketPath) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ path: socketPath });
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => resolve(false));
  });
}

async function main() {
  const args = process.argv.slice(2);
  const socketIndex = args.indexOf("--socket");
  const socketPath =
    socketIndex >= 0 ? path.resolve(args[socketIndex + 1]) : path.join(os.homedir(), ".raycast", "focus", "focus.sock");
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });
  if (fs.existsSync(socketPath)) {
    if (await answers(socketPath)) {
      console.error(`Something already answers on ${socketPath}; not starting.`);
      process.exit(1);
    }
    fs.unlinkSync(socketPath);
  }
  const daemon = createFakeDaemon({
    socketPath,
    configPath: path.join(path.dirname(socketPath), "config.json"),
    seedWaiting: !args.includes("--no-waiting"),
    seedHistory: true,
  });
  await daemon.listen();
  console.log(`fake focus-daemon listening on ${socketPath}`);
  const stop = () => {
    daemon.server.close();
    try {
      fs.unlinkSync(socketPath);
    } catch {
      // already gone
    }
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  daemon.server.on("close", stop);
  const originalHandle = daemon.state.requests.push.bind(daemon.state.requests);
  daemon.state.requests.push = (request) => {
    console.log(`<- ${JSON.stringify(request)}`);
    return originalHandle(request);
  };
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
