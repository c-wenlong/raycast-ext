import {
  Action,
  ActionPanel,
  Clipboard,
  Color,
  Icon,
  List,
  Toast,
  closeMainWindow,
  showInFinder,
  showToast,
  useNavigation,
} from "@raycast/api";
import {
  useCallback,
  useDeferredValue,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { NewNoteForm } from "./components/NewNoteForm";
import { NoteEditFormFromPath } from "./components/NoteEditorForm";
import { NoteDetailView } from "./components/NoteDetailView";
import { QuickCaptureForm } from "./components/QuickCaptureForm";
import { getNotesDirectory } from "./lib/config";
import { moveToTrash, readFileUtf8 } from "./lib/fs";
import {
  NoteFile,
  createDailyIfMissing,
  duplicateNoteFile,
  listMarkdownFiles,
} from "./lib/notes";
import { launchPanel } from "./lib/panel";
import {
  getPinnedPaths,
  reconcilePins,
  removePin,
  togglePin,
} from "./lib/pins";

function countOpenTasks(content: string): number {
  return (content.match(/^\s*[-*+]\s+\[ \]\s+/gm) ?? []).length;
}

export default function BrowseNotesCommand() {
  const [notes, setNotes] = useState<NoteFile[]>([]);
  const [pinned, setPinned] = useState<Set<string>>(new Set());
  const [isLoading, setIsLoading] = useState(true);
  const [searchText, setSearchText] = useState("");
  const deferredSearchText = useDeferredValue(searchText);
  const hasShownReadWarning = useRef(false);
  const { push } = useNavigation();

  const reloadNotes = useCallback(async () => {
    try {
      setIsLoading(true);
      const notesDir = getNotesDirectory();
      let skippedFiles = 0;
      // Full contents are read so search can match note bodies too.
      const files = await listMarkdownFiles(notesDir, () => {
        skippedFiles += 1;
      });
      // The notes window may have renamed a pinned note to match its
      // first line; the pin follows.
      const pins = await reconcilePins(files.map((file) => file.path));
      setNotes(files);
      setPinned(pins);
      if (skippedFiles > 0 && !hasShownReadWarning.current) {
        hasShownReadWarning.current = true;
        await showToast({
          style: Toast.Style.Failure,
          title: `Skipped ${skippedFiles} unreadable note${skippedFiles > 1 ? "s" : ""}`,
        });
      }
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to load notes",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    reloadNotes();
  }, [reloadNotes]);

  const filteredNotes = useMemo(() => {
    const query = deferredSearchText.trim().toLowerCase();
    if (!query) {
      return notes;
    }

    return notes.filter((note) => {
      return (
        note.title.toLowerCase().includes(query) ||
        note.filename.toLowerCase().includes(query) ||
        note.content.toLowerCase().includes(query)
      );
    });
  }, [deferredSearchText, notes]);

  const pinnedNotes = filteredNotes.filter((note) => pinned.has(note.path));
  const otherNotes = filteredNotes.filter((note) => !pinned.has(note.path));

  async function handleTogglePin(note: NoteFile) {
    try {
      const isPinned = await togglePin(note.path);
      setPinned(await getPinnedPaths());
      await showToast({
        style: Toast.Style.Success,
        title: isPinned ? "Note pinned" : "Note unpinned",
      });
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to update pin",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  async function handleDuplicate(note: NoteFile) {
    try {
      const duplicatedPath = await duplicateNoteFile(note.path);
      await reloadNotes();
      await showToast({
        style: Toast.Style.Success,
        title: "Note duplicated",
        message: duplicatedPath.split("/").pop(),
      });
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to duplicate note",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  // No confirmation: the note goes to the Trash, where it can be restored.
  async function handleDelete(note: NoteFile) {
    try {
      await moveToTrash(note.path);
      await removePin(note.path);
      await reloadNotes();
      await showToast({
        style: Toast.Style.Success,
        title: "Note moved to Trash",
      });
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to delete note",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  async function handleOpenToday() {
    try {
      const notesDir = getNotesDirectory();
      const todayPath = await createDailyIfMissing(notesDir);
      push(
        <NoteDetailView
          notePath={todayPath}
          onNoteChanged={() => {
            reloadNotes();
          }}
          onNoteDeleted={() => {
            reloadNotes();
          }}
        />,
      );
      await reloadNotes();
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to open today's note",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  async function handleOpenFloating(path: string) {
    try {
      await launchPanel(["open", path]);
      await closeMainWindow();
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to open the notes window",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  async function handleCopy(path: string) {
    try {
      const content = await readFileUtf8(path);
      await Clipboard.copy(content);
      await showToast({ style: Toast.Style.Success, title: "Note copied" });
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to copy note",
        message: error instanceof Error ? error.message : "Unknown error",
      });
    }
  }

  function renderNote(note: NoteFile) {
    const isPinned = pinned.has(note.path);
    const openTasks = countOpenTasks(note.content);
    const accessories: List.Item.Accessory[] = [];

    if (openTasks > 0) {
      accessories.push({
        icon: Icon.Circle,
        text: `${openTasks}`,
        tooltip: `${openTasks} open task${openTasks > 1 ? "s" : ""}`,
      });
    }

    if (note.isToday) {
      accessories.push({
        icon: { source: Icon.CircleFilled, tintColor: Color.Green },
        tooltip: "Today's note",
      });
    }

    accessories.push({ date: new Date(note.mtimeMs), tooltip: "Modified" });

    return (
      <List.Item
        key={note.path}
        id={note.path}
        icon={
          isPinned ? Icon.Pin : note.isDaily ? Icon.Calendar : Icon.Document
        }
        title={note.title}
        accessories={accessories}
        actions={
          <ActionPanel>
            <ActionPanel.Section title="Note">
              <Action.Push
                title="Open Note"
                icon={Icon.AppWindow}
                target={
                  <NoteDetailView
                    notePath={note.path}
                    onNoteChanged={() => {
                      reloadNotes();
                    }}
                    onNoteDeleted={() => {
                      reloadNotes();
                    }}
                  />
                }
              />
              <Action.Push
                title="Edit Note"
                icon={Icon.Pencil}
                shortcut={{ modifiers: ["cmd"], key: "e" }}
                target={
                  <NoteEditFormFromPath
                    notePath={note.path}
                    onSaved={() => {
                      reloadNotes();
                    }}
                  />
                }
              />
              <Action
                title="Open in Floating Window"
                icon={Icon.AppWindowSidebarLeft}
                shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
                onAction={() => handleOpenFloating(note.path)}
              />
              <Action
                title={isPinned ? "Unpin Note" : "Pin Note"}
                icon={isPinned ? Icon.PinDisabled : Icon.Pin}
                shortcut={{ modifiers: ["cmd", "shift"], key: "p" }}
                onAction={() => handleTogglePin(note)}
              />
              <Action.OpenWith
                path={note.path}
                shortcut={{ modifiers: ["cmd"], key: "o" }}
              />
              <Action
                title="Duplicate Note"
                icon={Icon.CopyClipboard}
                shortcut={{ modifiers: ["cmd"], key: "d" }}
                onAction={() => handleDuplicate(note)}
              />
              <Action
                title="Copy Note"
                icon={Icon.Clipboard}
                shortcut={{ modifiers: ["cmd"], key: "c" }}
                onAction={() => handleCopy(note.path)}
              />
              <Action
                title="Reveal in Finder"
                icon={Icon.Folder}
                onAction={() => showInFinder(note.path)}
              />
              <Action
                title="Delete Note"
                icon={Icon.Trash}
                style={Action.Style.Destructive}
                shortcut={{ modifiers: ["ctrl"], key: "x" }}
                onAction={() => handleDelete(note)}
              />
            </ActionPanel.Section>

            <ActionPanel.Section title="Create">
              <Action.Push
                title="New Note"
                icon={Icon.Plus}
                shortcut={{ modifiers: ["cmd"], key: "n" }}
                target={<NewNoteForm onCreated={() => reloadNotes()} />}
              />
              <Action.Push
                title="Quick Capture"
                icon={Icon.Bolt}
                shortcut={{ modifiers: ["cmd"], key: "k" }}
                target={<QuickCaptureForm onCaptured={() => reloadNotes()} />}
              />
              <Action
                title="Open Today's Note"
                icon={Icon.Calendar}
                shortcut={{ modifiers: ["cmd", "shift"], key: "o" }}
                onAction={handleOpenToday}
              />
              <Action
                title="Reload"
                icon={Icon.ArrowClockwise}
                shortcut={{ modifiers: ["cmd"], key: "r" }}
                onAction={reloadNotes}
              />
            </ActionPanel.Section>
          </ActionPanel>
        }
      />
    );
  }

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Search titles and contents..."
      onSearchTextChange={setSearchText}
      navigationTitle="Browse Notes"
    >
      <List.EmptyView
        icon={Icon.Document}
        title="No notes yet"
        description="Create one with ⌘N or Quick Capture with ⌘K"
        actions={
          <ActionPanel>
            <Action.Push
              title="New Note"
              icon={Icon.Plus}
              shortcut={{ modifiers: ["cmd"], key: "n" }}
              target={<NewNoteForm onCreated={() => reloadNotes()} />}
            />
            <Action.Push
              title="Quick Capture"
              icon={Icon.Bolt}
              shortcut={{ modifiers: ["cmd"], key: "k" }}
              target={<QuickCaptureForm onCaptured={() => reloadNotes()} />}
            />
            <Action
              title="Open Today's Note"
              icon={Icon.Calendar}
              shortcut={{ modifiers: ["cmd", "shift"], key: "o" }}
              onAction={handleOpenToday}
            />
          </ActionPanel>
        }
      />
      {pinnedNotes.length > 0 ? (
        <List.Section title="Pinned" subtitle={`${pinnedNotes.length}`}>
          {pinnedNotes.map(renderNote)}
        </List.Section>
      ) : null}
      {otherNotes.length > 0 ? (
        <List.Section
          title="Notes"
          subtitle={`${filteredNotes.length}/${notes.length}`}
        >
          {otherNotes.map(renderNote)}
        </List.Section>
      ) : null}
    </List>
  );
}
