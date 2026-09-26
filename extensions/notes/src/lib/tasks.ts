import path from "node:path";
import { appendToFile, readFileUtf8, writeFileUtf8 } from "./fs";
import {
  NoteFile,
  createDailyIfMissing,
  lineEndingOf,
  listMarkdownFiles,
} from "./notes";

export type Task = {
  notePath: string;
  noteTitle: string;
  noteFilename: string;
  lineIndex: number;
  // Which occurrence of this exact text within the note (0-based), so a
  // toggle can still find the right line when identical tasks exist.
  occurrence: number;
  text: string;
  done: boolean;
};

const TASK_LINE = /^(\s*[-*+]\s+)\[([ xX])\]\s+(.*)$/;

export function parseTasks(note: NoteFile): Task[] {
  const lines = note.content.replace(/\r\n/g, "\n").split("\n");
  const tasks: Task[] = [];
  const seen = new Map<string, number>();

  lines.forEach((line, lineIndex) => {
    const match = line.match(TASK_LINE);
    if (!match) {
      return;
    }

    const text = match[3].trim();
    const occurrence = seen.get(text) ?? 0;
    seen.set(text, occurrence + 1);

    tasks.push({
      notePath: note.path,
      noteTitle: note.title,
      noteFilename: note.filename,
      lineIndex,
      occurrence,
      text,
      done: match[2].toLowerCase() === "x",
    });
  });

  return tasks;
}

export async function listTasks(
  notesDir: string,
  onReadError?: (filename: string, error: unknown) => void,
): Promise<Task[]> {
  const notes = await listMarkdownFiles(notesDir, onReadError);
  return notes.flatMap(parseTasks);
}

// Re-reads the file immediately before writing so a toggle works on the
// current contents, not the copy the list was built from. The line is
// matched by index first; if the note shifted underneath us, the same
// occurrence of the same text is used instead, so duplicates stay distinct.
export async function setTaskDone(task: Task, done: boolean): Promise<void> {
  const content = await readFileUtf8(task.notePath);
  const eol = lineEndingOf(content);
  const lines = content.replace(/\r\n/g, "\n").split("\n");

  const textOf = (line: string | undefined) =>
    line?.match(TASK_LINE)?.[3].trim();

  let index = task.lineIndex;
  if (textOf(lines[index]) !== task.text) {
    const candidates = lines
      .map((line, lineIndex) => (textOf(line) === task.text ? lineIndex : -1))
      .filter((lineIndex) => lineIndex !== -1);
    index = candidates[task.occurrence] ?? -1;
    if (index === -1) {
      throw new Error(
        `Task not found in ${path.basename(task.notePath)}; the note changed`,
      );
    }
  }

  lines[index] = lines[index].replace(
    TASK_LINE,
    (_whole, prefix: string, _mark: string, text: string) =>
      `${prefix}[${done ? "x" : " "}] ${text}`,
  );

  await writeFileUtf8(task.notePath, lines.join(eol));
}

// A task is one list item, so multi-line input is collapsed onto one line.
export function formatTaskLine(text: string): string {
  const oneLine = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ");
  return `- [ ] ${oneLine}`;
}

export async function appendTaskToDaily(
  notesDir: string,
  text: string,
  date = new Date(),
): Promise<string> {
  const dailyPath = await createDailyIfMissing(notesDir, date);
  const existing = await readFileUtf8(dailyPath);
  const eol = lineEndingOf(existing);
  const separator = existing.length === 0 || existing.endsWith("\n") ? "" : eol;
  await appendToFile(dailyPath, `${separator}${formatTaskLine(text)}${eol}`);
  return dailyPath;
}
