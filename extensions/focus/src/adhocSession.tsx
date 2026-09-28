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
  ADHOC_PRESET_MINUTES,
  DEFAULT_ADHOC_MINUTES,
  MAX_ADHOC_MINUTES,
  MIN_ADHOC_MINUTES,
  adhocProfileFor,
  adhocRefusedText,
  adhocStartedText,
  initialAdhocCalendar,
  lastAdhocCalendar,
  rememberAdhocCalendar,
  resolveAdhocMinutes,
} from "./lib/adhoc";
import { FocusConfig, readConfig } from "./lib/config";
import {
  Calendar,
  DaemonError,
  Session,
  calendarLabel,
  errorMessage,
  getDaemon,
} from "./lib/daemon";
import { DEFAULT_PROFILE, profileNames } from "./lib/profiles";
import { sessionStatusText } from "./lib/session";
import { durationText } from "./lib/time";

// Ad-hoc Session (PLAN "Ad-hoc sessions"): a goal, a length, a calendar to
// file the session under for stats, and a blocking profile. The helper
// refuses a start while a session is open and sends that one to the end
// sheet, as Focus Today's Start does.

interface Loaded {
  calendars: Calendar[];
  config: FocusConfig;
  // The open session, if any, for the note at the top.
  open: Session | null;
}

interface Errors {
  goal?: string;
  custom?: string;
  calendar?: string;
}

function calendarIcon(calendar: Calendar): Image.ImageLike {
  return calendar.color
    ? { source: Icon.CircleFilled, tintColor: calendar.color }
    : Icon.Circle;
}

export default function AdhocSessionCommand() {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [goal, setGoal] = useState("");
  const [preset, setPreset] = useState(String(DEFAULT_ADHOC_MINUTES));
  const [custom, setCustom] = useState("");
  const [calendarId, setCalendarId] = useState("");
  const [profile, setProfile] = useState(DEFAULT_PROFILE);
  const [errors, setErrors] = useState<Errors>({});

  const load = useCallback(async () => {
    setIsLoading(true);
    try {
      const daemon = getDaemon();
      const [config, calendars, lastUsed, open] = await Promise.all([
        readConfig(),
        daemon.calendars(),
        lastAdhocCalendar().catch(() => undefined),
        daemon.status().catch((): Session | null => null),
      ]);
      const initial = initialAdhocCalendar(calendars, lastUsed, config);
      setLoaded({ calendars, config, open });
      setCalendarId(initial ?? "");
      setProfile(
        adhocProfileFor(initial, config, profileNames(config.profiles)),
      );
      setLoadError(null);
    } catch (error) {
      setLoadError(errorMessage(error));
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  function clearError(key: keyof Errors) {
    if (errors[key]) setErrors((current) => ({ ...current, [key]: undefined }));
  }

  async function handleSubmit() {
    if (!loaded) return;
    const next: Errors = {};
    const trimmedGoal = goal.trim();
    if (!trimmedGoal) next.goal = "Say what the session is for";
    const minutes = resolveAdhocMinutes(preset, custom);
    if (!minutes.ok) next.custom = minutes.error;
    if (!calendarId) next.calendar = "Pick a calendar to file it under";
    if (Object.keys(next).length > 0 || !minutes.ok) {
      setErrors(next);
      return;
    }
    setIsLoading(true);
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Starting session",
    });
    const daemon = getDaemon();
    try {
      const session = await daemon.startAdhoc({
        goal: trimmedGoal,
        durationSeconds: minutes.minutes * 60,
        calendarId,
        profile,
      });
      await rememberAdhocCalendar(calendarId).catch(() => undefined);
      const text = adhocStartedText(session, minutes.minutes);
      toast.style = Toast.Style.Success;
      toast.title = text.title;
      toast.message = text.message;
      setLoaded({ ...loaded, open: session });
      setGoal("");
      setCustom("");
    } catch (error) {
      // A refusal because a session is open has already sent that session
      // to the end sheet; ask for it so the toast can name it.
      const open =
        error instanceof DaemonError && error.code === "daemon"
          ? await daemon.status().catch((): Session | null => null)
          : null;
      const text = adhocRefusedText(errorMessage(error), open);
      toast.style = Toast.Style.Failure;
      toast.title = text.title;
      toast.message = text.message;
      setLoaded({ ...loaded, open });
    } finally {
      setIsLoading(false);
    }
  }

  if (loadError || !loaded) {
    return (
      <Form
        isLoading={isLoading}
        navigationTitle="Ad-hoc Session"
        actions={
          <ActionPanel>
            <Action title="Retry" icon={Icon.ArrowClockwise} onAction={load} />
          </ActionPanel>
        }
      >
        {loadError ? (
          <Form.Description title="Could not load calendars" text={loadError} />
        ) : null}
      </Form>
    );
  }

  const { calendars, config, open } = loaded;
  const names = profileNames(config.profiles);
  const openSession = open && open.state !== "finished" ? open : null;

  return (
    <Form
      isLoading={isLoading}
      navigationTitle="Ad-hoc Session"
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Start Session"
            icon={Icon.Play}
            onSubmit={handleSubmit}
          />
          <Action
            title="Reload"
            icon={Icon.ArrowClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={load}
          />
        </ActionPanel>
      }
    >
      {openSession ? (
        <Form.Description
          title="Running"
          text={`${openSession.goal} (${sessionStatusText(openSession, new Date())}). Starting another sends it to the end sheet first.`}
        />
      ) : null}
      <Form.TextField
        id="goal"
        title="Goal"
        placeholder="What this session is for"
        value={goal}
        error={errors.goal}
        onChange={(value) => {
          setGoal(value);
          clearError("goal");
        }}
      />
      <Form.Dropdown
        id="preset"
        title="Duration"
        value={preset}
        onChange={(value) => {
          setPreset(value);
          clearError("custom");
        }}
      >
        {ADHOC_PRESET_MINUTES.map((minutes) => (
          <Form.Dropdown.Item
            key={minutes}
            value={String(minutes)}
            title={durationText(minutes * 60)}
            icon={Icon.Clock}
          />
        ))}
      </Form.Dropdown>
      <Form.TextField
        id="custom"
        title="Custom Minutes"
        placeholder={`Overrides the duration (${MIN_ADHOC_MINUTES} to ${MAX_ADHOC_MINUTES})`}
        value={custom}
        error={errors.custom}
        onChange={(value) => {
          setCustom(value);
          clearError("custom");
        }}
      />
      {calendars.length === 0 ? (
        <Form.Description
          title="No Calendars"
          text="Calendar.app lists no calendars for Focus. Check Calendar access for focus-daemon in System Settings, then Reload."
        />
      ) : null}
      <Form.Dropdown
        id="calendarId"
        title="Calendar"
        info="Where the session is filed for stats. Its log event still goes to the log calendar from Focus Settings."
        value={calendarId}
        error={errors.calendar}
        onChange={(value) => {
          setCalendarId(value);
          clearError("calendar");
          setProfile(adhocProfileFor(value, config, names));
        }}
      >
        {calendars.map((calendar) => (
          <Form.Dropdown.Item
            key={calendar.id}
            value={calendar.id}
            title={calendarLabel(calendar)}
            icon={calendarIcon(calendar)}
          />
        ))}
      </Form.Dropdown>
      <Form.Dropdown
        id="profile"
        title="Blocking Profile"
        info="Starts on the calendar's default profile from Focus Settings."
        value={profile}
        onChange={setProfile}
      >
        {names.map((name) => (
          <Form.Dropdown.Item
            key={name}
            value={name}
            title={name}
            icon={Icon.Shield}
          />
        ))}
      </Form.Dropdown>
    </Form>
  );
}
