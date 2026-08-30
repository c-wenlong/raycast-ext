import { showHUD } from "@raycast/api";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { homedir } from "node:os";
import path from "node:path";

const run = promisify(execFile);

export default async function main() {
  const caff = path.join(homedir(), ".local", "bin", "caff");
  try {
    const { stdout } = await run(caff, ["toggle"]);
    const on = stdout.includes("ON");
    await showHUD(on ? "☕ Caffeinate on: no idle or display sleep" : "😴 Caffeinate off: normal idle sleep");
  } catch {
    await showHUD("❌ Caffeinate toggle failed");
  }
}
