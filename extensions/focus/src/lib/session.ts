import type { Session } from "./daemon";
import { durationText } from "./time";

// Pure helpers for the Running section of Focus Today. Everything takes
// `now` (and when the session was fetched) so tests can pin the clock.

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
// left", or "time's up" / "stopped" at the end sheet.
export function sessionStatusText(
  session: Pick<Session, "state" | "plannedEnd" | "endReason">,
  now: Date,
): string {
  if (session.state === "ending") {
    return session.endReason === "manual" ? "stopped" : "time's up";
  }
  if (session.state === "finished") return "finished";
  const left = session.plannedEnd
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
