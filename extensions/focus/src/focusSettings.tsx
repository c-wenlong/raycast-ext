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
import {
  CONFIG_PATH,
  FocusConfig,
  readConfig,
  writeConfig,
} from "./lib/config";
import { Calendar, calendarLabel, errorMessage, getDaemon } from "./lib/daemon";
import {
  NO_LOG_CALENDAR,
  resolveLogCalendar,
  settingsChoices,
} from "./lib/settings";

// Focus Settings, calendar half (PLAN step 1): which calendars Focus Today
// can start sessions from, and which calendar the log events go to.
// Profiles, categories, browsers, snooze length and the Raycast deeplink
// toggle are step 4; they get their own Form sections below these two.

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
  const [logCalendar, setLogCalendar] = useState<string>(NO_LOG_CALENDAR);

  const load = useCallback(async () => {
    setIsLoading(true);
    try {
      const [config, calendars] = await Promise.all([
        readConfig(),
        getDaemon().calendars(),
      ]);
      setLoaded({ config, calendars });
      setStartable(config.startableCalendars);
      setLogCalendar(config.logCalendarId ?? NO_LOG_CALENDAR);
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
      const config = await writeConfig({
        startableCalendars: startable,
        logCalendarId,
        logCalendarName,
      });
      setLoaded({ ...loaded, config });
      await showToast({
        style: Toast.Style.Success,
        title: "Focus settings saved",
        message: `${startable.length} startable calendar${startable.length === 1 ? "" : "s"}, logging to ${logCalendarName ?? "nothing yet"}`,
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
        text="Focus Today lists events from the startable calendars. When a session finishes, a log event with the actual time is written to the log calendar."
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
        info="Only calendars you can write to are listed."
        value={logCalendar}
        onChange={setLogCalendar}
      >
        <Form.Dropdown.Item
          value={NO_LOG_CALENDAR}
          title="None yet"
          icon={Icon.Minus}
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
    </Form>
  );
}
