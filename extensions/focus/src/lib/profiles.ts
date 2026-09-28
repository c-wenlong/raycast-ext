import type { FocusConfig } from "./config";

// Blocking profiles as Focus Settings edits them. The shape is the one the
// helper reads (HELPER.md "Blocking", helper/Config.swift ProfileSpec):
//
//   "profiles": { "deep": { "mode": "allowlist", "categories": [],
//                           "apps": ["com.microsoft.VSCode"], "hosts": ["github.com"] } }
//
// Pure: no Raycast, no disk.

export const DEFAULT_PROFILE = "default";

// helper/Categories.swift `Categories.all`: same ids, titles and order.
export const CATEGORIES = [
  { id: "social", title: "Social" },
  { id: "messaging", title: "Messaging" },
  { id: "gaming", title: "Gaming" },
  { id: "entertainment", title: "Entertainment" },
  { id: "news", title: "News" },
  { id: "shopping", title: "Shopping" },
] as const;

const CATEGORY_IDS: readonly string[] = CATEGORIES.map((c) => c.id);

export type ProfileMode = "blocklist" | "allowlist";
export const PROFILE_MODES: readonly ProfileMode[] = ["blocklist", "allowlist"];

export interface ProfileSpec {
  mode: ProfileMode;
  categories: string[];
  apps: string[];
  hosts: string[];
}

// The profile the helper uses when config.json has no usable "default":
// every category, blocklist.
export function builtInDefault(): ProfileSpec {
  return {
    mode: "blocklist",
    categories: [...CATEGORY_IDS],
    apps: [],
    hosts: [],
  };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function trimmedStrings(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

export type ParsedProfile =
  | { ok: true; spec: ProfileSpec; problems: string[] }
  | { ok: false; problem: string };

// Reads one entry of `profiles` the way the helper does: every key optional,
// an unknown mode is blocklist, a list of the wrong type makes the entry
// malformed (the helper drops it), categories are lowercased and unknown
// ones reported. Unknown categories are kept in the spec here so the editor
// can show them and ask for their removal.
export function parseProfile(raw: unknown): ParsedProfile {
  if (!isPlainObject(raw)) return { ok: false, problem: "is not an object" };
  for (const key of ["categories", "apps", "hosts"]) {
    const list = raw[key];
    if (list !== undefined && list !== null && !Array.isArray(list)) {
      return { ok: false, problem: `${key} is not a list` };
    }
  }
  const problems: string[] = [];
  let mode: ProfileMode = "blocklist";
  if (raw.mode !== undefined && raw.mode !== null) {
    const text =
      typeof raw.mode === "string" ? raw.mode.trim().toLowerCase() : "";
    if (text === "blocklist" || text === "allowlist") mode = text;
    else
      problems.push(
        `mode ${JSON.stringify(raw.mode)} is not blocklist or allowlist`,
      );
  }
  const categories: string[] = [];
  for (const name of trimmedStrings(raw.categories)) {
    const id = name.toLowerCase();
    if (!CATEGORY_IDS.includes(id)) problems.push(`unknown category "${name}"`);
    if (!categories.includes(id)) categories.push(id);
  }
  return {
    ok: true,
    spec: {
      mode,
      categories,
      apps: trimmedStrings(raw.apps),
      hosts: trimmedStrings(raw.hosts),
    },
    problems,
  };
}

export interface ProfileEntry {
  name: string;
  spec: ProfileSpec;
  // "default" when config.json does not define a usable one: the helper
  // falls back to the built-in default.
  builtIn: boolean;
  // Why the helper ignores this entry, or null.
  malformed: string | null;
  problems: string[];
}

// Every profile to show: "default" first (the built-in one when config has
// none, or a malformed one), then the rest by name like the helper sorts them.
export function profileEntries(
  profiles: Record<string, unknown>,
): ProfileEntry[] {
  const entries: ProfileEntry[] = [];
  let hasDefault = false;
  for (const [name, raw] of Object.entries(profiles)) {
    if (!name.trim()) continue;
    const parsed = parseProfile(raw);
    if (name === DEFAULT_PROFILE) hasDefault = true;
    if (parsed.ok) {
      entries.push({
        name,
        spec: parsed.spec,
        builtIn: false,
        malformed: null,
        problems: parsed.problems,
      });
    } else {
      entries.push({
        name,
        spec:
          name === DEFAULT_PROFILE
            ? builtInDefault()
            : { mode: "blocklist", categories: [], apps: [], hosts: [] },
        builtIn: name === DEFAULT_PROFILE,
        malformed: parsed.problem,
        problems: [],
      });
    }
  }
  if (!hasDefault) {
    entries.push({
      name: DEFAULT_PROFILE,
      spec: builtInDefault(),
      builtIn: true,
      malformed: null,
      problems: [],
    });
  }
  return entries.sort((a, b) => {
    if (a.name === DEFAULT_PROFILE) return -1;
    if (b.name === DEFAULT_PROFILE) return 1;
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
  });
}

// Names a session can be started with (malformed entries fall back to
// "default" in the helper, so they are left out).
export function profileNames(profiles: Record<string, unknown>): string[] {
  return profileEntries(profiles)
    .filter(
      (entry) => entry.malformed === null || entry.name === DEFAULT_PROFILE,
    )
    .map((entry) => entry.name);
}

function plural(count: number, word: string): string {
  return `${count} ${word}${count === 1 ? "" : "s"}`;
}

export function categoryTitle(id: string): string {
  return CATEGORIES.find((c) => c.id === id)?.title ?? id;
}

// One line per profile in Settings and the profile list:
// "Blocklist · all categories · 2 extra apps", "Allowlist · no categories · 1 extra host".
export function profileSummary(spec: ProfileSpec): string {
  const mode = spec.mode === "allowlist" ? "Allowlist" : "Blocklist";
  const known = spec.categories.filter((id) => CATEGORY_IDS.includes(id));
  let categories: string;
  if (known.length === 0) categories = "no categories";
  else if (CATEGORY_IDS.every((id) => known.includes(id)))
    categories = "all categories";
  else
    categories = CATEGORY_IDS.filter((id) => known.includes(id))
      .map(categoryTitle)
      .join(", ");
  const parts = [mode, categories];
  if (spec.apps.length > 0) parts.push(plural(spec.apps.length, "extra app"));
  if (spec.hosts.length > 0)
    parts.push(plural(spec.hosts.length, "extra host"));
  return parts.join(" · ");
}

export function entrySummary(entry: ProfileEntry): string {
  if (entry.malformed !== null) {
    return entry.name === DEFAULT_PROFILE
      ? `Not readable (${entry.malformed}); the built-in default is used`
      : `Not readable (${entry.malformed}); sessions asking for it use default`;
  }
  const summary = profileSummary(entry.spec);
  return entry.builtIn ? `${summary} (built in)` : summary;
}

// ---- validation ----

// One entry per non-empty line, trimmed.
export function splitLines(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

const BUNDLE_ID = /^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$/;

// Null when `id` reads as a bundle id: two or more dot-separated labels of
// letters, digits, hyphens and underscores ("desktop.WhatsApp" is real).
// Kept short: the form cuts long errors, and the field's info has an example.
export function bundleIdProblem(id: string): string | null {
  if (/\s/.test(id)) return `"${id}" has a space`;
  if (!BUNDLE_ID.test(id)) return `"${id}" is not a bundle id`;
  return null;
}

const LABEL = "[a-z0-9](?:[a-z0-9-]*[a-z0-9])?";
const HOST = new RegExp(`^${LABEL}(?:\\.${LABEL})+$`);

// What the helper would reduce `raw` to (Matching.normalizeHost), for the
// "write it as" hint. Null when nothing usable is left.
function hostHint(raw: string): string | null {
  let text = raw.trim().toLowerCase();
  const scheme = text.indexOf("://");
  if (scheme >= 0) text = text.slice(scheme + 3);
  text = text.split(/[/?#]/)[0];
  const at = text.lastIndexOf("@");
  if (at >= 0) text = text.slice(at + 1);
  text = text.split(":")[0].replace(/^\*\./, "").replace(/\.+$/, "");
  if (text.startsWith("www.")) text = text.slice(4);
  return HOST.test(text) ? text : null;
}

// Null when `host` is a bare lowercase host name: no scheme, path, port,
// wildcard or spaces, at least one dot. "www." is allowed here and dropped
// by normalizeHosts, like the helper does.
// Messages lead with the fix, since the form cuts long errors short.
export function hostProblem(host: string): string | null {
  const hint = hostHint(host);
  const fix = (reason: string) =>
    hint && hint !== host
      ? `Write ${hint} (${reason})`
      : `"${host}" is not a host (${reason})`;
  if (/\s/.test(host)) return fix("no spaces");
  if (host.includes("://")) return fix("no scheme");
  if (/[/?#]/.test(host)) return fix("no path");
  if (host.startsWith("*.")) return fix("it covers subdomains");
  if (host.includes(":")) return fix("no port");
  if (host !== host.toLowerCase()) return fix("lowercase");
  if (!HOST.test(host)) return `"${host}" is not a host (like youtube.com)`;
  return null;
}

// Drops "www." and duplicates, keeping the first spelling.
export function normalizeHosts(hosts: string[]): string[] {
  const out: string[] = [];
  for (const host of hosts) {
    const bare = host.startsWith("www.") ? host.slice(4) : host;
    if (!out.includes(bare)) out.push(bare);
  }
  return out;
}

// The helper compares bundle ids case-insensitively; keep the first spelling.
export function dedupeApps(apps: string[]): string[] {
  const seen = new Set<string>();
  return apps.filter((app) => {
    const key = app.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

// What the profile form holds.
export interface ProfileDraft {
  name: string;
  mode: string;
  categories: string[];
  apps: string;
  hosts: string;
}

export interface ProfileErrors {
  name?: string;
  mode?: string;
  categories?: string;
  apps?: string;
  hosts?: string;
}

export type ProfileValidation =
  | { ok: true; name: string; spec: ProfileSpec }
  | { ok: false; errors: ProfileErrors };

// `originalName` is the profile being edited (null when adding);
// `existingNames` every profile name there is, "default" included.
export function validateProfile(
  draft: ProfileDraft,
  originalName: string | null,
  existingNames: string[],
): ProfileValidation {
  const errors: ProfileErrors = {};
  const name =
    originalName === DEFAULT_PROFILE ? DEFAULT_PROFILE : draft.name.trim();
  if (!name) {
    errors.name = "Give the profile a name";
  } else if (
    existingNames.some(
      (other) =>
        other !== originalName &&
        other.trim().toLowerCase() === name.toLowerCase(),
    )
  ) {
    errors.name = `There is already a profile named "${name}"`;
  }
  if (draft.mode !== "blocklist" && draft.mode !== "allowlist") {
    errors.mode = "Pick blocklist or allowlist";
  }
  const unknown = draft.categories.filter((id) => !CATEGORY_IDS.includes(id));
  if (unknown.length > 0) {
    errors.categories = `Remove unknown ${unknown.length === 1 ? "category" : "categories"} ${unknown.map((id) => `"${id}"`).join(", ")}`;
  }
  const apps = splitLines(draft.apps);
  const appProblem = apps.map(bundleIdProblem).find((p) => p !== null);
  if (appProblem) errors.apps = appProblem;
  const hosts = splitLines(draft.hosts);
  const hostError = hosts.map(hostProblem).find((p) => p !== null);
  if (hostError) errors.hosts = hostError;
  if (Object.keys(errors).length > 0) return { ok: false, errors };
  return {
    ok: true,
    name,
    spec: {
      mode: draft.mode as ProfileMode,
      categories: CATEGORY_IDS.filter((id) => draft.categories.includes(id)),
      apps: dedupeApps(apps),
      hosts: normalizeHosts(hosts),
    },
  };
}

// The form's starting values for a profile (or a new one).
export function draftFor(entry: ProfileEntry | null): ProfileDraft {
  if (!entry) {
    return {
      name: "",
      mode: "blocklist",
      categories: [...CATEGORY_IDS],
      apps: "",
      hosts: "",
    };
  }
  return {
    name: entry.name,
    mode: entry.spec.mode,
    categories: [...entry.spec.categories],
    apps: entry.spec.apps.join("\n"),
    hosts: entry.spec.hosts.join("\n"),
  };
}

// ---- writing ----

type ProfileKeys = Pick<FocusConfig, "profiles" | "calendarProfiles">;

// Points every calendar that used `from` at `to`, or back to the default
// (by dropping it) when `to` is null.
export function remapCalendarProfiles(
  calendarProfiles: Record<string, string>,
  from: string,
  to: string | null,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [calendarId, name] of Object.entries(calendarProfiles)) {
    if (name !== from) out[calendarId] = name;
    else if (to !== null && to !== DEFAULT_PROFILE) out[calendarId] = to;
  }
  return out;
}

// Saves `spec` as `name`, replacing `originalName` when renaming. Keys of
// the old entry this version does not know are kept.
export function applyProfileSave(
  current: ProfileKeys,
  originalName: string | null,
  name: string,
  spec: ProfileSpec,
): ProfileKeys {
  const previous =
    originalName !== null ? current.profiles[originalName] : undefined;
  const extra = isPlainObject(previous) ? previous : {};
  const profiles: Record<string, unknown> = {};
  const entry = {
    ...extra,
    mode: spec.mode,
    categories: spec.categories,
    apps: spec.apps,
    hosts: spec.hosts,
  };
  let placed = false;
  for (const [key, value] of Object.entries(current.profiles)) {
    if (key === originalName || key === name) {
      if (!placed) profiles[name] = entry;
      placed = true;
    } else {
      profiles[key] = value;
    }
  }
  if (!placed) profiles[name] = entry;
  const renamed = originalName !== null && originalName !== name;
  return {
    profiles,
    calendarProfiles: renamed
      ? remapCalendarProfiles(current.calendarProfiles, originalName, name)
      : current.calendarProfiles,
  };
}

// Deletes a profile; calendars that used it go back to "default". The
// default profile itself cannot be deleted.
export function applyProfileDelete(
  current: ProfileKeys,
  name: string,
): ProfileKeys {
  if (name === DEFAULT_PROFILE)
    throw new RangeError("The default profile cannot be deleted.");
  const profiles = { ...current.profiles };
  delete profiles[name];
  return {
    profiles,
    calendarProfiles: remapCalendarProfiles(
      current.calendarProfiles,
      name,
      null,
    ),
  };
}

// ---- per-calendar default profile ----

// What Settings writes as `calendarProfiles`: only calendars still selected
// as startable, and only choices other than "default" (the helper's
// fallback), so deselecting a calendar or choosing default leaves no entry.
export function pruneCalendarProfiles(
  calendarProfiles: Record<string, string>,
  startable: string[],
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const id of startable) {
    const name = calendarProfiles[id];
    if (name && name !== DEFAULT_PROFILE) out[id] = name;
  }
  return out;
}

// The dropdown value for a calendar's row: its saved profile, else "default".
export function calendarProfileValue(
  calendarProfiles: Record<string, string>,
  calendarId: string,
): string {
  return calendarProfiles[calendarId] || DEFAULT_PROFILE;
}
