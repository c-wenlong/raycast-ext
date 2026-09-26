import {
  Action,
  ActionPanel,
  Form,
  Icon,
  Toast,
  showToast,
  useNavigation,
} from "@raycast/api";
import { useState } from "react";
import { getNotesDirectory } from "../lib/config";
import { appendTaskToDaily } from "../lib/tasks";

type AddTaskFormProps = {
  onAdded?: (path: string) => void;
};

export function AddTaskForm({ onAdded }: AddTaskFormProps) {
  const [text, setText] = useState("");
  const { pop } = useNavigation();

  async function handleSubmit() {
    const cleanText = text.trim();
    if (!cleanText) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Task is required",
      });
      return;
    }

    try {
      const dailyPath = await appendTaskToDaily(getNotesDirectory(), cleanText);
      onAdded?.(dailyPath);
      await showToast({ style: Toast.Style.Success, title: "Task added" });
      pop();
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to add task",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  return (
    <Form
      navigationTitle="Add Task to Today"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Add Task"
            icon={Icon.Plus}
            onSubmit={handleSubmit}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="task"
        title="Task"
        placeholder="Reply to the landlord"
        value={text}
        onChange={setText}
      />
    </Form>
  );
}
