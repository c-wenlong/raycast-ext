// The command handlers behind the socket. Everything here runs on one serial
// queue (main.swift), so sqlite and EventKit are never used concurrently.
// The calendar is reached through CalendarBackend, which EventKitBackend
// implements for real and the test harness fakes.

import Foundation

struct CalendarInfo: Equatable {
  var id: String
  var title: String
  var account: String
  var color: String?
  var writable: Bool

  /// "<title> (<account>)", the form stored as log_calendar_name.
  var displayName: String { "\(title) (\(account))" }
}

protocol CalendarBackend: LogCalendarStore {
  /// "fullAccess", "notDetermined", "denied", "restricted" or "writeOnly".
  var accessState: String { get }
  /// Shows the permission prompt if it has never been answered.
  func requestAccessIfNeeded()
  /// Notices access granted outside the prompt (System Settings) and
  /// returns true when it just became usable.
  func refreshAccess() -> Bool
  func calendars() -> [CalendarInfo]
  func calendar(id: String) -> CalendarInfo?
  /// Occurrences overlapping [start, end); `calendarIds` nil means all.
  func events(from start: Date, to end: Date, calendarIds: [String]?) -> [CalendarEvent]
}

final class FocusCore {
  static let version = "0.1.0"

  let config: ConfigFile
  let db: Database
  let calendar: CalendarBackend
  private let clock: () -> Date
  private let log: (String) -> Void
  /// Last recovery outcome per waiting session, for `pending` and so the log
  /// records a reason once instead of every 30 seconds.
  private var waitingReasons: [Int64: String] = [:]
  /// Extra commands (debug*) handled outside the core, or nil.
  var extraHandler: ((Request) throws -> Reply?)?

  init(
    config: ConfigFile, db: Database, calendar: CalendarBackend, clock: @escaping () -> Date = Date.init,
    log: @escaping (String) -> Void = { _ in }
  ) {
    self.config = config
    self.db = db
    self.calendar = calendar
    self.clock = clock
    self.log = log
  }

  private var now: Date { ISO.wholeSeconds(clock()) }

  // MARK: Dispatch

  func handle(line: String) -> Reply {
    if calendar.refreshAccess() { tick() }
    do {
      return try handle(try Request(line: line))
    } catch let error as FocusError {
      return .failure(error)
    } catch {
      return .failure(FocusError(error.localizedDescription))
    }
  }

  func handle(_ request: Request) throws -> Reply {
    switch request.cmd {
    case "ping":
      return .ok([
        "version": .string(FocusCore.version),
        "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
        "calendarAccess": .string(calendar.accessState),
      ])
    case "calendars": return try calendarsReply()
    case "today": return try todayReply()
    case "status": return .ok(["session": try db.openSession().map(sessionJSON) ?? .null])
    case "start": return try start(request)
    case "startAdhoc": return try startAdhoc(request)
    case "finish": return try finish(request)
    case "pending": return .ok(["waiting": try pendingJSON()])
    case "retryPending": return .ok(countsJSON(try runRecovery()))
    case "movePending": return try movePending(request)
    case "quit":
      var reply = Reply.ok()
      reply.quit = true
      return reply
    default:
      if let reply = try extraHandler?(request) { return reply }
      throw FocusError("unknown command: \(request.cmd)")
    }
  }

  /// The 30-second tick: heartbeat for the running session, then recovery.
  func tick() {
    _ = calendar.refreshAccess()
    do {
      if let open = try db.openSession() { try db.heartbeat(open.id, at: now) }
    } catch {
      log("heartbeat failed: \(error.localizedDescription)")
    }
    do {
      _ = try runRecovery()
    } catch {
      log("recovery failed: \(error.localizedDescription)")
    }
  }

  // MARK: Calendars and today

  private func requireAccess() throws {
    let state = calendar.accessState
    guard state == "fullAccess" else {
      calendar.requestAccessIfNeeded()
      let hint =
        state == "notDetermined"
        ? "answer the Calendar permission prompt for focus-daemon"
        : "allow focus-daemon in System Settings > Privacy & Security > Calendars"
      throw FocusError("calendar access is \(state); \(hint)", extra: ["calendarAccess": .string(state)])
    }
  }

  private func calendarsReply() throws -> Reply {
    try requireAccess()
    let list = calendar.calendars().sorted {
      ($0.title.lowercased(), $0.account.lowercased(), $0.id) < ($1.title.lowercased(), $1.account.lowercased(), $1.id)
    }
    return .ok([
      "calendars": .array(
        list.map {
          [
            "id": .string($0.id), "title": .string($0.title), "account": .string($0.account),
            "color": .optional($0.color), "writable": .bool($0.writable),
          ]
        })
    ])
  }

  private func todayReply() throws -> Reply {
    try requireAccess()
    let settings = config.load()
    let now = self.now
    let day = Rules.day(containing: now)
    let ids = settings.startableCalendars
    let events = ids.isEmpty ? [] : calendar.events(from: day.start, to: day.end, calendarIds: ids)
    let list = Rules.startable(events, calendarIds: Set(ids), now: now)
    return .ok([
      "events": .array(
        list.map {
          [
            "id": .string($0.id), "title": .string($0.title), "calendarId": .string($0.calendarId),
            "calendarTitle": .string($0.calendarTitle), "start": .string(ISO.local($0.start)),
            "end": .string(ISO.local($0.end)),
            "remainingSeconds": .int(Rules.remainingSeconds(until: $0.end, now: now)),
          ]
        })
    ])
  }

  // MARK: Starting

  private func refuseIfRunning() throws {
    guard let open = try db.openSession() else { return }
    let until = open.plannedEnd.map { " until \(ISO.local($0))" } ?? ""
    throw FocusError(
      "a session is already running: \"\(open.goal)\" (id \(open.id))\(until); finish it first",
      extra: ["session": sessionJSON(open)])
  }

  private func start(_ request: Request) throws -> Reply {
    let eventId = try request.requiredString("eventId")
    var requestedStart: Date?
    if let text = try request.string("start") {
      guard let date = ISO.parse(text) else { throw FocusError("start must be an ISO 8601 date") }
      requestedStart = date
    }
    try refuseIfRunning()
    try requireAccess()
    let now = self.now
    let day = Rules.day(containing: now)
    let candidates = calendar.events(from: day.start, to: day.end, calendarIds: nil)
    let event = try Rules.pickOccurrence(candidates, eventId: eventId, requestedStart: requestedStart, now: now).get()
    let settings = config.load()
    let id = try db.insertSession(
      NewSession(
        sourceEventId: event.id, calendarId: event.calendarId,
        goal: event.title.isEmpty ? "Untitled event" : event.title,
        profile: settings.profile(for: event.calendarId), plannedStart: event.start,
        plannedEnd: Rules.sessionEnd(for: event), startedAt: now))
    return .ok(["session": try sessionJSON(id)])
  }

  private func startAdhoc(_ request: Request) throws -> Reply {
    let goal = LogText.oneLine(try request.requiredString("goal"))
    guard let duration = try request.double("durationSeconds") else {
      throw FocusError("durationSeconds is required")
    }
    let calendarId = try request.requiredString("calendarId")
    let profile = try request.string("profile")?.trimmingCharacters(in: .whitespacesAndNewlines)
    try refuseIfRunning()
    let now = self.now
    let plan = try Rules.adhocPlan(now: now, durationSeconds: duration).get()
    let settings = config.load()
    let id = try db.insertSession(
      NewSession(
        sourceEventId: nil, calendarId: calendarId, goal: goal,
        profile: (profile?.isEmpty == false ? profile : nil) ?? settings.profile(for: calendarId),
        plannedStart: plan.start, plannedEnd: plan.end, startedAt: now))
    return .ok(["session": try sessionJSON(id)])
  }

  // MARK: Finishing and the log event

  private func finish(_ request: Request) throws -> Reply {
    let rating = try request.int("rating")
    if let rating, !(1...5).contains(rating) { throw FocusError("rating must be 1 to 5") }
    let note = try request.string("note")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reason = try request.string("reason") ?? "manual"
    guard reason == "timer" || reason == "manual" else {
      throw FocusError("reason must be \"timer\" or \"manual\"")
    }
    guard let open = try db.openSession() else { throw FocusError("no session is running") }

    // Step 1: close the row and fix its destination before touching EventKit.
    let settings = config.load()
    let logCalendarId = settings.logCalendarId
    var logCalendarName = settings.logCalendarName
    if logCalendarName == nil, let logCalendarId, calendar.accessState == "fullAccess" {
      logCalendarName = calendar.calendar(id: logCalendarId)?.displayName
    }
    let close = SessionClose(
      endedAt: max(now, open.startedAt), endReason: reason, rating: rating,
      note: (note?.isEmpty == false) ? note : nil, logCalendarId: logCalendarId, logCalendarName: logCalendarName)
    guard try db.finish(open.id, close) else { throw FocusError("the session had already ended") }

    // Steps 2 and 3: write (or adopt) the log event now; on failure the row
    // waits for the 30-second tick.
    guard let row = try db.session(id: open.id) else { throw FocusError("session \(open.id) vanished") }
    let outcome = try writeLogEvent(for: row)
    var logEventId: String?
    switch outcome {
    case .created(let id), .adopted(let id): logEventId = id
    case .waiting: break
    }
    return .ok([
      "session": try sessionJSON(open.id),
      "logEventId": .optional(logEventId),
      "logPending": .bool(logEventId == nil),
    ])
  }

  func logSummary(for row: SessionRow) throws -> LogSummary {
    let sourceTitle: String? =
      calendar.accessState == "fullAccess" ? calendar.calendar(id: row.calendarId)?.title : nil
    return LogSummary(
      sessionId: row.id, sourceCalendarId: row.calendarId, sourceCalendarTitle: sourceTitle,
      sourceEventId: row.sourceEventId, startedAt: row.startedAt, endedAt: row.endedAt ?? row.startedAt,
      endReason: row.endReason ?? "manual", extendedSeconds: row.extendedSeconds, pauses: try db.pauses(row.id),
      attempts: try db.attempts(row.id), rating: row.rating, note: row.note)
  }

  /// One pass of adopt-or-create for one finished row; stores the id on success.
  private func writeLogEvent(for row: SessionRow) throws -> RecoveryOutcome {
    let outcome: RecoveryOutcome
    if calendar.accessState != "fullAccess" {
      outcome = .waiting("calendar access is \(calendar.accessState)")
    } else {
      let summary = try logSummary(for: row)
      let draft = LogEventDraft(
        title: row.goal, start: summary.startedAt, end: summary.endedAt, notes: LogText.description(summary))
      outcome = Recovery.resolve(
        WaitingSession(sessionId: row.id, logCalendarId: row.logCalendarId, draft: draft), store: calendar)
    }
    switch outcome {
    case .created(let id), .adopted(let id):
      waitingReasons[row.id] = nil
      do {
        try db.setLogEventId(row.id, id)
      } catch {
        // The event exists and carries the marker: the next tick adopts it.
        log("session \(row.id): log event \(id) saved but its id was not stored: \(error.localizedDescription)")
      }
      if case .adopted = outcome { log("session \(row.id): adopted log event \(id)") }
    case .waiting(let reason):
      if waitingReasons[row.id] != reason { log("session \(row.id): log event waiting: \(reason)") }
      waitingReasons[row.id] = reason
    }
    return outcome
  }

  /// Recovery over every waiting row (launch, every 30 s, retryPending).
  func runRecovery() throws -> RecoveryCounts {
    var outcomes: [RecoveryOutcome] = []
    for row in try db.waitingSessions() {
      outcomes.append(try writeLogEvent(for: row))
    }
    return Recovery.tally(outcomes)
  }

  private func pendingJSON() throws -> JSONValue {
    .array(
      try db.waitingSessions().map { row in
        [
          "sessionId": .int(Int(row.id)), "goal": .string(row.goal),
          "endedAt": .optional(row.endedAt.map { ISO.local($0) }), "logCalendarId": .optional(row.logCalendarId),
          "logCalendarName": .optional(row.logCalendarName), "reason": .optional(waitingReasons[row.id]),
        ]
      })
  }

  private func movePending(_ request: Request) throws -> Reply {
    let calendarId = try request.requiredString("calendarId")
    try requireAccess()
    guard let target = calendar.calendar(id: calendarId) else {
      throw FocusError("no calendar with id \(calendarId)")
    }
    guard target.writable else { throw FocusError("\(target.displayName) is read-only") }
    let moved = try db.moveWaiting(toCalendar: calendarId, name: target.displayName)
    for id in waitingReasons.keys { waitingReasons[id] = nil }
    var fields = countsJSON(try runRecovery())
    fields["moved"] = .int(moved)
    return .ok(fields)
  }

  private func countsJSON(_ counts: RecoveryCounts) -> [String: JSONValue] {
    ["written": .int(counts.written), "adopted": .int(counts.adopted), "stillWaiting": .int(counts.stillWaiting)]
  }

  // MARK: Session JSON

  private func sessionJSON(_ id: Int64) throws -> JSONValue {
    guard let row = try db.session(id: id) else { throw FocusError("session \(id) not found") }
    return sessionJSON(row)
  }

  /// running | paused for an open session (paused = an open pause row);
  /// finished rows also carry their end, rating, note and log fields.
  func sessionJSON(_ row: SessionRow) -> JSONValue {
    var fields: [String: JSONValue] = [
      "id": .int(Int(row.id)), "goal": .string(row.goal), "startedAt": .string(ISO.local(row.startedAt)),
      "plannedEnd": .optional(row.plannedEnd.map { ISO.local($0) }), "calendarId": .string(row.calendarId),
      "profile": .string(row.profile), "sourceEventId": .optional(row.sourceEventId),
    ]
    if let endedAt = row.endedAt {
      fields["state"] = "finished"
      fields["endedAt"] = .string(ISO.local(endedAt))
      fields["endReason"] = .optional(row.endReason)
      fields["rating"] = .optional(row.rating)
      fields["note"] = .optional(row.note)
      fields["logCalendarId"] = .optional(row.logCalendarId)
      fields["logCalendarName"] = .optional(row.logCalendarName)
      fields["logEventId"] = .optional(row.logEventId)
    } else {
      let paused = ((try? db.pauses(row.id)) ?? []).contains { $0.end == nil }
      fields["state"] = paused ? "paused" : "running"
    }
    return .object(fields)
  }
}
