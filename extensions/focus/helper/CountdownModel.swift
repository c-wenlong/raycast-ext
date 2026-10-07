// The countdown's presentation model, pure Foundation: the session
// snapshot the UI draws (`SessionView`), what the pill shows
// (`PanelContent`), and the sweep that glides the fill between updates
// (`SweepClock`, `PanelSweep`). Shared by the floating panel, the notch
// island and Notes' hosted Focus tab; session state stays with the
// daemon. Moved out of FloatingPanel.swift/Presenter.swift unchanged.

import Foundation

/// What the UI shows for the current session. `nil` means idle.
struct SessionView: Equatable {
  var id: Int
  var goal: String
  var state: String              // "running", "paused", "ending", "break"
  var startedAt: Date
  var plannedEnd: Date           // extended end; the break's end while onBreak
  var remainingSeconds: Int      // never negative; 0 while ending
  var pausedSeconds: Int         // total non-focus time so far
  var calendarTitle: String
  var extendOptions: [Int]       // seconds, e.g. [300, 900, 1500, 2700]
  /// True for an ad-hoc session: a pause holds `remainingSeconds` and moves
  /// `plannedEnd` on (Session.swift), so its fill freezes while paused.
  var pauseStopsClock = false
  /// On a break: when the break ends.
  var breakUntil: Date? = nil
  /// On a break: the next focus block's length, seconds.
  var nextFocusSeconds: Int? = nil
  /// The task is resting between focus blocks (the hosted bridge still
  /// reports state "paused" to old clients, with `breakUntil` set).
  var isOnBreak: Bool { state == "break" || breakUntil != nil }
}

/// "mm:ss" under an hour, "h:mm:ss" from an hour up; never negative.
/// One formatter shared by the menu bar item, the pill and the hosted view.
enum CountdownModel {
  /// Pause menu titles and seconds; -1 is a separator, 0 is "until Resume".
  /// Shared by the floating panel and the hosted Focus tab.
  static let pauseChoices: [(String, Int)] = [
    ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600), ("", -1), ("Indefinitely", 0),
  ]

  static func clock(_ seconds: Int) -> String {
    let total = max(0, seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let rest = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%02d:%02d", minutes, rest)
  }
}

/// What the idle pill shows, from a session.
struct PanelContent: Equatable {
  var clock: String
  var paused: Bool
  /// Elapsed over planned length, 0 to 1.
  var progress: Double
  var goal: String

  init(clock: String, paused: Bool, progress: Double, goal: String) {
    self.clock = clock
    self.paused = paused
    self.progress = progress
    self.goal = goal
  }

  init(_ view: SessionView) {
    clock = CountdownModel.clock(view.state == "ending" ? 0 : view.remainingSeconds)
    paused = view.state == "paused" || view.isOnBreak
    progress = PanelContent.progress(view)
    let text = view.goal.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    goal = view.isOnBreak ? "Break · \(text)" : text
  }

  /// How much of the session has gone: 1 - remaining / (plannedEnd - start).
  /// Follows the digits (whole seconds); an extension raises the length and
  /// so lowers the fill. An ad-hoc session's length leaves out its pauses
  /// (`PanelSweep.focused`), since they moved its planned end.
  static func progress(_ view: SessionView) -> Double {
    // A break is not focus: no green fill while the task rests.
    if view.isOnBreak { return 0 }
    let view = PanelSweep.focused(view)
    let total = view.plannedEnd.timeIntervalSince(view.startedAt)
    guard total > 0 else { return 1 }
    let remaining = view.state == "ending" ? 0 : Double(view.remainingSeconds)
    return min(1, max(0, (total - remaining) / total))
  }

  /// Time and goal as one line: what the tests and VoiceOver read.
  var titleText: String { (paused ? "⏸ " : "") + clock + (goal.isEmpty ? "" : " " + goal) }
}

/// The sweep between updates. An update (about once a second) gives whole
/// seconds left; the sweep moves on from it with the wall clock, so it
/// glides instead of stepping, at a speed of 1 / total: a longer session
/// (or an extension) moves it slower.
///
/// A calendar session's countdown runs to the planned end while paused too
/// (a pause does not move its planned end; see Session.swift), so the sweep
/// keeps pace with the digits then; it stops only at the end sheet. What an
/// ad-hoc session's pause does is `PanelSweep`'s business. Pure.
struct SweepClock: Equatable {
  var sessionId: Int
  /// plannedEnd - startedAt, seconds.
  var total: TimeInterval
  /// Seconds left at `anchor`.
  var remaining: TimeInterval
  var anchor: Date
  /// True while the countdown moves (running or paused).
  var moving: Bool

  /// An update is followed unless it is more than this far from where the
  /// sweep already is; closer, the sweep carries on, so it never steps back.
  static let snapDrift: TimeInterval = 0.5

  /// From an update at `now`. `remainingSeconds` is whole seconds (the
  /// daemon rounds down); when `plannedEnd - now` agrees with it to within
  /// a second, that exact figure is used, so the sweep starts where the
  /// clock really is.
  init(_ view: SessionView, at now: Date) {
    sessionId = view.id
    total = view.plannedEnd.timeIntervalSince(view.startedAt)
    anchor = now
    moving = view.state == "running" || view.state == "paused"
    if view.state == "ending" {
      remaining = 0
    } else {
      let whole = Double(view.remainingSeconds)
      let exact = view.plannedEnd.timeIntervalSince(now)
      remaining = abs(exact - whole) <= 1 ? max(0, exact) : whole
    }
  }

  /// Seconds left at `time`.
  func remaining(at time: Date) -> TimeInterval {
    guard moving else { return remaining }
    return max(0, remaining - max(0, time.timeIntervalSince(anchor)))
  }

  /// 1 - remaining / total at `time`, 0 to 1.
  func progress(at time: Date) -> Double {
    guard total > 0 else { return 1 }
    return min(1, max(0, (total - remaining(at: time)) / total))
  }

  /// The clock after an update at `now`: this one carried on when the
  /// update is the same session, length and state and within `snapDrift`
  /// of it; otherwise the update's.
  func updated(with view: SessionView, at now: Date) -> SweepClock {
    let fresh = SweepClock(view, at: now)
    guard fresh.sessionId == sessionId, fresh.total == total, fresh.moving == moving, moving,
      abs(remaining(at: now) - fresh.remaining) <= Self.snapDrift
    else { return fresh }
    return self
  }
}

/// How full the sweep is: `SweepClock`, plus what a pause does to it. Both
/// displays (the floating panel and the notch) draw from one of these.
///
/// A calendar session's pause is a break inside the event: its time left
/// keeps falling while paused, and the fill keeps pace over the whole span.
/// An ad-hoc session's pause stops its clock (`SessionView.pauseStopsClock`,
/// see Session.swift): the time left holds and the planned end moves on with
/// the wall clock, so a length read as `plannedEnd - startedAt` would grow
/// and drain the fill. Its fill freezes where it was instead, and its length
/// leaves out the time spent paused (`pausedSeconds`), so after the resume
/// the fill carries on from where it froze. Pure.
struct PanelSweep: Equatable {
  private(set) var sessionId: Int?
  private(set) var clock: SweepClock?
  /// The fill held while an ad-hoc session is paused.
  private(set) var frozen: Double?

  init() {}

  /// `view` with its start moved later by the time spent paused when the
  /// pause stops its clock, so `plannedEnd - startedAt` is the focused length
  /// (the open pause counts too: `plannedEnd` has moved on by it as well).
  static func focused(_ view: SessionView) -> SessionView {
    guard view.pauseStopsClock else { return view }
    var view = view
    view.startedAt = view.startedAt.addingTimeInterval(TimeInterval(view.pausedSeconds))
    return view
  }

  mutating func update(_ view: SessionView, at now: Date) {
    if view.id != sessionId {
      self = PanelSweep()
      sessionId = view.id
    }
    let focused = Self.focused(view)
    switch view.state {
    case "paused" where view.pauseStopsClock:
      // The daemon froze the time left at the pause's start; this update
      // may be later than that, so the running sweep is capped at the
      // whole-second fill the update reports (never past what the digits
      // say), and stays fractional below it so the resume does not step.
      if frozen == nil {
        let reported = PanelContent.progress(view)
        frozen = clock.map { min($0.progress(at: now), reported) } ?? reported
      }
      clock = nil
    case "break":
      // A break is not focus: the fill holds empty (the digits still tick).
      frozen = 0
      clock = nil
    case "running", "paused":
      frozen = nil
      clock = clock?.updated(with: focused, at: now) ?? SweepClock(focused, at: now)
    default:
      frozen = 1
      clock = nil
    }
  }

  func progress(at time: Date) -> Double {
    if let frozen { return frozen }
    return clock?.progress(at: time) ?? 0
  }

  /// True while the fill moves on its own.
  var moving: Bool { frozen == nil && clock?.moving == true }
}

