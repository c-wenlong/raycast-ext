import { LocalStorage } from "@raycast/api";
import type { FocusConfig } from "./config";
import type { Calendar, Session } from "./daemon";
import { DEFAULT_PROFILE } from "./profiles";
import { durationText, formatClockIso } from "./time";

// The decisions behind the Ad-hoc Session form, kept out of the view.

export const ADHOC_PRESET_MINUTES = [15, 25, 45, 60, 90] as const;
export const DEFAULT_ADHOC_MINUTES = 25;
// The helper takes 60 to 86400 seconds.
export const MIN_ADHOC_MINUTES = 1;
export const MAX_ADHOC_MINUTES = 1440;

export type AdhocMinutes =
  | { ok: true; minutes: number }
  | { ok: false; error: string };

// "Custom minutes" wins when filled; otherwise the preset dropdown.
export function resolveAdhocMinutes(
  preset: string,
  custom: string,
): AdhocMinutes {
  const text = custom.trim();
  if (text) {
    const minutes = /^\d+$/.test(text) ? Number(text) : Number.NaN;
    if (
      !Number.isInteger(minutes) ||
      minutes < MIN_ADHOC_MINUTES ||
      minutes > MAX_ADHOC_MINUTES
    ) {
      return {
        ok: false,
        error: `Whole minutes from ${MIN_ADHOC_MINUTES} to ${MAX_ADHOC_MINUTES}`,
      };
    }
    return { ok: true, minutes };
  }
  const minutes = Number(preset);
  if (!(ADHOC_PRESET_MINUTES as readonly number[]).includes(minutes)) {
    return { ok: false, error: "Pick a duration" };
  }
  return { ok: true, minutes };
}

// The calendar the form opens on: the last one used if it still exists,
// else the first startable calendar, else the first calendar there is.
export function initialAdhocCalendar(
  calendars: Pick<Calendar, "id">[],
  lastUsed: string | undefined,
  config: Pick<FocusConfig, "startableCalendars">,
): string | null {
  const ids = calendars.map((calendar) => calendar.id);
  if (lastUsed && ids.includes(lastUsed)) return lastUsed;
  const startable = config.startableCalendars.find((id) => ids.includes(id));
  return startable ?? ids[0] ?? null;
}

// The profile preselected for a calendar: its default profile from Settings
// when that profile still exists, else "default".
export function adhocProfileFor(
  calendarId: string | null,
  config: Pick<FocusConfig, "calendarProfiles">,
  names: string[],
): string {
  const saved = calendarId ? config.calendarProfiles[calendarId] : undefined;
  return saved && names.includes(saved) ? saved : DEFAULT_PROFILE;
}

// The toast after a start: "Focusing: Write the report", "Until 15:40 (25 min), deep profile".
export function adhocStartedText(
  session: Pick<Session, "goal" | "plannedEnd" | "profile">,
  minutes: number,
): { title: string; message: string } {
  const until = session.plannedEnd
    ? `Until ${formatClockIso(session.plannedEnd)} `
    : "";
  return {
    title: `Focusing: ${session.goal}`,
    message: `${until}(${durationText(minutes * 60)}), ${session.profile} profile`,
  };
}

// The toast when the helper refused. A start while a session is open sends
// that session to the end sheet (PLAN), so the toast names it and says so.
export function adhocRefusedText(
  error: string,
  open: Pick<Session, "goal" | "state"> | null,
): { title: string; message: string } {
  if (open && open.state !== "finished") {
    return {
      title: "A session is already running",
      message: `"${open.goal}" is at the end sheet: finish or extend it first`,
    };
  }
  return { title: "Could not start the session", message: error };
}

// Raycast LocalStorage key for the last calendar a session was filed under.
export const LAST_CALENDAR_KEY = "adhoc.lastCalendarId";

export async function lastAdhocCalendar(): Promise<string | undefined> {
  const value = await LocalStorage.getItem<string>(LAST_CALENDAR_KEY);
  return typeof value === "string" && value ? value : undefined;
}

export async function rememberAdhocCalendar(calendarId: string): Promise<void> {
  await LocalStorage.setItem(LAST_CALENDAR_KEY, calendarId);
}
