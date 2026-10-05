import { LocalStorage } from "@raycast/api";
import { parseGeneratedFilename } from "./notes";

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
 * storage. A pinned path that no longer exists is moved to the one
 * existing note in its folder with the same id (or, for a pin from before
 * ids, the same timestamp); other dead pins are left alone (a note may be
 * back later). Returns the pins as they stand afterwards.
 */
export async function reconcilePins(
  existingPaths: string[],
): Promise<Set<string>> {
  const pins = await getPinnedPaths();
  const existing = new Set(existingPaths);
  let changed = false;
  for (const pinned of [...pins]) {
    if (existing.has(pinned)) {
      continue;
    }
    const name = parseGeneratedFilename(baseOf(pinned));
    if (!name) {
      continue;
    }
    const candidates = existingPaths.filter((candidate) => {
      if (candidate === pinned || dirOf(candidate) !== dirOf(pinned)) {
        return false;
      }
      const other = parseGeneratedFilename(baseOf(candidate));
      return name.id ? other?.id === name.id : other?.stamp === name.stamp;
    });
    if (candidates.length === 1) {
      pins.delete(pinned);
      pins.add(candidates[0]);
      changed = true;
    }
  }
  if (changed) {
    await savePinnedPaths(pins);
  }
  return pins;
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
