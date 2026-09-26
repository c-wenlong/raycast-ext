import path from "node:path";
import { appendToFile, readFileUtf8, writeFileUtf8 } from "./fs";
import { NoteFile, createDailyIfMissing, listMarkdownFiles } from "./notes";

export type Task = {
  notePath: string;
  noteTitle: string;
  noteFilename: string;
  lineIndex: number;
  text: string;
  done: boolean;
};

const TASK_LINE = /^(\s*[-*+]\s+)\[([ xX])\]\s+(.*)$/;

export function parseTasks(note: NoteFile): Task[] {
  const lines = note.content.replace(/\r\n/g, "\n").split("\n");
  const tasks: Task[] = [];

  lines.forEach((line, lineIndex) => {
    const match = line.match(TASK_LINE);
    if (!match) {
      return;
    }

    tasks.push({
      notePath: note.path,
      noteTitle: note.title,
      noteFilename: note.filename,
      lineIndex,
      text: match[3].trim(),
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

// Re-reads the file before writing so a toggle never clobbers edits made
// elsewhere since the list was loaded. The line is matched by index and
// then by text as a guard against the file having shifted underneath us.
export async function setTaskDone(task: Task, done: boolean): Promise<void> {
  const content = await readFileUtf8(task.notePath);
  const hadCrlf = content.includes("\r\n");
  const lines = content.replace(/\r\n/g, "\n").split("\n");

  let index = task.lineIndex;
  const matchesTask = (line: string | undefined) => {
    const match = line?.match(TASK_LINE);
    return (
      match !== null && match !== undefined && match[3].trim() === task.text
    );
  };

  if (!matchesTask(lines[index])) {
    index = lines.findIndex(matchesTask);
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

  const joined = lines.join(hadCrlf ? "\r\n" : "\n");
  await writeFileUtf8(task.notePath, joined);
}

export function formatTaskLine(text: string): string {
  return `- [ ] ${text.trim()}`;
}

export async function appendTaskToDaily(
  notesDir: string,
  text: string,
  date = new Date(),
): Promise<string> {
  const dailyPath = await createDailyIfMissing(notesDir, date);
  const existing = await readFileUtf8(dailyPath);
  const separator =
    existing.length === 0 || existing.endsWith("\n") ? "" : "\n";
  await appendToFile(dailyPath, `${separator}${formatTaskLine(text)}\n`);
  return dailyPath;
}
