import { randomBytes } from "node:crypto";
import { mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

// Everything Focus keeps on disk lives in ~/.raycast/focus (gitignored at the
// repo root). The helper owns the socket and the database; config.json is
// read by both sides and written only by Focus Settings.
export const FOCUS_DIR = path.join(os.homedir(), ".raycast", "focus");
export const CONFIG_PATH = path.join(FOCUS_DIR, "config.json");
export const SOCKET_PATH = path.join(FOCUS_DIR, "focus.sock");

export interface FocusConfig {
  startableCalendars: string[];
  logCalendarId: string | null;
  logCalendarName: string | null;
  calendarProfiles: Record<string, string>;
  profiles: Record<string, unknown>;
  browsers: string[];
  snoozeSeconds: number;
  raycastDeeplink: boolean;
  // Keys this version does not know about are kept as they are.
  [key: string]: unknown;
}

// The part of the config Focus Settings writes in this step. Profiles,
// browsers, snooze length and the deeplink toggle join it in step 4.
export type ConfigPatch = Partial<
  Pick<
    FocusConfig,
    | "startableCalendars"
    | "logCalendarId"
    | "logCalendarName"
    | "calendarProfiles"
    | "profiles"
    | "browsers"
    | "snoozeSeconds"
    | "raycastDeeplink"
  >
>;

export function defaultConfig(): FocusConfig {
  return {
    startableCalendars: [],
    logCalendarId: null,
    logCalendarName: null,
    calendarProfiles: {},
    profiles: {},
    browsers: ["com.google.Chrome", "company.thebrowser.dia"],
    snoozeSeconds: 180,
    raycastDeeplink: false,
  };
}

const KNOWN_KEYS = Object.keys(defaultConfig());

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.filter((item): item is string => typeof item === "string");
}

function stringOrNull(value: unknown): string | null | undefined {
  if (value === null) return null;
  return typeof value === "string" ? value : undefined;
}

function stringRecord(value: unknown): Record<string, string> | undefined {
  if (!isPlainObject(value)) return undefined;
  const out: Record<string, string> = {};
  for (const [key, item] of Object.entries(value)) {
    if (typeof item === "string") out[key] = item;
  }
  return out;
}

// Known keys with the wrong type fall back to their default; unknown keys are
// carried through untouched, after the known ones, in their original order.
export function normalizeConfig(raw: unknown): FocusConfig {
  const source = isPlainObject(raw) ? raw : {};
  const defaults = defaultConfig();
  const snooze = source.snoozeSeconds;
  const config: FocusConfig = {
    startableCalendars:
      stringArray(source.startableCalendars) ?? defaults.startableCalendars,
    logCalendarId: stringOrNull(source.logCalendarId) ?? defaults.logCalendarId,
    logCalendarName:
      stringOrNull(source.logCalendarName) ?? defaults.logCalendarName,
    calendarProfiles:
      stringRecord(source.calendarProfiles) ?? defaults.calendarProfiles,
    profiles: isPlainObject(source.profiles)
      ? source.profiles
      : defaults.profiles,
    browsers: stringArray(source.browsers) ?? defaults.browsers,
    snoozeSeconds:
      typeof snooze === "number" && Number.isFinite(snooze) && snooze > 0
        ? snooze
        : defaults.snoozeSeconds,
    raycastDeeplink:
      typeof source.raycastDeeplink === "boolean"
        ? source.raycastDeeplink
        : defaults.raycastDeeplink,
  };
  for (const [key, value] of Object.entries(source)) {
    if (!KNOWN_KEYS.includes(key)) config[key] = value;
  }
  return config;
}

// Returns the parsed JSON object, or undefined when the file does not exist.
// A file that exists but is not a JSON object is an error: silently treating
// it as empty would let the next save wipe whatever Kai wrote there.
async function readRaw(
  file: string,
): Promise<Record<string, unknown> | undefined> {
  let text: string;
  try {
    text = await readFile(file, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    throw new ConfigError(
      `${file} is not valid JSON (${reason}). Fix or delete it, then try again.`,
    );
  }
  if (!isPlainObject(parsed)) {
    throw new ConfigError(
      `${file} must hold a JSON object. Fix or delete it, then try again.`,
    );
  }
  return parsed;
}

export async function readConfig(
  file: string = CONFIG_PATH,
): Promise<FocusConfig> {
  return normalizeConfig(await readRaw(file));
}

// Re-reads the file right before writing so a change made elsewhere since the
// form loaded (another key, or the helper's future fields) is not lost, then
// writes a temp file in the same folder and renames it over config.json so a
// reader never sees half a file.
export async function writeConfig(
  patch: ConfigPatch,
  file: string = CONFIG_PATH,
): Promise<FocusConfig> {
  const current = normalizeConfig(await readRaw(file));
  const next: FocusConfig = { ...current };
  for (const [key, value] of Object.entries(patch)) {
    if (value !== undefined) next[key] = value;
  }
  await mkdir(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  try {
    await writeFile(temp, `${JSON.stringify(next, null, 2)}\n`, "utf8");
    await rename(temp, file);
  } catch (error) {
    await unlink(temp).catch(() => undefined);
    throw error;
  }
  return next;
}
