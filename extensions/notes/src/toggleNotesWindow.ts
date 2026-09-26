import { showToast, Toast } from "@raycast/api";
import { launchPanel } from "./lib/panel";

export default async function ToggleNotesWindowCommand() {
  try {
    await launchPanel(["toggle"]);
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Failed to open the notes window",
      message: error instanceof Error ? error.message : "Unknown error",
    });
  }
}
