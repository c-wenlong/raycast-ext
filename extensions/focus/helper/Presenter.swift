import Foundation

/// What the UI shows for the current session. `nil` means idle.
struct SessionView: Equatable {
  var id: Int
  var goal: String
  var state: String              // "running", "paused", "ending"
  var startedAt: Date
  var plannedEnd: Date           // extended end, if extended
  var remainingSeconds: Int      // never negative; 0 while ending
  var pausedSeconds: Int         // total time spent paused so far
  var calendarTitle: String
  var extendOptions: [Int]       // seconds, e.g. [300, 600, 900, 1500]
  /// True for an ad-hoc session: a pause holds `remainingSeconds` and moves
  /// `plannedEnd` on (Session.swift), so its fill freezes while paused.
  var pauseStopsClock = false
}

/// The UI calls back into the session logic through this.
protocol SessionPresenterDelegate: AnyObject {
  func presenterPause()
  func presenterResume()
  func presenterExtend(seconds: Int)
  func presenterStop()
  func presenterFinish(rating: Int?, note: String?)
}

/// The session logic drives the UI through this. Calls arrive on the main thread.
protocol SessionPresenter: AnyObject {
  var delegate: SessionPresenterDelegate? { get set }
  /// Called whenever anything visible changes and once a second while a session exists.
  func update(_ view: SessionView?)
  /// The session reached the end sheet (timer ran out, planned end passed while paused, or manual stop).
  func showEndSheet(_ view: SessionView)
  /// The session finished or was abandoned; hide any sheet.
  func dismissEndSheet()
}

/// Used when no UI is attached (tests, headless runs).
final class NullPresenter: SessionPresenter {
  weak var delegate: SessionPresenterDelegate?
  private(set) var views: [SessionView?] = []
  private(set) var endSheets: [SessionView] = []
  private(set) var dismissals = 0
  func update(_ view: SessionView?) { views.append(view) }
  func showEndSheet(_ view: SessionView) { endSheets.append(view) }
  func dismissEndSheet() { dismissals += 1 }
}

/// Anything that can be handed a presenter; FocusCore conforms so the UI can attach without knowing it.
protocol PresenterHost: AnyObject { var presenter: SessionPresenter { get set } }
