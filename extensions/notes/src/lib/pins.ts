import { LocalStorage } from "@raycast/api";
import { parseGeneratedFilename, readRenameLog, renamedByLog } from "./notes";

// Pins live in Raycast LocalStorage keyed by file path, so the markdown
// files stay untouched. Renaming a note through the extension moves the pin.
const PINS_KEY = "pinnedNotePaths";

export async function getPinnedPaths(): Promise<Set<string>> {
  const raw = await LocalStorage.getItem<string>(PINS_KEY);
  if (!raw) {
    return new Set();
  }

  try {
    const parsed = JSON.parse(raw);
    return new Set(Array.isArray(parsed) ? parsed.filter(Boolean) : []);
  } catch {
    return new Set();
  }
}

async function savePinnedPaths(paths: Set<string>): Promise<void> {
  await LocalStorage.setItem(PINS_KEY, JSON.stringify([...paths]));
}

export async function togglePin(notePath: string): Promise<boolean> {
  const pins = await getPinnedPaths();
  const isPinned = pins.has(notePath);

  if (isPinned) {
    pins.delete(notePath);
  } else {
    pins.add(notePath);
  }

  await savePinnedPaths(pins);
  return !isPinned;
}

export async function movePin(fromPath: string, toPath: string): Promise<void> {
  if (fromPath === toPath) {
    return;
  }

  const pins = await getPinnedPaths();
  if (!pins.has(fromPath)) {
    return;
  }

  pins.delete(fromPath);
  pins.add(toPath);
  await savePinnedPaths(pins);
}

/**
 * Pins point at paths, and the notes window renames a generated file
 * ("YYYY-MM-DD HHmm <id> - slug.md") when its first line changes, and
 * gives names from before ids one, without being able to reach this
 * storage. A pinned path that no longer exists moves to where the
 * window's rename log (`.note-renames.json` in its folder) says it went,
 * else to the one existing note in its folder with the same id. A pin
 * from before ids with no log entry is left alone (a timestamp is not an
 * identity: two notes can share a minute), as are other dead pins (a
 * note may be back later). Returns the pins as they stand afterwards.
 */
export async function reconcilePins(
  existingPaths: string[],
): Promise<Set<string>> {
  const pins = await getPinnedPaths();
  const existing = new Set(existingPaths);
  const logs = new Map<string, Record<string, string>>();
  let changed = false;
  for (const pinned of [...pins]) {
    if (existing.has(pinned)) {
      continue;
    }
    const dir = dirOf(pinned);
    if (!logs.has(dir)) {
      logs.set(dir, await readRenameLog(dir));
    }
    // The log's name, or (renamed since by its title) the note carrying
    // the id in the logged name.
    const logged = renamedByLog(baseOf(pinned), logs.get(dir) ?? {});
    let target = logged
      ? existing.has(`${dir}/${logged}`)
        ? `${dir}/${logged}`
        : sameIdIn(existingPaths, dir, logged, pinned)
      : undefined;
    const id = parseGeneratedFilename(baseOf(pinned))?.id;
    if (!target && id) {
      target = sameIdIn(existingPaths, dir, baseOf(pinned), pinned);
    }
    if (target) {
      pins.delete(pinned);
      pins.add(target);
      changed = true;
    }
  }
  if (changed) {
    await savePinnedPaths(pins);
  }
  return pins;
}

/** The one path in `dir` carrying the id in `filename`, if exactly one. */
function sameIdIn(
  paths: string[],
  dir: string,
  filename: string,
  except: string,
): string | undefined {
  const id = parseGeneratedFilename(filename)?.id;
  if (!id) {
    return undefined;
  }
  const candidates = paths.filter(
    (candidate) =>
      candidate !== except &&
      dirOf(candidate) === dir &&
      parseGeneratedFilename(baseOf(candidate))?.id === id,
  );
  return candidates.length === 1 ? candidates[0] : undefined;
}

function dirOf(filePath: string): string {
  return filePath.slice(0, filePath.lastIndexOf("/"));
}

function baseOf(filePath: string): string {
  return filePath.slice(filePath.lastIndexOf("/") + 1);
}

export async function removePin(notePath: string): Promise<void> {
  const pins = await getPinnedPaths();
  if (pins.delete(notePath)) {
    await savePinnedPaths(pins);
  }
}
