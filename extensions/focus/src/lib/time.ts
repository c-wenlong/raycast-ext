// Pure time helpers for the Raycast views. Everything takes `now` so tests
// can pin the clock.

// PLAN: an event is startable only while its planned end is more than one
// minute away. The helper already filters on this; the view applies it again
// because a list left open keeps ticking.
export const MIN_REMAINING_SECONDS = 60;

export interface Timed {
  start: string;
  end: string;
  title?: string;
}

export interface Grouped<T> {
  // Already started (start at or before now).
  now: T[];
  // Starts in the future.
  later: T[];
}

function time(iso: string): number {
  return Date.parse(iso);
}

export function secondsUntil(iso: string, now: Date): number {
  return (time(iso) - now.getTime()) / 1000;
}

function byStartThenEnd<T extends Timed>(a: T, b: T): number {
  return (
    time(a.start) - time(b.start) ||
    time(a.end) - time(b.end) ||
    (a.title ?? "").localeCompare(b.title ?? "")
  );
}

export function groupEvents<T extends Timed>(
  events: T[],
  now: Date,
): Grouped<T> {
  const nowMs = now.getTime();
  const startable = events.filter((event) => {
    const start = time(event.start);
    const end = time(event.end);
    if (Number.isNaN(start) || Number.isNaN(end)) return false;
    return end - nowMs > MIN_REMAINING_SECONDS * 1000;
  });
  startable.sort(byStartThenEnd);
  return {
    now: startable.filter((event) => time(event.start) <= nowMs),
    later: startable.filter((event) => time(event.start) > nowMs),
  };
}

// Minutes are rounded up, so a session with 49 min 50 s left reads "50 min".
export function durationText(seconds: number): string {
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest === 0 ? `${hours} h` : `${hours} h ${rest} min`;
}

export function remainingText(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "ended";
  return `${durationText(seconds)} left`;
}

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

// 24-hour local time, "14:05".
export function formatClock(date: Date): string {
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function formatClockIso(iso: string): string {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? "?" : formatClock(date);
}

function sameLocalDay(a: Date, b: Date): boolean {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// "14:00–15:00"; an event that ends on another day names that day,
// "23:00–Tue 01:00".
export function formatTimeRange(startIso: string, endIso: string): string {
  const start = new Date(startIso);
  const end = new Date(endIso);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) return "?";
  const endText = sameLocalDay(start, end)
    ? formatClock(end)
    : `${WEEKDAYS[end.getDay()]} ${formatClock(end)}`;
  return `${formatClock(start)}–${endText}`;
}

// Five characters, filled then empty: stars(4) is "★★★★☆".
export function stars(rating: number): string {
  const filled = Math.max(0, Math.min(5, Math.round(rating)));
  return "★".repeat(filled) + "☆".repeat(5 - filled);
}
