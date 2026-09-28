import {
  Action,
  ActionPanel,
  Color,
  Icon,
  List,
  Toast,
  showToast,
} from "@raycast/api";
import { useCallback, useEffect, useRef, useState } from "react";
import { FocusConfig, readConfig } from "./lib/config";
import {
  RecentSession,
  STATS_DAYS,
  Stats,
  StatsWaiting,
  deleteToastText,
  errorMessage,
  getDaemon,
} from "./lib/daemon";
import { moveTarget } from "./lib/settings";
import {
  attemptsText,
  endReasonText,
  focusedText,
  lastDaysLabel,
  overviewMarkdown,
  ratingText,
  recentMarkdown,
  sessionsText,
  spanText,
  waitingMarkdown,
} from "./lib/stats";

interface Data {
  stats: Stats;
  // When the stats arrived; busts Raycast's image cache for the chart.
  loadedAt: number;
  // Only for the Move action's target; the stats work without it.
  config: FocusConfig | null;
}

const DAYS = STATS_DAYS.default;

export default function FocusStatsCommand() {
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  // Only the newest load may write state (a slow one never overwrites a
  // reload after Retry or Move).
  const latest = useRef(0);

  const reload = useCallback(async () => {
    const id = ++latest.current;
    setIsLoading(true);
    try {
      const [stats, config] = await Promise.all([
        getDaemon().stats(DAYS),
        readConfig().catch((): FocusConfig | null => null),
      ]);
      if (id !== latest.current) return;
      setData({ stats, config, loadedAt: Date.now() });
      setError(null);
    } catch (loadError) {
      if (id !== latest.current) return;
      setData(null);
      setError(errorMessage(loadError));
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not load Focus Stats",
        message: errorMessage(loadError),
      });
    } finally {
      if (id === latest.current) setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

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

  // No confirmation (the notes extension's ⌃X convention): the toast says
  // whether the calendar event went too.
  async function handleDelete(sessionId: number) {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Deleting session",
    });
    try {
      const result = await getDaemon().deleteSession(sessionId);
      const text = deleteToastText(result);
      toast.style = Toast.Style.Success;
      toast.title = text.title;
      toast.message = text.message;
    } catch (deleteError) {
      toast.style = Toast.Style.Failure;
      toast.title = "Could not delete the session";
      toast.message = errorMessage(deleteError);
    }
    await reload();
  }

  const deleteAction = (sessionId: number) => (
    <ActionPanel.Section>
      <Action
        title="Delete Session"
        icon={Icon.Trash}
        style={Action.Style.Destructive}
        shortcut={{ modifiers: ["ctrl"], key: "x" }}
        onAction={() => handleDelete(sessionId)}
      />
    </ActionPanel.Section>
  );

  const refresh = (
    <Action
      title="Refresh"
      icon={Icon.ArrowClockwise}
      shortcut={{ modifiers: ["cmd"], key: "r" }}
      onAction={reload}
    />
  );

  const now = new Date();
  const windowLabel = lastDaysLabel(DAYS);

  function renderOverview(stats: Stats, loadedAt: number) {
    const rows = [
      { key: "today", title: "Today", totals: stats.today },
      { key: "week", title: windowLabel, totals: stats.week },
    ];
    return rows.map((row) => (
      <List.Item
        key={row.key}
        icon={row.key === "today" ? Icon.Sun : Icon.BarChart}
        title={row.title}
        accessories={[
          { text: focusedText(row.totals.focusedSeconds), icon: Icon.Clock },
          // The list is narrow beside the detail: a count with a tooltip.
          {
            text: String(row.totals.sessions),
            icon: Icon.CheckCircle,
            tooltip: sessionsText(row.totals.sessions),
          },
        ]}
        detail={
          <List.Item.Detail
            markdown={overviewMarkdown({
              label: row.title,
              totals: row.totals,
              chartPath: stats.chartPath,
              chartVersion: loadedAt,
              windowLabel,
              perCalendar: stats.perCalendar,
            })}
          />
        }
        actions={<ActionPanel>{refresh}</ActionPanel>}
      />
    ));
  }

  function renderCalendars(stats: Stats) {
    return stats.perCalendar.map((row) => (
      <List.Item
        key={`calendar-${row.calendarId}|${row.calendarTitle}`}
        icon={row.calendarId === "adhoc" ? Icon.Bolt : Icon.Calendar}
        title={row.calendarTitle}
        accessories={[
          { text: focusedText(row.focusedSeconds), icon: Icon.Clock },
        ]}
        detail={
          <List.Item.Detail
            metadata={
              <List.Item.Detail.Metadata>
                <List.Item.Detail.Metadata.Label
                  title="Calendar"
                  text={row.calendarTitle}
                />
                <List.Item.Detail.Metadata.Label
                  title={`Focused, ${windowLabel.toLowerCase()}`}
                  text={focusedText(row.focusedSeconds)}
                />
                <List.Item.Detail.Metadata.Label
                  title="Sessions"
                  text={String(row.sessions)}
                />
              </List.Item.Detail.Metadata>
            }
          />
        }
        actions={<ActionPanel>{refresh}</ActionPanel>}
      />
    ));
  }

  function renderRecent(session: RecentSession) {
    const abandoned = session.endReason === "abandoned";
    const accessories: List.Item.Accessory[] = [];
    if (session.logPending) {
      accessories.push({
        icon: { source: Icon.Hourglass, tintColor: Color.Orange },
        tooltip: "Log event not written yet",
      });
    }
    // The list is narrow beside the detail (a rating clipped there in the
    // live check): calendar, span, stars and attempts are in the detail.
    accessories.push({
      text: focusedText(session.focusedSeconds),
      tooltip: session.rating === null ? undefined : ratingText(session.rating),
    });
    return (
      <List.Item
        key={`recent-${session.id}`}
        icon={
          abandoned
            ? {
                value: {
                  source: Icon.XMarkCircle,
                  tintColor: Color.SecondaryText,
                },
                tooltip: "Abandoned: the helper stopped during the session",
              }
            : { source: Icon.CheckCircle, tintColor: Color.Green }
        }
        title={session.goal}
        accessories={accessories}
        detail={
          <List.Item.Detail
            markdown={recentMarkdown(session)}
            metadata={
              <List.Item.Detail.Metadata>
                <List.Item.Detail.Metadata.Label
                  title="Calendar"
                  text={session.calendarTitle}
                />
                <List.Item.Detail.Metadata.Label
                  title="When"
                  text={spanText(session.startedAt, session.endedAt, now)}
                />
                <List.Item.Detail.Metadata.Label
                  title="Focused"
                  text={focusedText(session.focusedSeconds)}
                />
                <List.Item.Detail.Metadata.Label
                  title="Rating"
                  text={ratingText(session.rating)}
                />
                <List.Item.Detail.Metadata.Label
                  title="Blocked attempts"
                  text={attemptsText(session)}
                />
                <List.Item.Detail.Metadata.Label
                  title="Ended"
                  text={endReasonText(session.endReason)}
                />
                {session.logPending ? (
                  <List.Item.Detail.Metadata.Label
                    title="Log event"
                    text="waiting for the log calendar"
                  />
                ) : null}
              </List.Item.Detail.Metadata>
            }
          />
        }
        actions={
          <ActionPanel>
            <Action.CopyToClipboard title="Copy Goal" content={session.goal} />
            {refresh}
            {deleteAction(session.id)}
          </ActionPanel>
        }
      />
    );
  }

  function renderWaiting(item: StatsWaiting, config: FocusConfig | null) {
    const target = config ? moveTarget(config) : null;
    const calendar = item.logCalendarName ?? "a log calendar";
    return (
      <List.Item
        key={`waiting-${item.sessionId}`}
        icon={{ source: Icon.Hourglass, tintColor: Color.Orange }}
        title={item.goal}
        subtitle={`waiting for ${calendar}`}
        detail={
          <List.Item.Detail markdown={waitingMarkdown(item.logCalendarName)} />
        }
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
            {refresh}
            {deleteAction(item.sessionId)}
          </ActionPanel>
        }
      />
    );
  }

  const stats = data?.stats;
  return (
    <List
      isLoading={isLoading}
      isShowingDetail={Boolean(stats)}
      navigationTitle="Focus Stats"
    >
      <List.EmptyView
        icon={error ? Icon.ExclamationMark : Icon.BarChart}
        title={error ? "Focus helper unavailable" : "Loading stats"}
        description={error ?? "Asking the Focus helper."}
        actions={<ActionPanel>{refresh}</ActionPanel>}
      />
      {stats ? (
        <List.Section title="Overview">
          {renderOverview(stats, data?.loadedAt ?? 0)}
        </List.Section>
      ) : null}
      {stats && stats.perCalendar.length > 0 ? (
        <List.Section title="By calendar" subtitle={windowLabel}>
          {renderCalendars(stats)}
        </List.Section>
      ) : null}
      {stats && stats.recent.length > 0 ? (
        <List.Section
          title="Recent sessions"
          subtitle={`${stats.recent.length}`}
        >
          {stats.recent.map(renderRecent)}
        </List.Section>
      ) : null}
      {stats && data && stats.waiting.length > 0 ? (
        <List.Section
          title="Waiting for log calendar"
          subtitle={`${stats.waiting.length}`}
        >
          {stats.waiting.map((item) => renderWaiting(item, data.config))}
        </List.Section>
      ) : null}
    </List>
  );
}
