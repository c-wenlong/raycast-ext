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
  ConfigError,
  defaultConfig,
  readConfig,
  writeConfig,
} from "../src/lib/config";
import {
  DaemonError,
  EXTEND_MINUTES,
  FocusDaemon,
  calendarLabel,
  sendRequest,
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
  NO_LOG_CALENDAR,
  moveTarget,
  resolveLogCalendar,
  settingsChoices,
} from "../src/lib/settings";
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
      assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).startableCalendars, ["x"]);

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
      assert.deepEqual(Object.keys(saved), [...Object.keys(defaultConfig()), "helperOnly"]);
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
      await assert.rejects(writeConfig({ startableCalendars: [] }, file), ConfigError);
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
        { id: "later", title: "later", start: at(now, 0.001), end: at(now, 3600) },
        { id: "starts-now", title: "starts now", start: at(now, 0), end: at(now, 3600) },
        { id: "ends-60", title: "ends in exactly 60 s", start: at(now, -600), end: at(now, 60) },
        { id: "ends-61", title: "ends in 61 s", start: at(now, -600), end: at(now, 61) },
        { id: "ended", title: "ended", start: at(now, -7200), end: at(now, -3600) },
        { id: "bad", title: "bad date", start: "garbage", end: at(now, 3600) },
        { id: "overlap-b", title: "b", start: at(now, -600), end: at(now, 3000) },
        { id: "overlap-a", title: "a", start: at(now, -600), end: at(now, 3000) },
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
      assert.equal(formatTimeRange(start.toISOString(), end.toISOString()), "09:05–15:00");
      const late = new Date(2026, 8, 27, 23, 0);
      const nextDay = new Date(2026, 8, 28, 1, 30); // a Monday
      assert.equal(formatTimeRange(late.toISOString(), nextDay.toISOString()), "23:00–Mon 01:30");
      assert.equal(formatTimeRange("x", end.toISOString()), "?");
      assert.equal(stars(4), "★★★★☆");
      assert.equal(stars(5), "★★★★★");
      assert.equal(stars(1), "★☆☆☆☆");
      assert.equal(stars(9), "★★★★★");
      assert.equal(stars(0), "☆☆☆☆☆");
      assert.equal(calendarLabel({ title: "Work", account: "kai@work.example" }), "Work (kai@work.example)");
    },
  ],

  // ---- settings and waiting-session decisions ----
  [
    "settings: unavailable calendars stay selectable and survive a save",
    async () => {
      const calendars = [
        { id: "w", title: "Work", account: "a", color: "#000", writable: true },
        { id: "w2", title: "Work", account: "a", color: null, writable: true },
        { id: "ro", title: "Holidays", account: "b", color: null, writable: false },
      ];
      const config = {
        ...defaultConfig(),
        startableCalendars: ["w", "gone"],
        logCalendarId: "old-log",
        logCalendarName: "Old Log (x)",
      };
      const choices = settingsChoices(calendars, config);
      assert.deepEqual(choices.missingStartable, ["gone"]);
      assert.deepEqual(choices.writable.map((c) => c.id), ["w", "w2"]);
      assert.deepEqual(choices.unavailableLog, { id: "old-log", title: "Old Log (x) (unavailable)" });
      // Keeping the unavailable log calendar keeps its stored name.
      assert.deepEqual(resolveLogCalendar("old-log", calendars, config), {
        logCalendarId: "old-log",
        logCalendarName: "Old Log (x)",
      });
      assert.deepEqual(resolveLogCalendar("w2", calendars, config), {
        logCalendarId: "w2",
        logCalendarName: "Work (a)",
      });
      assert.deepEqual(resolveLogCalendar(NO_LOG_CALENDAR, calendars, config), {
        logCalendarId: null,
        logCalendarName: null,
      });
      assert.deepEqual(resolveLogCalendar("stranger", calendars, config), {
        logCalendarId: null,
        logCalendarName: null,
      });
      // A saved log calendar that became read-only is also flagged.
      const readOnly = settingsChoices(calendars, { ...config, logCalendarId: "ro" });
      assert.equal(readOnly.unavailableLog?.id, "ro");
      assert.equal(settingsChoices(calendars, { ...config, logCalendarId: "w" }).unavailableLog, null);
      assert.equal(settingsChoices(calendars, defaultConfig()).unavailableLog, null);
    },
  ],
  [
    "settings: the move action targets the log calendar by id, whatever the names",
    async () => {
      assert.equal(moveTarget(defaultConfig()), null);
      // Two calendars can share "Work (a)"; the target is the id.
      assert.deepEqual(
        moveTarget({ ...defaultConfig(), logCalendarId: "w2", logCalendarName: "Work (a)" }),
        { id: "w2", name: "Work (a)" },
      );
      assert.deepEqual(moveTarget({ ...defaultConfig(), logCalendarId: "w2" }), {
        id: "w2",
        name: "the log calendar",
      });
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
      const daemon = new FocusDaemon({ socketPath, binaryPath: "/nonexistent" });
      assert.equal(await daemon.start("e1", "2026-09-27T14:00:00+08:00").catch((error) => error.message), 'The Focus helper\'s reply is missing a valid "session".');
      assert.equal(await daemon.status(), null);
      assert.equal(server.received.length, 2);
      for (const raw of server.received) {
        assert.ok(raw.endsWith("\n"));
        assert.equal(raw.indexOf("\n"), raw.length - 1, "exactly one newline, at the end");
      }
      // Recurring occurrences share an id, so the occurrence start goes along.
      assert.deepEqual(JSON.parse(server.received[0]), { eventId: "e1", start: "2026-09-27T14:00:00+08:00", cmd: "start" });
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
      const server = await scriptedServer(socketPath, (_raw, socket) => socket.end(reply));
      const daemon = new FocusDaemon({ socketPath, binaryPath: "/nonexistent" });
      await rejectsWith(daemon.start("e1"), "daemon", /^A session is already running\.$/);
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
      await rejectsWith(sendRequest(socketPath, { cmd: "status" }, 1000), "protocol", /not JSON/);
      mode = "no-ok";
      await rejectsWith(sendRequest(socketPath, { cmd: "status" }, 1000), "protocol", /"ok"/);
      mode = "array";
      await rejectsWith(sendRequest(socketPath, { cmd: "status" }, 1000), "protocol", /"ok"/);
      mode = "silent";
      await rejectsWith(sendRequest(socketPath, { cmd: "status" }, 1000), "protocol", /without answering "status"/);
      await server.close();
    },
  ],
  [
    "daemon: a helper that never answers times out",
    async () => {
      const socketPath = path.join(freshDir(), "s.sock");
      const server = await scriptedServer(socketPath, () => undefined);
      const daemon = new FocusDaemon({ socketPath, binaryPath: "/nonexistent", timeoutMs: 150 });
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
      const server = await scriptedServer(socketPath, (_raw, socket) => socket.end('{"ok":true}\n'));
      chmodSync(locked, 0o000);
      try {
        const binary = path.join(freshDir(), "must-not-run");
        const daemon = new FocusDaemon({ socketPath, binaryPath: binary });
        await rejectsWith(daemon.status(), "access-denied", /Permission denied/);
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
      const daemon = new FocusDaemon({ socketPath, binaryPath: binary, launchTimeoutMs: 10_000 });
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
      const daemon = new FocusDaemon({ socketPath, binaryPath: binary, launchTimeoutMs: 10_000 });
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
      writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${server}"\n`);
      chmodSync(binary, 0o755);
      const daemon = new FocusDaemon({ socketPath, binaryPath: binary, launchTimeoutMs: 10_000 });
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
      const fake = createFakeDaemon({ socketPath, configPath, now: () => clock });
      await fake.listen();
      const daemon = new FocusDaemon({ socketPath, binaryPath: "/nonexistent" });
      try {
        const calendars = await daemon.calendars();
        assert.deepEqual(
          calendars.filter((c) => c.title === "Work").map(calendarLabel),
          ["Work (kai@work.example)", "Work (kai@school.example)"],
        );

        await writeConfig({ startableCalendars: ["cal-work", "cal-study"] }, configPath);
        const events = await daemon.today();
        assert.deepEqual(
          events.map((e) => e.id),
          ["ev-review", "ev-pset", "ev-deep"],
        );
        const groups = groupEvents(events, clock);
        assert.deepEqual(groups.now.map((e) => e.id), ["ev-pset", "ev-review"]);
        assert.deepEqual(groups.later.map((e) => e.id), ["ev-deep"]);
        assert.equal(events[0].remainingSeconds, 3000);

        const session = await daemon.start("ev-review");
        assert.equal(session.goal, "Review the Focus plan");
        assert.equal(session.plannedEnd, at(clock, 3000));
        assert.equal((await daemon.status())?.id, session.id);
        // Starting while one is open sends that one to the end sheet.
        await rejectsWith(daemon.start("ev-pset"), "daemon", /already running.*end sheet/);
        assert.equal((await daemon.status())?.state, "ending");

        // Rating and note are checked before anything is sent.
        const sent = fake.state.requests.length;
        await assert.rejects(daemon.finish({ rating: 6 }), RangeError);
        await assert.rejects(daemon.finish({ rating: 2.5 }), RangeError);
        assert.equal(fake.state.requests.length, sent);

        // No log calendar yet: the session waits.
        const finished = await daemon.finish({ rating: 4, note: "  good\n run \n" });
        assert.equal(finished.logPending, true);
        assert.equal(finished.logEventId, null);
        // No reason unless asked: the helper knows why the session ended.
        assert.deepEqual(fake.state.requests.at(-1), {
          rating: 4,
          note: "good run",
          cmd: "finish",
        });
        assert.equal(await daemon.status(), null);
        const waiting = await daemon.pending();
        assert.deepEqual(waiting.map((w) => w.goal), ["Review the Focus plan"]);

        assert.deepEqual(await daemon.retryPending(), { written: 0, adopted: 0, stillWaiting: 1 });
        await rejectsWith(daemon.movePending("cal-holidays"), "daemon", /not writable/);
        assert.deepEqual(await daemon.movePending("cal-log"), { written: 1, adopted: 0, stillWaiting: 0 });
        assert.deepEqual(fake.state.requests.at(-1), { calendarId: "cal-log", cmd: "movePending" });
        assert.deepEqual(await daemon.pending(), []);

        // With a log calendar the event is written at once; an empty note
        // and no rating are left out of the request.
        await writeConfig({ logCalendarId: "cal-log", logCalendarName: "Focus Log (Google)" }, configPath);
        await assert.rejects(daemon.startAdhoc({ goal: "  ", durationSeconds: 60, calendarId: "cal-work" }), RangeError);
        await assert.rejects(daemon.startAdhoc({ goal: "x", durationSeconds: 0, calendarId: "cal-work" }), RangeError);
        const adhoc = await daemon.startAdhoc({ goal: " Read ", durationSeconds: 1500, calendarId: "cal-study" });
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

        await daemon.startAdhoc({ goal: "Deep", durationSeconds: 60, calendarId: "cal-work", profile: "deep" });
        assert.equal(fake.state.requests.at(-1).profile, "deep");
        await daemon.finish({ reason: "timer" });

        await rejectsWith(daemon.request("nonsense"), "daemon", /Unknown command/);
      } finally {
        await fake.close();
      }
    },
  ],
  // ---- session state: pause, resume, extend, stop ----
  [
    "session: actions follow the state",
    async () => {
      assert.deepEqual(sessionActions({ state: "running" }), { pause: true, resume: false, extend: true, stop: true, finish: true });
      assert.deepEqual(sessionActions({ state: "paused" }), { pause: false, resume: true, extend: true, stop: true, finish: true });
      assert.deepEqual(sessionActions({ state: "ending" }), { pause: false, resume: false, extend: true, stop: false, finish: true });
      assert.deepEqual(sessionActions({ state: "finished" }), { pause: false, resume: false, extend: false, stop: false, finish: false });
      assert.deepEqual([...EXTEND_MINUTES], [5, 10, 15, 25]);
    },
  ],
  [
    "session: status text and paused time",
    async () => {
      const now = new Date(2026, 8, 27, 14, 10, 0);
      const plannedEnd = at(now, 1190);
      assert.equal(sessionStatusText({ state: "running", plannedEnd, endReason: null }, now), "20 min left");
      assert.equal(sessionStatusText({ state: "paused", plannedEnd, endReason: null }, now), "paused, 20 min left");
      assert.equal(sessionStatusText({ state: "running", plannedEnd: at(now, -5), endReason: null }, now), "ending");
      assert.equal(sessionStatusText({ state: "ending", plannedEnd, endReason: "timer" }, now), "time's up");
      assert.equal(sessionStatusText({ state: "ending", plannedEnd, endReason: "manual" }, now), "stopped");
      assert.equal(sessionStatusText({ state: "running", plannedEnd: null, endReason: null }, now), "ending");
      const fetchedAt = new Date(now.getTime() - 90_000);
      assert.equal(pausedSecondsNow({ state: "paused", pausedSeconds: 30 }, fetchedAt, now), 120);
      assert.equal(pausedSecondsNow({ state: "running", pausedSeconds: 30 }, fetchedAt, now), 30);
      assert.equal(pausedSecondsNow({ state: "running" }, fetchedAt, now), 0);
      assert.equal(pausedText(0), null);
      assert.equal(pausedText(0.5), null);
      assert.equal(pausedText(120), "paused 2 min");
      assert.equal(pausedText(61), "paused 2 min");
      // A reply from before the deadline is read as the end sheet after it.
      // Paused since before the reply: the paused time runs on to the deadline.
      const past = { state: "paused" as const, plannedEnd: at(now, -1), endReason: null, pausedSeconds: 30 };
      const fetched = new Date(now.getTime() - 120_000);
      assert.deepEqual(effectiveSession(past, fetched, now), { ...past, state: "ending", endReason: "timer", pausedSeconds: 149 });
      assert.equal(pausedSecondsNow(effectiveSession(past, fetched, now), fetched, now), 149);
      assert.deepEqual(sessionActions(effectiveSession(past, fetched, now)).pause, false);
      const runningPast = { state: "running" as const, plannedEnd: at(now, -1), endReason: null, pausedSeconds: 30 };
      assert.equal(effectiveSession(runningPast, fetched, now).pausedSeconds, 30);
      const exact = { state: "running" as const, plannedEnd: at(now, 0), endReason: null };
      assert.equal(effectiveSession(exact, now, now).state, "ending");
      const ahead = { state: "running" as const, plannedEnd: at(now, 1), endReason: null };
      assert.equal(effectiveSession(ahead, now, now), ahead);
      const stopped = { state: "ending" as const, plannedEnd: at(now, 600), endReason: "manual" };
      assert.equal(effectiveSession(stopped, now, now), stopped);
      const unknown = { state: "running" as const, plannedEnd: null, endReason: null };
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
      const fake = createFakeDaemon({ socketPath, configPath, now: () => clock });
      await fake.listen();
      const daemon = new FocusDaemon({ socketPath, binaryPath: "/nonexistent" });
      const start = clock;
      try {
        await rejectsWith(daemon.pause(), "daemon", /^no session is running$/);
        const session = await daemon.startAdhoc({ goal: "Draft", durationSeconds: 600, calendarId: "cal-work" });
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
        assert.deepEqual(fake.state.requests.at(-1), { seconds: 300, cmd: "extend" });
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
        assert.deepEqual(fake.state.requests.at(-1), { rating: 5, cmd: "finish" });
        assert.equal(await daemon.status(), null);
        await rejectsWith(daemon.stop(), "daemon", /no session is running/);
      } finally {
        await fake.close();
      }
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
