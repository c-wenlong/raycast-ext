#!/usr/bin/env node
// A stand-in for assets/focus-daemon that answers the socket protocol with
// fixture data, so the Raycast commands can be driven without the Swift
// helper or Calendar access. Dev tool only; lib.test.ts uses it too.
//
//   node test/fake-daemon.js [--socket PATH] [--no-waiting]
//
// Default socket: ~/.raycast/focus/focus.sock. It reads config.json next to
// the socket on every request (startable calendars filter `today`, the log
// calendar decides whether `finish` logs or leaves the session waiting).
// It refuses to start if something already answers on the socket, so it
// never shadows a real helper. Ctrl-C stops it and removes the socket.

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
    switch (request.cmd) {
      case "ping":
        return { ok: true, version: "fake-1", pid: process.pid };
      case "calendars":
        return { ok: true, calendars: CALENDARS };
      case "today":
        return { ok: true, events: today() };
      case "status":
        return { ok: true, session: state.session };
      case "start": {
        if (state.session) return { ok: false, error: "A session is already running." };
        const event = fixtureEvents(now).find((e) => e.id === request.eventId);
        if (!event) return { ok: false, error: `No event ${request.eventId} today.` };
        if (Date.parse(event.end) - now.getTime() <= 60 * 1000) {
          return { ok: false, error: "That event has already ended." };
        }
        state.session = {
          id: state.nextId++,
          goal: event.title,
          state: "running",
          startedAt: now.toISOString(),
          plannedEnd: event.end,
          calendarId: event.calendarId,
          profile: "default",
          sourceEventId: event.id,
        };
        return { ok: true, session: state.session };
      }
      case "startAdhoc": {
        if (state.session) return { ok: false, error: "A session is already running." };
        if (typeof request.goal !== "string" || !request.goal.trim()) {
          return { ok: false, error: "goal is required." };
        }
        if (!Number.isInteger(request.durationSeconds) || request.durationSeconds <= 0) {
          return { ok: false, error: "durationSeconds must be a positive integer." };
        }
        state.session = {
          id: state.nextId++,
          goal: request.goal,
          state: "running",
          startedAt: now.toISOString(),
          plannedEnd: new Date(now.getTime() + request.durationSeconds * 1000).toISOString(),
          calendarId: request.calendarId,
          profile: request.profile || "default",
          sourceEventId: null,
        };
        return { ok: true, session: state.session };
      }
      case "finish": {
        const session = state.session;
        if (!session) return { ok: false, error: "No session is running." };
        if (request.rating !== undefined && !(Number.isInteger(request.rating) && request.rating >= 1 && request.rating <= 5)) {
          return { ok: false, error: "rating must be 1 to 5." };
        }
        state.session = null;
        const config = readConfig(configPath);
        const logCalendar = CALENDARS.find((c) => c.id === config.logCalendarId && c.writable);
        if (!logCalendar) {
          state.waiting.push({
            sessionId: session.id,
            goal: session.goal,
            endedAt: now.toISOString(),
            logCalendarName: config.logCalendarName || null,
          });
          return { ok: true, session, logEventId: null, logPending: true };
        }
        return { ok: true, session, logEventId: `log-${session.id}`, logPending: false };
      }
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

module.exports = { createFakeDaemon, CALENDARS, fixtureEvents };

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
