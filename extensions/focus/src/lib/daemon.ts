import { environment } from "@raycast/api";
import { spawn } from "node:child_process";
import { access, chmod } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { SOCKET_PATH } from "./config";

// Client for the focus-daemon helper (assets/focus-daemon). The protocol is
// one request per connection: send one JSON object and a newline, read one
// JSON line back, close. Replies are {"ok": true, ...} or
// {"ok": false, "error": "..."}.

export interface Calendar {
  id: string;
  title: string;
  account: string;
  color: string | null;
  writable: boolean;
}

// Duplicate calendars (one Google calendar reached through two accounts) only
// differ by account, so the account is always part of the label. This is also
// the logCalendarName written to config.json.
export function calendarLabel(
  calendar: Pick<Calendar, "title" | "account">,
): string {
  return `${calendar.title} (${calendar.account})`;
}

export interface TodayEvent {
  id: string;
  title: string;
  calendarId: string;
  calendarTitle: string;
  start: string;
  end: string;
  remainingSeconds: number;
}

// "ending" is the end sheet: the timer ran out (or the planned end passed
// while paused) or Kai pressed Stop; it waits for Extend or Finish.
export type SessionState = "running" | "paused" | "ending" | "finished";

export interface Session {
  id: number;
  goal: string;
  state: SessionState;
  startedAt: string;
  // The end the timer runs to, extensions included.
  plannedEnd: string | null;
  calendarId: string;
  profile: string;
  sourceEventId: string | null;
  // Seconds added by Extend so far.
  extendedSeconds?: number;
  // Seconds spent paused so far (open sessions count an open pause up to
  // the moment of the reply).
  pausedSeconds?: number;
  // Open sessions only: whole seconds to the planned end, 0 while ending.
  remainingSeconds?: number;
  // While ending, why ("timer" or "manual"), which Finish records unless
  // told otherwise; for a finished session, the recorded reason.
  endReason?: string | null;
}

export interface FinishResult {
  session: Session;
  logEventId: string | null;
  logPending: boolean;
  // Started under no calendar: nothing is written to any calendar.
  logSkipped: boolean;
}

export interface WaitingSession {
  sessionId: number;
  goal: string;
  endedAt: string;
  logCalendarName: string | null;
}

export interface PendingCounts {
  written: number;
  adopted: number;
  stillWaiting: number;
}

// The `blocking` reply: what the open session blocks. `profile` and `mode`
// are null only when no session is open; a paused session keeps them with
// `active: false`. In allowlist mode the listed apps and hosts are in
// `allowedApps` and `allowedHosts` (everything else is blocked) and the
// blocked lists are empty; in blocklist mode it is the other way round.
export interface BlockingStatus {
  // The open session this describes, or null when idle.
  sessionId: number | null;
  active: boolean;
  profile: string | null;
  // The name the session asked for when it was unknown and "default" was used.
  profileFallbackFrom: string | null;
  mode: "blocklist" | "allowlist" | null;
  blockedApps: string[];
  blockedHosts: string[];
  allowedApps: string[];
  allowedHosts: string[];
  snoozeSeconds: number;
  snoozed: { kind: "app" | "site"; target: string; until: string }[];
}

export interface SnoozeResult {
  kind: "app" | "site";
  target: string;
  until: string;
}

// The `stats` reply (HELPER.md "stats"). Focused seconds exclude pauses;
// running sessions are left out; abandoned ones count, with no rating.
export interface StatsTotals {
  focusedSeconds: number;
  sessions: number;
  // Mean of the rated sessions, null when none is rated.
  averageRating: number | null;
}

export interface CalendarStats {
  // "adhoc" for the "Ad hoc" row.
  calendarId: string;
  calendarTitle: string;
  focusedSeconds: number;
  sessions: number;
}

export interface DayStats {
  // Local date, "2026-09-22".
  date: string;
  focusedSeconds: number;
}

export interface RecentSession {
  id: number;
  goal: string;
  calendarTitle: string;
  startedAt: string;
  endedAt: string;
  focusedSeconds: number;
  rating: number | null;
  note: string | null;
  // "timer", "manual" or "abandoned".
  endReason: string | null;
  // Every blocked attempt, snoozed ones included, as the log event counts them.
  blockedAttempts: number;
  snoozes: number;
  // Finished but its log event is not written yet.
  logPending: boolean;
  // Filed under no calendar: nothing was or will be written to one.
  logSkipped: boolean;
}

export interface StatsWaiting {
  sessionId: number;
  goal: string;
  logCalendarName: string | null;
  endedAt?: string | null;
}

export interface Stats {
  today: StatsTotals;
  // The last `days` days, today included.
  week: StatsTotals;
  perCalendar: CalendarStats[];
  // Every day of the window, oldest first.
  days: DayStats[];
  // The last 20 finished or abandoned sessions, newest first.
  recent: RecentSession[];
  waiting: StatsWaiting[];
  // The bar chart of `days` as SVG, or null when the helper could not write it.
  chartPath: string | null;
}

export const STATS_DAYS = { min: 1, max: 90, default: 7 } as const;

export interface AdhocRequest {
  goal: string;
  durationSeconds: number;
  calendarId: string;
  profile?: string;
}

export interface FinishRequest {
  rating?: number;
  note?: string;
  // Left out, the helper records why the session reached the end sheet
  // ("timer" or "manual"), or "manual" when it never did.
  reason?: "timer" | "manual";
}

// Extend choices, as on the native end sheet.
export const EXTEND_MINUTES = [5, 10, 15, 25] as const;

export type DaemonErrorCode =
  | "missing-binary" // assets/focus-daemon is not there
  | "access-denied" // the socket or the binary refused us
  | "not-running" // nothing listening at the socket
  | "launch-failed" // spawned, but it never answered
  | "timeout" // connected, but no reply in time
  | "protocol" // the reply was not one JSON object with a boolean ok
  | "daemon"; // the helper answered {"ok": false, "error": ...}

export class DaemonError extends Error {
  readonly code: DaemonErrorCode;

  constructor(code: DaemonErrorCode, message: string) {
    super(message);
    this.name = "DaemonError";
    this.code = code;
  }
}

export type Reply = Record<string, unknown> & { ok: true };

// A reply longer than this is treated as a broken helper rather than buffered
// forever.
const MAX_REPLY_BYTES = 8 * 1024 * 1024;

function errnoCode(error: unknown): string | undefined {
  return (error as NodeJS.ErrnoException | undefined)?.code;
}

function socketError(error: unknown, socketPath: string): DaemonError {
  const code = errnoCode(error);
  if (code === "ENOENT" || code === "ECONNREFUSED") {
    return new DaemonError(
      "not-running",
      `The Focus helper is not running (nothing at ${socketPath}).`,
    );
  }
  if (code === "EACCES" || code === "EPERM") {
    return new DaemonError(
      "access-denied",
      `Permission denied opening the Focus helper socket at ${socketPath}. Check who owns ${path.dirname(socketPath)} and its permissions.`,
    );
  }
  const reason = error instanceof Error ? error.message : String(error);
  return new DaemonError(
    "protocol",
    `Could not talk to the Focus helper at ${socketPath}: ${reason}`,
  );
}

export function parseReply(line: string): Reply {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    throw new DaemonError(
      "protocol",
      `The Focus helper sent a reply that is not JSON: ${line.slice(0, 200)}`,
    );
  }
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    Array.isArray(parsed) ||
    typeof (parsed as { ok?: unknown }).ok !== "boolean"
  ) {
    throw new DaemonError(
      "protocol",
      `The Focus helper sent a reply without an "ok" field: ${line.slice(0, 200)}`,
    );
  }
  const reply = parsed as Record<string, unknown>;
  if (reply.ok === false) {
    const message =
      typeof reply.error === "string" && reply.error.trim()
        ? reply.error
        : "The Focus helper reported an error without a message.";
    throw new DaemonError("daemon", message);
  }
  return reply as Reply;
}

// One round trip: connect, write the request and a newline, read up to the
// first newline (or the end of the stream), close.
export function sendRequest(
  socketPath: string,
  request: Record<string, unknown>,
  timeoutMs: number,
): Promise<Reply> {
  return new Promise<Reply>((resolve, reject) => {
    let settled = false;
    let buffer = "";
    const socket = net.createConnection({ path: socketPath });
    socket.setEncoding("utf8");

    const settle = (error: Error | null, reply?: Reply) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error);
      else resolve(reply as Reply);
    };

    const finishWith = (line: string) => {
      try {
        settle(null, parseReply(line));
      } catch (error) {
        settle(error as Error);
      }
    };

    const timer = setTimeout(() => {
      settle(
        new DaemonError(
          "timeout",
          `The Focus helper did not answer "${String(request.cmd)}" within ${Math.round(timeoutMs / 1000)} s. If macOS is asking for Calendar access, answer the prompt and try again.`,
        ),
      );
    }, timeoutMs);

    socket.on("connect", () => {
      socket.write(`${JSON.stringify(request)}\n`);
    });
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline >= 0) {
        finishWith(buffer.slice(0, newline));
      } else if (buffer.length > MAX_REPLY_BYTES) {
        settle(
          new DaemonError(
            "protocol",
            "The Focus helper sent a reply larger than 8 MB without a newline.",
          ),
        );
      }
    });
    socket.on("end", () => {
      if (buffer.trim()) finishWith(buffer);
      else
        settle(
          new DaemonError(
            "protocol",
            `The Focus helper closed the connection without answering "${String(request.cmd)}".`,
          ),
        );
    });
    socket.on("close", () => {
      settle(
        new DaemonError(
          "protocol",
          `The Focus helper closed the connection without answering "${String(request.cmd)}".`,
        ),
      );
    });
    socket.on("error", (error) => settle(socketError(error, socketPath)));
  });
}

function field<T>(
  reply: Reply,
  key: string,
  check: (value: unknown) => boolean,
): T {
  const value = reply[key];
  if (!check(value)) {
    throw new DaemonError(
      "protocol",
      `The Focus helper's reply is missing a valid "${key}".`,
    );
  }
  return value as T;
}

const isArray = (value: unknown) => Array.isArray(value);
const isObjectOrNull = (value: unknown) =>
  value === null || (typeof value === "object" && !Array.isArray(value));
const isObject = (value: unknown) =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const isNumber = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value);
const isString = (value: unknown) => typeof value === "string";

function counts(reply: Reply): PendingCounts {
  return {
    written: field<number>(reply, "written", isNumber),
    adopted: field<number>(reply, "adopted", isNumber),
    stillWaiting: field<number>(reply, "stillWaiting", isNumber),
  };
}

export interface DaemonOptions {
  socketPath?: string;
  // Defaults to assets/focus-daemon inside the installed extension.
  binaryPath?: string;
  // How long one request may wait for its reply.
  timeoutMs?: number;
  // How long a freshly launched helper has to start answering.
  launchTimeoutMs?: number;
}

export class FocusDaemon {
  readonly socketPath: string;
  private readonly binaryOverride?: string;
  private readonly timeoutMs: number;
  private readonly launchTimeoutMs: number;
  private launching: Promise<void> | null = null;

  constructor(options: DaemonOptions = {}) {
    this.socketPath = options.socketPath ?? SOCKET_PATH;
    this.binaryOverride = options.binaryPath;
    this.timeoutMs = options.timeoutMs ?? 15_000;
    this.launchTimeoutMs = options.launchTimeoutMs ?? 5_000;
  }

  get binaryPath(): string {
    return (
      this.binaryOverride ?? path.join(environment.assetsPath, "focus-daemon")
    );
  }

  // Sends a request, launching the helper first if nothing answers.
  async request(
    cmd: string,
    payload: Record<string, unknown> = {},
  ): Promise<Reply> {
    const message = { ...payload, cmd };
    try {
      return await sendRequest(this.socketPath, message, this.timeoutMs);
    } catch (error) {
      if (!(error instanceof DaemonError) || error.code !== "not-running") {
        throw error;
      }
    }
    await this.ensureLaunched();
    return sendRequest(this.socketPath, message, this.timeoutMs);
  }

  // Parallel requests that all find the helper down share one launch.
  private ensureLaunched(): Promise<void> {
    if (!this.launching) {
      this.launching = this.launch().finally(() => {
        this.launching = null;
      });
    }
    return this.launching;
  }

  private async launch(): Promise<void> {
    const binary = this.binaryPath;
    try {
      await access(binary);
    } catch {
      throw new DaemonError(
        "missing-binary",
        `The Focus helper is missing at ${binary}. Build it with "npm run build-helper" in extensions/focus.`,
      );
    }
    // Raycast may copy assets without the executable bit (notes does the
    // same). If chmod is refused the spawn below reports it.
    await chmod(binary, 0o755).catch(() => undefined);

    // Held in an object so the exit callback's write is visible to the
    // polling loop below (TypeScript narrows a plain `let` to null).
    const exited: { code: number | null; signal: string | null }[] = [];
    const child = spawn(binary, [], { detached: true, stdio: "ignore" });
    child.once("exit", (code, signal) => {
      exited.push({ code, signal });
    });
    // spawn() reports a missing or non-executable binary asynchronously.
    await new Promise<void>((resolve, reject) => {
      child.once("spawn", resolve);
      child.once("error", (error) => {
        const code = errnoCode(error);
        reject(
          code === "EACCES" || code === "EPERM"
            ? new DaemonError(
                "access-denied",
                `Permission denied running the Focus helper at ${binary}.`,
              )
            : new DaemonError(
                "launch-failed",
                `Could not start the Focus helper at ${binary}: ${error.message}`,
              ),
        );
      });
    });
    child.unref();

    // `focus-daemon` with no arguments spawns the real daemon in its own
    // session and exits 0 once that daemon listens, so a clean exit is good
    // news, not a failure. Only a non-zero code or a signal means it gave up.
    // A ping that times out (the daemon is up but busy with its startup
    // recovery) is retried as well, until the launch window closes.
    const deadline = Date.now() + this.launchTimeoutMs;
    for (;;) {
      try {
        await sendRequest(this.socketPath, { cmd: "ping" }, 1_000);
        return;
      } catch (error) {
        if (
          !(error instanceof DaemonError) ||
          (error.code !== "not-running" && error.code !== "timeout")
        ) {
          throw error;
        }
      }
      if (exited.length > 0) {
        const { code, signal } = exited[0];
        if (signal !== null || (code !== null && code !== 0)) {
          throw new DaemonError(
            "launch-failed",
            `The Focus helper exited (${signal ?? `code ${code}`}) before it opened ${this.socketPath}.`,
          );
        }
      }
      if (Date.now() >= deadline) {
        throw new DaemonError(
          "launch-failed",
          `The Focus helper started but did not answer at ${this.socketPath} within ${Math.round(this.launchTimeoutMs / 1000)} s.`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }

  async ping(): Promise<{ version: string; pid: number }> {
    const reply = await this.request("ping");
    return {
      version: String(reply.version ?? ""),
      pid: field<number>(reply, "pid", isNumber),
    };
  }

  async calendars(): Promise<Calendar[]> {
    return field<Calendar[]>(
      await this.request("calendars"),
      "calendars",
      isArray,
    );
  }

  async today(): Promise<TodayEvent[]> {
    return field<TodayEvent[]>(await this.request("today"), "events", isArray);
  }

  async status(): Promise<Session | null> {
    return field<Session | null>(
      await this.request("status"),
      "session",
      isObjectOrNull,
    );
  }

  // Occurrences of a recurring event share an id, so the occurrence's start
  // is sent too and the helper picks that one.
  async start(eventId: string, start?: string): Promise<Session> {
    const payload: Record<string, unknown> = { eventId };
    if (start) payload.start = start;
    return field<Session>(
      await this.request("start", payload),
      "session",
      isObject,
    );
  }

  async startAdhoc(request: AdhocRequest): Promise<Session> {
    const goal = request.goal.trim();
    if (!goal) throw new RangeError("An ad-hoc session needs a goal.");
    if (
      !Number.isInteger(request.durationSeconds) ||
      request.durationSeconds <= 0
    ) {
      throw new RangeError("durationSeconds must be a positive whole number.");
    }
    const payload: Record<string, unknown> = {
      goal,
      durationSeconds: request.durationSeconds,
      calendarId: request.calendarId,
    };
    if (request.profile) payload.profile = request.profile;
    return field<Session>(
      await this.request("startAdhoc", payload),
      "session",
      isObject,
    );
  }

  // Pause, Resume, Extend and Stop reply with the session as it now is. The
  // helper refuses a change the session's state does not allow (pausing at
  // the end sheet, resuming a running session) with a message to show.
  async pause(): Promise<Session> {
    return this.sessionReply(await this.request("pause"));
  }

  async resume(): Promise<Session> {
    return this.sessionReply(await this.request("resume"));
  }

  // Also works at the end sheet, which returns the session to running.
  async extend(seconds: number): Promise<Session> {
    if (!Number.isInteger(seconds) || seconds < 60 || seconds > 86_400) {
      throw new RangeError("Extend takes whole seconds from 60 to 86400.");
    }
    return this.sessionReply(await this.request("extend", { seconds }));
  }

  // Sends the session to the end sheet.
  async stop(): Promise<Session> {
    return this.sessionReply(await this.request("stop"));
  }

  private sessionReply(reply: Reply): Session {
    return field<Session>(reply, "session", isObject);
  }

  async finish(request: FinishRequest = {}): Promise<FinishResult> {
    const payload: Record<string, unknown> = {};
    if (request.reason) payload.reason = request.reason;
    if (request.rating !== undefined) {
      if (
        !Number.isInteger(request.rating) ||
        request.rating < 1 ||
        request.rating > 5
      ) {
        throw new RangeError("rating must be a whole number from 1 to 5.");
      }
      payload.rating = request.rating;
    }
    // The log keeps a one-line note.
    const note = request.note?.replace(/\s+/g, " ").trim();
    if (note) payload.note = note;
    const reply = await this.request("finish", payload);
    return {
      session: field<Session>(reply, "session", isObject),
      logEventId:
        typeof reply.logEventId === "string" ? reply.logEventId : null,
      logPending: reply.logPending === true,
      logSkipped: reply.logSkipped === true,
    };
  }

  async blocking(): Promise<BlockingStatus> {
    const reply = await this.request("blocking");
    const strings = (key: string) => field<string[]>(reply, key, isArray);
    const mode = reply.mode;
    return {
      sessionId: typeof reply.sessionId === "number" ? reply.sessionId : null,
      active: reply.active === true,
      profile: typeof reply.profile === "string" ? reply.profile : null,
      profileFallbackFrom:
        typeof reply.profileFallbackFrom === "string"
          ? reply.profileFallbackFrom
          : null,
      mode: mode === "blocklist" || mode === "allowlist" ? mode : null,
      blockedApps: strings("blockedApps"),
      blockedHosts: strings("blockedHosts"),
      allowedApps: strings("allowedApps"),
      allowedHosts: strings("allowedHosts"),
      snoozeSeconds: field<number>(reply, "snoozeSeconds", isNumber),
      snoozed: field<BlockingStatus["snoozed"]>(reply, "snoozed", isArray),
    };
  }

  // Lets an app (bundle id) or a host through for the snooze length. The
  // helper guesses which it is unless `kind` says.
  async snooze(target: string, kind?: "app" | "site"): Promise<SnoozeResult> {
    const trimmed = target.trim();
    if (!trimmed) throw new RangeError("snooze needs a target.");
    const payload: Record<string, unknown> = { target: trimmed };
    if (kind) payload.kind = kind;
    const reply = await this.request("snooze", payload);
    return {
      kind: reply.kind === "app" ? "app" : "site",
      target: field<string>(reply, "target", isString),
      until: field<string>(reply, "until", isString),
    };
  }

  // Totals for today and the last `days` days, per calendar and per day, the
  // recent sessions, and the chart the helper just wrote.
  async stats(days: number = STATS_DAYS.default): Promise<Stats> {
    if (
      !Number.isInteger(days) ||
      days < STATS_DAYS.min ||
      days > STATS_DAYS.max
    ) {
      throw new RangeError("stats takes whole days from 1 to 90.");
    }
    const reply = await this.request("stats", { days });
    const totals = (key: string) => field<StatsTotals>(reply, key, isObject);
    const chartPath = reply.chartPath;
    return {
      today: totals("today"),
      week: totals("week"),
      perCalendar: field<CalendarStats[]>(reply, "perCalendar", isArray),
      days: field<DayStats[]>(reply, "days", isArray),
      recent: field<RecentSession[]>(reply, "recent", isArray),
      waiting: field<StatsWaiting[]>(reply, "waiting", isArray),
      chartPath:
        typeof chartPath === "string" && chartPath.startsWith("/")
          ? chartPath
          : null,
    };
  }

  async pending(): Promise<WaitingSession[]> {
    return field<WaitingSession[]>(
      await this.request("pending"),
      "waiting",
      isArray,
    );
  }

  async retryPending(): Promise<PendingCounts> {
    return counts(await this.request("retryPending"));
  }

  async movePending(calendarId: string): Promise<PendingCounts> {
    return counts(await this.request("movePending", { calendarId }));
  }

  // Never launches the helper just to stop it.
  async quit(): Promise<void> {
    try {
      await sendRequest(this.socketPath, { cmd: "quit" }, this.timeoutMs);
    } catch (error) {
      if (error instanceof DaemonError && error.code === "not-running") return;
      throw error;
    }
  }
}

let shared: FocusDaemon | null = null;

export function getDaemon(): FocusDaemon {
  shared ??= new FocusDaemon();
  return shared;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
