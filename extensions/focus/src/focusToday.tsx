import {
  Action,
  ActionPanel,
  Color,
  Icon,
  LaunchType,
  List,
  Toast,
  launchCommand,
  showToast,
} from "@raycast/api";
import { useCallback, useEffect, useRef, useState } from "react";
import { FinishSessionForm } from "./components/FinishSessionForm";
import { FocusConfig, readConfig } from "./lib/config";
import { moveTarget } from "./lib/settings";
import {
  BlockingStatus,
  Calendar,
  EXTEND_MINUTES,
  Session,
  TodayEvent,
  WaitingSession,
  errorMessage,
  getDaemon,
} from "./lib/daemon";
import {
  blockingText,
  effectiveSession,
  pausedSecondsNow,
  pausedText,
  sessionActions,
  sessionStatusText,
} from "./lib/session";
import {
  durationText,
  formatClockIso,
  formatTimeRange,
  groupEvents,
  remainingText,
  secondsUntil,
} from "./lib/time";

interface Data {
  config: FocusConfig;
  session: Session | null;
  // What the open session blocks; null when idle or the helper is older.
  blocking: BlockingStatus | null;
  // When `session` was read, for the paused time shown since.
  fetchedAt: Date;
  events: TodayEvent[];
  waiting: WaitingSession[];
  colors: Map<string, string>;
}

const STATE_COLORS: Record<Session["state"], Color> = {
  running: Color.Green,
  paused: Color.Orange,
  ending: Color.Red,
  finished: Color.SecondaryText,
};

async function openSettings() {
  try {
    await launchCommand({
      name: "focusSettings",
      type: LaunchType.UserInitiated,
    });
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not open Focus Settings",
      message: errorMessage(error),
    });
  }
}

export default function FocusTodayCommand() {
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  // Re-render every 30 s so remaining minutes and the Now/Later split stay
  // current while the list is open.
  const [now, setNow] = useState(() => new Date());
  // Each load gets a number; only the newest one may write state, so a slow
  // background refresh can never overwrite what a later reload (after Start
  // or Finish) showed. `running` counts loads still in flight.
  const latest = useRef(0);
  const running = useRef(0);

  // A quiet reload (the background refresh) shows no spinner and no toast,
  // is skipped while another load is running, and on failure keeps the last
  // good view; the next tick tries again.
  const reload = useCallback(async (options: { quiet?: boolean } = {}) => {
    if (options.quiet && running.current > 0) return;
    const id = ++latest.current;
    running.current += 1;
    if (!options.quiet) setIsLoading(true);
    try {
      const config = await readConfig();
      const daemon = getDaemon();
      const [{ session, fetchedAt }, waiting, events, calendars, blocking] =
        await Promise.all([
          // The paused time is counted from when this reply came back, not
          // from when the slowest of the four did.
          daemon
            .status()
            .then((session) => ({ session, fetchedAt: new Date() })),
          daemon.pending(),
          config.startableCalendars.length > 0
            ? daemon.today()
            : Promise.resolve([]),
          // Only for row colours; the list works without them.
          daemon.calendars().catch((): Calendar[] => []),
          // Only for the Running row's profile line.
          daemon.blocking().catch((): BlockingStatus | null => null),
        ]);
      if (id !== latest.current) return;
      const colors = new Map<string, string>();
      for (const calendar of calendars) {
        if (calendar.color) colors.set(calendar.id, calendar.color);
      }
      setData({
        config,
        session,
        blocking: session ? blocking : null,
        fetchedAt,
        events,
        waiting,
        colors,
      });
      setError(null);
    } catch (loadError) {
      if (id !== latest.current || options.quiet) return;
      // Drop what was shown before: a stale Running row would mislead.
      setData(null);
      setError(errorMessage(loadError));
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not load Focus Today",
        message: errorMessage(loadError),
      });
    } finally {
      running.current -= 1;
      if (id === latest.current) {
        setNow(new Date());
        setIsLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  // The helper sends a session to the end sheet at its planned end; refetch
  // then so the row shows it (the view already treats it as ending).
  const deadline = data?.session?.plannedEnd;
  const deadlineOpen =
    data?.session?.state === "running" || data?.session?.state === "paused";
  useEffect(() => {
    if (!deadline || !deadlineOpen) return;
    const wait = Date.parse(deadline) - Date.now();
    if (!Number.isFinite(wait) || wait > 2 ** 31 - 1) return;
    const timer = setTimeout(
      () => {
        setNow(new Date());
        reload({ quiet: true });
      },
      Math.max(0, wait) + 1_000,
    );
    return () => clearTimeout(timer);
  }, [deadline, deadlineOpen, reload]);

  useEffect(() => {
    const clock = setInterval(() => setNow(new Date()), 30_000);
    // Refetch too, so events added or moved while the list is open (or a
    // new day) show up without a manual refresh.
    const refresh = setInterval(() => reload({ quiet: true }), 60_000);
    return () => {
      clearInterval(clock);
      clearInterval(refresh);
    };
  }, [reload]);

  async function handleStart(event: TodayEvent) {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Starting session",
    });
    try {
      const session = await getDaemon().start(event.id, event.start);
      toast.style = Toast.Style.Success;
      toast.title = `Focusing: ${session.goal}`;
      toast.message = session.plannedEnd
        ? `Until ${formatClockIso(session.plannedEnd)}`
        : undefined;
      await reload();
    } catch (startError) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not start the session";
      toast.message = errorMessage(startError);
      // Starting while a session is open sends that one to the end sheet.
      await reload({ quiet: true });
    }
  }

  // Pause, Resume, Extend and Stop: one round trip, a toast, a reload.
  async function handleChange(
    busy: string,
    change: () => Promise<Session>,
    done: (session: Session) => string,
  ) {
    const toast = await showToast({ style: Toast.Style.Animated, title: busy });
    try {
      const session = await change();
      toast.style = Toast.Style.Success;
      toast.title = done(session);
      await reload();
    } catch (changeError) {
      toast.style = Toast.Style.Failure;
      toast.title = `${busy.replace(/…$/, "")} failed`;
      toast.message = errorMessage(changeError);
      await reload({ quiet: true });
    }
  }

  async function handleRetryPending() {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Retrying waiting sessions",
    });
    try {
      const counts = await getDaemon().retryPending();
      toast.style =
        counts.stillWaiting > 0 ? Toast.Style.Failure : Toast.Style.Success;
      toast.title =
        counts.stillWaiting > 0
          ? `${counts.stillWaiting} still waiting`
          : "All waiting sessions logged";
      toast.message = `${counts.written} written, ${counts.adopted} found already logged`;
      await reload();
    } catch (retryError) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not retry";
      toast.message = errorMessage(retryError);
    }
  }

  async function handleMovePending(calendarId: string, name: string) {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: `Moving waiting sessions to ${name}`,
    });
    try {
      const counts = await getDaemon().movePending(calendarId);
      toast.style =
        counts.stillWaiting > 0 ? Toast.Style.Failure : Toast.Style.Success;
      toast.title =
        counts.stillWaiting > 0
          ? `${counts.stillWaiting} still waiting for ${name}`
          : `Moved to ${name}`;
      toast.message = `${counts.written} written, ${counts.adopted} found already logged`;
      await reload();
    } catch (moveError) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not move waiting sessions";
      toast.message = errorMessage(moveError);
    }
  }

  const commonActions = (
    <ActionPanel.Section>
      <Action
        title="Refresh"
        icon={Icon.ArrowClockwise}
        shortcut={{ modifiers: ["cmd"], key: "r" }}
        onAction={reload}
      />
      <Action
        title="Open Focus Settings"
        icon={Icon.Gear}
        shortcut={{ modifiers: ["cmd"], key: "," }}
        onAction={openSettings}
      />
    </ActionPanel.Section>
  );

  function renderSession(
    session: Session,
    config: FocusConfig,
    fetchedAt: Date,
  ) {
    const allowed = sessionActions(session);
    const paused = pausedText(pausedSecondsNow(session, fetchedAt, now));
    const accessories: List.Item.Accessory[] = [];
    const blocking = data?.blocking ?? null;
    accessories.push({
      text: blockingText(session, blocking),
      icon: Icon.Shield,
      tooltip:
        blocking?.mode === "allowlist"
          ? "Blocking profile: everything but the listed apps and sites is blocked"
          : "Blocking profile: the listed apps and sites are blocked",
    });
    if (paused) accessories.push({ text: paused, icon: Icon.Pause });
    accessories.push({
      text: sessionStatusText(session, now),
      tooltip: session.plannedEnd
        ? `Planned end ${formatClockIso(session.plannedEnd)}`
        : undefined,
    });
    accessories.push({
      tag: { value: session.state, color: STATE_COLORS[session.state] },
    });
    const finishForm = (
      <FinishSessionForm
        session={session}
        logCalendarName={config.logCalendarName}
        onFinished={() => {
          reload();
        }}
      />
    );
    return (
      <List.Item
        key={`session-${session.id}`}
        icon={{
          source: session.state === "paused" ? Icon.Pause : Icon.Clock,
          tintColor: STATE_COLORS[session.state],
        }}
        title={session.goal}
        subtitle={
          session.plannedEnd
            ? `until ${formatClockIso(session.plannedEnd)}`
            : undefined
        }
        accessories={accessories}
        actions={
          <ActionPanel>
            {allowed.pause ? (
              <Action
                title="Pause"
                icon={Icon.Pause}
                shortcut={{ modifiers: ["cmd", "shift"], key: "p" }}
                onAction={() =>
                  handleChange(
                    "Pausing…",
                    () => getDaemon().pause(),
                    () => "Paused",
                  )
                }
              />
            ) : null}
            {allowed.resume ? (
              <Action
                title="Resume"
                icon={Icon.Play}
                shortcut={{ modifiers: ["cmd", "shift"], key: "p" }}
                onAction={() =>
                  handleChange(
                    "Resuming…",
                    () => getDaemon().resume(),
                    () => "Resumed",
                  )
                }
              />
            ) : null}
            {allowed.extend ? (
              <ActionPanel.Submenu
                title="Extend"
                icon={Icon.PlusCircle}
                shortcut={{ modifiers: ["cmd"], key: "e" }}
              >
                {EXTEND_MINUTES.map((minutes) => (
                  <Action
                    key={minutes}
                    title={`${minutes} Minutes`}
                    onAction={() =>
                      handleChange(
                        `Extending by ${minutes} min…`,
                        () => getDaemon().extend(minutes * 60),
                        (next) =>
                          next.plannedEnd
                            ? `Extended until ${formatClockIso(next.plannedEnd)}`
                            : "Extended",
                      )
                    }
                  />
                ))}
              </ActionPanel.Submenu>
            ) : null}
            {allowed.stop ? (
              <Action
                title="Stop"
                icon={Icon.Stop}
                shortcut={{ modifiers: ["cmd", "shift"], key: "s" }}
                onAction={() =>
                  handleChange(
                    "Stopping…",
                    () => getDaemon().stop(),
                    () => "Stopped: rate it on the end sheet",
                  )
                }
              />
            ) : null}
            {allowed.finish ? (
              <Action.Push
                title="Finish (Rating and Note)"
                icon={Icon.CheckCircle}
                shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
                target={finishForm}
              />
            ) : null}
            {commonActions}
          </ActionPanel>
        }
      />
    );
  }

  function renderEvent(event: TodayEvent, started: boolean) {
    const left = secondsUntil(event.end, now);
    const color = data?.colors.get(event.calendarId);
    const tooltip = started
      ? `Runs until ${formatClockIso(event.end)}`
      : `Starting now runs ${durationText(left)}, until ${formatClockIso(event.end)}`;
    return (
      <List.Item
        key={`${event.id}|${event.start}`}
        icon={
          color
            ? { source: Icon.CircleFilled, tintColor: color }
            : Icon.Calendar
        }
        title={event.title}
        subtitle={event.calendarTitle}
        accessories={[
          { text: formatTimeRange(event.start, event.end) },
          { tag: remainingText(left), tooltip },
        ]}
        actions={
          <ActionPanel>
            <Action
              title="Start Session"
              icon={Icon.Play}
              onAction={() => handleStart(event)}
            />
            {commonActions}
          </ActionPanel>
        }
      />
    );
  }

  function renderWaiting(item: WaitingSession, config: FocusConfig) {
    const target = moveTarget(config);
    return (
      <List.Item
        key={`waiting-${item.sessionId}`}
        icon={{ source: Icon.Hourglass, tintColor: Color.Orange }}
        title={item.goal}
        subtitle={`waiting for ${item.logCalendarName ?? "a log calendar"}`}
        accessories={[{ date: new Date(item.endedAt), tooltip: "Ended" }]}
        actions={
          <ActionPanel>
            <Action
              title="Retry"
              icon={Icon.ArrowClockwise}
              onAction={handleRetryPending}
            />
            {target ? (
              <Action
                title={`Move Waiting Sessions to ${target.name}`}
                icon={Icon.ArrowRight}
                onAction={() => handleMovePending(target.id, target.name)}
              />
            ) : null}
            <Action
              title={
                target ? "Choose Another Log Calendar" : "Choose a Log Calendar"
              }
              icon={Icon.Gear}
              onAction={openSettings}
            />
            {commonActions}
          </ActionPanel>
        }
      />
    );
  }

  const config = data?.config;
  const noCalendars =
    config !== undefined && config.startableCalendars.length === 0;
  const groups = groupEvents(data?.events ?? [], now);
  const session = data?.session ?? null;
  const waiting = data?.waiting ?? [];

  let empty: { title: string; description: string; icon: Icon };
  if (!data && !error) {
    empty = {
      title: "Loading today's events",
      description: "Asking the Focus helper.",
      icon: Icon.Clock,
    };
  } else if (error) {
    empty = {
      title: "Focus helper unavailable",
      description: error,
      icon: Icon.ExclamationMark,
    };
  } else if (noCalendars) {
    empty = {
      title: "No startable calendars",
      description:
        "Pick the calendars you start sessions from in Focus Settings.",
      icon: Icon.Gear,
    };
  } else {
    empty = {
      title: "Nothing left today",
      description:
        "No events from your startable calendars end more than a minute from now.",
      icon: Icon.Calendar,
    };
  }

  return (
    <List isLoading={isLoading} navigationTitle="Focus Today">
      <List.EmptyView
        icon={empty.icon}
        title={empty.title}
        description={empty.description}
        actions={
          noCalendars && !error ? (
            <ActionPanel>
              <Action
                title="Open Focus Settings"
                icon={Icon.Gear}
                onAction={openSettings}
              />
              <Action
                title="Refresh"
                icon={Icon.ArrowClockwise}
                shortcut={{ modifiers: ["cmd"], key: "r" }}
                onAction={reload}
              />
            </ActionPanel>
          ) : (
            <ActionPanel>{commonActions}</ActionPanel>
          )
        }
      />
      {session && config ? (
        <List.Section title="Running">
          {renderSession(
            effectiveSession(session, data?.fetchedAt ?? now, now),
            config,
            data?.fetchedAt ?? now,
          )}
        </List.Section>
      ) : null}
      {groups.now.length > 0 ? (
        <List.Section title="Now" subtitle={`${groups.now.length}`}>
          {groups.now.map((event) => renderEvent(event, true))}
        </List.Section>
      ) : null}
      {groups.later.length > 0 ? (
        <List.Section title="Later" subtitle={`${groups.later.length}`}>
          {groups.later.map((event) => renderEvent(event, false))}
        </List.Section>
      ) : null}
      {waiting.length > 0 && config ? (
        <List.Section
          title="Waiting for log calendar"
          subtitle={`${waiting.length}`}
        >
          {waiting.map((item) => renderWaiting(item, config))}
        </List.Section>
      ) : null}
    </List>
  );
}
