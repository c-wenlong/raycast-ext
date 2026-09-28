// The numbers behind Focus Stats (PLAN.md "Stats view"). Pure: FocusCore reads
// the rows from sqlite and the calendar titles from the backend, and these
// functions turn them into the `stats` reply, so the aggregation is tested
// with fixture rows and a fixed clock.
//
// Rules:
// - Focused seconds of a session = (ended_at - started_at) - closed pauses,
//   never negative (LogText.focusedSeconds). Inside a window only the part
//   of the session and of its pauses that falls in the window counts, so a
//   session across midnight splits between the two days.
// - Days are local calendar days from Calendar (midnight to midnight), so a
//   DST day is 23 or 25 hours long and nothing drifts.
// - A running session (ended_at null) is left out everywhere; an abandoned
//   one counts, with no rating.
// - A session belongs to a window (its session count, average rating and
//   calendar row) when it started inside it or was still going when the
//   window began.

import Foundation

/// One finished or abandoned session with what the stats need from its
/// pauses and blocked attempts.
struct StatsRow: Equatable {
  var id: Int64
  var goal: String
  var calendarId: String
  var sourceEventId: String?
  var startedAt: Date
  var endedAt: Date?
  var endReason: String?
  var rating: Int?
  var note: String?
  var logCalendarId: String?
  var logCalendarName: String?
  var logEventId: String?
  var logSkipped: Bool = false
  var pauses: [PauseSpan] = []
  /// Every blocked_attempts row, as the log event counts them.
  var attempts: Int = 0
  /// The rows among them with outcome "snoozed".
  var snoozes: Int = 0

  init(
    id: Int64, goal: String, calendarId: String, sourceEventId: String? = nil, startedAt: Date, endedAt: Date?,
    endReason: String? = nil, rating: Int? = nil, note: String? = nil, logCalendarId: String? = nil,
    logCalendarName: String? = nil, logEventId: String? = nil, logSkipped: Bool = false, pauses: [PauseSpan] = [], attempts: Int = 0,
    snoozes: Int = 0
  ) {
    self.id = id
    self.goal = goal
    self.calendarId = calendarId
    self.sourceEventId = sourceEventId
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.endReason = endReason
    self.rating = rating
    self.note = note
    self.logCalendarId = logCalendarId
    self.logCalendarName = logCalendarName
    self.logEventId = logEventId
    self.logSkipped = logSkipped
    self.pauses = pauses
    self.attempts = attempts
    self.snoozes = snoozes
  }

  init(_ row: SessionRow, pauses: [PauseSpan], attempts: Int, snoozes: Int) {
    self.init(
      id: row.id, goal: row.goal, calendarId: row.calendarId, sourceEventId: row.sourceEventId,
      startedAt: row.startedAt, endedAt: row.endedAt, endReason: row.endReason, rating: row.rating, note: row.note,
      logCalendarId: row.logCalendarId, logCalendarName: row.logCalendarName, logEventId: row.logEventId,
      logSkipped: row.logSkipped,
      pauses: pauses, attempts: attempts, snoozes: snoozes)
  }

  /// Finished and owed a log event (abandoned sessions never get one).
  var logPending: Bool { endedAt != nil && endReason != "abandoned" && logEventId == nil && !logSkipped }
}

/// How a session's calendar is named. With Calendar access, `titles` holds
/// every calendar EventKit knows; without it, it is empty.
struct CalendarNames: Equatable {
  var access: Bool
  var titles: [String: String]

  static let adHocId = "adhoc"
  static let adHocTitle = "Ad hoc"
  static let unknownTitle = "Unknown calendar"

  /// The perCalendar row a session counts under. An ad-hoc session filed
  /// under something that is not a calendar (no id, or an id EventKit does
  /// not know while access is granted) goes to "Ad hoc". Otherwise the
  /// calendar's title; without access (or once the calendar is gone) the
  /// log calendar's stored name when the session was filed under it, else
  /// "Unknown calendar".
  func bucket(for row: StatsRow) -> (id: String, title: String) {
    if let title = titles[row.calendarId] { return (row.calendarId, title) }
    if row.sourceEventId == nil && (row.calendarId.isEmpty || access) {
      return (CalendarNames.adHocId, CalendarNames.adHocTitle)
    }
    if row.calendarId == row.logCalendarId, let name = row.logCalendarName, !name.isEmpty {
      return (row.calendarId, name)
    }
    return (row.calendarId, CalendarNames.unknownTitle)
  }
}

struct StatsTotals: Equatable {
  var focusedSeconds: Int
  var sessions: Int
  /// Mean of the sessions that have a rating, to two decimals; nil when none do.
  var averageRating: Double?
}

struct CalendarTotal: Equatable {
  var calendarId: String
  var calendarTitle: String
  var focusedSeconds: Int
  var sessions: Int
}

struct DayTotal: Equatable {
  /// Local midnight that starts the day.
  var start: Date
  /// "2026-09-22": the local day, written in the Gregorian calendar.
  var date: String
  /// 1 is Sunday, as Calendar numbers weekdays.
  var weekday: Int
  var focusedSeconds: Int
}

struct StatsReport: Equatable {
  var today: StatsTotals
  var week: StatsTotals
  var perCalendar: [CalendarTotal]
  var days: [DayTotal]
  /// Newest first, as given.
  var recent: [StatsRow]
  var recentTitles: [String]
}

enum Stats {
  static let defaultDays = 7
  static let dayRange = 1...90
  static let recentLimit = 20

  /// The local days of the window, oldest first: `days` of them, the last
  /// one today.
  static func dayIntervals(days: Int, now: Date, calendar: Calendar = .current) -> [DateInterval] {
    let today = calendar.startOfDay(for: now)
    return (0..<max(1, days)).reversed().map { back in
      let start = calendar.date(byAdding: .day, value: -back, to: today) ?? today
      let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
      return DateInterval(start: start, end: end)
    }
  }

  /// Local midnight `days - 1` days ago to the next local midnight.
  static func window(days: Int, now: Date, calendar: Calendar = .current) -> DateInterval {
    let intervals = dayIntervals(days: days, now: now, calendar: calendar)
    return DateInterval(start: intervals.first!.start, end: intervals.last!.end)
  }

  /// Seconds of [a, b] inside `interval` (the whole of it when nil).
  private static func overlap(_ a: Date, _ b: Date, _ interval: DateInterval?) -> TimeInterval {
    let from = interval.map { max(a, $0.start) } ?? a
    let to = interval.map { min(b, $0.end) } ?? b
    return max(0, to.timeIntervalSince(from))
  }

  /// Focused seconds of a finished session, or of its part inside
  /// `interval`: the span minus the pauses within it, never negative. A
  /// pause still open at the end runs to the end. Nil `interval` gives the
  /// same number as the log event's "Focused" line.
  static func focusedSeconds(_ row: StatsRow, within interval: DateInterval? = nil) -> Int {
    guard let endedAt = row.endedAt, endedAt > row.startedAt else { return 0 }
    let span = overlap(row.startedAt, endedAt, interval)
    let paused = row.pauses.reduce(0.0) { sum, pause in
      let from = max(pause.start, row.startedAt)
      let to = min(pause.end ?? endedAt, endedAt)
      guard to > from else { return sum }
      return sum + overlap(from, to, interval)
    }
    return max(0, Int(span.rounded()) - Int(paused.rounded()))
  }

  /// Started inside the window, or started before it and still going when
  /// it began. Running sessions never belong.
  static func belongs(_ row: StatsRow, to interval: DateInterval) -> Bool {
    guard let endedAt = row.endedAt else { return false }
    if row.startedAt >= interval.start { return row.startedAt < interval.end }
    return endedAt > interval.start
  }

  static func totals(_ rows: [StatsRow], in interval: DateInterval) -> StatsTotals {
    let members = rows.filter { belongs($0, to: interval) }
    let ratings = members.compactMap(\.rating)
    let average =
      ratings.isEmpty ? nil : (Double(ratings.reduce(0, +)) / Double(ratings.count) * 100).rounded() / 100
    return StatsTotals(
      focusedSeconds: members.reduce(0) { $0 + focusedSeconds($1, within: interval) }, sessions: members.count,
      averageRating: average)
  }

  /// One row per calendar with a session in the window, most focused first
  /// (ties by title, then id).
  static func perCalendar(_ rows: [StatsRow], in interval: DateInterval, names: CalendarNames) -> [CalendarTotal] {
    var byId: [String: CalendarTotal] = [:]
    for row in rows where belongs(row, to: interval) {
      let bucket = names.bucket(for: row)
      var total =
        byId[bucket.id]
        ?? CalendarTotal(calendarId: bucket.id, calendarTitle: bucket.title, focusedSeconds: 0, sessions: 0)
      total.focusedSeconds += focusedSeconds(row, within: interval)
      total.sessions += 1
      byId[bucket.id] = total
    }
    return byId.values.sorted {
      ($0.focusedSeconds, $1.calendarTitle.lowercased(), $1.calendarId)
        > ($1.focusedSeconds, $0.calendarTitle.lowercased(), $0.calendarId)
    }
  }

  /// The Gregorian calendar in `calendar`'s time zone: `date` strings and
  /// chart labels are Gregorian whatever calendar the Mac is set to, while
  /// the day boundaries stay local midnight.
  static func gregorian(like calendar: Calendar) -> Calendar {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    gregorian.locale = calendar.locale
    return gregorian
  }

  /// Every day of the window, oldest first, zero-filled.
  static func days(_ rows: [StatsRow], days: Int, now: Date, calendar: Calendar = .current) -> [DayTotal] {
    let gregorian = gregorian(like: calendar)
    return dayIntervals(days: days, now: now, calendar: calendar).map { day in
      let parts = gregorian.dateComponents([.year, .month, .day, .weekday], from: day.start)
      let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
      let seconds = rows.reduce(0) { $0 + focusedSeconds($1, within: day) }
      return DayTotal(start: day.start, date: date, weekday: parts.weekday ?? 1, focusedSeconds: seconds)
    }
  }

  /// `windowRows`: the finished sessions that may overlap the window (more
  /// is fine, they are filtered); `recent`: the newest finished sessions,
  /// newest first. Running rows in either are dropped.
  static func report(
    windowRows: [StatsRow], recent: [StatsRow], names: CalendarNames, days: Int, now: Date,
    calendar: Calendar = .current
  ) -> StatsReport {
    let finished = windowRows.filter { $0.endedAt != nil }
    let intervals = dayIntervals(days: days, now: now, calendar: calendar)
    let week = DateInterval(start: intervals.first!.start, end: intervals.last!.end)
    let latest = Array(recent.filter { $0.endedAt != nil }.prefix(recentLimit))
    return StatsReport(
      today: totals(finished, in: intervals.last!), week: totals(finished, in: week),
      perCalendar: perCalendar(finished, in: week, names: names),
      days: self.days(finished, days: days, now: now, calendar: calendar), recent: latest,
      recentTitles: latest.map { names.bucket(for: $0).title })
  }

  // MARK: JSON

  static func json(_ totals: StatsTotals) -> JSONValue {
    [
      "focusedSeconds": .int(totals.focusedSeconds), "sessions": .int(totals.sessions),
      "averageRating": totals.averageRating.map(JSONValue.double) ?? .null,
    ]
  }

  /// Every field of the reply but `waiting` and `chartPath`, which need sqlite and the disk.
  static func json(_ report: StatsReport) -> [String: JSONValue] {
    [
      "today": json(report.today),
      "week": json(report.week),
      "perCalendar": .array(
        report.perCalendar.map {
          [
            "calendarId": .string($0.calendarId), "calendarTitle": .string($0.calendarTitle),
            "focusedSeconds": .int($0.focusedSeconds), "sessions": .int($0.sessions),
          ]
        }),
      "days": .array(report.days.map { ["date": .string($0.date), "focusedSeconds": .int($0.focusedSeconds)] }),
      "recent": .array(
        zip(report.recent, report.recentTitles).map { row, title in
          [
            "id": .int(Int(row.id)), "goal": .string(row.goal), "calendarTitle": .string(title),
            "startedAt": .string(ISO.local(row.startedAt)),
            "endedAt": .string(ISO.local(row.endedAt ?? row.startedAt)),
            "focusedSeconds": .int(focusedSeconds(row)), "rating": .optional(row.rating), "note": .optional(row.note),
            "endReason": .optional(row.endReason), "blockedAttempts": .int(row.attempts),
            "snoozes": .int(row.snoozes), "logPending": .bool(row.logPending), "logSkipped": .bool(row.logSkipped),
          ]
        }),
    ]
  }
}
