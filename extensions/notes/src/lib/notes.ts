import { constants } from "node:fs";
import { randomInt } from "node:crypto";
import {
  access,
  link,
  open,
  readdir,
  rename,
  stat,
  unlink,
} from "node:fs/promises";
import path from "node:path";
import {
  appendToFile,
  ensureDirExists,
  readFileUtf8,
  writeFileUtf8Exclusive,
} from "./fs";

export type NoteFile = {
  path: string;
  filename: string;
  title: string;
  content: string;
  characterCount: number;
  mtimeMs: number;
  isDaily: boolean;
  isToday: boolean;
};

export type NoteListItem = Omit<NoteFile, "content" | "characterCount">;

// CRLF only if the file already uses it, so appends never mix endings.
export function lineEndingOf(content: string): "\r\n" | "\n" {
  return content.includes("\r\n") ? "\r\n" : "\n";
}

function pad2(value: number): string {
  return String(value).padStart(2, "0");
}

function formatDateYYYYMMDD(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

/** A slug or filename as words. Mirrors humanize() in helper/NoteNames.swift. */
function humanizeSlug(value: string): string {
  const words = value
    .replace(/[-_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .split(" ")
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1));

  if (words.length === 0) {
    return "Untitled";
  }

  return words.join(" ");
}

function isDailyFilename(filename: string): boolean {
  return /^\d{4}-\d{2}-\d{2}\.md$/i.test(filename);
}

/**
 * A generated note name, `YYYY-MM-DD HHmm <id> - slug.md`: the minute the
 * note was made, a stable id (four lowercase base36 characters, unique in
 * its folder) and the title's slug. Names from before ids
 * (`YYYY-MM-DD HHmm - slug.md`) parse with no id. Mirrors NoteNames in
 * helper/NoteNames.swift.
 */
export type GeneratedName = { stamp: string; id: string | null; slug: string };

const GENERATED_NAME =
  /^(\d{4}-\d{2}-\d{2} \d{4})(?: ([0-9a-z]{4}))? - (.+)\.md$/;

export function parseGeneratedFilename(
  filename: string,
): GeneratedName | undefined {
  const match = filename.match(GENERATED_NAME);
  if (!match) {
    return undefined;
  }
  return { stamp: match[1], id: match[2] ?? null, slug: match[3] };
}

export function generatedFilename(
  stamp: string,
  id: string,
  slug: string,
): string {
  return `${stamp} ${id} - ${slug}.md`;
}

const ID_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz";

export function randomNoteId(): string {
  let id = "";
  for (let i = 0; i < 4; i += 1) {
    id += ID_ALPHABET[randomInt(ID_ALPHABET.length)];
  }
  return id;
}

/** The ids the generated names in `names` carry. */
export function noteIdsIn(names: string[]): Set<string> {
  return new Set(
    names
      .map((name) => parseGeneratedFilename(name)?.id)
      .filter((id): id is string => Boolean(id)),
  );
}

/** A fresh id, drawn again while it clashes with `taken`. */
export function newNoteId(
  taken: Set<string>,
  random: () => string = randomNoteId,
): string {
  let id = random();
  for (let tries = 0; taken.has(id) && tries < 10_000; tries += 1) {
    id = random();
  }
  return id;
}

/**
 * For a new note: the name to try after `filename` was taken, on attempt
 * 2, 3...: a generated name with an id draws a new id (`newId`), so two
 * notes never share one; any other name gets "-2", "-3". Mirrors
 * NoteNames.clashCandidate in helper/NoteNames.swift.
 */
export function clashCandidate(
  filename: string,
  attempt: number,
  newId: () => string,
): string {
  if (attempt <= 1) {
    return filename;
  }
  const generated = parseGeneratedFilename(filename);
  if (generated?.id) {
    return generatedFilename(generated.stamp, newId(), generated.slug);
  }
  return renameClashCandidate(filename, attempt);
}

/**
 * For a rename: the name to try after `filename` was taken. A rename never
 * changes the id, so the slug gets "-2", "-3". Mirrors
 * NoteNames.renameClashCandidate in helper/NoteNames.swift.
 */
export function renameClashCandidate(
  filename: string,
  attempt: number,
): string {
  if (attempt <= 1) {
    return filename;
  }
  const extension = path.extname(filename);
  return `${path.basename(filename, extension)}-${attempt}${extension}`;
}

/** `clashCandidate` with a new id checked against the folder as it is now. */
async function candidateIn(
  dir: string,
  filename: string,
  attempt: number,
): Promise<string> {
  if (attempt <= 1 || !parseGeneratedFilename(filename)?.id) {
    return clashCandidate(filename, attempt, () => "");
  }
  const id = await freshNoteId(dir);
  return clashCandidate(filename, attempt, () => id);
}

async function freshNoteId(dir: string): Promise<string> {
  return newNoteId(await usedNoteIds(dir));
}

/**
 * The window's record of what its migration to ids renamed in a folder,
 * and the ids retired there: `.note-renames.jsonl` beside the notes,
 * append-only JSON Lines, one event per line, each line one O_APPEND
 * write so the window and Browse Notes never drop each other's events:
 *   {"rename":["old filename","new filename"]}
 *   {"retire":"k3x9"}
 *   {"links":"pending"} / {"links":"done"}
 * Readers fold every line in order and skip a line that does not parse (a
 * half-written last line included). State follows line order: the last
 * "links" event wins, so a "done" never outlives a later "pending", and a
 * "rename" counts as "pending" by itself.
 * Mirrors NoteNames.RenameLog in helper/NoteNames.swift.
 */
export const RENAME_LOG_NAME = ".note-renames.jsonl";

export type NoteLog = {
  renames: Record<string, string>;
  linksRewritten: boolean;
  /**
   * Ids of notes deleted from the window or Browse Notes: never drawn
   * again, so an old link or pin cannot land on an unrelated note that
   * got the same id. Deletions in Finder are not seen.
   */
  retiredIDs?: string[];
};

export type NoteLogEvent =
  | { rename: [string, string] }
  | { retire: string }
  | { links: "pending" | "done" };

function foldEvent(log: NoteLog, event: unknown): void {
  if (!event || typeof event !== "object") {
    return;
  }
  const e = event as Record<string, unknown>;
  if (
    Array.isArray(e.rename) &&
    e.rename.length === 2 &&
    e.rename.every((name) => typeof name === "string")
  ) {
    log.renames[e.rename[0]] = e.rename[1];
    // A rename means its links are not rewritten yet, even if the
    // "pending" written after it was lost.
    log.linksRewritten = false;
  } else if (typeof e.retire === "string") {
    const retired = log.retiredIDs ?? [];
    if (!retired.includes(e.retire)) {
      retired.push(e.retire);
    }
    log.retiredIDs = retired;
  } else if (typeof e.links === "string") {
    log.linksRewritten = e.links === "done";
  }
}

/** The folder's log, folded; undefined when it has none. */
export async function readNoteLog(dir: string): Promise<NoteLog | undefined> {
  let text: string;
  try {
    text = await readFileUtf8(path.join(dir, RENAME_LOG_NAME));
  } catch {
    return undefined;
  }
  const log: NoteLog = { renames: {}, linksRewritten: true };
  const lines = text.split("\n");
  // Only lines ended by "\n" are whole; the last piece never is.
  lines.pop();
  for (const line of lines) {
    if (!line) {
      continue;
    }
    try {
      foldEvent(log, JSON.parse(line));
    } catch {
      // A line a writer never finished, or not ours.
    }
  }
  return log;
}

/**
 * Appends `events` to the folder's log, each line by one write on an
 * O_APPEND handle (starting on a fresh line if a writer stopped half
 * way). Mirrors NoteNames.appendLog.
 */
export async function appendNoteLog(
  dir: string,
  events: NoteLogEvent[],
): Promise<void> {
  // "a+": read-write, every write at the end (O_APPEND).
  const handle = await open(path.join(dir, RENAME_LOG_NAME), "a+");
  try {
    const { size } = await handle.stat();
    let needsBreak = false;
    if (size > 0) {
      const last = Buffer.alloc(1);
      await handle.read(last, 0, 1, size - 1);
      needsBreak = last[0] !== 0x0a;
    }
    for (const event of events) {
      const line = `${needsBreak ? "\n" : ""}${JSON.stringify(event)}\n`;
      needsBreak = false;
      await handle.write(line);
    }
  } finally {
    await handle.close();
  }
}

export async function readRenameLog(
  dir: string,
): Promise<Record<string, string>> {
  return (await readNoteLog(dir))?.renames ?? {};
}

/**
 * Every id a new note must not take in `dir`: those its notes carry,
 * those in the rename log, and retired ones. Mirrors NoteNames.usedIDs.
 */
export async function usedNoteIds(dir: string): Promise<Set<string>> {
  const names = await readdir(dir).catch(() => [] as string[]);
  const used = noteIdsIn(names);
  const log = await readNoteLog(dir);
  if (log) {
    const logged = [...Object.keys(log.renames), ...Object.values(log.renames)];
    for (const id of noteIdsIn(logged)) {
      used.add(id);
    }
    for (const id of log.retiredIDs ?? []) {
      used.add(id);
    }
  }
  return used;
}

/**
 * Records the id of a note just deleted (moved to the Trash) as retired
 * in its folder's log. Mirrors NoteNames.retireID. Does nothing for a
 * name without an id.
 */
export async function retireNoteId(notePath: string): Promise<void> {
  const id = parseGeneratedFilename(path.basename(notePath))?.id;
  if (!id) {
    return;
  }
  await appendNoteLog(path.dirname(notePath), [{ retire: id }]);
}

/** Where the log says `filename` went, following a name renamed again. */
export function renamedByLog(
  filename: string,
  renames: Record<string, string>,
): string | undefined {
  let name = filename;
  for (let steps = 0; steps < 16 && renames[name]; steps += 1) {
    name = renames[name];
  }
  return name === filename ? undefined : name;
}

export function slugify(title: string): string {
  const normalized = title
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  return normalized || "untitled";
}

export function getDailyFilename(date = new Date()): string {
  return `${formatDateYYYYMMDD(date)}.md`;
}

export function formatTimeHHmm(date = new Date()): string {
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

const TITLE_MAX_LENGTH = 80;

/** Cuts a title to TITLE_MAX_LENGTH user-perceived characters (grapheme
 * clusters, as Swift's Character counts), never splitting an emoji. */
function capTitle(title: string): string {
  const graphemes = [
    ...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(
      title,
    ),
  ].map((segment) => segment.segment);
  if (graphemes.length <= TITLE_MAX_LENGTH) {
    return title;
  }
  return graphemes.slice(0, TITLE_MAX_LENGTH).join("").trim();
}

/**
 * The note's title: its first line with any words once the markdown is
 * stripped (heading marks, list, quote, toggle and callout markers, inline markers, link
 * targets). Fence lines are skipped. Mirrors Titles.firstLine in
 * helper/Titles.swift.
 */
export function firstLineTitle(content: string): string | undefined {
  for (const line of content.split(/\r\n|\r|\n/)) {
    if (/^\s*(`{3,}|~{3,})/.test(line)) {
      continue;
    }
    const stripped = line
      .replace(
        /^\s*(?:#{1,6}\s+|!?>\s+|\|\s+|[-*+]\s+(?:\[[ xX]\]\s*)?|\d+[.)]\s+)*/,
        "",
      )
      .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/(\*\*|__|~~|`|(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w))/g, "")
      .trim();
    if (stripped) {
      return capTitle(stripped);
    }
  }
  return undefined;
}

export function parseTitleFromContentOrFilename(
  filePath: string,
  content: string,
): string {
  const firstLine = firstLineTitle(content);
  if (firstLine) {
    return firstLine;
  }

  // An empty note: the slug of a generated name, never its date, time
  // or id; else the filename.
  const generated = parseGeneratedFilename(path.basename(filePath));
  if (generated) {
    return humanizeSlug(generated.slug);
  }

  return humanizeSlug(path.basename(filePath, ".md"));
}

export function countCharacters(content: string): number {
  return content.length;
}

export async function listMarkdownFiles(
  notesDir: string,
  onReadError?: (filename: string, error: unknown) => void,
): Promise<NoteFile[]> {
  await ensureDirExists(notesDir);

  const entries = await readdir(notesDir, { withFileTypes: true });
  const markdownEntries = entries.filter(
    (entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".md"),
  );
  const todayFilename = getDailyFilename();

  const notes = await Promise.all(
    markdownEntries.map(async (entry) => {
      const filePath = path.join(notesDir, entry.name);

      try {
        const [content, fileStats] = await Promise.all([
          readFileUtf8(filePath),
          stat(filePath),
        ]);

        return {
          path: filePath,
          filename: entry.name,
          title: parseTitleFromContentOrFilename(filePath, content),
          content,
          characterCount: countCharacters(content),
          mtimeMs: fileStats.mtimeMs,
          isDaily: isDailyFilename(entry.name),
          isToday: entry.name === todayFilename,
        } satisfies NoteFile;
      } catch (error) {
        onReadError?.(entry.name, error);
        return null;
      }
    }),
  );

  return notes
    .filter((note): note is NoteFile => note !== null)
    .sort((a, b) => b.mtimeMs - a.mtimeMs);
}

export async function listMarkdownFileMetadata(
  notesDir: string,
  onReadError?: (filename: string, error: unknown) => void,
): Promise<NoteListItem[]> {
  await ensureDirExists(notesDir);

  const entries = await readdir(notesDir, { withFileTypes: true });
  const markdownEntries = entries.filter(
    (entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".md"),
  );
  const todayFilename = getDailyFilename();

  const notes = await Promise.all(
    markdownEntries.map(async (entry) => {
      const filePath = path.join(notesDir, entry.name);

      try {
        const fileStats = await stat(filePath);
        // Title resolution strategy:
        // - For filenames that match the extension's own created pattern
        //   (e.g. "YYYY-MM-DD HHmm <id> - slug.md"), we derive the visible
        //   title from the slug rather than reading the file's H1 heading.
        //   This keeps the Browse Notes list stable when users rename the
        //   note via the UI. The tradeoff is that if a user edits the
        //   H1 heading in an external editor, the list will not reflect
        //   that change — the title remains derived from the filename's
        //   slug. This is an intentional design decision and not a bug.
        const shouldReadForTitle =
          !isDailyFilename(entry.name) && !parseGeneratedFilename(entry.name);
        const contentForTitle = shouldReadForTitle
          ? await readFileUtf8(filePath)
          : "";

        return {
          path: filePath,
          filename: entry.name,
          title: parseTitleFromContentOrFilename(filePath, contentForTitle),
          mtimeMs: fileStats.mtimeMs,
          isDaily: isDailyFilename(entry.name),
          isToday: entry.name === todayFilename,
        } satisfies NoteListItem;
      } catch (error) {
        onReadError?.(entry.name, error);
        return null;
      }
    }),
  );

  return notes
    .filter((note): note is NoteListItem => note !== null)
    .sort((a, b) => b.mtimeMs - a.mtimeMs);
}

export async function getNoteByPath(notePath: string): Promise<NoteFile> {
  const [content, fileStats] = await Promise.all([
    readFileUtf8(notePath),
    stat(notePath),
  ]);
  const filename = path.basename(notePath);

  return {
    path: notePath,
    filename,
    title: parseTitleFromContentOrFilename(notePath, content),
    content,
    characterCount: countCharacters(content),
    mtimeMs: fileStats.mtimeMs,
    isDaily: isDailyFilename(filename),
    isToday: filename === getDailyFilename(),
  };
}

async function writeUniqueFile(
  dir: string,
  baseFilename: string,
  content: string,
): Promise<string> {
  let attempt = 1;
  while (true) {
    const candidate = await candidateIn(dir, baseFilename, attempt);
    const filePath = path.join(dir, candidate);

    try {
      await writeFileUtf8Exclusive(filePath, content);
      return filePath;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "EEXIST") {
        attempt += 1;
        continue;
      }

      throw error;
    }
  }
}

export async function createDailyIfMissing(
  notesDir: string,
  date = new Date(),
): Promise<string> {
  await ensureDirExists(notesDir);

  const dailyFilename = getDailyFilename(date);
  const dailyPath = path.join(notesDir, dailyFilename);

  try {
    await writeFileUtf8Exclusive(
      dailyPath,
      `# ${formatDateYYYYMMDD(date)}\n\n`,
    );
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
      throw error;
    }
  }

  return dailyPath;
}

export async function appendDailyEntry(
  notesDir: string,
  text: string,
  date = new Date(),
): Promise<string> {
  const cleanText = text.trim();
  const dailyPath = await createDailyIfMissing(notesDir, date);

  if (!cleanText) {
    return dailyPath;
  }

  const existingContent = await readFileUtf8(dailyPath);
  const eol = lineEndingOf(existingContent);
  const separator =
    existingContent.length === 0 || existingContent.endsWith("\n") ? "" : eol;
  const entry = `- ${formatTimeHHmm(date)} ${cleanText}${eol}`;

  await appendToFile(dailyPath, `${separator}${entry}`);
  return dailyPath;
}

export async function createNewNoteFile(
  notesDir: string,
  title: string,
  content: string,
  date = new Date(),
): Promise<string> {
  await ensureDirExists(notesDir);

  const trimmedTitle = title.trim();
  const trimmedContent = content.trim();
  const filename = generatedFilename(
    `${formatDateYYYYMMDD(date)} ${formatTimeHHmm(date).replace(":", "")}`,
    await freshNoteId(notesDir),
    slugify(trimmedTitle),
  );

  const fileContent = trimmedContent
    ? `# ${trimmedTitle}\n\n${trimmedContent.replace(/\s+$/, "")}\n`
    : `# ${trimmedTitle}\n\n`;

  return writeUniqueFile(notesDir, filename, fileContent);
}

export async function duplicateNoteFile(sourcePath: string): Promise<string> {
  const directory = path.dirname(sourcePath);
  const extension = path.extname(sourcePath);
  const basename = path.basename(sourcePath, extension);

  const content = await readFileUtf8(sourcePath);
  // A generated name gets an id of its own, so ids stay unique.
  const generated = parseGeneratedFilename(path.basename(sourcePath));
  const copyName = generated
    ? generatedFilename(
        generated.stamp,
        await freshNoteId(directory),
        `${generated.slug}-copy`,
      )
    : `${basename} copy${extension}`;
  return writeUniqueFile(directory, copyName, content);
}

export async function renameNoteFromTitleIfNeeded(
  notePath: string,
  newTitle: string,
): Promise<string> {
  const filename = path.basename(notePath);
  const extension = path.extname(filename);

  if (extension.toLowerCase() !== ".md" || isDailyFilename(filename)) {
    return notePath;
  }

  const generated = parseGeneratedFilename(filename);
  if (!generated) {
    return notePath;
  }

  // Only the slug follows the title; the id stays (a name from before
  // ids gets one). Mirrors NoteNames.renamed in helper/NoteNames.swift.
  const directory = path.dirname(notePath);
  const base = generatedFilename(
    generated.stamp,
    generated.id ?? (await freshNoteId(directory)),
    slugify(newTitle),
  );
  const nextFilename = await renameTarget(filename, base, async (name) =>
    access(path.join(directory, name), constants.F_OK).then(
      () => true,
      () => false,
    ),
  );
  if (!nextFilename) {
    return notePath;
  }
  return moveToUniquePath(directory, nextFilename, notePath);
}

/**
 * Where a rename of `current` to `base` lands: `base`, or `base` with
 * "-2", "-3" while the names before it are taken by other notes. Undefined
 * when that is `current` itself, so a note that took "-2" by a clash stays
 * put save after save, while "plan-2" retitled "Plan" becomes "plan" once
 * that name is free. Mirrors NoteNames.renamed.
 */
export async function renameTarget(
  current: string,
  base: string,
  exists: (name: string) => Promise<boolean>,
): Promise<string | undefined> {
  for (let attempt = 1; attempt < 10_000; attempt += 1) {
    const candidate = renameClashCandidate(base, attempt);
    if (candidate === current) {
      return undefined;
    }
    if (!(await exists(candidate))) {
      return candidate;
    }
  }
  return undefined;
}

// Errors that mean "this filesystem has no hard links" rather than "the
// name is taken": fall back to a plain rename in that case.
const NO_LINK_SUPPORT = new Set([
  "EPERM",
  "ENOTSUP",
  "EOPNOTSUPP",
  "ENOSYS",
  "EXDEV",
]);

// Moves sourcePath to the first free name. link() fails with EEXIST when
// the target exists, so two renames can never land on the same file. The
// old name is removed afterwards; if that fails the new link is dropped
// again so the note never has two names.
async function moveToUniquePath(
  dir: string,
  filename: string,
  sourcePath: string,
): Promise<string> {
  let attempt = 1;
  while (true) {
    const candidate = renameClashCandidate(filename, attempt);
    const candidatePath = path.join(dir, candidate);

    try {
      await link(sourcePath, candidatePath);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code ?? "";
      if (code === "EEXIST") {
        attempt += 1;
        continue;
      }
      if (NO_LINK_SUPPORT.has(code)) {
        return renameToUniquePath(dir, filename, sourcePath);
      }
      throw error;
    }

    try {
      await unlink(sourcePath);
    } catch (error) {
      await unlink(candidatePath).catch(() => undefined);
      throw error;
    }
    return candidatePath;
  }
}

// Fallback for filesystems without hard links: check, then rename. There
// is a small window between the check and the rename; it only applies
// where link() is unavailable.
async function renameToUniquePath(
  dir: string,
  filename: string,
  sourcePath: string,
): Promise<string> {
  let attempt = 1;
  while (true) {
    const candidate = renameClashCandidate(filename, attempt);
    const candidatePath = path.join(dir, candidate);

    try {
      await access(candidatePath, constants.F_OK);
      attempt += 1;
    } catch {
      await rename(sourcePath, candidatePath);
      return candidatePath;
    }
  }
}

export function syncTitleInMarkdown(content: string, title: string): string {
  const cleanTitle = title.trim();
  const normalized = content.replace(/\r\n/g, "\n");
  const lines = normalized.split("\n");
  const firstContentLine = lines.findIndex((line) => line.trim().length > 0);

  if (firstContentLine >= 0 && /^#\s+/.test(lines[firstContentLine])) {
    lines[firstContentLine] = `# ${cleanTitle}`;
    const updated = lines.join("\n").replace(/\s+$/, "");
    return `${updated}\n`;
  }

  const body = normalized.trim();
  if (!body) {
    return `# ${cleanTitle}\n\n`;
  }

  return `# ${cleanTitle}\n\n${body}\n`;
}
