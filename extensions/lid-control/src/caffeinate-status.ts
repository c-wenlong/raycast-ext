import { showHUD } from "@raycast/api";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { homedir } from "node:os";
import path from "node:path";

const run = promisify(execFile);

export default async function main() {
  const caff = path.join(homedir(), ".local", "bin", "caff");
  try {
    const { stdout } = await run(caff, ["status"]);
    const on = stdout.includes("ON");
    await showHUD(on ? "☕ Caffeinate is running" : "😴 Caffeinate is not running");
  } catch {
    await showHUD("❌ Could not read caffeinate status");
  }
}
