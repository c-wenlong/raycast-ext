import {
  Action,
  ActionPanel,
  Color,
  Icon,
  List,
  Toast,
  showToast,
} from "@raycast/api";
import { useCallback, useEffect, useMemo, useState } from "react";
import { AddTaskForm } from "./components/AddTaskForm";
import { NoteDetailView } from "./components/NoteDetailView";
import { getNotesDirectory } from "./lib/config";
import { Task, listTasks, setTaskDone } from "./lib/tasks";

type Filter = "open" | "done" | "all";

export default function TasksCommand() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [filter, setFilter] = useState<Filter>("open");

  const reload = useCallback(async () => {
    try {
      setIsLoading(true);
      setTasks(await listTasks(getNotesDirectory()));
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to load tasks",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  const visible = useMemo(() => {
    if (filter === "all") {
      return tasks;
    }
    return tasks.filter((task) => task.done === (filter === "done"));
  }, [tasks, filter]);

  // Group by note, keeping the note order from listTasks (newest first).
  const sections = useMemo(() => {
    const byNote = new Map<string, { title: string; tasks: Task[] }>();
    for (const task of visible) {
      const entry = byNote.get(task.notePath) ?? {
        title: task.noteTitle,
        tasks: [],
      };
      entry.tasks.push(task);
      byNote.set(task.notePath, entry);
    }
    return [...byNote.entries()];
  }, [visible]);

  async function handleToggle(task: Task) {
    try {
      await setTaskDone(task, !task.done);
      await reload();
      await showToast({
        style: Toast.Style.Success,
        title: task.done ? "Task reopened" : "Task done",
      });
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to update task",
        message: error instanceof Error ? error.message : "Unknown error",
      });
      await reload();
    }
  }

  const openCount = tasks.filter((task) => !task.done).length;

  return (
    <List
      isLoading={isLoading}
      navigationTitle="Tasks"
      searchBarPlaceholder="Search tasks..."
      searchBarAccessory={
        <List.Dropdown
          tooltip="Filter"
          value={filter}
          onChange={(value) => setFilter(value as Filter)}
        >
          <List.Dropdown.Item title="Open" value="open" />
          <List.Dropdown.Item title="Done" value="done" />
          <List.Dropdown.Item title="All" value="all" />
        </List.Dropdown>
      }
    >
      <List.EmptyView
        icon={Icon.CheckCircle}
        title={filter === "open" ? "No open tasks" : "No tasks"}
        description="Add one with ⌘N, or write “- [ ] something” in any note"
        actions={
          <ActionPanel>
            <Action.Push
              title="Add Task to Today"
              icon={Icon.Plus}
              shortcut={{ modifiers: ["cmd"], key: "n" }}
              target={<AddTaskForm onAdded={reload} />}
            />
          </ActionPanel>
        }
      />
      {sections.map(([notePath, section]) => (
        <List.Section
          key={notePath}
          title={section.title}
          subtitle={`${section.tasks.length}`}
        >
          {section.tasks.map((task) => (
            <List.Item
              key={`${task.notePath}:${task.lineIndex}`}
              icon={
                task.done
                  ? { source: Icon.CheckCircle, tintColor: Color.Green }
                  : Icon.Circle
              }
              title={task.text}
              accessories={[
                { text: `${openCount} open`, tooltip: "Open tasks" },
              ]}
              actions={
                <ActionPanel>
                  <ActionPanel.Section title="Task">
                    <Action
                      title={task.done ? "Mark as Open" : "Mark as Done"}
                      icon={task.done ? Icon.Circle : Icon.CheckCircle}
                      onAction={() => handleToggle(task)}
                    />
                    <Action.Push
                      title="Open Note"
                      icon={Icon.Document}
                      shortcut={{ modifiers: ["cmd"], key: "o" }}
                      target={
                        <NoteDetailView
                          notePath={task.notePath}
                          onNoteChanged={reload}
                          onNoteDeleted={reload}
                        />
                      }
                    />
                    <Action.CopyToClipboard
                      title="Copy Task"
                      content={task.text}
                      shortcut={{ modifiers: ["cmd"], key: "c" }}
                    />
                  </ActionPanel.Section>
                  <ActionPanel.Section title="Create">
                    <Action.Push
                      title="Add Task to Today"
                      icon={Icon.Plus}
                      shortcut={{ modifiers: ["cmd"], key: "n" }}
                      target={<AddTaskForm onAdded={reload} />}
                    />
                    <Action
                      title="Reload"
                      icon={Icon.ArrowClockwise}
                      shortcut={{ modifiers: ["cmd"], key: "r" }}
                      onAction={reload}
                    />
                  </ActionPanel.Section>
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      ))}
    </List>
  );
}
