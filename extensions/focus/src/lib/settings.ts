import { CountdownDisplay, FocusConfig } from "./config";
import { Calendar, calendarLabel } from "./daemon";

// The decisions behind the Focus Settings form and the waiting-session
// actions in Focus Today, kept out of the views so they are testable.

// The log calendar dropdown's first item, "Each session's own calendar": no
// override, so each session's log event goes to the calendar it is filed
// under (PLAN "Log event", 2026-09-28). Saved as `logCalendarId: null`.
export const OWN_CALENDAR = "__own__";

export const LOG_CALENDAR_INFO =
  "Optional. Off: each session's event goes to the calendar the session belongs to. On: every event goes to this one calendar instead.";

export interface SettingsChoices {
  // Every calendar EventKit lists, for the startable TagPicker.
  calendars: Calendar[];
  // Saved startable ids EventKit does not list right now (account offline or
  // removed). They stay selectable so saving does not silently drop them.
  missingStartable: string[];
  // Calendars that can take every log event (the override's choices).
  writable: Calendar[];
  // The saved log calendar when it is missing or no longer writable, so the
  // dropdown can still show (and keep) it.
  unavailableLog: { id: string; title: string } | null;
}

export function settingsChoices(
  calendars: Calendar[],
  config: FocusConfig,
): SettingsChoices {
  const known = new Set(calendars.map((c) => c.id));
  const writable = calendars.filter((c) => c.writable);
  const logId = config.logCalendarId;
  const unavailableLog =
    logId !== null && !writable.some((c) => c.id === logId)
      ? {
          id: logId,
          title: `${config.logCalendarName ?? logId} (unavailable)`,
        }
      : null;
  return {
    calendars,
    missingStartable: config.startableCalendars.filter((id) => !known.has(id)),
    writable,
    unavailableLog,
  };
}

// What the log calendar dropdown's value becomes in config.json: null for
// "Each session's own calendar" (and for anything it cannot place), else the
// override's id and "Title (account)".
export function resolveLogCalendar(
  selected: string,
  calendars: Calendar[],
  config: FocusConfig,
): { logCalendarId: string | null; logCalendarName: string | null } {
  if (selected === OWN_CALENDAR || selected === "") {
    return { logCalendarId: null, logCalendarName: null };
  }
  const chosen = calendars.find((c) => c.id === selected);
  if (chosen) {
    return { logCalendarId: chosen.id, logCalendarName: calendarLabel(chosen) };
  }
  if (selected === config.logCalendarId) {
    // The saved log calendar is not in EventKit right now; keep it as is.
    return {
      logCalendarId: config.logCalendarId,
      logCalendarName: config.logCalendarName,
    };
  }
  return { logCalendarId: null, logCalendarName: null };
}

// The dropdown's value for a saved config.
export function logCalendarValue(config: FocusConfig): string {
  return config.logCalendarId ?? OWN_CALENDAR;
}

// The toast after Save: where log events go from now on.
export function logDestinationText(logCalendarName: string | null): string {
  return logCalendarName
    ? `logging every session to ${logCalendarName}`
    : "logging each session to its own calendar";
}

export interface MoveChoice {
  id: string;
  name: string;
}

// Where "Move Waiting Sessions" can send the waiting sessions. With the
// override set: one action, to the override. Without it there is no one
// destination, so the view offers every writable calendar (a submenu).
// The helper only reports names for waiting sessions, and two calendars can
// share a name, so the view never hides a choice by comparing names; moving
// onto the calendar a session already waits for is harmless (and the helper
// refuses a read-only target).
export type MoveTargets =
  | { kind: "single"; target: MoveChoice }
  | { kind: "menu"; targets: MoveChoice[] }
  | null;

export function moveTargets(
  config: FocusConfig,
  calendars: Calendar[],
): MoveTargets {
  if (config.logCalendarId) {
    return {
      kind: "single",
      target: {
        id: config.logCalendarId,
        name: config.logCalendarName ?? "the log calendar",
      },
    };
  }
  const targets = calendars
    .filter((calendar) => calendar.writable)
    .map((calendar) => ({ id: calendar.id, name: calendarLabel(calendar) }));
  return targets.length > 0 ? { kind: "menu", targets } : null;
}

// ---- blocking half (PLAN step 4) ----

export interface Option {
  value: string;
  title: string;
}

// Snooze length choices, in seconds on disk. A saved length that is not one
// of them (hand-edited) stays selectable as "N seconds" so saving the form
// does not change it.
export const SNOOZE_MINUTES = [1, 3, 5, 10] as const;

export function snoozeOptions(savedSeconds: number): Option[] {
  const options: Option[] = SNOOZE_MINUTES.map((minutes) => ({
    value: String(minutes * 60),
    title: `${minutes} minute${minutes === 1 ? "" : "s"}`,
  }));
  if (!options.some((option) => option.value === String(savedSeconds))) {
    options.push({
      value: String(savedSeconds),
      title: `${savedSeconds} seconds`,
    });
  }
  return options;
}

// The browsers whose front tab the helper watches (PLAN "Browsers").
export const KNOWN_BROWSERS: readonly Option[] = [
  { value: "com.google.Chrome", title: "Google Chrome" },
  { value: "company.thebrowser.dia", title: "Dia" },
];

// The two known browsers, then any other saved bundle id as it is, so an
// id added by hand survives a save.
export function browserOptions(saved: string[]): Option[] {
  const options = [...KNOWN_BROWSERS];
  for (const id of saved) {
    if (!options.some((option) => option.value === id)) {
      options.push({ value: id, title: id });
    }
  }
  return options;
}

// Where the countdown shows while a session runs: the floating panel (the
// default; its "…" menu can move it to the menu bar) or the menu bar item
// (whose menu can move it back). The helper switches within a second.
export const COUNTDOWN_OPTIONS: readonly {
  value: CountdownDisplay;
  title: string;
}[] = [
  { value: "panel", title: "Floating panel" },
  { value: "menuBar", title: "Menu bar" },
];

export function isCountdownDisplay(value: string): value is CountdownDisplay {
  return COUNTDOWN_OPTIONS.some((option) => option.value === value);
}
