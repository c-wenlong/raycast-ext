import { FocusConfig } from "./config";
import { Calendar, calendarLabel } from "./daemon";

// The decisions behind the Focus Settings form and the waiting-session
// actions in Focus Today, kept out of the views so they are testable.

export const NO_LOG_CALENDAR = "__none__";

export interface SettingsChoices {
  // Every calendar EventKit lists, for the startable TagPicker.
  calendars: Calendar[];
  // Saved startable ids EventKit does not list right now (account offline or
  // removed). They stay selectable so saving does not silently drop them.
  missingStartable: string[];
  // Calendars that can take the log event.
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

// What the log calendar dropdown's value becomes in config.json.
export function resolveLogCalendar(
  selected: string,
  calendars: Calendar[],
  config: FocusConfig,
): { logCalendarId: string | null; logCalendarName: string | null } {
  if (selected === NO_LOG_CALENDAR) {
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

// Where "Move Waiting Sessions" sends the waiting sessions: the current log
// calendar, whenever one is set. The helper only reports names for waiting
// sessions, and two calendars can share a name, so the view never hides the
// action by comparing names; moving onto the calendar a session already
// waits for is harmless.
export function moveTarget(
  config: FocusConfig,
): { id: string; name: string } | null {
  if (!config.logCalendarId) return null;
  return {
    id: config.logCalendarId,
    name: config.logCalendarName ?? "the log calendar",
  };
}
