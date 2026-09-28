import { environment, LaunchProps, showHUD } from "@raycast/api";
import { execFile } from "node:child_process";
import { chmod } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

export default async function main(props: LaunchProps<{ arguments: Arguments.SetGrayscale }>) {
  const raw = (props.arguments.level ?? "").trim();
  const helper = path.join(environment.assetsPath, "colorfilter");

  let args: string[];
  if (raw === "") {
    args = ["toggle"];
  } else {
    const level = Number(raw);
    if (!Number.isFinite(level) || level < 0 || level > 100) {
      await showHUD("❌ Level must be a number between 0 and 100");
      return;
    }
    args = ["set", String(Math.round(level))];
  }

  try {
    await chmod(helper, 0o755);
    const { stdout } = await run(helper, args);
    const result = Number(stdout.trim());
    await showHUD(result === 0 ? "🌈 Grayscale off" : `🩶 Grayscale ${result}%`);
  } catch {
    await showHUD("❌ Failed to set grayscale");
  }
}
