import {
  Action,
  ActionPanel,
  Alert,
  Color,
  Icon,
  List,
  Toast,
  confirmAlert,
  showToast,
} from "@raycast/api";
import { useState } from "react";
import { FocusConfig, updateConfig } from "../lib/config";
import { errorMessage } from "../lib/daemon";
import {
  DEFAULT_PROFILE,
  ProfileEntry,
  ProfileSpec,
  applyProfileDelete,
  applyProfileSave,
  entrySummary,
  profileEntries,
  remapCalendarProfiles,
} from "../lib/profiles";
import { ProfileForm } from "./ProfileForm";

// Manage Profiles, pushed from Focus Settings. Every change is written to
// config.json at once; `onChange` lets Settings update its own (unsaved)
// per-calendar choices when a profile is renamed or deleted.

export interface ProfileRename {
  from: string;
  // Null when the profile was deleted: its calendars go back to "default".
  to: string | null;
}

const APPLIES = "A running session picks it up within seconds";

export function ProfileList(props: {
  config: FocusConfig;
  // Settings' current per-calendar choices (saved or not) and labels, for
  // the "used by" line.
  calendarProfiles: Record<string, string>;
  calendarLabels: Record<string, string>;
  onChange: (config: FocusConfig, rename: ProfileRename | null) => void;
}) {
  const [profiles, setProfiles] = useState(props.config.profiles);
  const [calendarProfiles, setCalendarProfiles] = useState(
    props.calendarProfiles,
  );
  const entries = profileEntries(profiles);
  const names = entries.map((entry) => entry.name);

  function usedBy(name: string): string[] {
    return Object.entries(calendarProfiles)
      .filter(([, profile]) => profile === name)
      .map(([id]) => props.calendarLabels[id] ?? id);
  }

  function applied(next: FocusConfig, rename: ProfileRename | null) {
    setProfiles(next.profiles);
    if (rename) {
      setCalendarProfiles((current) =>
        remapCalendarProfiles(current, rename.from, rename.to),
      );
    }
    props.onChange(next, rename);
  }

  async function save(
    originalName: string | null,
    name: string,
    spec: ProfileSpec,
  ) {
    const next = await updateConfig((current) =>
      applyProfileSave(current, originalName, name, spec),
    );
    const renamed = originalName !== null && originalName !== name;
    applied(next, renamed ? { from: originalName, to: name } : null);
    await showToast({
      style: Toast.Style.Success,
      title: `Saved profile "${name}"`,
      message: APPLIES,
    });
  }

  async function remove(entry: ProfileEntry) {
    const users = usedBy(entry.name);
    const confirmed = await confirmAlert({
      title: `Delete profile "${entry.name}"?`,
      message:
        users.length > 0
          ? `${users.join(", ")} will use the default profile.`
          : "No calendar uses it.",
      primaryAction: { title: "Delete", style: Alert.ActionStyle.Destructive },
    });
    if (!confirmed) return;
    try {
      const next = await updateConfig((current) =>
        applyProfileDelete(current, entry.name),
      );
      applied(next, { from: entry.name, to: null });
      await showToast({
        style: Toast.Style.Success,
        title: `Deleted profile "${entry.name}"`,
      });
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not delete the profile",
        message: errorMessage(error),
      });
    }
  }

  const addAction = (
    <Action.Push
      title="Add Profile"
      icon={Icon.Plus}
      shortcut={{ modifiers: ["cmd"], key: "n" }}
      target={<ProfileForm entry={null} existingNames={names} onSave={save} />}
    />
  );

  return (
    <List navigationTitle="Blocking Profiles">
      {entries.map((entry) => {
        const users = usedBy(entry.name);
        const accessories: List.Item.Accessory[] = [];
        if (entry.malformed) {
          accessories.push({
            tag: { value: "not readable", color: Color.Red },
          });
        } else if (entry.problems.length > 0) {
          accessories.push({
            icon: { source: Icon.Warning, tintColor: Color.Orange },
            tooltip: entry.problems.join("; "),
          });
        }
        if (entry.name === DEFAULT_PROFILE) {
          accessories.push({
            text: "fallback",
            tooltip: "Used by every calendar without a profile of its own",
          });
        } else if (users.length > 0) {
          accessories.push({
            text: `${users.length} calendar${users.length === 1 ? "" : "s"}`,
            tooltip: users.join(", "),
          });
        }
        return (
          <List.Item
            key={entry.name}
            title={entry.name}
            subtitle={entrySummary(entry)}
            icon={
              entry.spec.mode === "allowlist"
                ? Icon.CheckCircle
                : Icon.XMarkCircle
            }
            accessories={accessories}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit Profile"
                  icon={Icon.Pencil}
                  target={
                    <ProfileForm
                      entry={entry}
                      existingNames={names}
                      onSave={save}
                    />
                  }
                />
                {addAction}
                {entry.name !== DEFAULT_PROFILE ? (
                  <Action
                    title="Delete Profile"
                    icon={Icon.Trash}
                    style={Action.Style.Destructive}
                    shortcut={{ modifiers: ["ctrl"], key: "x" }}
                    onAction={() => remove(entry)}
                  />
                ) : null}
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
