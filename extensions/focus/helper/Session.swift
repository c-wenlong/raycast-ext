// The session lifecycle from PLAN.md as a pure value type: no sqlite, no
// EventKit, no clock of its own. FocusCore feeds it inputs with the time,
// persists whatever changed, and drives the UI from the transition it
// reports. FocusCore ticks before every command, so pause, resume and stop
// never act on a session whose deadline passed unnoticed. Tested
// exhaustively in test/helper/main.swift.
//
//   idle ──start──▶ running ◀──resume── paused
//                     │  └────pause─────┘   │
//                     ├── deadline ─────────┼──▶ ending (reason timer)
//                     ├── stop ─────────────┴──▶ ending (reason manual)
//   ending ──extend──▶ running (same session)
//   running | paused | ending ──finish──▶ finished
//   running | paused | ending ──abandon─▶ abandoned (recovery at launch only)
//
// What a pause does to the deadline depends on the session (Kai, 2026-09-28):
//
// - A calendar session (it has a source event) runs to the event's end. Its
//   deadline is wall-clock: pausing does not move it, so a paused session
//   reaches the end sheet when its planned end passes, exactly like a running
//   one. Reaching the end sheet closes an open pause (blocking is back on
//   while the sheet waits), at the deadline for the timer and at the stop
//   time for a manual stop.
// - An ad-hoc session asked for a length, so a pause stops its clock
//   (`pauseStopsClock`): while paused the time left stays where it was, the
//   deadline never passes, and closing the pause (resume, stop, finish,
//   abandon) moves the planned end later by the pause's length. While paused,
//   `effectiveEnd(at:)` is the planned end moved on by the pause so far: the
//   end the session would have if it were resumed now.

import Foundation

enum SessionState: String, Equatable {
  case idle, running, paused, ending, finished, abandoned

  /// A session exists (it has not finished or been abandoned).
  var isOpen: Bool { self == .running || self == .paused || self == .ending }
}

/// Why a session is at the end sheet, and the `end_reason` it is closed with.
enum EndReason: String, Equatable {
  case timer, manual, abandoned
}

enum SessionInput: Equatable {
  case start(at: Date, plannedEnd: Date)
  case pause(at: Date)
  case resume(at: Date)
  case extend(seconds: Int, at: Date)
  case stop(at: Date)
  /// `reason` nil: the ending reason at the end sheet, otherwise "manual".
  case finish(at: Date, rating: Int?, note: String?, reason: EndReason?)
  case tick(at: Date)
  /// Launch recovery: the helper died and its heartbeat went stale.
  case abandon(at: Date)
}

enum SessionTransition: Equatable {
  case started
  case paused
  case resumed
  case extended(seconds: Int, fromEnding: Bool)
  /// Manual stop: running or paused to ending.
  case stopped
  /// The planned end passed while running or paused: to ending.
  case reachedDeadline
  case finished(EndReason)
  case abandoned
  /// A tick that changed nothing.
  case none
}

struct SessionMachine: Equatable {
  /// The Extend choices on the end sheet and in Focus Today, in seconds.
  static let extendOptions = [300, 600, 900, 1500]
  /// What `extend` accepts, in seconds.
  static let extendRange = 60...86_400

  private(set) var state: SessionState = .idle
  /// True for an ad-hoc session: a pause stops the clock and moves the end.
  let pauseStopsClock: Bool
  private(set) var startedAt: Date?
  /// The end the timer runs to: extensions included, and for an ad-hoc
  /// session every closed pause too (an open one is added by `effectiveEnd`).
  private(set) var plannedEnd: Date?
  /// Sum of the extensions asked for.
  private(set) var extendedSeconds = 0
  private(set) var pauses: [PauseSpan] = []
  /// Set while ending: timer or manual.
  private(set) var endingReason: EndReason?
  private(set) var endedAt: Date?
  private(set) var endReason: EndReason?
  private(set) var rating: Int?
  private(set) var note: String?

  /// `pauseStopsClock` true for an ad-hoc session (no source event).
  init(pauseStopsClock: Bool = false) {
    self.pauseStopsClock = pauseStopsClock
  }

  /// An open session read back from sqlite after a quick restart. An open
  /// pause means paused; an ending reason means it was at the end sheet.
  /// `plannedEnd` is the stored deadline: for an ad-hoc session it already
  /// holds every closed pause, so an open one keeps the time left frozen at
  /// its start.
  init(
    restoring startedAt: Date, plannedEnd: Date, extendedSeconds: Int, pauses: [PauseSpan], endingReason: EndReason?,
    pauseStopsClock: Bool = false
  ) {
    self.pauseStopsClock = pauseStopsClock
    self.startedAt = startedAt
    self.plannedEnd = plannedEnd
    self.extendedSeconds = extendedSeconds
    self.pauses = pauses
    if let endingReason, endingReason != .abandoned {
      state = .ending
      self.endingReason = endingReason
    } else {
      state = pauses.last.map { $0.end == nil } == true ? .paused : .running
    }
  }

  var isPaused: Bool { state == .paused }

  // MARK: Derived numbers

  /// The start of the open pause, if the session is paused.
  private var openPauseStart: Date? {
    guard state == .paused, let last = pauses.last, last.end == nil else { return nil }
    return last.start
  }

  /// True while an ad-hoc session is paused: its clock is not moving.
  var isClockStopped: Bool { pauseStopsClock && openPauseStart != nil }

  /// The end the session runs to as of `now`: the planned end, moved on by
  /// the open pause so far while an ad-hoc session is paused.
  func effectiveEnd(at now: Date) -> Date? {
    guard let plannedEnd else { return nil }
    guard pauseStopsClock, let pausedAt = openPauseStart else { return plannedEnd }
    return plannedEnd.addingTimeInterval(max(0, now.timeIntervalSince(pausedAt)))
  }

  /// Whole seconds until the planned end; 0 once ending or closed. Frozen at
  /// the pause's start while an ad-hoc session is paused.
  func remainingSeconds(at now: Date) -> Int {
    guard state == .running || state == .paused, let plannedEnd else { return 0 }
    if pauseStopsClock, let pausedAt = openPauseStart {
      return Rules.remainingSeconds(until: plannedEnd, now: pausedAt)
    }
    return Rules.remainingSeconds(until: plannedEnd, now: now)
  }

  /// Time spent paused so far (an open pause counts up to `now`).
  func pausedSeconds(at now: Date) -> Int {
    guard let startedAt else { return 0 }
    return LogText.pausedSeconds(pauses, start: startedAt, end: max(startedAt, endedAt ?? now))
  }

  /// Elapsed time minus pauses.
  func focusedSeconds(at now: Date) -> Int {
    guard let startedAt else { return 0 }
    let end = max(startedAt, endedAt ?? now)
    return max(0, Int(end.timeIntervalSince(startedAt).rounded()) - pausedSeconds(at: now))
  }

  // MARK: Transitions

  /// Applies one input. A refusal leaves the machine unchanged and says why
  /// in words the client can show as is.
  mutating func apply(_ input: SessionInput) -> Result<SessionTransition, FocusError> {
    var next = self
    let result = next.step(input)
    if case .success = result { self = next }
    return result
  }

  private func refusal(_ action: String) -> FocusError {
    switch state {
    case .idle: return FocusError("no session is running")
    case .finished, .abandoned: return FocusError("the session has already ended")
    case .ending: return FocusError("the session is at the end sheet; extend or finish it (cannot \(action))")
    case .paused: return FocusError("the session is paused; cannot \(action)")
    case .running: return FocusError("the session is running; cannot \(action)")
    }
  }

  private mutating func step(_ input: SessionInput) -> Result<SessionTransition, FocusError> {
    switch input {
    case .start(let at, let end):
      guard state == .idle else {
        return .failure(state.isOpen ? FocusError("a session is already running") : FocusError("this session has already ended"))
      }
      guard end > at else { return .failure(FocusError("the planned end must be after the start")) }
      state = .running
      startedAt = at
      plannedEnd = end
      return .success(.started)

    case .pause(let at):
      if state == .paused { return .failure(FocusError("the session is already paused")) }
      guard state == .running, let startedAt else { return .failure(refusal("pause")) }
      pauses.append(PauseSpan(start: max(at, startedAt), end: nil))
      state = .paused
      return .success(.paused)

    case .resume(let at):
      if state == .running { return .failure(FocusError("the session is not paused")) }
      guard state == .paused else { return .failure(refusal("resume")) }
      closeOpenPause(at: at)
      state = .running
      return .success(.resumed)

    case .extend(let seconds, let at):
      guard SessionMachine.extendRange.contains(seconds) else {
        return .failure(FocusError("seconds must be a whole number from 60 to 86400"))
      }
      guard state.isOpen, let plannedEnd else { return .failure(refusal("extend")) }
      // From the end sheet the extension counts from now when the deadline
      // is already behind (the sheet may have waited), so +5 always gives
      // five more minutes; otherwise it moves the planned end. A paused
      // ad-hoc session's deadline is never behind (its clock is stopped, and
      // the stored end may be, since the open pause is not in it yet), so
      // the extension adds to its end as it stands.
      let base = isClockStopped ? plannedEnd : max(plannedEnd, at)
      self.plannedEnd = base.addingTimeInterval(TimeInterval(seconds))
      extendedSeconds += seconds
      let fromEnding = state == .ending
      if fromEnding {
        state = .running
        endingReason = nil
      }
      return .success(.extended(seconds: seconds, fromEnding: fromEnding))

    case .stop(let at):
      guard state == .running || state == .paused else { return .failure(refusal("stop")) }
      closeOpenPause(at: at)
      state = .ending
      endingReason = .manual
      return .success(.stopped)

    case .finish(let at, let rating, let note, let reason):
      guard state.isOpen, let startedAt else { return .failure(refusal("finish")) }
      if let rating, !(1...5).contains(rating) { return .failure(FocusError("rating must be 1 to 5")) }
      if reason == .abandoned { return .failure(FocusError("reason must be \"timer\" or \"manual\"")) }
      let end = max(at, startedAt)
      closeOpenPause(at: end)
      endReason = reason ?? endingReason ?? .manual
      endedAt = end
      self.rating = rating
      self.note = note
      state = .finished
      endingReason = nil
      return .success(.finished(endReason!))

    case .tick(let at):
      // A paused ad-hoc session never reaches its deadline: its clock is stopped.
      guard state == .running || state == .paused, !isClockStopped, let plannedEnd, at >= plannedEnd else {
        return .success(.none)
      }
      closeOpenPause(at: plannedEnd)
      state = .ending
      endingReason = .timer
      return .success(.reachedDeadline)

    case .abandon(let at):
      guard state.isOpen, let startedAt else { return .failure(refusal("abandon")) }
      let end = max(at, startedAt)
      closeOpenPause(at: end)
      endedAt = end
      endReason = .abandoned
      state = .abandoned
      endingReason = nil
      return .success(.abandoned)
    }
  }

  /// Ends an open pause at `at`, never before the pause began. For an
  /// ad-hoc session the planned end moves later by the pause's length, so
  /// the time left carries on from where the pause froze it.
  private mutating func closeOpenPause(at: Date) {
    guard let last = pauses.indices.last, pauses[last].end == nil else { return }
    let end = max(at, pauses[last].start)
    pauses[last].end = end
    if pauseStopsClock, let plannedEnd {
      self.plannedEnd = plannedEnd.addingTimeInterval(end.timeIntervalSince(pauses[last].start))
    }
  }
}

// MARK: - Raycast deeplink

/// `raycast://focus/...` URLs for running Raycast Focus side by side
/// (config `raycastDeeplink`). Values are percent-encoded as query
/// components: everything but unreserved characters is escaped, so `&`,
/// `=`, `+` and `#` in a goal cannot break the query.
enum RaycastDeeplink {
  private static let unreserved = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

  static func encode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  static func start(goal: String, durationSeconds: Int) -> URL {
    URL(
      string:
        "raycast://focus/start?goal=\(encode(goal))&duration=\(max(0, durationSeconds))&mode=block")!
  }

  static let complete = URL(string: "raycast://focus/complete")!
}
