import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  ADHOC_PRESET_MINUTES,
  DEFAULT_ADHOC_MINUTES,
  LAST_CALENDAR_KEY,
  adhocCalendarGone,
  adhocCalendarInfo,
  adhocProfileFor,
  adhocRefusedText,
  adhocStartedText,
  initialAdhocCalendar,
  lastAdhocCalendar,
  rememberAdhocCalendar,
  resolveAdhocMinutes,
  NO_CALENDAR,
} from "../src/lib/adhoc";
import {
  ConfigError,
  defaultConfig,
  readConfig,
  updateConfig,
  writeConfig,
} from "../src/lib/config";
import {
  DaemonError,
  EXTEND_MINUTES,
  FocusDaemon,
  NO_RATING,
  calendarLabel,
  deleteToastText,
  editSessionRequest,
  editSessionValues,
  finishToastText,
  sendRequest,
  updateToastText,
} from "../src/lib/daemon";
import {
  blockingText,
  effectiveSession,
  pausedSecondsNow,
  pausedText,
  sessionActions,
  sessionStatusText,
} from "../src/lib/session";
import {
  appPickerItems,
  alignSelection,
  CATEGORIES,
  applyProfileDelete,
  applyProfileSave,
  builtInDefault,
  bundleIdProblem,
  calendarProfileValue,
  categoryTitle,
  dedupeApps,
  draftFor,
  entrySummary,
  hostProblem,
  normalizeHosts,
  parseProfile,
  profileEntries,
  profileNames,
  profileSummary,
  pruneCalendarProfiles,
  remapCalendarProfiles,
  splitLines,
  validateProfile,
} from "../src/lib/profiles";
import {
  COUNTDOWN_OPTIONS,
  LOG_CALENDAR_INFO,
  OWN_CALENDAR,
  SNOOZE_MINUTES,
  browserOptions,
  isCountdownDisplay,
  logCalendarValue,
  logDestinationText,
  moveTargets,
  resolveLogCalendar,
  settingsChoices,
  snoozeOptions,
} from "../src/lib/settings";
import {
  attemptsText,
  averageRatingText,
  calendarTable,
  chartMarkdown,
  dayLabel,
  endReasonText,
  escapeMarkdown,
  focusedText,
  lastDaysLabel,
  overviewMarkdown,
  ratingText,
  recentMarkdown,
  sessionsText,
  spanText,
  totalsText,
  waitingMarkdown,
} from "../src/lib/stats";
import {
  durationText,
  formatClock,
  formatTimeRange,
  groupEvents,
  remainingText,
  stars,
} from "../src/lib/time";
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { createFakeDaemon } = require("./fake-daemon.js");
// The stub @raycast/api (esbuild aliases the import), for its LocalStorage.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const raycastStub = require("@raycast/api");

type Case = [string, () => Promise<void>];

// Short prefix: unix socket paths are capped at 104 bytes on macOS.
function freshDir(): string {
  return mkdtempSync(path.join(tmpdir(), "fx-"));
}

async function rejectsWith(
  promise: Promise<unknown>,
  code: string,
  pattern?: RegExp,
): Promise<DaemonError> {
  try {
    await promise;
  } catch (error) {
    assert.ok(error instanceof DaemonError, `not a DaemonError: ${error}`);
    assert.equal(error.code, code, error.message);
    if (pattern) assert.match(error.message, pattern);
    return error;
  }
  assert.fail(`expected a ${code} error`);
}

// A one-shot server: records what each connection sent and lets the test
// script the reply.
function scriptedServer(
  socketPath: string,
  onRequest: (raw: string, socket: net.Socket) => void,
): Promise<{ received: string[]; close: () => Promise<void> }> {
  const received: string[] = [];
  const server = net.createServer((socket) => {
    let raw = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      raw += chunk;
      if (raw.includes("\n")) {
        received.push(raw);
        onRequest(raw, socket);
      }
    });
    socket.on("error", () => undefined);
  });
  return new Promise((resolve) => {
    server.listen(socketPath, () =>
      resolve({
        received,
        close: () => new Promise<void>((done) => server.close(() => done())),
      }),
    );
  });
}

const at = (base: Date, seconds: number) =>
  new Date(base.getTime() + seconds * 1000).toISOString();

const cases: Case[] = [
  // ---- config ----
  [
    "config: a missing file (and folder) reads as the defaults",
    async () => {
      const file = path.join(freshDir(), "nope", "config.json");
      assert.deepEqual(await readConfig(file), defaultConfig());
      assert.deepEqual(defaultConfig(), {
        startableCalendars: [],
        logCalendarId: null,
        logCalendarName: null,
        calendarProfiles: {},
        profiles: {},
        browsers: ["com.google.Chrome", "company.thebrowser.dia"],
        snoozeSeconds: 180,
        raycastDeeplink: false,
        countdownDisplay: "panel",
        panelPosition: null,
      });
    },
  ],
  [
    "config: countdown display and panel position read, fall back and round-trip",
    async () => {
      const file = path.join(freshDir(), "config.json");
      // As the helper writes it: sorted keys, whole points.
      writeFileSync(
        file,
        JSON.stringify({
          countdownDisplay: "menuBar",
          panelPosition: { x: 1204, y: 870 },
          snoozeSeconds: 300,
        }),
      );
      const config = await readConfig(file);
      assert.equal(config.countdownDisplay, "menuBar");
      assert.deepEqual(config.panelPosition, { x: 1204, y: 870 });
      // Saving the Settings form (which never writes panelPosition) keeps
      // the helper's position, and switches the display.
      await writeConfig(
        { countdownDisplay: "panel", snoozeSeconds: 180 },
        file,
      );
      const saved = JSON.parse(readFileSync(file, "utf8"));
      assert.equal(saved.countdownDisplay, "panel");
      assert.deepEqual(saved.panelPosition, { x: 1204, y: 870 });
      // Bad values fall back: an unknown display is the panel, a position
      // that is not two finite numbers is null.
      for (const [display, position] of [
        ["dock", { x: "1", y: 2 }],
        [3, [1, 2]],
        [null, { x: 1 }],
        ["menubar", "top right"],
      ] as const) {
        writeFileSync(
          file,
          JSON.stringify({
            countdownDisplay: display,
            panelPosition: position,
          }),
        );
        const fallback = await readConfig(file);
        assert.equal(fallback.countdownDisplay, "panel");
        assert.equal(fallback.panelPosition, null);
      }
      // Negative and fractional positions are fine (a screen left of the main one).
      writeFileSync(
        file,
        JSON.stringify({ panelPosition: { x: -1500.5, y: 20 } }),
      );
      assert.deepEqual((await readConfig(file)).panelPosition, {
        x: -1500.5,
        y: 20,
      });
    },
  ],
  [
    "config: partial files fill defaults, bad types fall back, unknown keys stay",
    async () => {
      const file = path.join(freshDir(), "config.json");
      writeFileSync(
        file,
        JSON.stringify({
          startableCalendars: ["a", 7, "b"],
          logCalendarId: 42,
          snoozeSeconds: -1,
          raycastDeeplink: "yes",
          calendarProfiles: { a: "deep", b: 3 },
          futureKey: { nested: [1, 2] },
        }),
      );
      const config = await readConfig(file);
      assert.deepEqual(config.startableCalendars, ["a", "b"]);
      assert.equal(config.logCalendarId, null);
      assert.equal(config.snoozeSeconds, 180);
      assert.equal(config.raycastDeeplink, false);
      assert.deepEqual(config.calendarProfiles, { a: "deep" });
      assert.deepEqual(config.browsers, defaultConfig().browsers);
      assert.deepEqual(config.futureKey, { nested: [1, 2] });
    },
  ],
  [
    "config: writes keep unknown keys and untouched known keys, atomically",
    async () => {
      const dir = path.join(freshDir(), "focus");
      const file = path.join(dir, "config.json");
      // Creates the folder when it is missing.
      await writeConfig({ startableCalendars: ["x"] }, file);
      assert.deepEqual(
        JSON.parse(readFileSync(file, "utf8")).startableCalendars,
        ["x"],
      );

      // Someone else (the helper, a hand edit) changes the file after the
      // form loaded; the next save must not lose it.
      const onDisk = JSON.parse(readFileSync(file, "utf8"));
      onDisk.snoozeSeconds = 300;
      onDisk.profiles = { deep: { categories: ["social"] } };
      onDisk.helperOnly = "keep me";
      writeFileSync(file, JSON.stringify(onDisk));

      const written = await writeConfig(
        {
          startableCalendars: ["a", "b"],
          logCalendarId: "log",
          logCalendarName: "Focus Log (Google)",
        },
        file,
      );
      const text = readFileSync(file, "utf8");
      assert.ok(text.endsWith("}\n"), "ends with a newline");
      const saved = JSON.parse(text);
      assert.deepEqual(saved, written);
      assert.deepEqual(saved.startableCalendars, ["a", "b"]);
      assert.equal(saved.logCalendarId, "log");
      assert.equal(saved.logCalendarName, "Focus Log (Google)");
      assert.equal(saved.snoozeSeconds, 300);
      assert.deepEqual(saved.profiles, { deep: { categories: ["social"] } });
      assert.equal(saved.helperOnly, "keep me");
      // Known keys first in schema order, unknown keys after.
      assert.deepEqual(Object.keys(saved), [
        ...Object.keys(defaultConfig()),
        "helperOnly",
      ]);
      // Clearing the log calendar writes explicit nulls.
      await writeConfig({ logCalendarId: null, logCalendarName: null }, file);
      const cleared = JSON.parse(readFileSync(file, "utf8"));
      assert.equal(cleared.logCalendarId, null);
      assert.equal(cleared.logCalendarName, null);
      assert.equal(cleared.helperOnly, "keep me");
      // No temp files left behind.
      assert.deepEqual(readdirSync(dir), ["config.json"]);
    },
  ],
  [
    "config: a corrupt file is an error on read and is never overwritten",
    async () => {
      const file = path.join(freshDir(), "config.json");
      writeFileSync(file, "{ not json");
      await assert.rejects(readConfig(file), (error: unknown) => {
        assert.ok(error instanceof ConfigError);
        assert.match(error.message, /not valid JSON/);
        assert.ok(error.message.includes(file));
        return true;
      });
      await assert.rejects(
        writeConfig({ startableCalendars: [] }, file),
        ConfigError,
      );
      assert.equal(readFileSync(file, "utf8"), "{ not json");
      writeFileSync(file, "[1, 2]");
      await assert.rejects(readConfig(file), /must hold a JSON object/);
    },
  ],

  // ---- time ----
  [
    "time: Now/Later split and the one-minute rule at their boundaries",
    async () => {
      const now = new Date(2026, 8, 27, 14, 10, 0);
      const events = [
        {
          id: "later",
          title: "later",
          start: at(now, 0.001),
          end: at(now, 3600),
        },
        {
          id: "starts-now",
          title: "starts now",
          start: at(now, 0),
          end: at(now, 3600),
        },
        {
          id: "ends-60",
          title: "ends in exactly 60 s",
          start: at(now, -600),
          end: at(now, 60),
        },
        {
          id: "ends-61",
          title: "ends in 61 s",
          start: at(now, -600),
          end: at(now, 61),
        },
        {
          id: "ended",
          title: "ended",
          start: at(now, -7200),
          end: at(now, -3600),
        },
        { id: "bad", title: "bad date", start: "garbage", end: at(now, 3600) },
        {
          id: "overlap-b",
          title: "b",
          start: at(now, -600),
          end: at(now, 3000),
        },
        {
          id: "overlap-a",
          title: "a",
          start: at(now, -600),
          end: at(now, 3000),
        },
      ];
      const groups = groupEvents(events, now);
      assert.deepEqual(
        groups.now.map((e) => e.id),
        ["ends-61", "overlap-a", "overlap-b", "starts-now"],
      );
      assert.deepEqual(
        groups.later.map((e) => e.id),
        ["later"],
      );
      assert.deepEqual(groupEvents([], now), { now: [], later: [] });
    },
  ],
  [
    "time: remaining text rounds minutes up and switches to hours",
    async () => {
      // 14:10:10 on a 14:00-15:00 event: 49 min 50 s left.
      assert.equal(remainingText(2990), "50 min left");
      assert.equal(remainingText(3000), "50 min left");
      assert.equal(remainingText(61), "2 min left");
      assert.equal(remainingText(60), "1 min left");
      assert.equal(remainingText(1), "1 min left");
      assert.equal(remainingText(0), "ended");
      assert.equal(remainingText(-5), "ended");
      assert.equal(remainingText(Number.NaN), "ended");
      assert.equal(remainingText(3600), "1 h left");
      assert.equal(remainingText(3601), "1 h 1 min left");
      assert.equal(remainingText(3900), "1 h 5 min left");
      assert.equal(durationText(7200), "2 h");
      assert.equal(durationText(59 * 60), "59 min");
    },
  ],
  [
    "time: clock, range and stars formatting",
    async () => {
      const start = new Date(2026, 8, 27, 9, 5);
      const end = new Date(2026, 8, 27, 15, 0);
      assert.equal(formatClock(start), "09:05");
      assert.equal(
        formatTimeRange(start.toISOString(), end.toISOString()),
        "09:05–15:00",
      );
      const late = new Date(2026, 8, 27, 23, 0);
      const nextDay = new Date(2026, 8, 28, 1, 30); // a Monday
      assert.equal(
        formatTimeRange(late.toISOString(), nextDay.toISOString()),
        "23:00–Mon 01:30",
      );
      assert.equal(formatTimeRange("x", end.toISOString()), "?");
      assert.equal(stars(4), "★★★★☆");
      assert.equal(stars(5), "★★★★★");
      assert.equal(stars(1), "★☆☆☆☆");
      assert.equal(stars(9), "★★★★★");
      assert.equal(stars(0), "☆☆☆☆☆");
      assert.equal(
        calendarLabel({ title: "Work", account: "kai@work.example" }),
        "Work (kai@work.example)",
      );
    },
  ],

  // ---- settings and waiting-session decisions ----
  [
    "settings: unavailable calendars stay selectable and survive a save",
    async () => {
      const calendars = [
        { id: "w", title: "Work", account: "a", color: "#000", writable: true },
        { id: "w2", title: "Work", account: "a", color: null, writable: true },
        {
          id: "ro",
          title: "Holidays",
          account: "b",
          color: null,
          writable: false,
        },
      ];
      const config = {
        ...defaultConfig(),
        startableCalendars: ["w", "gone"],
        logCalendarId: "old-log",
        logCalendarName: "Old Log (x)",
      };
      const choices = settingsChoices(calendars, config);
      assert.deepEqual(choices.missingStartable, ["gone"]);
      assert.deepEqual(
        choices.writable.map((c) => c.id),
        ["w", "w2"],
      );
      assert.deepEqual(choices.unavailableLog, {
        id: "old-log",
        title: "Old Log (x) (unavailable)",
      });
      // Keeping the unavailable log calendar keeps its stored name.
      assert.deepEqual(resolveLogCalendar("old-log", calendars, config), {
        logCalendarId: "old-log",
        logCalendarName: "Old Log (x)",
      });
      assert.deepEqual(resolveLogCalendar("w2", calendars, config), {
        logCalendarId: "w2",
        logCalendarName: "Work (a)",
      });
      assert.deepEqual(resolveLogCalendar(OWN_CALENDAR, calendars, config), {
        logCalendarId: null,
        logCalendarName: null,
      });
      assert.deepEqual(resolveLogCalendar("stranger", calendars, config), {
        logCalendarId: null,
        logCalendarName: null,
      });
      // A saved log calendar that became read-only is also flagged.
      const readOnly = settingsChoices(calendars, {
        ...config,
        logCalendarId: "ro",
      });
      assert.equal(readOnly.unavailableLog?.id, "ro");
      assert.equal(
        settingsChoices(calendars, { ...config, logCalendarId: "w" })
          .unavailableLog,
        null,
      );
      assert.equal(
        settingsChoices(calendars, defaultConfig()).unavailableLog,
        null,
      );
    },
  ],
  [
    "settings: the log calendar is an optional override, own calendar first",
    async () => {
      // No override saved: the dropdown shows "Each session's own calendar".
      assert.equal(logCalendarValue(defaultConfig()), OWN_CALENDAR);
      assert.equal(
        logCalendarValue({ ...defaultConfig(), logCalendarId: "w" }),
        "w",
      );
      // Choosing it (or an empty value) saves no override.
      for (const value of [OWN_CALENDAR, ""]) {
        assert.deepEqual(resolveLogCalendar(value, [], defaultConfig()), {
          logCalendarId: null,
          logCalendarName: null,
        });
      }
      assert.match(LOG_CALENDAR_INFO, /^Optional\./);
      assert.match(LOG_CALENDAR_INFO, /calendar the session belongs to/);
      assert.equal(
        logDestinationText(null),
        "logging each session to its own calendar",
      );
      assert.equal(
        logDestinationText("Log (x)"),
        "logging every session to Log (x)",
      );
    },
  ],
  [
    "config: a null override survives a save and a read",
    async () => {
      const file = path.join(freshDir(), "config.json");
      await writeConfig(
        { logCalendarId: "w", logCalendarName: "Work (a)" },
        file,
      );
      const { logCalendarId, logCalendarName } = resolveLogCalendar(
        OWN_CALENDAR,
        [],
        await readConfig(file),
      );
      await writeConfig({ logCalendarId, logCalendarName }, file);
      const raw = JSON.parse(readFileSync(file, "utf8"));
      assert.equal(raw.logCalendarId, null);
      assert.equal(raw.logCalendarName, null);
      const back = await readConfig(file);
      assert.equal(back.logCalendarId, null);
      assert.equal(logCalendarValue(back), OWN_CALENDAR);
    },
  ],
  [
    "settings: the move action targets the override by id, else offers every writable calendar",
    async () => {
      const calendars = [
        { id: "w", title: "Work", account: "a", color: null, writable: true },
        {
          id: "ro",
          title: "Holidays",
          account: "b",
          color: null,
          writable: false,
        },
        { id: "w2", title: "Work", account: "a", color: null, writable: true },
      ];
      // No override: a submenu of the writable calendars, by id.
      assert.deepEqual(moveTargets(defaultConfig(), calendars), {
        kind: "menu",
        targets: [
          { id: "w", name: "Work (a)" },
          { id: "w2", name: "Work (a)" },
        ],
      });
      // Nothing writable (or no access): no action.
      assert.equal(moveTargets(defaultConfig(), [calendars[1]]), null);
      assert.equal(moveTargets(defaultConfig(), []), null);
      // The override: one action. Two calendars can share "Work (a)"; the
      // target is the id.
      assert.deepEqual(
        moveTargets(
          {
            ...defaultConfig(),
            logCalendarId: "w2",
            logCalendarName: "Work (a)",
          },
          calendars,
        ),
        { kind: "single", target: { id: "w2", name: "Work (a)" } },
      );
      assert.deepEqual(
        moveTargets({ ...defaultConfig(), logCalendarId: "w2" }, []),
        { kind: "single", target: { id: "w2", name: "the log calendar" } },
      );
    },
  ],
  [
    "adhoc: the Calendar info says where the log event goes",
    async () => {
      const own = adhocCalendarInfo(defaultConfig());
      assert.match(own, /log event is written to this calendar too/);
      assert.match(own, /read-only/);
      assert.match(own, /\(No Calendar\)/);
      const override = adhocCalendarInfo({
        logCalendarId: "log",
        logCalendarName: "Focus Log (Google)",
      });
      assert.match(override, /goes to Focus Log \(Google\), the log calendar/);
      assert.doesNotMatch(override, /written to this calendar/);
      assert.match(
        adhocCalendarInfo({ logCalendarId: "log", logCalendarName: null }),
        /goes to the log calendar/,
      );
    },
  ],
  [
    "finish: the toast names the calendar the helper chose",
    async () => {
      const session = {
        id: 1,
        goal: "g",
        state: "finished" as const,
        startedAt: "",
        plannedEnd: null,
        calendarId: "w",
        profile: "default",
        sourceEventId: null,
      };
      const result = (over: object, sessionOver: object = {}) => ({
        session: { ...session, ...sessionOver },
        logEventId: null,
        logPending: false,
        logSkipped: false,
        ...over,
      });
      assert.equal(
        finishToastText(result({}, { logCalendarName: "Work (a)" }), null),
        "Logged to Work (a)",
      );
      assert.equal(
        finishToastText(result({}, { logCalendarName: "Work (a)" }), "Log (x)"),
        "Logged to Work (a)",
      );
      assert.equal(finishToastText(result({}), "Log (x)"), "Logged to Log (x)");
      assert.equal(finishToastText(result({}), null), "Logged");
      assert.equal(
        finishToastText(
          result({ logPending: true }, { logCalendarName: "Holidays (b)" }),
          null,
        ),
        "The log event is waiting for Holidays (b)",
      );
      assert.equal(
        finishToastText(result({ logPending: true }), null),
        "The log event is waiting; see Focus Today",
      );
      // The helper returned the destination without a name (no access): the
      // config's override name, which may be stale, is not used.
      assert.equal(
        finishToastText(
          result({ logPending: true }, { logCalendarName: null }),
          "Old override (x)",
        ),
        "The log event is waiting; see Focus Today",
      );
      assert.equal(
        finishToastText(result({ logSkipped: true }), "Log (x)"),
        "Not logged: the session had no calendar",
      );
    },
  ],

  // ---- daemon client: framing ----
  [
    "daemon: one JSON line out, reply read up to its newline across chunks",
    async () => {
      const socketPath = path.join(freshDir(), "s.sock");
      const server = await scriptedServer(socketPath, (_raw, socket) => {
        // The reply arrives in three pieces, with trailing junk after the
        // newline that must be ignored.
        socket.write('{"ok":true,"sess');
        setTimeout(() => socket.write('ion":null}'), 20);
        setTimeout(() => socket.end("\ntrailing junk"), 40);
      });
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      assert.equal(
        await daemon
          .start("e1", "2026-09-27T14:00:00+08:00")
          .catch((error) => error.message),
        'The Focus helper\'s reply is missing a valid "session".',
      );
      assert.equal(await daemon.status(), null);
      assert.equal(server.received.length, 2);
      for (const raw of server.received) {
        assert.ok(raw.endsWith("\n"));
        assert.equal(
          raw.indexOf("\n"),
          raw.length - 1,
          "exactly one newline, at the end",
        );
      }
      // Recurring occurrences share an id, so the occurrence start goes along.
      assert.deepEqual(JSON.parse(server.received[0]), {
        eventId: "e1",
        start: "2026-09-27T14:00:00+08:00",
        cmd: "start",
      });
      assert.deepEqual(JSON.parse(server.received[1]), { cmd: "status" });
      await server.close();
    },
  ],
  [
    "daemon: a reply that ends the stream without a newline still counts",
    async () => {
      const socketPath = path.join(freshDir(), "s.sock");
      const server = await scriptedServer(socketPath, (_raw, socket) => {
        socket.end('{"ok":true,"version":"1","pid":42}');
      });
      const reply = await sendRequest(socketPath, { cmd: "ping" }, 1000);
      assert.equal(reply.pid, 42);
      await server.close();
    },
  ],
  [
    "daemon: ok:false becomes a daemon error carrying the helper's message",
    async () => {
      const socketPath = path.join(freshDir(), "s.sock");
      let reply = '{"ok":false,"error":"A session is already running."}\n';
      const server = await scriptedServer(socketPath, (_raw, socket) =>
        socket.end(reply),
      );
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      await rejectsWith(
        daemon.start("e1"),
        "daemon",
        /^A session is already running\.$/,
      );
      reply = '{"ok":false}\n';
      await rejectsWith(daemon.status(), "daemon", /without a message/);
      await server.close();
    },
  ],
  [
    "daemon: garbage, a missing ok and a silent close are protocol errors",
    async () => {
      const socketPath = path.join(freshDir(), "s.sock");
      let mode = "garbage";
      const server = await scriptedServer(socketPath, (_raw, socket) => {
        if (mode === "garbage") socket.end("<html>\n");
        else if (mode === "no-ok") socket.end('{"session":null}\n');
        else if (mode === "array") socket.end("[true]\n");
        else socket.end();
      });
      await rejectsWith(
        sendRequest(socketPath, { cmd: "status" }, 1000),
        "protocol",
        /not JSON/,
      );
      mode = "no-ok";
      await rejectsWith(
        sendRequest(socketPath, { cmd: "status" }, 1000),
        "protocol",
        /"ok"/,
      );
      mode = "array";
      await rejectsWith(
        sendRequest(socketPath, { cmd: "status" }, 1000),
        "protocol",
        /"ok"/,
      );
      mode = "silent";
      await rejectsWith(
        sendRequest(socketPath, { cmd: "status" }, 1000),
        "protocol",
        /without answering "status"/,
      );
      await server.close();
    },
  ],
  [
    "daemon: a helper that never answers times out",
    async () => {
      const socketPath = path.join(freshDir(), "s.sock");
      const server = await scriptedServer(socketPath, () => undefined);
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
        timeoutMs: 150,
      });
      await rejectsWith(daemon.today(), "timeout", /did not answer "today"/);
      await server.close();
    },
  ],
  [
    "daemon: a socket we may not open is access denied, with no launch",
    async () => {
      const locked = path.join(freshDir(), "locked");
      mkdirSync(locked);
      const socketPath = path.join(locked, "s.sock");
      const server = await scriptedServer(socketPath, (_raw, socket) =>
        socket.end('{"ok":true}\n'),
      );
      chmodSync(locked, 0o000);
      try {
        const binary = path.join(freshDir(), "must-not-run");
        const daemon = new FocusDaemon({ socketPath, binaryPath: binary });
        await rejectsWith(
          daemon.status(),
          "access-denied",
          /Permission denied/,
        );
      } finally {
        chmodSync(locked, 0o755);
        await server.close();
      }
    },
  ],
  [
    "daemon: nothing listening and no binary names the missing helper",
    async () => {
      const socketPath = path.join(freshDir(), "s.sock");
      const binary = path.join(freshDir(), "focus-daemon");
      const daemon = new FocusDaemon({ socketPath, binaryPath: binary });
      const error = await rejectsWith(daemon.status(), "missing-binary");
      assert.ok(error.message.includes(binary));
      assert.match(error.message, /npm run build-helper/);
      // quit() never launches anything.
      await daemon.quit();
    },
  ],

  // ---- daemon client: launch ----
  [
    "daemon: launches the helper once for parallel requests, then talks to it",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const launches = path.join(dir, "launches.log");
      const binary = path.join(dir, "focus-daemon");
      const fake = path.resolve(__dirname, "..", "test", "fake-daemon.js");
      writeFileSync(
        binary,
        `#!/bin/sh\necho launched >> "${launches}"\nexec "${process.execPath}" "${fake}" --socket "${socketPath}" --no-waiting\n`,
      );
      // Not executable yet: the client sets the bit, like notes does.
      chmodSync(binary, 0o644);
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: binary,
        launchTimeoutMs: 10_000,
      });
      try {
        const [session, waiting, calendars] = await Promise.all([
          daemon.status(),
          daemon.pending(),
          daemon.calendars(),
        ]);
        assert.equal(session, null);
        assert.deepEqual(waiting, []);
        assert.ok(calendars.length > 0);
        assert.equal(readFileSync(launches, "utf8"), "launched\n");
        const ping = await daemon.ping();
        assert.equal(ping.version, "fake-1");
        assert.equal(readFileSync(launches, "utf8"), "launched\n");
      } finally {
        await daemon.quit();
      }
      // The fake removes its socket on quit.
      for (let i = 0; i < 50 && existsSync(socketPath); i += 1) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      assert.equal(existsSync(socketPath), false);
    },
  ],
  [
    "daemon: a helper that exits before listening is reported with its code",
    async () => {
      const dir = freshDir();
      const binary = path.join(dir, "focus-daemon");
      writeFileSync(binary, "#!/bin/sh\nexit 3\n");
      chmodSync(binary, 0o755);
      const daemon = new FocusDaemon({
        socketPath: path.join(dir, "s.sock"),
        binaryPath: binary,
        launchTimeoutMs: 5_000,
      });
      await rejectsWith(daemon.status(), "launch-failed", /exited \(code 3\)/);
    },
  ],
  [
    "daemon: a launcher that backgrounds the helper and exits 0 is not a failure",
    async () => {
      // The real focus-daemon with no arguments spawns the daemon in its own
      // session and exits 0 once it listens; the client must keep pinging.
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const binary = path.join(dir, "focus-daemon");
      const fake = path.resolve(__dirname, "..", "test", "fake-daemon.js");
      writeFileSync(
        binary,
        `#!/bin/sh\n(sleep 0.3; exec "${process.execPath}" "${fake}" --socket "${socketPath}" --no-waiting) >/dev/null 2>&1 &\nexit 0\n`,
      );
      chmodSync(binary, 0o755);
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: binary,
        launchTimeoutMs: 10_000,
      });
      try {
        assert.equal(await daemon.status(), null);
      } finally {
        await daemon.quit();
      }
    },
  ],
  [
    "daemon: a helper that is slow to answer its first ping still counts as up",
    async () => {
      // Startup recovery can hold the queue past the 1 s ping timeout; the
      // client retries within the launch window instead of giving up.
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const binary = path.join(dir, "focus-daemon");
      const server = path.join(dir, "slow.js");
      writeFileSync(
        server,
        `const net = require("net");
const started = Date.now();
net.createServer((socket) => {
  socket.setEncoding("utf8");
  socket.on("data", (raw) => {
    const request = JSON.parse(raw);
    const reply = request.cmd === "ping" ? { ok: true, version: "slow", pid: process.pid } : { ok: true, session: null };
    if (request.cmd === "quit") { socket.end('{"ok":true}\\n'); setTimeout(() => process.exit(0), 50); return; }
    const delay = Date.now() - started < 1_800 ? 1_500 : 0;
    setTimeout(() => socket.end(JSON.stringify(reply) + "\\n"), delay);
  });
}).listen(${JSON.stringify(socketPath)});
`,
      );
      writeFileSync(
        binary,
        `#!/bin/sh\nexec "${process.execPath}" "${server}"\n`,
      );
      chmodSync(binary, 0o755);
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: binary,
        launchTimeoutMs: 10_000,
      });
      try {
        assert.equal(await daemon.status(), null);
      } finally {
        await daemon.quit();
      }
    },
  ],

  // ---- blocking: status and snooze against the fake daemon ----
  [
    "daemon: blocking status and snooze",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      const clock = new Date(2026, 8, 28, 10, 0, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      try {
        writeFileSync(
          configPath,
          JSON.stringify({
            snoozeSeconds: 45,
            profiles: {
              default: {
                mode: "blocklist",
                apps: ["com.apple.Calculator"],
                hosts: ["youtube.com"],
              },
              deep: {
                mode: "allowlist",
                apps: ["com.microsoft.VSCode"],
                hosts: ["github.com"],
              },
            },
          }),
        );
        const idle = await daemon.blocking();
        assert.equal(idle.active, false);
        assert.equal(idle.sessionId, null);
        assert.equal(idle.profile, null);
        assert.equal(idle.mode, null);
        await rejectsWith(
          daemon.snooze("youtube.com"),
          "daemon",
          /blocking is off/,
        );
        await assert.rejects(daemon.snooze("  "), RangeError);

        await daemon.startAdhoc({
          goal: "Deep",
          durationSeconds: 1500,
          calendarId: "cal-work",
          profile: "deep",
        });
        const deep = await daemon.blocking();
        assert.equal(deep.active, true);
        assert.equal(deep.sessionId, (await daemon.status())?.id);
        assert.equal(deep.profile, "deep");
        assert.equal(deep.mode, "allowlist");
        assert.deepEqual(deep.allowedHosts, ["github.com"]);
        assert.deepEqual(deep.blockedHosts, []);
        assert.equal(deep.snoozeSeconds, 45);

        const snoozed = await daemon.snooze("com.apple.Calculator");
        assert.equal(snoozed.kind, "app");
        assert.equal(
          snoozed.until,
          new Date(clock.getTime() + 45_000).toISOString(),
        );
        assert.deepEqual(fake.state.requests.at(-1), {
          target: "com.apple.Calculator",
          cmd: "snooze",
        });
        await daemon.snooze("x.com", "site");
        assert.deepEqual(fake.state.requests.at(-1), {
          target: "x.com",
          kind: "site",
          cmd: "snooze",
        });
        assert.deepEqual(
          (await daemon.blocking()).snoozed.map((s) => `${s.kind} ${s.target}`),
          ["app com.apple.Calculator", "site x.com"],
        );

        await daemon.pause();
        const paused = await daemon.blocking();
        assert.equal(paused.active, false);
        assert.equal(paused.profile, "deep");
        await daemon.finish({});
        assert.equal((await daemon.blocking()).profile, null);

        await daemon.startAdhoc({
          goal: "Other",
          durationSeconds: 600,
          calendarId: "cal-work",
          profile: "nope",
        });
        const fallback = await daemon.blocking();
        assert.equal(fallback.profile, "default");
        assert.equal(fallback.profileFallbackFrom, "nope");
        assert.deepEqual(fallback.blockedApps, ["com.apple.Calculator"]);
      } finally {
        await fake.close();
      }
    },
  ],
  [
    "session: blocking text for the Running row",
    () => {
      assert.equal(
        blockingText(
          { state: "running", profile: "default" },
          { profile: "default", mode: "blocklist" },
        ),
        "default · blocklist",
      );
      assert.equal(
        blockingText(
          { state: "paused", profile: "deep" },
          { profile: "deep", mode: "allowlist" },
        ),
        "deep · allowlist, off while paused",
      );
      assert.equal(
        blockingText({ state: "ending", profile: "light" }, null),
        "light",
      );
      assert.equal(
        blockingText(
          { state: "running", profile: "nope" },
          { profile: "default", mode: "blocklist" },
        ),
        "default · blocklist",
      );
    },
  ],

  // ---- daemon client: typed commands against the fake daemon ----
  [
    "daemon: every command round-trips against the fake daemon",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      const clock = new Date(2026, 8, 27, 14, 10, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      try {
        const calendars = await daemon.calendars();
        assert.deepEqual(
          calendars.filter((c) => c.title === "Work").map(calendarLabel),
          ["Work (kai@work.example)", "Work (kai@school.example)"],
        );

        await writeConfig(
          { startableCalendars: ["cal-work", "cal-study"] },
          configPath,
        );
        const events = await daemon.today();
        assert.deepEqual(
          events.map((e) => e.id),
          ["ev-review", "ev-pset", "ev-deep"],
        );
        const groups = groupEvents(events, clock);
        assert.deepEqual(
          groups.now.map((e) => e.id),
          ["ev-pset", "ev-review"],
        );
        assert.deepEqual(
          groups.later.map((e) => e.id),
          ["ev-deep"],
        );
        assert.equal(events[0].remainingSeconds, 3000);

        const session = await daemon.start("ev-review");
        assert.equal(session.goal, "Review the Focus plan");
        assert.equal(session.plannedEnd, at(clock, 3000));
        assert.equal((await daemon.status())?.id, session.id);
        // Starting while one is open sends that one to the end sheet.
        await rejectsWith(
          daemon.start("ev-pset"),
          "daemon",
          /already running.*end sheet/,
        );
        assert.equal((await daemon.status())?.state, "ending");

        // Rating and note are checked before anything is sent.
        const sent = fake.state.requests.length;
        await assert.rejects(daemon.finish({ rating: 6 }), RangeError);
        await assert.rejects(daemon.finish({ rating: 2.5 }), RangeError);
        assert.equal(fake.state.requests.length, sent);

        // No override: the event goes beside the planned one, in its calendar.
        const finished = await daemon.finish({
          rating: 4,
          note: "  good\n run \n",
        });
        assert.equal(finished.logPending, false);
        assert.equal(finished.logEventId, `log-${session.id}`);
        assert.equal(finished.session.logCalendarId, "cal-work");
        assert.equal(
          finished.session.logCalendarName,
          "Work (kai@work.example)",
        );
        assert.equal(fake.state.calendarEvents.at(-1).calendarId, "cal-work");
        // No reason unless asked: the helper knows why the session ended.
        assert.deepEqual(fake.state.requests.at(-1), {
          rating: 4,
          note: "good run",
          cmd: "finish",
        });
        assert.equal(await daemon.status(), null);
        assert.deepEqual(await daemon.pending(), []);

        // A read-only calendar cannot take it: the session waits and says why.
        await daemon.startAdhoc({
          goal: "Review the Focus plan",
          durationSeconds: 600,
          calendarId: "cal-holidays",
        });
        const readOnly = await daemon.finish({});
        assert.equal(readOnly.logPending, true);
        assert.equal(readOnly.logEventId, null);
        assert.equal(readOnly.session.logCalendarId, "cal-holidays");
        const waiting = await daemon.pending();
        assert.deepEqual(
          waiting.map((w) => w.goal),
          ["Review the Focus plan"],
        );
        assert.match(waiting[0].reason ?? "", /read-only.*move the waiting/);
        assert.equal(waiting[0].logCalendarName, "Holidays (Subscribed)");

        assert.deepEqual(await daemon.retryPending(), {
          written: 0,
          adopted: 0,
          stillWaiting: 1,
        });
        await rejectsWith(
          daemon.movePending("cal-holidays"),
          "daemon",
          /not writable/,
        );
        assert.deepEqual(await daemon.movePending("cal-log"), {
          written: 1,
          adopted: 0,
          stillWaiting: 0,
        });
        assert.deepEqual(fake.state.requests.at(-1), {
          calendarId: "cal-log",
          cmd: "movePending",
        });
        assert.deepEqual(await daemon.pending(), []);

        // With a log calendar the event is written at once; an empty note
        // and no rating are left out of the request.
        await writeConfig(
          { logCalendarId: "cal-log", logCalendarName: "Focus Log (Google)" },
          configPath,
        );
        await assert.rejects(
          daemon.startAdhoc({
            goal: "  ",
            durationSeconds: 60,
            calendarId: "cal-work",
          }),
          RangeError,
        );
        await assert.rejects(
          daemon.startAdhoc({
            goal: "x",
            durationSeconds: 0,
            calendarId: "cal-work",
          }),
          RangeError,
        );
        const adhoc = await daemon.startAdhoc({
          goal: " Read ",
          durationSeconds: 1500,
          calendarId: "cal-study",
        });
        assert.deepEqual(fake.state.requests.at(-1), {
          goal: "Read",
          durationSeconds: 1500,
          calendarId: "cal-study",
          cmd: "startAdhoc",
        });
        assert.equal(adhoc.sourceEventId, null);
        const logged = await daemon.finish({ note: "   " });
        assert.equal(logged.logPending, false);
        assert.equal(logged.logEventId, `log-${adhoc.id}`);
        assert.deepEqual(fake.state.requests.at(-1), { cmd: "finish" });

        await daemon.startAdhoc({
          goal: "Deep",
          durationSeconds: 60,
          calendarId: "cal-work",
          profile: "deep",
        });
        assert.equal(fake.state.requests.at(-1).profile, "deep");
        await daemon.finish({ reason: "timer" });

        await rejectsWith(
          daemon.request("nonsense"),
          "daemon",
          /Unknown command/,
        );
      } finally {
        await fake.close();
      }
    },
  ],
  // ---- session state: pause, resume, extend, stop ----
  [
    "session: actions follow the state",
    async () => {
      assert.deepEqual(sessionActions({ state: "running" }), {
        pause: true,
        resume: false,
        extend: true,
        stop: true,
        finish: true,
      });
      assert.deepEqual(sessionActions({ state: "paused" }), {
        pause: false,
        resume: true,
        extend: true,
        stop: true,
        finish: true,
      });
      assert.deepEqual(sessionActions({ state: "ending" }), {
        pause: false,
        resume: false,
        extend: true,
        stop: false,
        finish: true,
      });
      assert.deepEqual(sessionActions({ state: "finished" }), {
        pause: false,
        resume: false,
        extend: false,
        stop: false,
        finish: false,
      });
      assert.deepEqual([...EXTEND_MINUTES], [5, 10, 15, 25]);
    },
  ],
  [
    "session: status text and paused time",
    async () => {
      const now = new Date(2026, 8, 27, 14, 10, 0);
      const plannedEnd = at(now, 1190);
      assert.equal(
        sessionStatusText(
          { state: "running", plannedEnd, endReason: null },
          now,
        ),
        "20 min left",
      );
      assert.equal(
        sessionStatusText(
          { state: "paused", plannedEnd, endReason: null },
          now,
        ),
        "paused, 20 min left",
      );
      assert.equal(
        sessionStatusText(
          { state: "running", plannedEnd: at(now, -5), endReason: null },
          now,
        ),
        "ending",
      );
      assert.equal(
        sessionStatusText(
          { state: "ending", plannedEnd, endReason: "timer" },
          now,
        ),
        "time's up",
      );
      assert.equal(
        sessionStatusText(
          { state: "ending", plannedEnd, endReason: "manual" },
          now,
        ),
        "stopped",
      );
      assert.equal(
        sessionStatusText(
          { state: "running", plannedEnd: null, endReason: null },
          now,
        ),
        "ending",
      );
      const fetchedAt = new Date(now.getTime() - 90_000);
      assert.equal(
        pausedSecondsNow(
          { state: "paused", pausedSeconds: 30 },
          fetchedAt,
          now,
        ),
        120,
      );
      assert.equal(
        pausedSecondsNow(
          { state: "running", pausedSeconds: 30 },
          fetchedAt,
          now,
        ),
        30,
      );
      assert.equal(pausedSecondsNow({ state: "running" }, fetchedAt, now), 0);
      assert.equal(pausedText(0), null);
      assert.equal(pausedText(0.5), null);
      assert.equal(pausedText(120), "paused 2 min");
      assert.equal(pausedText(61), "paused 2 min");
      // A reply from before the deadline is read as the end sheet after it.
      // Paused since before the reply: the paused time runs on to the deadline.
      const past = {
        state: "paused" as const,
        plannedEnd: at(now, -1),
        endReason: null,
        pausedSeconds: 30,
      };
      const fetched = new Date(now.getTime() - 120_000);
      assert.deepEqual(effectiveSession(past, fetched, now), {
        ...past,
        state: "ending",
        endReason: "timer",
        pausedSeconds: 149,
      });
      assert.equal(
        pausedSecondsNow(effectiveSession(past, fetched, now), fetched, now),
        149,
      );
      assert.deepEqual(
        sessionActions(effectiveSession(past, fetched, now)).pause,
        false,
      );
      const runningPast = {
        state: "running" as const,
        plannedEnd: at(now, -1),
        endReason: null,
        pausedSeconds: 30,
      };
      assert.equal(
        effectiveSession(runningPast, fetched, now).pausedSeconds,
        30,
      );
      const exact = {
        state: "running" as const,
        plannedEnd: at(now, 0),
        endReason: null,
      };
      assert.equal(effectiveSession(exact, now, now).state, "ending");
      const ahead = {
        state: "running" as const,
        plannedEnd: at(now, 1),
        endReason: null,
      };
      assert.equal(effectiveSession(ahead, now, now), ahead);
      const stopped = {
        state: "ending" as const,
        plannedEnd: at(now, 600),
        endReason: "manual",
      };
      assert.equal(effectiveSession(stopped, now, now), stopped);
      const unknown = {
        state: "running" as const,
        plannedEnd: null,
        endReason: null,
      };
      assert.equal(effectiveSession(unknown, now, now), unknown);
    },
  ],
  [
    "daemon: pause, resume, extend, stop and finish round-trip against the fake daemon",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      let clock = new Date(2026, 8, 27, 10, 0, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      const start = clock;
      try {
        await rejectsWith(daemon.pause(), "daemon", /^no session is running$/);
        const session = await daemon.startAdhoc({
          goal: "Draft",
          durationSeconds: 600,
          calendarId: "cal-work",
        });
        assert.equal(session.state, "running");
        assert.equal(session.remainingSeconds, 600);

        clock = new Date(start.getTime() + 120_000);
        const paused = await daemon.pause();
        assert.equal(paused.state, "paused");
        assert.deepEqual(fake.state.requests.at(-1), { cmd: "pause" });
        await rejectsWith(daemon.pause(), "daemon", /already paused/);
        clock = new Date(start.getTime() + 180_000);
        const status = await daemon.status();
        assert.equal(status?.pausedSeconds, 60);
        assert.equal(status?.remainingSeconds, 420);

        const resumed = await daemon.resume();
        assert.equal(resumed.state, "running");
        await rejectsWith(daemon.resume(), "daemon", /not paused/);

        // Extend is checked before anything is sent.
        const sent = fake.state.requests.length;
        await assert.rejects(daemon.extend(30), RangeError);
        await assert.rejects(daemon.extend(90.5), RangeError);
        assert.equal(fake.state.requests.length, sent);
        const extended = await daemon.extend(300);
        assert.deepEqual(fake.state.requests.at(-1), {
          seconds: 300,
          cmd: "extend",
        });
        assert.equal(extended.plannedEnd, at(start, 900));
        assert.equal(extended.extendedSeconds, 300);

        const stopped = await daemon.stop();
        assert.equal(stopped.state, "ending");
        assert.equal(stopped.endReason, "manual");
        assert.equal(stopped.remainingSeconds, 0);
        await rejectsWith(daemon.pause(), "daemon", /end sheet/);
        await rejectsWith(daemon.stop(), "daemon", /end sheet/);

        // Extend from the end sheet returns to running.
        const back = await daemon.extend(600);
        assert.equal(back.state, "running");
        assert.equal(back.plannedEnd, at(start, 1500));

        // The planned end passes while paused: ending by the timer.
        await daemon.pause();
        clock = new Date(start.getTime() + 1_600_000);
        const ending = await daemon.status();
        assert.equal(ending?.state, "ending");
        assert.equal(ending?.endReason, "timer");
        const finished = await daemon.finish({ rating: 5 });
        assert.equal(finished.session.state, "finished");
        assert.equal(finished.session.endReason, "timer");
        assert.equal(finished.session.extendedSeconds, 900);
        assert.deepEqual(fake.state.requests.at(-1), {
          rating: 5,
          cmd: "finish",
        });
        assert.equal(await daemon.status(), null);
        await rejectsWith(daemon.stop(), "daemon", /no session is running/);
      } finally {
        await fake.close();
      }
    },
  ],
  // ---- settings, blocking half (step 4): profiles ----
  [
    "profiles: categories mirror helper/Categories.swift (ids, titles, order)",
    async () => {
      const swift = readFileSync(
        path.resolve("helper/Categories.swift"),
        "utf8",
      );
      const defs = new Map<string, string>();
      for (const match of swift.matchAll(
        /static let (\w+) = BlockCategory\(\s*id: "([^"]+)", title: "([^"]+)"/g,
      )) {
        defs.set(match[1], JSON.stringify({ id: match[2], title: match[3] }));
      }
      const order = /static let all: \[BlockCategory\] = \[([^\]]+)\]/.exec(
        swift,
      );
      assert.ok(order, "Categories.all not found");
      const swiftCategories = order[1]
        .split(",")
        .map((name) => JSON.parse(defs.get(name.trim()) ?? "null"));
      assert.deepEqual(
        CATEGORIES.map((c) => ({ id: c.id, title: c.title })),
        swiftCategories,
      );
      assert.equal(swiftCategories.length, 6);
    },
  ],
  [
    "profiles: entries are read like the helper reads them",
    async () => {
      assert.deepEqual(parseProfile("deep"), {
        ok: false,
        problem: "is not an object",
      });
      assert.deepEqual(parseProfile({ categories: "social" }), {
        ok: false,
        problem: "categories is not a list",
      });
      assert.deepEqual(parseProfile({ hosts: { a: 1 } }), {
        ok: false,
        problem: "hosts is not a list",
      });
      // Every key optional.
      assert.deepEqual(parseProfile({}), {
        ok: true,
        spec: { mode: "blocklist", categories: [], apps: [], hosts: [] },
        problems: [],
      });
      const parsed = parseProfile({
        mode: " AllowList ",
        categories: ["Social", "social", "sports", 3],
        apps: [" com.a.b ", "", 7],
        hosts: null,
        extra: true,
      });
      assert.ok(parsed.ok);
      assert.deepEqual(parsed.spec, {
        mode: "allowlist",
        categories: ["social", "sports"],
        apps: ["com.a.b"],
        hosts: [],
      });
      assert.deepEqual(parsed.problems, ['unknown category "sports"']);
      const badMode = parseProfile({ mode: "strict" });
      assert.ok(badMode.ok);
      assert.equal(badMode.spec.mode, "blocklist");
      assert.deepEqual(badMode.problems, [
        'mode "strict" is not blocklist or allowlist',
      ]);
    },
  ],
  [
    "profiles: the app picker lists installed apps by name, then saved ids that are not installed",
    async () => {
      const installed = [
        {
          name: "Slack",
          path: "/Applications/Slack.app",
          bundleId: "com.tinyspeck.slackmacgap",
        },
        {
          name: "Music",
          path: "/System/Applications/Music.app",
          bundleId: "com.apple.Music",
        },
        { name: "No Id", path: "/Applications/NoId.app" },
        {
          name: "Music copy",
          path: "/Applications/Music copy.app",
          bundleId: "COM.APPLE.MUSIC",
        },
        {
          name: "Chess",
          path: "/System/Applications/Chess.app",
          bundleId: "com.apple.Chess",
        },
      ];
      const items = appPickerItems(installed, [
        "com.spotify.client",
        " COM.apple.music ",
        "",
        "com.spotify.client",
      ]);
      assert.deepEqual(items, [
        {
          value: "com.apple.Chess",
          title: "Chess",
          path: "/System/Applications/Chess.app",
        },
        {
          value: "com.apple.Music",
          title: "Music",
          path: "/System/Applications/Music.app",
        },
        {
          value: "com.tinyspeck.slackmacgap",
          title: "Slack",
          path: "/Applications/Slack.app",
        },
        {
          value: "com.spotify.client",
          title: "Not installed: com.spotify.client",
        },
      ]);
      // The selection takes the picker's spelling and drops ids the picker lacks.
      assert.deepEqual(
        alignSelection(
          [
            " COM.apple.music ",
            "com.spotify.client",
            "nope",
            "com.apple.Music",
          ],
          items,
        ),
        ["com.apple.Music", "com.spotify.client"],
      );
      assert.deepEqual(appPickerItems([], []), []);
    },
  ],
  [
    "profiles: default comes first (built in when config has none), the rest by name",
    async () => {
      const none = profileEntries({});
      assert.equal(none.length, 1);
      assert.equal(none[0].name, "default");
      assert.equal(none[0].builtIn, true);
      assert.deepEqual(none[0].spec, builtInDefault());
      assert.deepEqual(
        builtInDefault().categories,
        CATEGORIES.map((c) => c.id),
      );
      assert.equal(
        entrySummary(none[0]),
        "Blocklist · all categories (built in)",
      );

      const entries = profileEntries({
        zeta: { mode: "allowlist" },
        deep: { categories: "social" },
        default: { categories: ["news"] },
        "  ": {},
        alpha: {},
      });
      assert.deepEqual(
        entries.map((e) => e.name),
        ["default", "alpha", "deep", "zeta"],
      );
      assert.equal(entries[0].builtIn, false);
      assert.equal(entries[2].malformed, "categories is not a list");
      assert.equal(
        entrySummary(entries[2]),
        "Not readable (categories is not a list); sessions asking for it use default",
      );
      // A malformed entry cannot be picked for a session.
      assert.deepEqual(profileNames({ zeta: {}, deep: { apps: "x" } }), [
        "default",
        "zeta",
      ]);

      const brokenDefault = profileEntries({ default: [] });
      assert.equal(brokenDefault[0].malformed, "is not an object");
      assert.deepEqual(brokenDefault[0].spec, builtInDefault());
      assert.equal(
        entrySummary(brokenDefault[0]),
        "Not readable (is not an object); the built-in default is used",
      );
      assert.deepEqual(profileNames({ default: [] }), ["default"]);
    },
  ],
  [
    "profiles: summary line names the mode, categories and extra counts",
    async () => {
      assert.equal(
        profileSummary(builtInDefault()),
        "Blocklist · all categories",
      );
      assert.equal(
        profileSummary({
          mode: "allowlist",
          categories: [],
          apps: ["com.microsoft.VSCode"],
          hosts: ["github.com"],
        }),
        "Allowlist · no categories · 1 extra app · 1 extra host",
      );
      // Canonical order, unknown ids left out of the names.
      assert.equal(
        profileSummary({
          mode: "blocklist",
          categories: ["news", "social", "sports"],
          apps: ["a.b", "c.d"],
          hosts: ["x.com", "y.com", "z.com"],
        }),
        "Blocklist · Social, News · 2 extra apps · 3 extra hosts",
      );
      assert.equal(categoryTitle("gaming"), "Gaming");
    },
  ],
  [
    "profiles: bundle id shape",
    async () => {
      for (const good of [
        "com.tinyspeck.slackmacgap",
        "desktop.WhatsApp",
        "com.foo_bar.App-2",
        "net.battle.app",
      ]) {
        assert.equal(bundleIdProblem(good), null, good);
      }
      assert.equal(bundleIdProblem("Slack"), '"Slack" is not a bundle id');
      assert.equal(
        bundleIdProblem("com.tiny speck.x"),
        '"com.tiny speck.x" has a space',
      );
      for (const bad of [
        ".com.a",
        "com..a",
        "com.a.",
        "https://com.a",
        "com/a.b",
        "-",
        "com.a!b",
      ]) {
        assert.notEqual(bundleIdProblem(bad), null, bad);
      }
    },
  ],
  [
    "profiles: host shape (lowercase, no scheme, path, port, wildcard or spaces)",
    async () => {
      for (const good of [
        "youtube.com",
        "m.youtube.com",
        "www.youtube.com",
        "a-b.co.uk",
        "news.ycombinator.com",
        "10.0.0.1",
      ]) {
        assert.equal(hostProblem(good), null, good);
      }
      assert.equal(
        hostProblem("https://www.YouTube.com/watch?v=1"),
        "Write youtube.com (no scheme)",
      );
      assert.equal(
        hostProblem("youtube.com/feed"),
        "Write youtube.com (no path)",
      );
      assert.equal(hostProblem("YouTube.com"), "Write youtube.com (lowercase)");
      assert.equal(
        hostProblem("you tube.com"),
        '"you tube.com" is not a host (no spaces)',
      );
      assert.equal(
        hostProblem("youtube.com:443"),
        "Write youtube.com (no port)",
      );
      assert.equal(
        hostProblem("*.youtube.com"),
        "Write youtube.com (it covers subdomains)",
      );
      assert.equal(
        hostProblem("youtube"),
        '"youtube" is not a host (like youtube.com)',
      );
      for (const bad of [
        "-x.com",
        "x-.com",
        "x..com",
        ".x.com",
        "x_y.com",
        "ex@mple.com",
      ]) {
        assert.notEqual(hostProblem(bad), null, bad);
      }
      assert.deepEqual(normalizeHosts(["www.x.com", "x.com", "y.com"]), [
        "x.com",
        "y.com",
      ]);
      assert.deepEqual(dedupeApps(["com.A.b", "com.a.B", "com.c.d"]), [
        "com.A.b",
        "com.c.d",
      ]);
      assert.deepEqual(splitLines(" a \r\n\n b\n  "), ["a", "b"]);
    },
  ],
  [
    "profiles: validation (name, duplicates, mode, categories, apps, hosts)",
    async () => {
      const names = ["default", "deep"];
      const draft = {
        name: "reading",
        mode: "blocklist",
        categories: ["news", "social"],
        apps: [],
        hosts: "",
      };
      const errorsOf = (result: ReturnType<typeof validateProfile>) =>
        result.ok ? {} : result.errors;

      assert.deepEqual(
        errorsOf(validateProfile({ ...draft, name: "   " }, null, names)),
        { name: "Give the profile a name" },
      );
      assert.deepEqual(
        errorsOf(validateProfile({ ...draft, name: " Deep " }, null, names)),
        {
          name: 'There is already a profile named "Deep"',
        },
      );
      assert.deepEqual(
        errorsOf(validateProfile({ ...draft, name: "DEFAULT" }, null, names)),
        {
          name: 'There is already a profile named "DEFAULT"',
        },
      );
      // Editing keeps its own name; renaming onto another is a duplicate.
      assert.ok(validateProfile({ ...draft, name: "deep" }, "deep", names).ok);
      assert.ok(validateProfile({ ...draft, name: "Deep" }, "deep", names).ok);
      assert.equal(
        errorsOf(validateProfile({ ...draft, name: "default" }, "deep", names))
          .name,
        'There is already a profile named "default"',
      );
      // "default" cannot be renamed, whatever the draft says.
      const kept = validateProfile(
        { ...draft, name: "renamed" },
        "default",
        names,
      );
      assert.ok(kept.ok && kept.name === "default");

      assert.deepEqual(
        errorsOf(validateProfile({ ...draft, mode: "strict" }, null, names)),
        { mode: "Pick blocklist or allowlist" },
      );
      assert.deepEqual(
        errorsOf(
          validateProfile(
            { ...draft, categories: ["social", "sports", "games"] },
            null,
            names,
          ),
        ),
        {
          categories: 'Remove unknown categories "sports", "games"',
        },
      );
      assert.deepEqual(
        errorsOf(
          validateProfile(
            { ...draft, apps: ["com.a.b", "Slack"] },
            null,
            names,
          ),
        ),
        {
          apps: '"Slack" is not a bundle id',
        },
      );
      assert.deepEqual(
        errorsOf(
          validateProfile(
            { ...draft, hosts: "x.com\nhttps://y.com/a" },
            null,
            names,
          ),
        ),
        {
          hosts: "Write y.com (no scheme)",
        },
      );
      // Several problems at once are all reported.
      assert.deepEqual(
        Object.keys(
          errorsOf(
            validateProfile(
              {
                name: "",
                mode: "x",
                categories: ["nope"],
                apps: ["a"],
                hosts: "B.com",
              },
              null,
              names,
            ),
          ),
        ),
        ["name", "mode", "categories", "apps", "hosts"],
      );

      const saved = validateProfile(
        {
          name: "  reading ",
          mode: "allowlist",
          categories: ["news", "social"],
          apps: [" com.a.b ", "", "com.A.B", "com.c.d"],
          hosts: "www.github.com\ngithub.com\n docs.rs ",
        },
        null,
        names,
      );
      assert.deepEqual(saved, {
        ok: true,
        name: "reading",
        spec: {
          mode: "allowlist",
          categories: ["social", "news"],
          apps: ["com.a.b", "com.c.d"],
          hosts: ["github.com", "docs.rs"],
        },
      });
      // A new profile starts as a blocklist of every category.
      assert.deepEqual(draftFor(null), {
        name: "",
        mode: "blocklist",
        categories: CATEGORIES.map((c) => c.id),
        apps: [],
        hosts: "",
      });
      assert.deepEqual(
        draftFor(
          profileEntries({
            deep: { mode: "allowlist", apps: ["a.b", "c.d"], hosts: ["x.com"] },
          })[1],
        ),
        {
          name: "deep",
          mode: "allowlist",
          categories: [],
          apps: ["a.b", "c.d"],
          hosts: "x.com",
        },
      );
    },
  ],
  [
    "profiles: save, rename and delete rewrite profiles and the calendars using them",
    async () => {
      const spec = {
        mode: "allowlist" as const,
        categories: [],
        apps: ["com.a.b"],
        hosts: ["github.com"],
      };
      const current = {
        profiles: {
          default: { mode: "blocklist", categories: ["social"] },
          deep: { mode: "blocklist", note: "keep me", apps: ["x.y"] },
          study: {},
        },
        calendarProfiles: { work: "deep", school: "study", home: "deep" },
      };
      // Add: appended, calendars untouched.
      const added = applyProfileSave(current, null, "new", spec);
      assert.deepEqual(Object.keys(added.profiles), [
        "default",
        "deep",
        "study",
        "new",
      ]);
      assert.deepEqual(added.calendarProfiles, current.calendarProfiles);
      // Edit in place keeps keys the helper does not read and the position.
      const edited = applyProfileSave(current, "deep", "deep", spec);
      assert.deepEqual(Object.keys(edited.profiles), [
        "default",
        "deep",
        "study",
      ]);
      assert.deepEqual(edited.profiles.deep, {
        mode: "allowlist",
        note: "keep me",
        apps: ["com.a.b"],
        categories: [],
        hosts: ["github.com"],
      });
      // Rename: same position, calendars follow.
      const renamed = applyProfileSave(current, "deep", "focus", spec);
      assert.deepEqual(Object.keys(renamed.profiles), [
        "default",
        "focus",
        "study",
      ]);
      assert.equal(
        (renamed.profiles.focus as { note?: string }).note,
        "keep me",
      );
      assert.deepEqual(renamed.calendarProfiles, {
        work: "focus",
        school: "study",
        home: "focus",
      });
      // Editing the built-in default (absent from config) writes it.
      const defaulted = applyProfileSave(
        { profiles: {}, calendarProfiles: {} },
        "default",
        "default",
        builtInDefault(),
      );
      assert.deepEqual(defaulted.profiles, {
        default: { ...builtInDefault() },
      });
      // The input is not mutated.
      assert.deepEqual(Object.keys(current.profiles), [
        "default",
        "deep",
        "study",
      ]);

      const deleted = applyProfileDelete(current, "deep");
      assert.deepEqual(Object.keys(deleted.profiles), ["default", "study"]);
      assert.deepEqual(deleted.calendarProfiles, { school: "study" });
      assert.throws(() => applyProfileDelete(current, "default"), RangeError);

      // "__proto__" is an ordinary key in config.json (JSON.parse makes it
      // one); it must stay an own property through a save, never become the
      // object's prototype, and cannot be picked as a new name.
      const withProto = JSON.parse(
        '{"profiles": {"__proto__": {"mode": "allowlist"}, "deep": {}}, "calendarProfiles": {"work": "__proto__"}}',
      );
      const kept = applyProfileSave(withProto, "deep", "deep", spec);
      assert.deepEqual(Object.keys(kept.profiles), ["__proto__", "deep"]);
      assert.equal(Object.getPrototypeOf(kept.profiles), Object.prototype);
      assert.deepEqual(JSON.parse(JSON.stringify(kept.profiles)).__proto__, {
        mode: "allowlist",
      });
      const protoRenamed = applyProfileSave(
        withProto,
        "__proto__",
        "legacy",
        spec,
      );
      assert.deepEqual(Object.keys(protoRenamed.profiles), ["legacy", "deep"]);
      assert.deepEqual(protoRenamed.calendarProfiles, { work: "legacy" });
      const intoProto = applyProfileSave(
        { profiles: {}, calendarProfiles: {} },
        null,
        "__proto__",
        spec,
      );
      assert.deepEqual(Object.keys(intoProto.profiles), ["__proto__"]);
      assert.deepEqual(
        validateProfile(
          {
            name: "__proto__",
            mode: "blocklist",
            categories: [],
            apps: [],
            hosts: "",
          },
          null,
          ["default"],
        ),
        { ok: false, errors: { name: "Pick another name" } },
      );
      // One already in config.json can still be edited under its own name.
      assert.ok(
        validateProfile(
          {
            name: "__proto__",
            mode: "blocklist",
            categories: [],
            apps: [],
            hosts: "",
          },
          "__proto__",
          ["default", "__proto__"],
        ).ok,
      );
      assert.deepEqual(
        pruneCalendarProfiles({}, ["__proto__", "toString"]),
        {},
      );
      assert.equal(calendarProfileValue({}, "toString"), "default");
      assert.deepEqual(
        remapCalendarProfiles({ a: "x", b: "y" }, "x", "default"),
        { b: "y" },
      );
    },
  ],
  // ---- settings, blocking half: the form's other fields ----
  [
    "settings: calendarProfiles are pruned to the calendars still selected",
    async () => {
      const saved = {
        work: "deep",
        school: "study",
        gone: "deep",
        home: "default",
      };
      // Deselecting school drops its entry; "default" is the fallback, so it is not written.
      assert.deepEqual(pruneCalendarProfiles(saved, ["work", "home", "new"]), {
        work: "deep",
      });
      assert.deepEqual(pruneCalendarProfiles(saved, []), {});
      assert.equal(calendarProfileValue(saved, "work"), "deep");
      assert.equal(calendarProfileValue(saved, "new"), "default");
    },
  ],
  [
    "settings: snooze choices keep an odd saved length as an extra option",
    async () => {
      const standard = [
        { value: "60", title: "1 minute" },
        { value: "180", title: "3 minutes" },
        { value: "300", title: "5 minutes" },
        { value: "600", title: "10 minutes" },
      ];
      assert.deepEqual(snoozeOptions(180), standard);
      assert.deepEqual(snoozeOptions(600), standard);
      assert.deepEqual(snoozeOptions(90), [
        ...standard,
        { value: "90", title: "90 seconds" },
      ]);
      assert.deepEqual(SNOOZE_MINUTES, [1, 3, 5, 10]);
    },
  ],
  [
    "settings: the Countdown field offers the floating panel and the menu bar",
    async () => {
      assert.deepEqual(COUNTDOWN_OPTIONS, [
        { value: "panel", title: "Floating panel" },
        { value: "menuBar", title: "Menu bar" },
      ]);
      // The default is the first choice, so a fresh form shows the panel.
      assert.equal(
        COUNTDOWN_OPTIONS[0].value,
        defaultConfig().countdownDisplay,
      );
      assert.ok(isCountdownDisplay("panel"));
      assert.ok(isCountdownDisplay("menuBar"));
      assert.ok(!isCountdownDisplay("menubar"));
      assert.ok(!isCountdownDisplay(""));
    },
  ],
  [
    "settings: browser choices keep unknown saved bundle ids",
    async () => {
      const known = [
        { value: "com.google.Chrome", title: "Google Chrome" },
        { value: "company.thebrowser.dia", title: "Dia" },
      ];
      assert.deepEqual(browserOptions(defaultConfig().browsers), known);
      assert.deepEqual(browserOptions([]), known);
      assert.deepEqual(
        browserOptions(["com.brave.Browser", "company.thebrowser.dia"]),
        [...known, { value: "com.brave.Browser", title: "com.brave.Browser" }],
      );
    },
  ],
  [
    "settings: saving the blocking half round-trips and keeps unknown keys",
    async () => {
      const dir = path.join(freshDir(), "focus");
      const file = path.join(dir, "config.json");
      mkdirSync(dir, { recursive: true });
      writeFileSync(
        file,
        JSON.stringify({
          startableCalendars: ["work"],
          profiles: {
            default: { categories: ["social"], helperNote: 1 },
            deep: { mode: "allowlist" },
          },
          futureKey: [1, { two: 2 }],
        }),
      );
      // What the Settings form writes (never `profiles`).
      await writeConfig(
        {
          startableCalendars: ["work", "school"],
          calendarProfiles: pruneCalendarProfiles(
            { work: "deep", school: "default", old: "deep" },
            ["work", "school"],
          ),
          snoozeSeconds: 300,
          browsers: ["company.thebrowser.dia", "com.brave.Browser"],
          raycastDeeplink: true,
        },
        file,
      );
      const afterForm = await readConfig(file);
      assert.deepEqual(afterForm.calendarProfiles, { work: "deep" });
      assert.equal(afterForm.snoozeSeconds, 300);
      assert.deepEqual(afterForm.browsers, [
        "company.thebrowser.dia",
        "com.brave.Browser",
      ]);
      assert.equal(afterForm.raycastDeeplink, true);
      assert.deepEqual(afterForm.profiles, {
        default: { categories: ["social"], helperNote: 1 },
        deep: { mode: "allowlist" },
      });
      assert.deepEqual(afterForm.futureKey, [1, { two: 2 }]);

      // What Manage Profiles writes: computed from the file as it is now.
      writeFileSync(
        file,
        JSON.stringify({
          ...JSON.parse(readFileSync(file, "utf8")),
          laterKey: "hand edit",
        }),
      );
      const renamed = await updateConfig(
        (current) =>
          applyProfileSave(current, "deep", "focus", {
            mode: "allowlist",
            categories: [],
            apps: [],
            hosts: ["github.com"],
          }),
        file,
      );
      const onDisk = JSON.parse(readFileSync(file, "utf8"));
      assert.deepEqual(onDisk, renamed);
      assert.deepEqual(Object.keys(onDisk.profiles), ["default", "focus"]);
      assert.deepEqual(onDisk.calendarProfiles, { work: "focus" });
      assert.equal(onDisk.laterKey, "hand edit");
      assert.deepEqual(onDisk.futureKey, [1, { two: 2 }]);
      assert.equal(onDisk.snoozeSeconds, 300);
      const deleted = await updateConfig(
        (current) => applyProfileDelete(current, "focus"),
        file,
      );
      assert.deepEqual(deleted.calendarProfiles, {});
      assert.deepEqual(Object.keys(deleted.profiles), ["default"]);
      assert.deepEqual(readdirSync(dir), ["config.json"]);
    },
  ],
  // ---- ad-hoc session ----
  [
    "adhoc: duration is the preset unless custom minutes are filled (1 to 1440)",
    async () => {
      assert.deepEqual(ADHOC_PRESET_MINUTES, [15, 25, 45, 60, 90]);
      assert.equal(DEFAULT_ADHOC_MINUTES, 45);
      assert.deepEqual(resolveAdhocMinutes("25", ""), {
        ok: true,
        minutes: 25,
      });
      assert.deepEqual(resolveAdhocMinutes("90", "   "), {
        ok: true,
        minutes: 90,
      });
      assert.deepEqual(resolveAdhocMinutes("25", " 40 "), {
        ok: true,
        minutes: 40,
      });
      assert.deepEqual(resolveAdhocMinutes("25", "1"), {
        ok: true,
        minutes: 1,
      });
      assert.deepEqual(resolveAdhocMinutes("25", "1440"), {
        ok: true,
        minutes: 1440,
      });
      assert.deepEqual(resolveAdhocMinutes("25", "007"), {
        ok: true,
        minutes: 7,
      });
      for (const bad of [
        "0",
        "1441",
        "2.5",
        "-5",
        "1e3",
        "abc",
        "25 min",
        "+5",
      ]) {
        assert.deepEqual(
          resolveAdhocMinutes("25", bad),
          { ok: false, error: "Whole minutes from 1 to 1440" },
          bad,
        );
      }
      assert.deepEqual(resolveAdhocMinutes("30", ""), {
        ok: false,
        error: "Pick a duration",
      });
      assert.deepEqual(resolveAdhocMinutes("", ""), {
        ok: false,
        error: "Pick a duration",
      });
    },
  ],
  [
    "adhoc: calendar and profile preselection",
    async () => {
      const calendars = [{ id: "a" }, { id: "b" }, { id: "c" }];
      assert.equal(
        initialAdhocCalendar(calendars, "c", { startableCalendars: ["b"] }),
        "c",
      );
      // The last one is gone: the first startable one that exists, else the first.
      assert.equal(
        initialAdhocCalendar(calendars, "gone", {
          startableCalendars: ["x", "b"],
        }),
        "b",
      );
      assert.equal(
        initialAdhocCalendar(calendars, undefined, {
          startableCalendars: ["x"],
        }),
        "a",
      );
      assert.equal(
        initialAdhocCalendar([], "a", { startableCalendars: ["a"] }),
        null,
      );

      const config = { calendarProfiles: { a: "deep", b: "deleted" } };
      assert.equal(adhocProfileFor("a", config, ["default", "deep"]), "deep");
      assert.equal(
        adhocProfileFor("b", config, ["default", "deep"]),
        "default",
      );
      assert.equal(
        adhocProfileFor("c", config, ["default", "deep"]),
        "default",
      );
      assert.equal(
        adhocProfileFor(null, config, ["default", "deep"]),
        "default",
      );
      // Inherited names are never read as a calendar's profile.
      assert.equal(
        adhocProfileFor("toString", config, ["default", "deep"]),
        "default",
      );

      // The calendar is checked again right before a start.
      assert.equal(adhocCalendarGone(calendars, "b"), false);
      // "(No Calendar)" is never gone and is remembered like any other choice.
      assert.equal(adhocCalendarGone(calendars, NO_CALENDAR), false);
      assert.equal(adhocCalendarGone(null, NO_CALENDAR), false);
      assert.equal(
        initialAdhocCalendar(calendars, NO_CALENDAR, {
          startableCalendars: ["b"],
        }),
        NO_CALENDAR,
      );
      assert.equal(
        adhocProfileFor(NO_CALENDAR, { calendarProfiles: { none: "deep" } }, [
          "default",
          "deep",
        ]),
        "deep",
      );
      assert.deepEqual(
        adhocStartedText(
          {
            goal: "Scratch",
            plannedEnd: null,
            profile: "default",
            calendarId: NO_CALENDAR,
          },
          45,
        ),
        {
          title: "Focusing: Scratch",
          message: "(45 min), default profile, no calendar",
        },
      );
      assert.equal(adhocCalendarGone(calendars, "removed"), true);
      assert.equal(adhocCalendarGone(null, "removed"), false);
    },
  ],
  [
    "adhoc: the last calendar is remembered in LocalStorage",
    async () => {
      raycastStub.LocalStorage._reset();
      assert.equal(await lastAdhocCalendar(), undefined);
      await rememberAdhocCalendar("cal-study");
      assert.equal(await lastAdhocCalendar(), "cal-study");
      assert.equal(
        await raycastStub.LocalStorage.getItem(LAST_CALENDAR_KEY),
        "cal-study",
      );
      await raycastStub.LocalStorage.setItem(LAST_CALENDAR_KEY, "");
      assert.equal(await lastAdhocCalendar(), undefined);
      raycastStub.LocalStorage._reset();
    },
  ],
  [
    "adhoc: toasts for a start and for a refusal while a session is open",
    async () => {
      const plannedEnd = new Date(2026, 8, 28, 15, 40).toISOString();
      assert.deepEqual(
        adhocStartedText(
          { goal: "Write the report", plannedEnd, profile: "deep" },
          25,
        ),
        {
          title: "Focusing: Write the report",
          message: "Until 15:40 (25 min), deep profile",
        },
      );
      assert.deepEqual(
        adhocStartedText(
          { goal: "Read", plannedEnd: null, profile: "default" },
          90,
        ),
        {
          title: "Focusing: Read",
          message: "(1 h 30 min), default profile",
        },
      );
      assert.deepEqual(
        adhocRefusedText("whatever", {
          goal: "Review the plan",
          state: "ending",
        }),
        {
          title: "A session is already running",
          message:
            '"Review the plan" is at the end sheet: finish or extend it first',
        },
      );
      assert.deepEqual(adhocRefusedText("calendar gone", null), {
        title: "Could not start the session",
        message: "calendar gone",
      });
    },
  ],
  [
    "adhoc: against the fake daemon, a start while one runs sends that one to the end sheet",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      const clock = new Date(2026, 8, 28, 10, 0, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      try {
        const minutes = resolveAdhocMinutes("25", "");
        assert.ok(minutes.ok);
        const first = await daemon.startAdhoc({
          goal: "Write",
          durationSeconds: minutes.minutes * 60,
          calendarId: "cal-study",
          profile: "deep",
        });
        assert.deepEqual(fake.state.requests.at(-1), {
          goal: "Write",
          durationSeconds: 1500,
          calendarId: "cal-study",
          profile: "deep",
          cmd: "startAdhoc",
        });
        assert.equal(
          adhocStartedText(first, 25).message,
          "Until 10:25 (25 min), deep profile",
        );

        const refusal = await rejectsWith(
          daemon.startAdhoc({
            goal: "Another",
            durationSeconds: 900,
            calendarId: "cal-work",
          }),
          "daemon",
          /already running/,
        );
        const open = await daemon.status();
        assert.equal(open?.state, "ending");
        assert.deepEqual(adhocRefusedText(refusal.message, open), {
          title: "A session is already running",
          message: '"Write" is at the end sheet: finish or extend it first',
        });
        await daemon.finish();
      } finally {
        await fake.close();
      }
    },
  ],

  // ---- stats: formatting ----
  [
    "stats: focused time, sessions and ratings read as text",
    async () => {
      assert.equal(focusedText(0), "0 min");
      assert.equal(focusedText(-5), "0 min");
      assert.equal(focusedText(1), "under a minute");
      assert.equal(focusedText(59), "under a minute");
      assert.equal(focusedText(60), "1 min");
      assert.equal(focusedText(89), "1 min");
      assert.equal(focusedText(90), "2 min");
      assert.equal(focusedText(2700), "45 min");
      assert.equal(focusedText(3600), "1 h");
      assert.equal(focusedText(5100), "1 h 25 min");
      assert.equal(focusedText(3599), "1 h");
      assert.equal(focusedText(Number.NaN), "0 min");
      assert.equal(sessionsText(0), "no sessions");
      assert.equal(sessionsText(1), "1 session");
      assert.equal(sessionsText(3), "3 sessions");
      assert.equal(averageRatingText(null), "no ratings");
      assert.equal(averageRatingText(3.67), "3.7 ★");
      assert.equal(averageRatingText(4), "4.0 ★");
      assert.equal(ratingText(null), "unrated");
      assert.equal(ratingText(4), "★★★★☆");
      assert.equal(lastDaysLabel(7), "Last 7 days");
      assert.equal(lastDaysLabel(1), "Today");
      assert.equal(
        totalsText({ focusedSeconds: 5100, sessions: 2, averageRating: 3.5 }),
        "1 h 25 min over 2 sessions, average 3.5 ★",
      );
      assert.equal(
        totalsText({ focusedSeconds: 0, sessions: 0, averageRating: null }),
        "0 min over no sessions",
      );
      assert.equal(endReasonText("timer"), "when the timer ran out");
      assert.equal(
        endReasonText("abandoned"),
        "abandoned (the helper stopped)",
      );
      assert.equal(endReasonText(null), "unknown");
    },
  ],
  [
    "stats: days, spans, attempts and markdown",
    async () => {
      const now = new Date(2026, 8, 28, 15, 0, 0);
      const iso = (d: number, h: number, m: number) =>
        new Date(2026, 8, d, h, m).toISOString();
      assert.equal(dayLabel(iso(28, 9, 0), now), "Today");
      assert.equal(dayLabel(iso(27, 23, 59), now), "Yesterday");
      assert.equal(dayLabel(iso(22, 10, 0), now), "Tue 22 Sep");
      assert.equal(dayLabel("nope", now), "?");
      assert.equal(
        spanText(iso(28, 14, 10), iso(28, 15, 0), now),
        "Today 14:10–15:00",
      );
      assert.equal(
        spanText(iso(27, 23, 30), iso(28, 0, 30), now),
        "Yesterday 23:30–Mon 00:30",
      );
      const session = {
        id: 1,
        goal: "Write *the* report",
        calendarTitle: "Work",
        startedAt: iso(28, 9, 0),
        endedAt: iso(28, 10, 0),
        focusedSeconds: 3000,
        rating: 4,
        note: "Line one\n# not a heading [link](x)",
        endReason: "timer",
        blockedAttempts: 3,
        snoozes: 1,
        logPending: false,
      };
      assert.equal(attemptsText(session), "3, 1 snoozed");
      assert.equal(attemptsText({ ...session, snoozes: 0 }), "3");
      assert.equal(attemptsText({ ...session, blockedAttempts: 0 }), "none");
      assert.equal(
        recentMarkdown(session),
        "## Write \\*the\\* report\n\nLine one \\# not a heading \\[link\\]\\(x\\)",
      );
      assert.equal(
        recentMarkdown({ ...session, note: "  " }).endsWith("_No note_"),
        true,
      );
      assert.equal(escapeMarkdown("a | b <script>"), "a \\| b \\<script\\>");
      assert.equal(
        chartMarkdown("/Users/kai/.raycast/focus/stats/week.svg"),
        "![Focused minutes](file:///Users/kai/.raycast/focus/stats/week.svg)",
      );
      assert.equal(
        chartMarkdown("/tmp/my focus (1)/week.svg"),
        "![Focused minutes](file:///tmp/my%20focus%20%281%29/week.svg)",
      );
      assert.equal(chartMarkdown(null), "_The chart could not be drawn._");
      const rows = [
        {
          calendarId: "w",
          calendarTitle: "Work | Deep",
          focusedSeconds: 5100,
          sessions: 2,
        },
        {
          calendarId: "adhoc",
          calendarTitle: "Ad hoc",
          focusedSeconds: 30,
          sessions: 1,
        },
      ];
      assert.equal(
        calendarTable(rows),
        [
          "| Calendar | Focused | Sessions |",
          "| --- | ---: | ---: |",
          "| Work \\| Deep | 1 h 25 min | 2 |",
          "| Ad hoc | under a minute | 1 |",
        ].join("\n"),
      );
      assert.equal(calendarTable([]), "_No sessions in this period._");
      assert.ok(
        waitingMarkdown("Old Log (kai@old.example)").startsWith(
          "The log event for this session waits for `Old Log (kai@old.example)`.",
        ),
      );
      assert.ok(waitingMarkdown("a`b").includes("`a'b`"));
      assert.ok(waitingMarkdown(null).includes("waits for a calendar."));
      const markdown = overviewMarkdown({
        label: "Today",
        totals: { focusedSeconds: 5100, sessions: 2, averageRating: null },
        chartPath: "/x/week.svg",
        windowLabel: "Last 7 days",
        perCalendar: rows,
      });
      assert.ok(
        markdown.startsWith(
          "**Today**: 1 h 25 min over 2 sessions\n\n![Focused minutes](file:///x/week.svg)",
        ),
        markdown,
      );
      assert.ok(
        markdown.includes("### By calendar, last 7 days\n\n| Calendar |"),
        markdown,
      );
    },
  ],

  // ---- stats: round trip against the fake daemon ----
  [
    "daemon: stats round-trips against the fake daemon",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      let clock = new Date(2026, 8, 27, 23, 30, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      try {
        writeFileSync(configPath, JSON.stringify({ logCalendarId: "cal-log" }));
        const empty = await daemon.stats();
        assert.deepEqual(empty.today, {
          focusedSeconds: 0,
          sessions: 0,
          averageRating: null,
        });
        assert.equal(empty.days.length, 7);
        assert.deepEqual(fake.state.requests.at(-1), { days: 7, cmd: "stats" });

        // Across midnight, with a 5-minute pause after midnight.
        await daemon.startAdhoc({
          goal: "Late night",
          durationSeconds: 3600,
          calendarId: "cal-work",
        });
        clock = new Date(2026, 8, 28, 0, 10, 0);
        await daemon.pause();
        clock = new Date(2026, 8, 28, 0, 15, 0);
        await daemon.resume();
        clock = new Date(2026, 8, 28, 0, 30, 0);
        await daemon.finish({ rating: 4, note: "Wrapped up" });
        // Ad hoc on no calendar, and one still running.
        await daemon.startAdhoc({
          goal: "Inbox",
          durationSeconds: 600,
          calendarId: "none",
        });
        clock = new Date(2026, 8, 28, 0, 40, 0);
        await daemon.finish({ rating: 2 });
        await daemon.startAdhoc({
          goal: "Running",
          durationSeconds: 600,
          calendarId: "cal-work",
        });

        const stats = await daemon.stats();
        assert.deepEqual(stats.today, {
          focusedSeconds: 1500 + 600,
          sessions: 2,
          averageRating: 3,
        });
        assert.deepEqual(stats.week, {
          focusedSeconds: 1800 + 1500 + 600,
          sessions: 2,
          averageRating: 3,
        });
        assert.deepEqual(stats.days.slice(-2), [
          { date: "2026-09-27", focusedSeconds: 1800 },
          { date: "2026-09-28", focusedSeconds: 2100 },
        ]);
        assert.equal(stats.days[0].date, "2026-09-22");
        assert.deepEqual(stats.perCalendar, [
          {
            calendarId: "cal-work",
            calendarTitle: "Work",
            focusedSeconds: 3300,
            sessions: 1,
          },
          {
            calendarId: "adhoc",
            calendarTitle: "Ad hoc",
            focusedSeconds: 600,
            sessions: 1,
          },
        ]);
        assert.deepEqual(
          stats.recent.map((s) => s.goal),
          ["Inbox", "Late night"],
        );
        assert.equal(stats.recent[1].note, "Wrapped up");
        assert.equal(stats.recent[1].focusedSeconds, 3300);
        assert.equal(stats.recent[1].logPending, false);
        assert.deepEqual(stats.waiting, []);
        assert.equal(stats.chartPath, path.join(dir, "stats", "week.svg"));
        assert.ok(existsSync(stats.chartPath as string));
        assert.equal(
          (
            readFileSync(stats.chartPath as string, "utf8").match(/<rect/g) ??
            []
          ).length,
          7,
        );

        // A snooze during a session counts; a waiting session moved to a
        // writable calendar stops being pending.
        writeFileSync(
          configPath,
          JSON.stringify({
            logCalendarId: "cal-gone",
            logCalendarName: "Gone (x)",
          }),
        );
        await daemon.finish({});
        await daemon.startAdhoc({
          goal: "Snoozy",
          durationSeconds: 600,
          calendarId: "cal-work",
        });
        await daemon.snooze("x.com");
        await daemon.snooze("com.apple.Calculator");
        clock = new Date(2026, 8, 28, 0, 50, 0);
        await daemon.finish({});
        const waiting = await daemon.stats();
        const snoozy = waiting.recent.find((s) => s.goal === "Snoozy");
        assert.equal(snoozy?.snoozes, 2);
        assert.equal(snoozy?.blockedAttempts, 2);
        assert.equal(snoozy?.logPending, true);
        assert.deepEqual(
          waiting.waiting.map((w) => w.goal),
          ["Running", "Snoozy"],
        );
        await daemon.movePending("cal-log");
        const moved = await daemon.stats();
        assert.deepEqual(moved.waiting, []);
        assert.equal(
          moved.recent.some((s) => s.logPending),
          false,
        );

        const month = await daemon.stats(30);
        assert.equal(month.days.length, 30);
        assert.deepEqual(fake.state.requests.at(-1), {
          days: 30,
          cmd: "stats",
        });

        // Checked before anything is sent.
        const sent = fake.state.requests.length;
        await assert.rejects(daemon.stats(0), RangeError);
        await assert.rejects(daemon.stats(91), RangeError);
        await assert.rejects(daemon.stats(7.5), RangeError);
        assert.equal(fake.state.requests.length, sent);
      } finally {
        await fake.close();
      }
    },
  ],
  [
    "daemon: a no-calendar session finishes skipped and shows as Ad hoc in stats",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      let clock = new Date(2026, 8, 28, 9, 0, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      try {
        writeFileSync(configPath, JSON.stringify({ logCalendarId: "cal-log" }));
        await daemon.startAdhoc({
          goal: "Scratch",
          durationSeconds: 1500,
          calendarId: NO_CALENDAR,
        });
        clock = new Date(2026, 8, 28, 9, 25, 0);
        const finished = await daemon.finish({ rating: 3 });
        assert.equal(finished.logSkipped, true);
        assert.equal(finished.logPending, false);
        assert.equal(finished.logEventId, null);
        assert.deepEqual(await daemon.pending(), []);
        const stats = await daemon.stats();
        assert.equal(stats.recent[0].logSkipped, true);
        assert.equal(stats.recent[0].logPending, false);
        assert.equal(stats.recent[0].calendarTitle, "Ad hoc");
      } finally {
        await fake.close();
      }
    },
  ],
  [
    "daemon: stats rejects a malformed reply and tolerates a missing chart",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const base = {
        ok: true,
        today: { focusedSeconds: 0, sessions: 0, averageRating: null },
        week: { focusedSeconds: 0, sessions: 0, averageRating: null },
        perCalendar: [],
        days: [],
        recent: [],
        waiting: [],
      };
      let reply: Record<string, unknown> = {
        ...base,
        chartPath: "relative/week.svg",
      };
      const server = await scriptedServer(socketPath, (_raw, socket) => {
        socket.end(`${JSON.stringify(reply)}\n`);
      });
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      try {
        assert.equal((await daemon.stats()).chartPath, null);
        reply = { ...base, chartPath: null };
        assert.equal((await daemon.stats()).chartPath, null);
        reply = { ...base, days: "nope", chartPath: null };
        await rejectsWith(daemon.stats(), "protocol", /"days"/);
        reply = { ok: false, error: "unknown command: stats" };
        await rejectsWith(daemon.stats(), "daemon", /unknown command/);
      } finally {
        await server.close();
      }
    },
  ],

  // ---- deleteSession: client, fake daemon and toast text ----
  [
    "daemon: deleteSession round-trips against the fake daemon",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      let clock = new Date(2026, 8, 28, 9, 0, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      const finishOne = async (goal: string, calendarId = "cal-work") => {
        const started = await daemon.startAdhoc({
          goal,
          durationSeconds: 600,
          calendarId,
        });
        clock = new Date(clock.getTime() + 10 * 60 * 1000);
        const done = await daemon.finish({ rating: 3 });
        return { id: started.id, logEventId: done.logEventId };
      };
      try {
        writeFileSync(configPath, JSON.stringify({ logCalendarId: "cal-log" }));

        // A finished session with a log event: both go.
        const logged = await finishOne("Logged");
        const kept = await finishOne("Kept");
        assert.equal(fake.state.calendarEvents.length, 2);
        const removed = await daemon.deleteSession(logged.id);
        assert.deepEqual(removed, {
          deleted: true,
          logEventRemoved: true,
          warning: null,
        });
        assert.deepEqual(fake.state.requests.at(-1), {
          sessionId: logged.id,
          cmd: "deleteSession",
        });
        assert.deepEqual(
          fake.state.calendarEvents.map((e: { id: string }) => e.id),
          [kept.logEventId],
        );
        assert.deepEqual(
          (await daemon.stats()).recent.map((r) => r.goal),
          ["Kept"],
        );
        await rejectsWith(
          daemon.deleteSession(logged.id),
          "daemon",
          /no session with id/,
        );

        // Notes rewritten: the row goes, the event stays, with a warning.
        const rewritten = await finishOne("Rewritten");
        const event = fake.state.calendarEvents.find(
          (e: { sessionId: number }) => e.sessionId === rewritten.id,
        );
        event.notes = "My own notes";
        const warned = await daemon.deleteSession(rewritten.id);
        assert.equal(warned.logEventRemoved, false);
        assert.match(warned.warning ?? "", /focus-session marker/);
        assert.ok(fake.state.calendarEvents.includes(event));
        assert.equal(
          (await daemon.stats()).recent.some((r) => r.id === rewritten.id),
          false,
        );

        // The id marker with another start (a reused id): not ours, kept.
        const reused = await finishOne("Reused");
        const reusedEvent = fake.state.calendarEvents.find(
          (e: { sessionId: number }) => e.sessionId === reused.id,
        );
        reusedEvent.notes = `focus-session: ${reused.id}\nfocus-started: 2026-01-01T00:00:00Z`;
        const reusedReply = await daemon.deleteSession(reused.id);
        assert.equal(reusedReply.logEventRemoved, false);
        assert.match(reusedReply.warning ?? "", /focus-session marker/);
        assert.ok(fake.state.calendarEvents.includes(reusedEvent));

        // No calendar access: the same.
        const blind = await finishOne("Blind");
        fake.state.calendarAccess = "denied";
        const denied = await daemon.deleteSession(blind.id);
        assert.equal(denied.logEventRemoved, false);
        assert.match(denied.warning ?? "", /calendar access is denied/);
        fake.state.calendarAccess = "fullAccess";

        // No calendar: nothing to remove, no warning.
        const scratch = await finishOne("Scratch", NO_CALENDAR);
        assert.equal(scratch.logEventId, null);
        assert.deepEqual(await daemon.deleteSession(scratch.id), {
          deleted: true,
          logEventRemoved: false,
          warning: null,
        });

        // Waiting for a log calendar: deleted, and pending and stats are clean.
        writeFileSync(
          configPath,
          JSON.stringify({
            logCalendarId: "cal-gone",
            logCalendarName: "Gone (x)",
          }),
        );
        const waiting = await finishOne("Waiting");
        assert.equal((await daemon.pending()).length, 1);
        assert.deepEqual(await daemon.deleteSession(waiting.id), {
          deleted: true,
          logEventRemoved: false,
          warning: null,
        });
        assert.deepEqual(await daemon.pending(), []);
        assert.deepEqual((await daemon.stats()).waiting, []);

        // The open session (at the end sheet here) ends with nothing logged and goes.
        writeFileSync(configPath, JSON.stringify({ logCalendarId: "cal-log" }));
        const open = await daemon.startAdhoc({
          goal: "Discard",
          durationSeconds: 600,
          calendarId: "cal-work",
        });
        await daemon.stop();
        const events = fake.state.calendarEvents.length;
        const history = fake.state.history.length;
        assert.deepEqual(await daemon.deleteSession(open.id), {
          deleted: true,
          logEventRemoved: false,
          warning: null,
        });
        assert.equal(await daemon.status(), null);
        assert.deepEqual(await daemon.pending(), []);
        assert.equal(fake.state.calendarEvents.length, events);
        assert.equal(fake.state.history.length, history);
        await rejectsWith(daemon.finish({}), "daemon", /no session is running/);

        // Checked before anything is sent.
        const sent = fake.state.requests.length;
        await assert.rejects(daemon.deleteSession(0), RangeError);
        await assert.rejects(daemon.deleteSession(-3), RangeError);
        await assert.rejects(daemon.deleteSession(1.5), RangeError);
        assert.equal(fake.state.requests.length, sent);
        await rejectsWith(
          daemon.deleteSession(4242),
          "daemon",
          /no session with id 4242/,
        );
      } finally {
        await fake.close();
      }
    },
  ],
  [
    "daemon: the fake's seeded waiting session can be deleted and a movePending event removed",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        seedWaiting: true,
        seedHistory: true,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      try {
        assert.deepEqual(
          (await daemon.pending()).map((w) => w.sessionId),
          [900],
        );
        assert.deepEqual(await daemon.deleteSession(900), {
          deleted: true,
          logEventRemoved: false,
          warning: null,
        });
        assert.deepEqual(await daemon.pending(), []);
        // A seeded history row has no log event.
        assert.deepEqual(await daemon.deleteSession(801), {
          deleted: true,
          logEventRemoved: false,
          warning: null,
        });
        // A session moved to a writable calendar gets an event, which delete removes.
        writeFileSync(
          configPath,
          JSON.stringify({ logCalendarId: "cal-gone" }),
        );
        const started = await daemon.startAdhoc({
          goal: "Moved",
          durationSeconds: 600,
          calendarId: "cal-work",
        });
        await daemon.finish({});
        await daemon.movePending("cal-log");
        assert.equal(fake.state.calendarEvents.length, 1);
        assert.equal(
          (await daemon.deleteSession(started.id)).logEventRemoved,
          true,
        );
        assert.deepEqual(fake.state.calendarEvents, []);
      } finally {
        await fake.close();
      }
    },
  ],
  [
    "daemon: deleteSession rejects a malformed reply and drops an empty warning",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      let reply: Record<string, unknown> = { ok: true };
      const server = await scriptedServer(socketPath, (_raw, socket) => {
        socket.end(`${JSON.stringify(reply)}\n`);
      });
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      try {
        await rejectsWith(daemon.deleteSession(3), "protocol", /"deleted"/);
        reply = {
          ok: true,
          deleted: true,
          logEventRemoved: false,
          warning: "  ",
        };
        assert.deepEqual(await daemon.deleteSession(3), {
          deleted: true,
          logEventRemoved: false,
          warning: null,
        });
        reply = { ok: true, deleted: true, logEventRemoved: "yes" };
        assert.equal((await daemon.deleteSession(3)).logEventRemoved, false);
        reply = { ok: false, error: "unknown command: deleteSession" };
        await rejectsWith(daemon.deleteSession(3), "daemon", /unknown command/);
        assert.deepEqual(JSON.parse(server.received[0]), {
          sessionId: 3,
          cmd: "deleteSession",
        });
      } finally {
        await server.close();
      }
    },
  ],
  [
    "deleteToastText: says whether the calendar event went",
    async () => {
      assert.deepEqual(
        deleteToastText({
          deleted: true,
          logEventRemoved: true,
          warning: null,
        }),
        {
          title: "Session deleted",
          message: "Its calendar event was removed too",
        },
      );
      assert.deepEqual(
        deleteToastText({
          deleted: true,
          logEventRemoved: false,
          warning:
            "calendar access is denied, so the log event was left in Calendar",
        }),
        {
          title: "Session deleted, calendar event kept",
          message:
            "calendar access is denied, so the log event was left in Calendar",
        },
      );
      assert.deepEqual(
        deleteToastText({
          deleted: true,
          logEventRemoved: false,
          warning: null,
        }),
        {
          title: "Session deleted",
          message: "It had no calendar event",
        },
      );
      assert.deepEqual(
        deleteToastText(
          { deleted: true, logEventRemoved: false, warning: null },
          "discarded",
        ),
        {
          title: "Session discarded",
        },
      );
      assert.deepEqual(
        deleteToastText(
          { deleted: true, logEventRemoved: false, warning: "x" },
          "discarded",
        ),
        {
          title: "Session discarded, calendar event kept",
          message: "x",
        },
      );
    },
  ],
  [
    "fake daemon: finish follows the helper's destination rule",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      const clock = new Date(2026, 8, 28, 10, 0, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      const run = async (calendarId: string) => {
        await daemon.startAdhoc({ goal: "G", durationSeconds: 60, calendarId });
        return daemon.finish({});
      };
      try {
        // No override: the session's own calendar.
        const own = await run("cal-study");
        assert.equal(own.logPending, false);
        assert.equal(own.session.logCalendarId, "cal-study");
        assert.equal(fake.state.calendarEvents.at(-1).calendarId, "cal-study");
        // None is skipped.
        const none = await run(NO_CALENDAR);
        assert.equal(none.logSkipped, true);
        assert.equal(none.logPending, false);
        assert.equal(none.session.logCalendarId, null);
        // A calendar the fake does not list waits, and says so.
        const unknown = await run("cal-gone");
        assert.equal(unknown.logPending, true);
        assert.equal(unknown.session.logCalendarId, "cal-gone");
        assert.equal(
          (await daemon.pending()).at(-1)?.reason,
          "calendar cal-gone is not in Calendar.app",
        );
        // The override wins; none stays skipped under it.
        await writeConfig(
          { logCalendarId: "cal-log", logCalendarName: "Focus Log (Google)" },
          configPath,
        );
        const events = fake.state.calendarEvents.length;
        const overridden = await run("cal-study");
        assert.equal(overridden.logPending, false);
        assert.equal(overridden.session.logCalendarId, "cal-log");
        assert.equal(overridden.session.logCalendarName, "Focus Log (Google)");
        assert.equal(fake.state.calendarEvents.at(-1).calendarId, "cal-log");
        const noneAgain = await run(NO_CALENDAR);
        assert.equal(noneAgain.logSkipped, true);
        assert.equal(fake.state.calendarEvents.length, events + 1);
        // An override the fake does not list leaves every session waiting.
        await writeConfig(
          { logCalendarId: "cal-gone2", logCalendarName: "Old (x)" },
          configPath,
        );
        const gone = await run("cal-study");
        assert.equal(gone.logPending, true);
        assert.equal(gone.session.logCalendarName, "Old (x)");
        assert.equal(
          (await daemon.pending()).at(-1)?.reason,
          "calendar Old (x) is not in Calendar.app",
        );
      } finally {
        await fake.close();
      }
    },
  ],

  // ---- updateSession: client, fake daemon, form values and toast text ----
  [
    "daemon: updateSession round-trips against the fake daemon",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      const configPath = path.join(dir, "config.json");
      let clock = new Date(2026, 8, 28, 9, 0, 0);
      const fake = createFakeDaemon({
        socketPath,
        configPath,
        now: () => clock,
      });
      await fake.listen();
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      const finishOne = async (goal: string, calendarId = "cal-work") => {
        const started = await daemon.startAdhoc({
          goal,
          durationSeconds: 600,
          calendarId,
        });
        clock = new Date(clock.getTime() + 10 * 60 * 1000);
        const done = await daemon.finish({ rating: 3, note: "before" });
        return { id: started.id, logEventId: done.logEventId };
      };
      const eventOf = (id: number) =>
        fake.state.calendarEvents.find(
          (e: { sessionId: number }) => e.sessionId === id,
        );
      try {
        writeFileSync(configPath, JSON.stringify({ logCalendarId: "cal-log" }));

        // Rating and note changed: the history row and the event follow.
        const logged = await finishOne("Logged");
        assert.match(eventOf(logged.id).notes, /Rating: ★★★☆☆\nNote: before/);
        const updated = await daemon.updateSession(logged.id, {
          rating: 5,
          note: "after",
        });
        assert.equal(updated.logEventUpdated, true);
        assert.equal(updated.warning, null);
        assert.equal(updated.session.id, logged.id);
        assert.equal(updated.session.state, "finished");
        assert.equal(updated.session.rating, 5);
        assert.equal(updated.session.note, "after");
        assert.deepEqual(fake.state.requests.at(-1), {
          sessionId: logged.id,
          rating: 5,
          note: "after",
          cmd: "updateSession",
        });
        const notes = eventOf(logged.id).notes;
        assert.match(notes, /Rating: ★★★★★\nNote: after/);
        assert.doesNotMatch(notes, /before/);
        assert.match(notes, new RegExp(`focus-session: ${logged.id}`));
        const row = (await daemon.stats()).recent.find(
          (r) => r.id === logged.id,
        );
        assert.equal(row?.rating, 5);
        assert.equal(row?.note, "after");
        assert.deepEqual(updateToastText(updated), {
          title: "Session updated",
          message: "Its calendar event was updated too",
        });

        // Clearing both; a multi-line note goes on one line, a blank one as null.
        const cleared = await daemon.updateSession(logged.id, {
          rating: null,
          note: "  \n ",
        });
        assert.deepEqual(fake.state.requests.at(-1), {
          sessionId: logged.id,
          rating: null,
          note: null,
          cmd: "updateSession",
        });
        assert.equal(cleared.session.rating, null);
        assert.equal(cleared.session.note, null);
        assert.match(eventOf(logged.id).notes, /Rating: none\n\n/);
        assert.doesNotMatch(eventOf(logged.id).notes, /Note:/);
        await daemon.updateSession(logged.id, {
          rating: 2,
          note: "two\nlines ",
        });
        assert.equal(fake.state.requests.at(-1).note, "two lines");
        assert.match(eventOf(logged.id).notes, /Note: two lines/);

        // The event's markers are gone: the row changes, the event stays.
        const rewritten = await finishOne("Rewritten");
        eventOf(rewritten.id).notes = "My own notes";
        const warned = await daemon.updateSession(rewritten.id, {
          rating: 4,
          note: null,
        });
        assert.equal(warned.logEventUpdated, false);
        assert.match(warned.warning ?? "", /focus-session marker/);
        assert.equal(warned.session.rating, 4);
        assert.equal(eventOf(rewritten.id).notes, "My own notes");
        assert.deepEqual(updateToastText(warned), {
          title: "Session updated, calendar event unchanged",
          message: warned.warning,
        });

        // Kai's own text in the event stays; only the review lines change.
        const annotated = await finishOne("Annotated");
        const own = `Mine above\n${eventOf(annotated.id).notes}\nMine below`;
        eventOf(annotated.id).notes = own;
        const kept = await daemon.updateSession(annotated.id, {
          rating: 1,
          note: null,
        });
        assert.equal(kept.logEventUpdated, true);
        assert.equal(
          eventOf(annotated.id).notes,
          own.replace("Rating: ★★★☆☆\nNote: before", "Rating: ★☆☆☆☆"),
        );
        // Its Rating line removed: kept as it is, with a warning.
        const lineless = eventOf(annotated.id).notes.replace(
          "Rating: ★☆☆☆☆\n",
          "",
        );
        eventOf(annotated.id).notes = lineless;
        const noLine = await daemon.updateSession(annotated.id, {
          rating: 5,
          note: "x",
        });
        assert.equal(noLine.logEventUpdated, false);
        assert.match(noLine.warning ?? "", /Rating line/);
        assert.equal(eventOf(annotated.id).notes, lineless);

        // The event is gone: warns, the row still changes.
        const gone = await finishOne("Gone");
        fake.state.calendarEvents = fake.state.calendarEvents.filter(
          (e: { sessionId: number }) => e.sessionId !== gone.id,
        );
        const missing = await daemon.updateSession(gone.id, {
          rating: 1,
          note: "gone",
        });
        assert.equal(missing.logEventUpdated, false);
        assert.match(missing.warning ?? "", /not found in Calendar/);
        assert.equal(
          (await daemon.stats()).recent.find((r) => r.id === gone.id)?.note,
          "gone",
        );

        // No calendar access: the same.
        const blind = await finishOne("Blind");
        fake.state.calendarAccess = "denied";
        const denied = await daemon.updateSession(blind.id, {
          rating: 5,
          note: null,
        });
        assert.equal(denied.logEventUpdated, false);
        assert.match(denied.warning ?? "", /calendar access is denied/);
        assert.match(eventOf(blind.id).notes, /Rating: ★★★☆☆/);
        fake.state.calendarAccess = "fullAccess";

        // No calendar: nothing to rewrite, no warning.
        const scratch = await finishOne("Scratch", NO_CALENDAR);
        const events = JSON.stringify(fake.state.calendarEvents);
        const noCal = await daemon.updateSession(scratch.id, {
          rating: 4,
          note: "fine",
        });
        assert.equal(noCal.logEventUpdated, false);
        assert.equal(noCal.warning, null);
        assert.equal(noCal.session.logSkipped, true);
        assert.equal(JSON.stringify(fake.state.calendarEvents), events);
        assert.deepEqual(updateToastText(noCal), {
          title: "Session updated",
          message: "It has no calendar event",
        });

        // Waiting: the event written later carries the edit.
        writeFileSync(
          configPath,
          JSON.stringify({ logCalendarId: "cal-gone" }),
        );
        const waiting = await finishOne("Waiting");
        const waited = await daemon.updateSession(waiting.id, {
          rating: 2,
          note: "later",
        });
        assert.deepEqual(updateToastText(waited), {
          title: "Session updated",
          message:
            "Its calendar event is not written yet and will show the change",
        });
        await daemon.movePending("cal-log");
        assert.match(eventOf(waiting.id).notes, /Rating: ★★☆☆☆\nNote: later/);

        // The open session and an unknown id are refused.
        const open = await daemon.startAdhoc({
          goal: "Open",
          durationSeconds: 600,
          calendarId: "cal-work",
        });
        await rejectsWith(
          daemon.updateSession(open.id, { rating: 5, note: null }),
          "daemon",
          /still open; finish it before editing it/,
        );
        await rejectsWith(
          daemon.updateSession(4242, { rating: 5, note: null }),
          "daemon",
          /no session with id 4242/,
        );

        // Checked before anything is sent.
        const sent = fake.state.requests.length;
        await assert.rejects(
          daemon.updateSession(0, { rating: 5, note: null }),
          RangeError,
        );
        await assert.rejects(
          daemon.updateSession(1.5, { rating: 5, note: null }),
          RangeError,
        );
        await assert.rejects(
          daemon.updateSession(logged.id, { rating: 6, note: null }),
          RangeError,
        );
        await assert.rejects(
          daemon.updateSession(logged.id, { rating: 0, note: null }),
          RangeError,
        );
        await assert.rejects(
          daemon.updateSession(logged.id, { rating: 2.5, note: null }),
          RangeError,
        );
        assert.equal(fake.state.requests.length, sent);
      } finally {
        await fake.close();
      }
    },
  ],
  [
    "daemon: updateSession rejects a malformed reply and drops an empty warning",
    async () => {
      const dir = freshDir();
      const socketPath = path.join(dir, "s.sock");
      let reply: Record<string, unknown> = { ok: true };
      const server = await scriptedServer(socketPath, (_raw, socket) => {
        socket.end(`${JSON.stringify(reply)}\n`);
      });
      const daemon = new FocusDaemon({
        socketPath,
        binaryPath: "/nonexistent",
      });
      const session = { id: 3, goal: "G", state: "finished" };
      try {
        await rejectsWith(
          daemon.updateSession(3, { rating: null, note: null }),
          "protocol",
          /"session"/,
        );
        reply = { ok: true, session, logEventUpdated: false, warning: "  " };
        assert.deepEqual(
          await daemon.updateSession(3, { rating: 4, note: "x" }),
          { session, logEventUpdated: false, warning: null },
        );
        reply = { ok: true, session, logEventUpdated: "yes" };
        assert.equal(
          (await daemon.updateSession(3, { rating: 4, note: null }))
            .logEventUpdated,
          false,
        );
        reply = { ok: false, error: "unknown command: updateSession" };
        await rejectsWith(
          daemon.updateSession(3, { rating: null, note: null }),
          "daemon",
          /unknown command/,
        );
        // Both fields are always sent, null included.
        assert.deepEqual(JSON.parse(server.received[0]), {
          sessionId: 3,
          rating: null,
          note: null,
          cmd: "updateSession",
        });
      } finally {
        await server.close();
      }
    },
  ],
  [
    "editSessionValues and editSessionRequest: map the form both ways",
    async () => {
      assert.deepEqual(editSessionValues({ rating: 4, note: "Shipped" }), {
        rating: "4",
        note: "Shipped",
      });
      assert.deepEqual(editSessionValues({ rating: null, note: null }), {
        rating: NO_RATING,
        note: "",
      });
      // Anything the dropdown cannot show reads as no rating.
      assert.equal(editSessionValues({ rating: 7, note: null }).rating, "none");
      assert.equal(
        editSessionValues({ rating: 2.5, note: null }).rating,
        "none",
      );
      assert.deepEqual(editSessionRequest({ rating: "5", note: " after " }), {
        rating: 5,
        note: "after",
      });
      assert.deepEqual(editSessionRequest({ rating: NO_RATING, note: "" }), {
        rating: null,
        note: null,
      });
      assert.deepEqual(
        editSessionRequest({ rating: "1", note: "two\n  lines" }),
        { rating: 1, note: "two lines" },
      );
      // Round trip: the prefilled form submitted as is changes nothing.
      for (const session of [
        { rating: 3, note: "kept" },
        { rating: null, note: null },
      ]) {
        assert.deepEqual(
          editSessionRequest(editSessionValues(session)),
          session,
        );
      }
    },
  ],
  [
    "updateToastText: says whether the calendar event changed",
    async () => {
      const session = {
        id: 1,
        goal: "G",
        state: "finished" as const,
        startedAt: "",
        plannedEnd: null,
        calendarId: "cal-work",
        profile: "default",
        sourceEventId: null,
      };
      assert.deepEqual(
        updateToastText({
          session: { ...session, logEventId: "e1" },
          logEventUpdated: true,
          warning: null,
        }),
        {
          title: "Session updated",
          message: "Its calendar event was updated too",
        },
      );
      assert.deepEqual(
        updateToastText({
          session: { ...session, logEventId: "e1" },
          logEventUpdated: false,
          warning:
            "calendar access is denied, so the log event was not updated",
        }),
        {
          title: "Session updated, calendar event unchanged",
          message:
            "calendar access is denied, so the log event was not updated",
        },
      );
      const quiet = (extra: Record<string, unknown>) =>
        updateToastText({
          session: { ...session, logEventId: null, ...extra },
          logEventUpdated: false,
          warning: null,
        }).message;
      assert.equal(
        quiet({}),
        "Its calendar event is not written yet and will show the change",
      );
      assert.equal(quiet({ logSkipped: true }), "It has no calendar event");
      assert.equal(
        quiet({ endReason: "abandoned" }),
        "It has no calendar event",
      );
    },
  ],
];

(async () => {
  let failed = 0;
  for (const [name, run] of cases) {
    try {
      await run();
      console.log(`ok   ${name}`);
    } catch (error) {
      failed += 1;
      console.log(`FAIL ${name}`);
      console.log(error instanceof Error ? error.stack : error);
    }
  }
  console.log(`${cases.length - failed}/${cases.length} passed`);
  process.exit(failed === 0 ? 0 : 1);
})();
