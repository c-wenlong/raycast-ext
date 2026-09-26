import { environment } from "@raycast/api";
import { spawn } from "node:child_process";
import { chmod } from "node:fs/promises";
import path from "node:path";
import { getNotesDirectory } from "./config";

// The floating window is a native helper (helper/main.swift) built into
// assets/notes-panel. The first launch keeps running as a small server;
// later launches forward their command to it and exit, so spawning it
// detached for every action is cheap.
export async function launchPanel(args: string[]): Promise<void> {
  const helper = path.join(environment.assetsPath, "notes-panel");
  await chmod(helper, 0o755);
  const child = spawn(helper, [...args, "--dir", getNotesDirectory()], {
    detached: true,
    stdio: "ignore",
  });
  // spawn() reports a missing or non-executable helper asynchronously, so
  // wait for either the "spawn" or the "error" event before resolving.
  await new Promise<void>((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });
  child.unref();
}
