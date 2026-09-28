import { CalendarStats, RecentSession, StatsTotals } from "./daemon";
import { formatTimeRange, stars } from "./time";

// Text for the Focus Stats view, kept out of the view so it is testable.
// Everything that depends on the day takes `now`.

// "under a minute", "45 min", "1 h", "1 h 25 min"; rounded to the nearest
// minute, as the helper's log event rounds. Zero is "0 min".
export function focusedText(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "0 min";
  if (seconds < 60) return "under a minute";
  const minutes = Math.round(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours === 0) return `${rest} min`;
  return rest === 0 ? `${hours} h` : `${hours} h ${rest} min`;
}

export function sessionsText(count: number): string {
  if (count === 0) return "no sessions";
  return count === 1 ? "1 session" : `${count} sessions`;
}

// "3.7 ★", or "no ratings".
export function averageRatingText(average: number | null): string {
  if (average === null || !Number.isFinite(average)) return "no ratings";
  return `${average.toFixed(1)} ★`;
}

export function ratingText(rating: number | null): string {
  return rating === null ? "unrated" : stars(rating);
}

export function lastDaysLabel(days: number): string {
  return days === 1 ? "Today" : `Last ${days} days`;
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];

function startOfDay(date: Date): number {
  return new Date(
    date.getFullYear(),
    date.getMonth(),
    date.getDate(),
  ).getTime();
}

// "Today", "Yesterday", else "Mon 22 Sep" (local days).
export function dayLabel(iso: string, now: Date): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "?";
  const today = startOfDay(now);
  const day = startOfDay(date);
  if (day === today) return "Today";
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  if (day === startOfDay(yesterday)) return "Yesterday";
  return `${WEEKDAYS[date.getDay()]} ${date.getDate()} ${MONTHS[date.getMonth()]}`;
}

// "Today 14:10–15:00", "Mon 22 Sep 23:30–Tue 00:30".
export function spanText(startIso: string, endIso: string, now: Date): string {
  return `${dayLabel(startIso, now)} ${formatTimeRange(startIso, endIso)}`;
}

export function endReasonText(reason: string | null): string {
  switch (reason) {
    case "timer":
      return "when the timer ran out";
    case "manual":
      return "stopped by hand";
    case "abandoned":
      return "abandoned (the helper stopped)";
    default:
      return "unknown";
  }
}

// "none", "3", "3, 1 snoozed".
export function attemptsText(session: RecentSession): string {
  if (session.blockedAttempts === 0) return "none";
  return session.snoozes > 0
    ? `${session.blockedAttempts}, ${session.snoozes} snoozed`
    : `${session.blockedAttempts}`;
}

// Text dropped into markdown as is: characters that would format it, open a
// link or an HTML tag, or end a table cell are escaped, and newlines become
// spaces so a note cannot start a heading.
export function escapeMarkdown(text: string): string {
  return text
    .replace(/\s+/g, " ")
    .replace(/([\\`*_[\]{}()<>#+!|~-])/g, "\\$1")
    .trim();
}

// The chart as a local image. Spaces and parentheses in the path would end
// the link, so they are percent-encoded. Raycast caches an image by its URL
// and the helper rewrites the same file on every request, so `version` (one
// per load) goes in the query to make each load show the new chart.
export function chartMarkdown(
  chartPath: string | null,
  version?: number,
): string {
  if (!chartPath) return "_The chart could not be drawn._";
  const path = encodeURI(chartPath).replace(/\(/g, "%28").replace(/\)/g, "%29");
  const query = version === undefined ? "" : `?v=${version}`;
  return `![Focused minutes](file://${path}${query})`;
}

export function calendarTable(rows: CalendarStats[]): string {
  if (rows.length === 0) return "_No sessions in this period._";
  const lines = [
    "| Calendar | Focused | Sessions |",
    "| --- | ---: | ---: |",
    ...rows.map(
      (row) =>
        `| ${escapeMarkdown(row.calendarTitle)} | ${focusedText(row.focusedSeconds)} | ${row.sessions} |`,
    ),
  ];
  return lines.join("\n");
}

// "1 h 25 min over 2 sessions, average 3.5 ★".
export function totalsText(totals: StatsTotals): string {
  const base = `${focusedText(totals.focusedSeconds)} over ${sessionsText(totals.sessions)}`;
  return totals.averageRating === null
    ? base
    : `${base}, average ${averageRatingText(totals.averageRating)}`;
}

// The Detail of an Overview row: its own numbers, then the chart and the
// per-calendar table, which always cover the whole window.
export function overviewMarkdown(options: {
  label: string;
  totals: StatsTotals;
  chartPath: string | null;
  chartVersion?: number;
  windowLabel: string;
  perCalendar: CalendarStats[];
}): string {
  return [
    `**${options.label}**: ${totalsText(options.totals)}`,
    chartMarkdown(options.chartPath, options.chartVersion),
    `### By calendar, ${options.windowLabel.toLowerCase()}`,
    calendarTable(options.perCalendar),
  ].join("\n\n");
}

export function recentMarkdown(session: RecentSession): string {
  const note = session.note?.trim()
    ? escapeMarkdown(session.note)
    : "_No note_";
  return `## ${escapeMarkdown(session.goal)}\n\n${note}`;
}

// The Detail of a waiting session. The calendar name ("Title (account)") is
// set as code so an account's email address is not turned into a link.
export function waitingMarkdown(logCalendarName: string | null): string {
  const target = logCalendarName
    ? `\`${logCalendarName.replace(/`/g, "'").replace(/\s+/g, " ")}\``
    : "a log calendar";
  return `The log event for this session waits for ${target}. Retry once that calendar is back, or move the waiting sessions to the current log calendar.`;
}
