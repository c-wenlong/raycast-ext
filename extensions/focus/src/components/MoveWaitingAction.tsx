import { Action, ActionPanel, Icon } from "@raycast/api";
import { MoveTargets } from "../lib/settings";

// "Move Waiting Sessions" in Focus Today and Focus Stats (`movePending`).
// With the Settings override set it is one action to that calendar; without
// it each session's event goes to its own calendar, so there is no one
// destination and the action is a submenu of the writable calendars.
export function MoveWaitingAction(props: {
  targets: MoveTargets;
  onMove: (calendarId: string, name: string) => void;
}) {
  const { targets, onMove } = props;
  if (!targets) return null;
  if (targets.kind === "single") {
    return (
      <Action
        title={`Move Waiting Sessions to ${targets.target.name}`}
        icon={Icon.ArrowRight}
        onAction={() => onMove(targets.target.id, targets.target.name)}
      />
    );
  }
  return (
    <ActionPanel.Submenu
      title="Move Waiting Sessions to"
      icon={Icon.ArrowRight}
    >
      {targets.targets.map((target) => (
        <Action
          key={target.id}
          title={target.name}
          onAction={() => onMove(target.id, target.name)}
        />
      ))}
    </ActionPanel.Submenu>
  );
}
