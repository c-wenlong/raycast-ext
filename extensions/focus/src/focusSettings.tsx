import {
  Action,
  ActionPanel,
  Form,
  Icon,
  Image,
  Toast,
  showToast,
} from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import { ProfileList, ProfileRename } from "./components/ProfileList";
import {
  CONFIG_PATH,
  CountdownDisplay,
  FocusConfig,
  readConfig,
  writeConfig,
} from "./lib/config";
import { Calendar, calendarLabel, errorMessage, getDaemon } from "./lib/daemon";
import {
  DEFAULT_PROFILE,
  calendarProfileValue,
  entrySummary,
  profileEntries,
  profileNames,
  pruneCalendarProfiles,
  remapCalendarProfiles,
} from "./lib/profiles";
import {
  COUNTDOWN_OPTIONS,
  LOG_CALENDAR_INFO,
  OWN_CALENDAR,
  browserOptions,
  isCountdownDisplay,
  logCalendarValue,
  logDestinationText,
  resolveLogCalendar,
  settingsChoices,
  snoozeOptions,
} from "./lib/settings";

// Focus Settings. Calendar half (PLAN step 1): which calendars Focus Today
// can start sessions from, and the optional log calendar override (off:
// each session's log event goes to its own calendar).
// Blocking half (step 4): each startable calendar's default profile, the
// snooze length, the watched browsers, the Raycast Focus deeplink, and the
// profiles themselves (edited in Manage Profiles, which saves on its own).
// Countdown: the floating panel or the menu bar.

function calendarIcon(calendar: Calendar): Image.ImageLike {
  return calendar.color
    ? { source: Icon.CircleFilled, tintColor: calendar.color }
    : Icon.Circle;
}

interface Loaded {
  calendars: Calendar[];
  config: FocusConfig;
}

export default function FocusSettingsCommand() {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [startable, setStartable] = useState<string[]>([]);
  const [logCalendar, setLogCalendar] = useState<string>(OWN_CALENDAR);
  const [calendarProfiles, setCalendarProfiles] = useState<
    Record<string, string>
  >({});
  const [snooze, setSnooze] = useState("180");
  const [browsers, setBrowsers] = useState<string[]>([]);
  const [raycastDeeplink, setRaycastDeeplink] = useState(false);
  const [countdown, setCountdown] = useState<CountdownDisplay>("panel");

  const load = useCallback(async () => {
    setIsLoading(true);
    try {
      const [config, calendars] = await Promise.all([
        readConfig(),
        getDaemon().calendars(),
      ]);
      setLoaded({ config, calendars });
      setStartable(config.startableCalendars);
      setLogCalendar(logCalendarValue(config));
      setCalendarProfiles(config.calendarProfiles);
      setSnooze(String(config.snoozeSeconds));
      setBrowsers(config.browsers);
      setRaycastDeeplink(config.raycastDeeplink);
      setCountdown(config.countdownDisplay);
      setError(null);
    } catch (loadError) {
      setError(errorMessage(loadError));
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function handleSubmit() {
    if (!loaded) return;
    const { logCalendarId, logCalendarName } = resolveLogCalendar(
      logCalendar,
      loaded.calendars,
      loaded.config,
    );
    try {
      // `profiles` is not written here: Manage Profiles saves it itself.
      const config = await writeConfig({
        startableCalendars: startable,
        logCalendarId,
        logCalendarName,
        calendarProfiles: pruneCalendarProfiles(calendarProfiles, startable),
        snoozeSeconds: Number(snooze),
        browsers,
        raycastDeeplink,
        countdownDisplay: countdown,
      });
      setLoaded({ ...loaded, config });
      setCalendarProfiles(config.calendarProfiles);
      await showToast({
        style: Toast.Style.Success,
        title: "Focus settings saved",
        message: `${startable.length} startable calendar${startable.length === 1 ? "" : "s"}, ${logDestinationText(logCalendarName)}. Applies to the next session.`,
      });
    } catch (saveError) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not save Focus settings",
        message: errorMessage(saveError),
      });
    }
  }

  if (error || !loaded) {
    return (
      <Form
        isLoading={isLoading}
        navigationTitle="Focus Settings"
        actions={
          <ActionPanel>
            <Action title="Retry" icon={Icon.ArrowClockwise} onAction={load} />
          </ActionPanel>
        }
      >
        {error ? (
          <Form.Description title="Could not load calendars" text={error} />
        ) : null}
      </Form>
    );
  }

  const { calendars, missingStartable, writable, unavailableLog } =
    settingsChoices(loaded.calendars, loaded.config);

  const labels: Record<string, string> = {};
  for (const calendar of calendars)
    labels[calendar.id] = calendarLabel(calendar);
  for (const id of missingStartable) {
    labels[id] = `Unavailable calendar (${id.slice(0, 8)})`;
  }
  // One profile row per calendar selected right now (saved or not). The row
  // is titled with the calendar's name, or its full label when two selected
  // calendars share a name.
  const rows = startable.map((id) => {
    const calendar = calendars.find((c) => c.id === id);
    const shared =
      calendar !== undefined &&
      startable.some(
        (other) =>
          other !== id &&
          calendars.find((c) => c.id === other)?.title === calendar.title,
      );
    return {
      id,
      title: calendar && !shared ? calendar.title : labels[id],
      label: labels[id],
    };
  });
  const entries = profileEntries(loaded.config.profiles);
  const names = profileNames(loaded.config.profiles);

  function profilesChanged(next: FocusConfig, rename: ProfileRename | null) {
    setLoaded((current) =>
      current
        ? { ...current, config: { ...current.config, profiles: next.profiles } }
        : current,
    );
    if (rename) {
      setCalendarProfiles((current) =>
        remapCalendarProfiles(current, rename.from, rename.to),
      );
    }
  }

  const manageProfiles = (
    <Action.Push
      title="Manage Profiles"
      icon={Icon.List}
      shortcut={{ modifiers: ["cmd", "shift"], key: "p" }}
      target={
        <ProfileList
          config={loaded.config}
          calendarProfiles={calendarProfiles}
          calendarLabels={labels}
          onChange={profilesChanged}
        />
      }
    />
  );

  return (
    <Form
      isLoading={isLoading}
      navigationTitle="Focus Settings"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save Settings"
            icon={Icon.CheckCircle}
            onSubmit={handleSubmit}
          />
          {manageProfiles}
          <Action
            title="Reload Calendars"
            icon={Icon.ArrowClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={load}
          />
          <Action.ShowInFinder
            title="Show Config in Finder"
            path={CONFIG_PATH}
            shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
          />
        </ActionPanel>
      }
    >
      <Form.Description
        title="Calendars"
        text="Focus Today lists events from the startable calendars. When a session finishes, a log event with the actual time is written to the session's own calendar, beside the planned event, or to the log calendar below when one is set."
      />
      <Form.TagPicker
        id="startableCalendars"
        title="Startable Calendars"
        value={startable}
        onChange={setStartable}
      >
        {calendars.map((calendar) => (
          <Form.TagPicker.Item
            key={calendar.id}
            value={calendar.id}
            title={calendarLabel(calendar)}
            icon={calendarIcon(calendar)}
          />
        ))}
        {missingStartable.map((id) => (
          <Form.TagPicker.Item
            key={id}
            value={id}
            title={`Unavailable calendar (${id.slice(0, 8)})`}
            icon={Icon.Warning}
          />
        ))}
      </Form.TagPicker>
      <Form.Dropdown
        id="logCalendarId"
        title="Log Calendar"
        info={LOG_CALENDAR_INFO}
        value={logCalendar}
        onChange={setLogCalendar}
      >
        <Form.Dropdown.Item
          value={OWN_CALENDAR}
          title="Each session's own calendar"
          icon={Icon.Calendar}
        />
        {writable.map((calendar) => (
          <Form.Dropdown.Item
            key={calendar.id}
            value={calendar.id}
            title={calendarLabel(calendar)}
            icon={calendarIcon(calendar)}
          />
        ))}
        {unavailableLog ? (
          <Form.Dropdown.Item
            value={unavailableLog.id}
            title={unavailableLog.title}
            icon={Icon.Warning}
          />
        ) : null}
      </Form.Dropdown>

      <Form.Separator />
      <Form.Description
        title="Blocking"
        text={
          rows.length > 0
            ? "The profile each startable calendar's sessions block with. Ad-hoc sessions pick one in their own form."
            : "Pick startable calendars above to choose the profile their sessions block with."
        }
      />
      {rows.map((row) => {
        const value = calendarProfileValue(calendarProfiles, row.id);
        return (
          <Form.Dropdown
            key={row.id}
            id={`calendarProfile:${row.id}`}
            title={row.title}
            info={`Blocking profile for sessions started from ${row.label}.`}
            value={value}
            onChange={(next) =>
              setCalendarProfiles((current) => ({ ...current, [row.id]: next }))
            }
          >
            {names.map((name) => (
              <Form.Dropdown.Item
                key={name}
                value={name}
                title={name}
                icon={Icon.Shield}
              />
            ))}
            {names.includes(value) ? null : (
              <Form.Dropdown.Item
                value={value}
                title={`${value} (missing, uses ${DEFAULT_PROFILE})`}
                icon={Icon.Warning}
              />
            )}
          </Form.Dropdown>
        );
      })}
      <Form.Dropdown
        id="snoozeSeconds"
        title="Snooze Length"
        info="How long Snooze on a block page lets that site or app through."
        value={snooze}
        onChange={setSnooze}
      >
        {snoozeOptions(loaded.config.snoozeSeconds).map((option) => (
          <Form.Dropdown.Item
            key={option.value}
            value={option.value}
            title={option.title}
          />
        ))}
      </Form.Dropdown>
      <Form.TagPicker
        id="browsers"
        title="Browsers"
        info="Focus reads the front tab of these browsers every two seconds and sends a blocked site to the block page. macOS asks once per browser for permission."
        value={browsers}
        onChange={setBrowsers}
      >
        {browserOptions(loaded.config.browsers).map((option) => (
          <Form.TagPicker.Item
            key={option.value}
            value={option.value}
            title={option.title}
            icon={Icon.Globe}
          />
        ))}
      </Form.TagPicker>

      <Form.Separator />
      <Form.Description
        title="Profiles"
        text="Manage Profiles (⌘⇧P) adds, edits and deletes them; changes there are saved at once."
      />
      {entries.map((entry) => (
        <Form.Description
          key={entry.name}
          title={entry.name}
          text={entrySummary(entry)}
        />
      ))}

      <Form.Separator />
      <Form.Dropdown
        id="countdownDisplay"
        title="Countdown"
        info="Where the time left shows during a session. The floating panel stays above every window; hover it for Pause, Complete and more. Either one can switch to the other from its own menu."
        value={countdown}
        onChange={(next) => {
          if (isCountdownDisplay(next)) setCountdown(next);
        }}
      >
        {COUNTDOWN_OPTIONS.map((option) => (
          <Form.Dropdown.Item
            key={option.value}
            value={option.value}
            title={option.title}
            icon={option.value === "panel" ? Icon.AppWindow : Icon.Clock}
          />
        ))}
      </Form.Dropdown>
      <Form.Checkbox
        id="raycastDeeplink"
        title="Raycast Focus"
        label="Also start Raycast Focus"
        info="Opens raycast://focus/start when a session starts and raycast://focus/complete when it finishes, so both run side by side."
        value={raycastDeeplink}
        onChange={setRaycastDeeplink}
      />
    </Form>
  );
}
