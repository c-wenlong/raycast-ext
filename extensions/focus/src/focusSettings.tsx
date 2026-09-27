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

// Focus Settings, calendar half (PLAN step 1): which calendars Focus Today
// can start sessions from, and which calendar the log events go to.
// Profiles, categories, browsers, snooze length and the Raycast deeplink
// toggle are step 4; they get their own Form sections below these two.

const NO_LOG_CALENDAR = "__none__";

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
    const chosen = loaded.calendars.find((c) => c.id === logCalendar);
    let logCalendarId: string | null = null;
    let logCalendarName: string | null = null;
    if (chosen) {
      logCalendarId = chosen.id;
      logCalendarName = calendarLabel(chosen);
    } else if (
      logCalendar !== NO_LOG_CALENDAR &&
      logCalendar === loaded.config.logCalendarId
    ) {
      // The saved log calendar is not in EventKit right now; keep it as is.
      logCalendarId = loaded.config.logCalendarId;
      logCalendarName = loaded.config.logCalendarName;
    }
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

  const { calendars, config } = loaded;
  const knownIds = new Set(calendars.map((c) => c.id));
  // Calendars saved earlier that EventKit does not list right now (an
  // account offline or removed). They stay selectable so saving the form
  // does not silently drop them.
  const missingStartable = config.startableCalendars.filter(
    (id) => !knownIds.has(id),
  );
  const writable = calendars.filter((c) => c.writable);
  const logMissing =
    config.logCalendarId !== null &&
    !writable.some((c) => c.id === config.logCalendarId);

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
        {logMissing && config.logCalendarId ? (
          <Form.Dropdown.Item
            value={config.logCalendarId}
            title={`${config.logCalendarName ?? config.logCalendarId} (unavailable)`}
            icon={Icon.Warning}
          />
        ) : null}
      </Form.Dropdown>
    </Form>
  );
}
