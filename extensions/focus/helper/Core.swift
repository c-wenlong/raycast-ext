// The command handlers behind the socket, the session timer and the bridge
// to the UI. Everything here runs on one serial queue (`queue`), so sqlite,
// EventKit and the session state are never used concurrently: socket
// requests, the 30-second tick, the 1 Hz session tick and calls from the UI
// (SessionPresenterDelegate) all go through it. Pass the daemon's work queue
// as `queue` so EventKit's own callbacks share it; without one the core makes
// its own and every entry point hops onto it (a nested sync, never a deadlock:
// the core never waits on the caller's queue).
// The calendar is reached through CalendarBackend, which EventKitBackend
// implements for real and the test harness fakes. The session lifecycle is
// SessionMachine (Session.swift); this file persists what it does and shows
// it through `presenter`, whose calls always arrive on the main thread.

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

/// The presenter until a UI attaches (and in a headless daemon). Unlike
/// NullPresenter, which records every call for tests, it keeps nothing, so a
/// long-running daemon does not collect a view a second.
private final class DiscardingPresenter: SessionPresenter {
  weak var delegate: SessionPresenterDelegate?
  func update(_ view: SessionView?) {}
  func showEndSheet(_ view: SessionView) {}
  func dismissEndSheet() {}
}

final class FocusCore: SessionPresenterDelegate {
  static let version = "0.2.0"
  /// At launch, an open session whose heartbeat is older than this is
  /// abandoned; a fresher one (the helper restarted quickly) carries on.
  static let abandonAfter: TimeInterval = 90

  let config: ConfigFile
  let db: Database
  let calendar: CalendarBackend
  let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Bool>()
  private let clock: () -> Date
  private let log: (String) -> Void
  private let usesTimer: Bool
  /// Last recovery outcome per waiting session, for `pending` and so the log
  /// records a reason once instead of every 30 seconds.
  private var waitingReasons: [Int64: String] = [:]
  /// Extra commands (debug*) handled outside the core, or nil.
  var extraHandler: ((Request) throws -> Reply?)?
  /// Opens the Raycast deeplink; tests record the URL instead.
  var openURL: (URL) -> Void
  /// Runs presenter calls: on the main queue in the daemon, inline in tests.
  var runOnMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

  /// The open session: its row as read at start or recovery, the state
  /// machine, and the calendar title the UI shows.
  private struct Active {
    var row: SessionRow
    var machine: SessionMachine
    var calendarTitle: String
  }

  private var active: Active?
  private var secondTimer: DispatchSourceTimer?
  /// True while the 1 Hz session tick is scheduled, which is exactly while a
  /// session exists.
  private(set) var ticking = false
  private var storedPresenter: SessionPresenter = DiscardingPresenter()

  /// The UI. Setting it makes the core its delegate and shows the current
  /// session at once (the end sheet too, if the session is waiting at it).
  var presenter: SessionPresenter {
    get { onQueue { storedPresenter } }
    set {
      newValue.delegate = self
      onQueue {
        storedPresenter = newValue
        publish(active?.machine.state == .ending ? .show : .keep)
      }
    }
  }

  /// Creating the core runs launch recovery, so a presenter that must see
  /// it (tests) is passed here. `secondTimer: false` leaves the 1 Hz tick to
  /// the caller (`secondTick()`), and `runOnMain` replaces the main-queue
  /// hop, both for tests on a fake clock.
  init(
    config: ConfigFile, db: Database, calendar: CalendarBackend, clock: @escaping () -> Date = Date.init,
    log: @escaping (String) -> Void = { _ in }, queue: DispatchQueue? = nil, secondTimer: Bool = true,
    presenter: SessionPresenter? = nil, runOnMain: ((@escaping () -> Void) -> Void)? = nil,
    openURL: ((URL) -> Void)? = nil
  ) {
    self.config = config
    self.db = db
    self.calendar = calendar
    self.clock = clock
    self.log = log
    self.queue = queue ?? DispatchQueue(label: "focus-core")
    self.usesTimer = secondTimer
    self.openURL = openURL ?? { FocusCore.open($0, log: log) }
    if let runOnMain { self.runOnMain = runOnMain }
    if let presenter { storedPresenter = presenter }
    storedPresenter.delegate = self
    self.queue.setSpecific(key: queueKey, value: true)
    onQueue {
      do {
        _ = try current()
      } catch {
        log("launch recovery failed: \(error.localizedDescription)")
      }
    }
  }

  private var now: Date { ISO.wholeSeconds(clock()) }

  /// Runs `body` on the core's queue, inline when already there.
  private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
    return try queue.sync(execute: body)
  }

  /// Waits until everything queued so far (UI calls included) has run.
  func drain() { queue.sync {} }

  // MARK: Dispatch

  func handle(line: String) -> Reply {
    onQueue {
      if calendar.refreshAccess() { tick() }
      do {
        return try handle(try Request(line: line))
      } catch let error as FocusError {
        return .failure(error)
      } catch {
        return .failure(FocusError(error.localizedDescription))
      }
    }
  }

  func handle(_ request: Request) throws -> Reply {
    try onQueue {
      // A command never acts on a session whose deadline passed unnoticed.
      try advance()
      switch request.cmd {
      case "ping":
        return .ok([
          "version": .string(FocusCore.version),
          "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
          "calendarAccess": .string(calendar.accessState),
        ])
      case "calendars": return try calendarsReply()
      case "today": return try todayReply()
      case "status":
        _ = try current()
        return .ok(["session": activeJSON()])
      case "start": return try start(request)
      case "startAdhoc": return try startAdhoc(request)
      case "pause": return try change(.pause(at: now))
      case "resume": return try change(.resume(at: now))
      case "extend":
        guard let seconds = try request.int("seconds") else { throw FocusError("seconds is required") }
        return try change(.extend(seconds: seconds, at: now))
      case "stop": return try change(.stop(at: now))
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
  }

  /// The 30-second tick: heartbeat for the open session, then recovery.
  func tick() {
    onQueue {
      _ = calendar.refreshAccess()
      do {
        if let open = try current() {
          try db.heartbeat(open.row.id, at: now)
          refreshCalendarTitle()
        }
      } catch {
        log("heartbeat failed: \(error.localizedDescription)")
      }
      do {
        _ = try runRecovery()
      } catch {
        log("recovery failed: \(error.localizedDescription)")
      }
    }
  }

  /// The 1 Hz tick while a session exists: checks the deadline and refreshes
  /// the UI. The timer calls it; tests call it after moving the clock.
  func secondTick() {
    onQueue {
      guard active != nil else {
        stopTicking()
        return
      }
      do {
        try advance()
      } catch {
        log("session tick failed: \(error.localizedDescription)")
      }
      publish(.keep)
    }
  }

  // MARK: The open session

  /// The open session, recovering it from sqlite first if memory has none
  /// (launch, or a row written behind the core's back).
  private func current() throws -> Active? {
    for _ in 0..<8 {
      if active != nil { break }
      guard let row = try db.openSession() else { break }
      try recover(row)
    }
    return active
  }

  /// Launch recovery for one open row. A stale heartbeat means the helper
  /// died with the session open (quit, crash, the Mac slept through it): the
  /// row closes as abandoned at its last heartbeat, with no rating and no
  /// log event. A fresh one means a quick restart: the session carries on as
  /// running, paused or at the end sheet.
  private func recover(_ row: SessionRow) throws {
    let pauses = try db.pauses(row.id)
    var machine = SessionMachine(
      restoring: row.startedAt, plannedEnd: row.deadline ?? row.startedAt, extendedSeconds: row.extendedSeconds,
      pauses: pauses, endingReason: row.endReason.flatMap(EndReason.init(rawValue:)))
    let now = self.now
    if now.timeIntervalSince(row.lastHeartbeat) > FocusCore.abandonAfter {
      _ = try machine.apply(.abandon(at: row.lastHeartbeat)).get()
      let close = SessionClose(endedAt: machine.endedAt ?? row.lastHeartbeat, endReason: EndReason.abandoned.rawValue)
      if try db.finish(row.id, close) {
        log("session \(row.id): abandoned; last heartbeat \(ISO.local(row.lastHeartbeat))")
      }
      publish(.dismiss)
      return
    }
    active = Active(row: row, machine: machine, calendarTitle: calendarTitle(for: row.calendarId))
    log("session \(row.id): resumed as \(machine.state.rawValue)")
    startTicking()
    publish(machine.state == .ending ? .show : .keep)
  }

  /// Checks the deadline. Returns true when the session just reached it (and
  /// the end sheet was shown).
  @discardableResult
  private func advance() throws -> Bool {
    guard try current() != nil else { return false }
    guard try commit(.tick(at: now)) == .reachedDeadline else { return false }
    log("session \(active?.row.id ?? 0): planned end reached")
    publish(.show)
    return true
  }

  /// Applies an input to the open session and persists what changed, in one
  /// transaction; memory changes only once sqlite has. Not for finish.
  private func commit(_ input: SessionInput) throws -> SessionTransition {
    guard var current = try current() else { throw FocusError("no session is running") }
    let before = current.machine
    var after = before
    let transition = try after.apply(input).get()
    guard transition != .none else { return .none }
    let id = current.row.id
    try db.transaction {
      if after.pauses.count > before.pauses.count, let pause = after.pauses.last {
        try db.addPause(id, start: pause.start, end: pause.end)
      } else if before.pauses.last?.end == nil, let closed = after.pauses.last?.end {
        try db.closePause(id, at: closed)
      }
      if after.extendedSeconds != before.extendedSeconds || after.plannedEnd != before.plannedEnd,
        let end = after.plannedEnd
      {
        try db.setExtension(id, seconds: after.extendedSeconds, end: end)
      }
      if after.endingReason != before.endingReason {
        try db.setEnding(id, reason: after.endingReason?.rawValue)
      }
    }
    current.machine = after
    active = current
    return transition
  }

  /// pause, resume, extend and stop from the socket.
  private func change(_ input: SessionInput) throws -> Reply {
    let transition = try commit(input)
    announce(transition)
    return .ok(["session": activeJSON()])
  }

  /// Logs a change and shows it: the end sheet after a stop, no sheet after
  /// an extension from it.
  private func announce(_ transition: SessionTransition) {
    let id = active?.row.id ?? 0
    switch transition {
    case .stopped:
      log("session \(id): stopped")
      publish(.show)
    case .extended(let seconds, let fromEnding):
      log("session \(id): extended by \(seconds) s\(fromEnding ? " from the end sheet" : "")")
      publish(fromEnding ? .dismiss : .keep)
    case .paused, .resumed:
      log("session \(id): \(transition == .paused ? "paused" : "resumed")")
      publish(.keep)
    default:
      publish(.keep)
    }
  }

  private func calendarTitle(for calendarId: String) -> String {
    guard calendar.accessState == "fullAccess" else { return "" }
    return calendar.calendar(id: calendarId)?.title ?? ""
  }

  /// A title unknown at start (no access yet) is looked up again every 30 s.
  private func refreshCalendarTitle() {
    guard var current = active, current.calendarTitle.isEmpty else { return }
    let title = calendarTitle(for: current.row.calendarId)
    guard !title.isEmpty else { return }
    current.calendarTitle = title
    active = current
    publish(.keep)
  }

  // MARK: Timer and UI

  private func startTicking() {
    ticking = true
    guard usesTimer, secondTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    // Fire just after each wall-clock second so the countdown steps with the clock.
    let fraction = clock().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
    timer.schedule(deadline: .now() + (1 - fraction) + 0.02, repeating: 1, leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in self?.secondTick() }
    timer.resume()
    secondTimer = timer
  }

  private func stopTicking() {
    ticking = false
    secondTimer?.cancel()
    secondTimer = nil
  }

  private enum Sheet {
    case keep, show, dismiss
  }

  /// What the UI shows for the open session, or nil when idle.
  func sessionView() -> SessionView? {
    onQueue {
      guard let current = active, current.machine.state.isOpen, let startedAt = current.machine.startedAt,
        let plannedEnd = current.machine.plannedEnd
      else { return nil }
      let now = self.now
      return SessionView(
        id: Int(current.row.id), goal: current.row.goal, state: current.machine.state.rawValue, startedAt: startedAt,
        plannedEnd: plannedEnd, remainingSeconds: current.machine.remainingSeconds(at: now),
        pausedSeconds: current.machine.pausedSeconds(at: now), calendarTitle: current.calendarTitle,
        extendOptions: SessionMachine.extendOptions)
    }
  }

  /// Sends the current view to the presenter on the main thread, then shows
  /// or hides the end sheet.
  private func publish(_ sheet: Sheet) {
    let view = sessionView()
    let presenter = storedPresenter
    runOnMain {
      presenter.update(view)
      switch sheet {
      case .keep: break
      case .show: if let view { presenter.showEndSheet(view) }
      case .dismiss: presenter.dismissEndSheet()
      }
    }
  }

  // MARK: UI callbacks (SessionPresenterDelegate); called on the main thread

  func presenterPause() { fromUI("pause") { try self.change(.pause(at: self.now)) } }
  func presenterResume() { fromUI("resume") { try self.change(.resume(at: self.now)) } }
  func presenterExtend(seconds: Int) { fromUI("extend") { try self.change(.extend(seconds: seconds, at: self.now)) } }
  func presenterStop() { fromUI("stop") { try self.change(.stop(at: self.now)) } }

  func presenterFinish(rating: Int?, note: String?) {
    fromUI("finish") { try self.finishSession(rating: rating, note: note, reason: nil) }
  }

  /// UI calls queue behind socket requests; a refusal is logged and the UI
  /// is refreshed so it shows the real state.
  private func fromUI(_ action: String, _ body: @escaping () throws -> Any) {
    queue.async {
      do {
        try self.advance()
        _ = try body()
      } catch let error as FocusError {
        self.log("\(action) from the UI refused: \(error.message)")
        self.publish(.keep)
      } catch {
        self.log("\(action) from the UI failed: \(error.localizedDescription)")
        self.publish(.keep)
      }
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

  /// PLAN: starting while a session is open sends that one to the end sheet
  /// first. The start itself is refused; Kai finishes (or extends) the open
  /// session, then starts again.
  private func refuseIfRunning() throws {
    guard let open = try current() else { return }
    let state = open.machine.state
    if state == .running || state == .paused {
      announce(try commit(.stop(at: now)))
    } else {
      publish(.show)
    }
    let until = open.machine.plannedEnd.map { " until \(ISO.local($0))" } ?? ""
    throw FocusError(
      "a session is already running: \"\(open.row.goal)\" (id \(open.row.id))\(until); it is at the end sheet, finish or extend it first",
      extra: ["session": activeJSON()])
  }

  private func start(_ request: Request) throws -> Reply {
    let eventId = try request.requiredString("eventId")
    var requestedStart: Date?
    if let text = try request.string("start") {
      guard let date = ISO.parse(text) else { throw FocusError("start must be an ISO 8601 date") }
      requestedStart = date
    }
    try requireAccess()
    let now = self.now
    let day = Rules.day(containing: now)
    // Only the calendars picked in Settings are startable (PLAN.md).
    let settings = config.load()
    let startable = settings.startableCalendars
    let candidates = startable.isEmpty ? [] : calendar.events(from: day.start, to: day.end, calendarIds: startable)
    let event = try Rules.pickOccurrence(candidates, eventId: eventId, requestedStart: requestedStart, now: now).get()
    try refuseIfRunning()
    return try begin(
      NewSession(
        sourceEventId: event.id, calendarId: event.calendarId,
        goal: event.title.isEmpty ? "Untitled event" : event.title,
        profile: settings.profile(for: event.calendarId), plannedStart: event.start,
        plannedEnd: Rules.sessionEnd(for: event), startedAt: now),
      calendarTitle: event.calendarTitle, settings: settings)
  }

  private func startAdhoc(_ request: Request) throws -> Reply {
    let goal = LogText.oneLine(try request.requiredString("goal"))
    guard let duration = try request.double("durationSeconds") else {
      throw FocusError("durationSeconds is required")
    }
    let calendarId = try request.requiredString("calendarId")
    let profile = try request.string("profile")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let now = self.now
    let plan = try Rules.adhocPlan(now: now, durationSeconds: duration).get()
    try refuseIfRunning()
    let settings = config.load()
    return try begin(
      NewSession(
        sourceEventId: nil, calendarId: calendarId, goal: goal,
        profile: (profile?.isEmpty == false ? profile : nil) ?? settings.profile(for: calendarId),
        plannedStart: plan.start, plannedEnd: plan.end, startedAt: now),
      calendarTitle: calendarTitle(for: calendarId), settings: settings)
  }

  private func begin(_ new: NewSession, calendarTitle: String, settings: FocusConfig) throws -> Reply {
    var machine = SessionMachine()
    _ = try machine.apply(.start(at: new.startedAt, plannedEnd: new.plannedEnd ?? new.startedAt)).get()
    let id = try db.insertSession(new)
    guard let row = try db.session(id: id) else { throw FocusError("session \(id) vanished") }
    active = Active(row: row, machine: machine, calendarTitle: calendarTitle)
    log("session \(id): started, until \(ISO.local(machine.plannedEnd ?? new.startedAt))")
    startTicking()
    publish(.keep)
    if settings.raycastDeeplink {
      openURL(RaycastDeeplink.start(goal: row.goal, durationSeconds: machine.remainingSeconds(at: new.startedAt)))
    }
    return .ok(["session": activeJSON()])
  }

  // MARK: Finishing and the log event

  private func finish(_ request: Request) throws -> Reply {
    let rating = try request.int("rating")
    if let rating, !(1...5).contains(rating) { throw FocusError("rating must be 1 to 5") }
    let note = try request.string("note")
    var reason: EndReason?
    if let text = try request.string("reason") {
      guard let parsed = EndReason(rawValue: text), parsed != .abandoned else {
        throw FocusError("reason must be \"timer\" or \"manual\"")
      }
      reason = parsed
    }
    let (id, logEventId) = try finishSession(rating: rating, note: note, reason: reason)
    return .ok([
      "session": try sessionJSON(id),
      "logEventId": .optional(logEventId),
      "logPending": .bool(logEventId == nil),
    ])
  }

  /// Finish from running, paused or ending. `reason` nil records why the
  /// session reached the end sheet ("timer" or "manual"), or "manual" when
  /// it never did. Returns the session id and the log event id, if written.
  private func finishSession(rating: Int?, note: String?, reason: EndReason?) throws -> (Int64, String?) {
    guard let open = try current() else { throw FocusError("no session is running") }
    let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    var machine = open.machine
    _ = try machine.apply(
      .finish(at: now, rating: rating, note: (trimmed?.isEmpty == false) ? trimmed : nil, reason: reason)
    ).get()

    // Step 1: close the row and fix its destination before touching EventKit.
    let settings = config.load()
    let logCalendarId = settings.logCalendarId
    var logCalendarName = settings.logCalendarName
    if logCalendarName == nil, let logCalendarId, calendar.accessState == "fullAccess" {
      logCalendarName = calendar.calendar(id: logCalendarId)?.displayName
    }
    let close = SessionClose(
      endedAt: machine.endedAt ?? now, endReason: (machine.endReason ?? .manual).rawValue, rating: machine.rating,
      note: machine.note, logCalendarId: logCalendarId, logCalendarName: logCalendarName)
    let id = open.row.id
    guard try db.finish(id, close) else {
      active = nil
      stopTicking()
      publish(.dismiss)
      throw FocusError("the session had already ended")
    }
    active = nil
    stopTicking()
    log("session \(id): finished (\(close.endReason))")
    publish(.dismiss)
    if settings.raycastDeeplink { openURL(RaycastDeeplink.complete) }

    // Steps 2 and 3: write (or adopt) the log event now; on failure the row
    // waits for the 30-second tick.
    guard let row = try db.session(id: id) else { throw FocusError("session \(id) vanished") }
    switch try writeLogEvent(for: row) {
    case .created(let eventId), .adopted(let eventId): return (id, eventId)
    case .waiting: return (id, nil)
    }
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
    try onQueue {
      var outcomes: [RecoveryOutcome] = []
      for row in try db.waitingSessions() {
        outcomes.append(try writeLogEvent(for: row))
      }
      return Recovery.tally(outcomes)
    }
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

  private func baseJSON(_ row: SessionRow) -> [String: JSONValue] {
    [
      "id": .int(Int(row.id)), "goal": .string(row.goal), "startedAt": .string(ISO.local(row.startedAt)),
      "plannedEnd": .optional(row.deadline.map { ISO.local($0) }), "calendarId": .string(row.calendarId),
      "profile": .string(row.profile), "sourceEventId": .optional(row.sourceEventId),
      "extendedSeconds": .int(row.extendedSeconds),
    ]
  }

  /// The open session from memory: state running, paused or ending, the
  /// extended planned end, and the live numbers. Null when idle.
  private func activeJSON() -> JSONValue {
    guard let current = active else { return .null }
    let now = self.now
    var fields = baseJSON(current.row)
    fields["state"] = .string(current.machine.state.rawValue)
    fields["plannedEnd"] = .optional(current.machine.plannedEnd.map { ISO.local($0) })
    fields["extendedSeconds"] = .int(current.machine.extendedSeconds)
    fields["remainingSeconds"] = .int(current.machine.remainingSeconds(at: now))
    fields["pausedSeconds"] = .int(current.machine.pausedSeconds(at: now))
    fields["endReason"] = .optional(current.machine.endingReason?.rawValue)
    return .object(fields)
  }

  /// A row as JSON: the open session comes from memory; finished rows carry
  /// their end, rating, note and log fields.
  func sessionJSON(_ row: SessionRow) -> JSONValue {
    onQueue {
      if row.endedAt == nil, let current = active, current.row.id == row.id { return activeJSON() }
      var fields = baseJSON(row)
      let pauses = (try? db.pauses(row.id)) ?? []
      if let endedAt = row.endedAt {
        fields["state"] = "finished"
        fields["endedAt"] = .string(ISO.local(endedAt))
        fields["endReason"] = .optional(row.endReason)
        fields["rating"] = .optional(row.rating)
        fields["note"] = .optional(row.note)
        fields["logCalendarId"] = .optional(row.logCalendarId)
        fields["logCalendarName"] = .optional(row.logCalendarName)
        fields["logEventId"] = .optional(row.logEventId)
        fields["pausedSeconds"] = .int(LogText.pausedSeconds(pauses, start: row.startedAt, end: endedAt))
      } else {
        fields["state"] = pauses.contains { $0.end == nil } ? "paused" : "running"
      }
      return .object(fields)
    }
  }

  // MARK: Deeplink

  /// `open <url>`, without waiting (AppKit is not needed for this).
  static func open(_ url: URL, log: (String) -> Void) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    do {
      try process.run()
    } catch {
      log("could not open \(url.absoluteString): \(error.localizedDescription)")
    }
  }
}

/// Lets `attachPresenter(to:)` in UIPresenter.swift hand the daemon its UI.
extension FocusCore: PresenterHost {}
