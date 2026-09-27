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

export interface Session {
  id: number;
  goal: string;
  // "running" or "paused" today; step 2 adds "ending".
  state: string;
  startedAt: string;
  plannedEnd: string | null;
  calendarId: string;
  profile: string;
  sourceEventId: string | null;
}

export interface FinishResult {
  session: Session;
  logEventId: string | null;
  logPending: boolean;
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

export interface AdhocRequest {
  goal: string;
  durationSeconds: number;
  calendarId: string;
  profile?: string;
}

export interface FinishRequest {
  rating?: number;
  note?: string;
  reason?: "timer" | "manual";
}

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

    const deadline = Date.now() + this.launchTimeoutMs;
    for (;;) {
      try {
        await sendRequest(this.socketPath, { cmd: "ping" }, 1_000);
        return;
      } catch (error) {
        if (!(error instanceof DaemonError) || error.code !== "not-running") {
          throw error;
        }
      }
      if (exited.length > 0) {
        const { code, signal } = exited[0];
        throw new DaemonError(
          "launch-failed",
          `The Focus helper exited (${signal ?? `code ${code}`}) before it opened ${this.socketPath}.`,
        );
      }
      if (Date.now() >= deadline) {
        throw new DaemonError(
          "launch-failed",
          `The Focus helper started but did not open ${this.socketPath} within ${Math.round(this.launchTimeoutMs / 1000)} s.`,
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

  async finish(request: FinishRequest = {}): Promise<FinishResult> {
    const payload: Record<string, unknown> = {
      reason: request.reason ?? "manual",
    };
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
