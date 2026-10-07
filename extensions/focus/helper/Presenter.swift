import Foundation

/// The UI calls back into the session logic through this.
protocol SessionPresenterDelegate: AnyObject {
  func presenterPause()
  func presenterResume()
  func presenterExtend(seconds: Int)
  func presenterStop()
  func presenterFinish(rating: Int?, note: String?)
  /// The break controls name their session: a stale card or hosted click
  /// can never reach another task.
  func presenterStartBreak(sessionId: Int, seconds: Int, focusSeconds: Int)
  func presenterResumeBreak(sessionId: Int)
  func presenterExtendBreak(sessionId: Int, seconds: Int)
  func presenterFinishBreak(sessionId: Int, rating: Int?, note: String?)
}

/// Defaults keep delegates that predate the break controls (the UI demo,
/// headless presenters) compiling; the real core implements all four.
extension SessionPresenterDelegate {
  func presenterStartBreak(sessionId: Int, seconds: Int, focusSeconds: Int) {}
  func presenterResumeBreak(sessionId: Int) {}
  func presenterExtendBreak(sessionId: Int, seconds: Int) {}
  func presenterFinishBreak(sessionId: Int, rating: Int?, note: String?) {}
}

/// The session logic drives the UI through this. Calls arrive on the main thread.
/// A break's Finish reached a host (the shared notch's helper) whose own UI
/// holds no stars or note: the presenter that owns the end card fills in
/// the review it kept for that session. Called on the main thread; the
/// session-targeted delegate call re-validates id and break state.
protocol SessionPresenter: AnyObject {
  var delegate: SessionPresenterDelegate? { get set }
  /// Finish `sessionId`'s break with whatever review the end card kept.
  func finishHostedBreak(sessionId: Int)
  /// Called whenever anything visible changes and once a second while a session exists.
  func update(_ view: SessionView?)
  /// The session reached the end sheet (timer ran out, planned end passed while paused, or manual stop).
  func showEndSheet(_ view: SessionView)
  /// The session finished or was abandoned; hide any sheet.
  func dismissEndSheet()
  /// Another helper (Notes) holds a live claim on the notch, so the native
  /// island stays hidden even though the display is still "notch". Only the
  /// notch is affected; the menu bar item, the panel and the end card are not.
  func setNotchHosted(_ hosted: Bool)
  /// True when this presenter can arm a "pause for N seconds" timer for a
  /// session the hosting helper paused through the bridge (`pauseFor`).
  var supportsHostedTimedPause: Bool { get }
  /// Arms a timed resume for session `sessionId`, already paused via the
  /// bridge. Called on the main thread after the pause lands.
  func scheduleHostedPause(sessionId: Int, seconds: Int)
}

/// UIPresenter implements hosting and timed pauses; presenters that have
/// no UI (tests, headless) ignore both and finish a hosted break with no
/// review.
extension SessionPresenter {
  func setNotchHosted(_ hosted: Bool) {}
  var supportsHostedTimedPause: Bool { false }
  func scheduleHostedPause(sessionId: Int, seconds: Int) {}
  func finishHostedBreak(sessionId: Int) {
    delegate?.presenterFinishBreak(sessionId: sessionId, rating: nil, note: nil)
  }
}

/// Used when no UI is attached (tests, headless runs).
final class NullPresenter: SessionPresenter {
  weak var delegate: SessionPresenterDelegate?
  private(set) var views: [SessionView?] = []
  private(set) var endSheets: [SessionView] = []
  private(set) var dismissals = 0
  /// Every setNotchHosted value Core sent, in order.
  private(set) var hostedFlags: [Bool] = []
  /// Tests opt into timed-pause support to exercise the hosted path.
  var supportsHostedTimedPause = false
  /// Every scheduleHostedPause(sessionId, seconds) Core sent, in order.
  private(set) var scheduledPauses: [(sessionId: Int, seconds: Int)] = []
  func update(_ view: SessionView?) { views.append(view) }
  func showEndSheet(_ view: SessionView) { endSheets.append(view) }
  func dismissEndSheet() { dismissals += 1 }
  func setNotchHosted(_ hosted: Bool) { hostedFlags.append(hosted) }
  func scheduleHostedPause(sessionId: Int, seconds: Int) {
    scheduledPauses.append((sessionId, seconds))
  }
}

/// Anything that can be handed a presenter; FocusCore conforms so the UI can attach without knowing it.
protocol PresenterHost: AnyObject { var presenter: SessionPresenter { get set } }
