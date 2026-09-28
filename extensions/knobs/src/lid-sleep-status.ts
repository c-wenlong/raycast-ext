import { showHUD } from "@raycast/api";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { homedir } from "node:os";
import path from "node:path";

const run = promisify(execFile);

export default async function main() {
  const lid = path.join(homedir(), ".local", "bin", "lid");
  try {
    const { stdout } = await run(lid, ["status"]);
    const stayAwake = stdout.includes("ON");
    await showHUD(stayAwake ? "💤 Mac stays awake with lid closed" : "😴 Normal lid sleep");
  } catch {
    await showHUD("❌ Could not read status");
  }
}
