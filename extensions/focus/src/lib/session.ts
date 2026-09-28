import type { BlockingStatus, Session } from "./daemon";
import { durationText } from "./time";

// Pure helpers for the Running section of Focus Today. Everything takes
// `now` (and when the session was fetched) so tests can pin the clock.

// The session as the helper has it now: a running or paused session whose
// planned end has passed is at the end sheet (the helper checks every
// second), even if the reply predates that. Keeps the row from offering
// actions the helper would refuse until the next refresh. A paused one
// stayed paused until the deadline (where the helper closes the pause), so
// its paused time runs on from `fetchedAt` to the deadline. A paused ad-hoc
// session (`pauseStopsClock`) never reaches its deadline: its clock is
// stopped, so it is left as it is.
export function effectiveSession<
  T extends Pick<
    Session,
    "state" | "plannedEnd" | "endReason" | "pausedSeconds" | "pauseStopsClock"
  >,
>(session: T, fetchedAt: Date, now: Date): T {
  if (session.state !== "running" && session.state !== "paused") {
    return session;
  }
  if (session.state === "paused" && session.pauseStopsClock) return session;
  const end = session.plannedEnd ? Date.parse(session.plannedEnd) : Number.NaN;
  if (!Number.isFinite(end) || now.getTime() < end) return session;
  const ending = { ...session, state: "ending", endReason: "timer" };
  if (session.state === "paused") {
    const since = Math.max(0, (end - fetchedAt.getTime()) / 1000);
    ending.pausedSeconds = (session.pausedSeconds ?? 0) + since;
  }
  return ending;
}

export interface SessionActions {
  pause: boolean;
  resume: boolean;
  extend: boolean;
  stop: boolean;
  finish: boolean;
}

// Which actions the session's state allows; the helper refuses the rest.
export function sessionActions(
  session: Pick<Session, "state">,
): SessionActions {
  const open =
    session.state === "running" ||
    session.state === "paused" ||
    session.state === "ending";
  return {
    pause: session.state === "running",
    resume: session.state === "paused",
    extend: open,
    stop: session.state === "running" || session.state === "paused",
    finish: open,
  };
}

// Paused seconds now: the helper's count at `fetchedAt`, plus the time since
// if the session is still paused.
export function pausedSecondsNow(
  session: Pick<Session, "state" | "pausedSeconds">,
  fetchedAt: Date,
  now: Date,
): number {
  const base = session.pausedSeconds ?? 0;
  if (session.state !== "paused") return base;
  return base + Math.max(0, (now.getTime() - fetchedAt.getTime()) / 1000);
}

// The short state text beside the session: "12 min left", "paused, 12 min
// left", or "time's up" / "stopped" at the end sheet. A paused ad-hoc
// session's time left is frozen (`pauseStopsClock`; its `plannedEnd` moves
// on with the clock instead), so the reply's `remainingSeconds` is read as
// it is rather than counted down from the planned end.
export function sessionStatusText(
  session: Pick<
    Session,
    | "state"
    | "plannedEnd"
    | "endReason"
    | "pauseStopsClock"
    | "remainingSeconds"
  >,
  now: Date,
): string {
  if (session.state === "ending") {
    return session.endReason === "manual" ? "stopped" : "time's up";
  }
  if (session.state === "finished") return "finished";
  const frozen =
    session.state === "paused" &&
    session.pauseStopsClock === true &&
    typeof session.remainingSeconds === "number";
  const left = frozen
    ? (session.remainingSeconds as number)
    : session.plannedEnd
      ? (Date.parse(session.plannedEnd) - now.getTime()) / 1000
      : Number.NaN;
  const remaining =
    Number.isFinite(left) && left > 0 ? `${durationText(left)} left` : "ending";
  return session.state === "paused" ? `paused, ${remaining}` : remaining;
}

// "paused 5 min", or null when it has not been paused.
export function pausedText(seconds: number): string | null {
  if (!Number.isFinite(seconds) || seconds < 1) return null;
  return `paused ${durationText(seconds)}`;
}

// The blocking line on the Running row: "default · blocklist", "deep ·
// allowlist, off while paused". Falls back to the session's profile name
// when the helper's blocking status is not available.
export function blockingText(
  session: Pick<Session, "state" | "profile">,
  blocking: Pick<BlockingStatus, "profile" | "mode"> | null,
): string {
  const profile = blocking?.profile ?? session.profile;
  const label = blocking?.mode ? `${profile} · ${blocking.mode}` : profile;
  return session.state === "paused" ? `${label}, off while paused` : label;
}
