import Foundation

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
/// no UI (tests, headless) ignore both.
extension SessionPresenter {
  func setNotchHosted(_ hosted: Bool) {}
  var supportsHostedTimedPause: Bool { false }
  func scheduleHostedPause(sessionId: Int, seconds: Int) {}
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
