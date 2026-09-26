import { trash } from "@raycast/api";
import { appendFile, mkdir, open, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

export function expandHome(inputPath: string): string {
  if (!inputPath) {
    return inputPath;
  }

  if (inputPath === "~") {
    return homedir();
  }

  if (inputPath.startsWith("~/")) {
    return path.join(homedir(), inputPath.slice(2));
  }

  return inputPath;
}

export async function ensureDirExists(dirPath: string): Promise<void> {
  await mkdir(dirPath, { recursive: true });
}

export async function appendToFile(
  filePath: string,
  text: string,
): Promise<void> {
  await appendFile(filePath, text, { encoding: "utf8" });
}

export async function readFileUtf8(filePath: string): Promise<string> {
  return readFile(filePath, { encoding: "utf8" });
}

export async function writeFileUtf8(
  filePath: string,
  content: string,
): Promise<void> {
  await writeFile(filePath, content, { encoding: "utf8" });
}

export async function writeFileUtf8Exclusive(
  filePath: string,
  content: string,
): Promise<void> {
  const handle = await open(filePath, "wx");
  try {
    await handle.writeFile(content, { encoding: "utf8" });
  } finally {
    await handle.close();
  }
}

export async function moveToTrash(filePath: string): Promise<void> {
  try {
    await trash(filePath);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    throw new Error(`Failed to move note to Trash: ${message}`);
  }
}
