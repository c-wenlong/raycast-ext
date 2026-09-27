import AppKit
import Foundation

// MARK: - The presenter behind the session logic
//
// UIPresenter is what the session logic (Core) drives through
// SessionPresenter: it owns the menu bar countdown (MenuBar.swift) and the
// end sheet (EndSheet.swift), and hands their actions to the delegate.
// Main thread only.

final class UIPresenter: SessionPresenter {
  weak var delegate: SessionPresenterDelegate? {
    didSet {
      menuBar.delegate = delegate
      endSheet.delegate = delegate
    }
  }
  let menuBar: MenuBar
  let endSheet: EndSheet

  /// The tests pass a private NSStatusBar and a fixed clock.
  init(statusBar: NSStatusBar = .system, clock: @escaping () -> Date = Date.init) {
    menuBar = MenuBar(statusBar: statusBar)
    endSheet = EndSheet(clock: clock)
  }

  /// Runs `body` now on the main thread. Anywhere else is a bug in the
  /// caller: it traps in debug builds and is moved to the main queue in
  /// release, so the daemon does not die mid-session over it.
  private func onMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread {
      body()
    } else {
      assertionFailure("UIPresenter must be called on the main thread")
      DispatchQueue.main.async(execute: body)
    }
  }

  func update(_ view: SessionView?) {
    onMain { [self] in
      menuBar.update(view)
      guard let view else {
        // No session left, so nothing for a sheet to ask about.
        if endSheet.isVisible { endSheet.dismiss() }
        return
      }
      // Back to running or paused (extended from the menu, say): the
      // question is answered.
      if endSheet.isVisible, endSheet.session?.id == view.id, view.state != "ending", view.remainingSeconds > 0 {
        endSheet.hide()
      }
    }
  }

  func showEndSheet(_ view: SessionView) {
    onMain { [self] in
      menuBar.update(view)
      endSheet.show(view)
    }
  }

  func dismissEndSheet() {
    onMain { [self] in endSheet.dismiss() }
  }
}

/// What Core conforms to once the session PR adds `presenter` to it.
protocol PresenterHost: AnyObject { var presenter: SessionPresenter { get set } }

/// Gives the daemon its UI. Called once from runServer() on the main thread,
/// before any request is served.
func attachPresenter(to core: AnyObject) {
  let ui = UIPresenter()
  if ProcessInfo.processInfo.environment["FOCUS_UI_DEMO"] == "1" {
    // Debug only: a fake session drives the UI instead of Core.
    UIDemo.start(ui)
    return
  }
  // Step 2a adds `presenter` to Core; until it is merged this is a no-op.
  if let host = core as? PresenterHost { host.presenter = ui; ui.delegate = host as? SessionPresenterDelegate }
}

/// An accessory app has no menu bar of its own, and without a main menu
/// the note field gets no ⌘C, ⌘V, ⌘A or ⌘Z. No Quit item: ⌘Q must not stop
/// the daemon.
func installEditMenu() {
  let main = NSMenu()
  let appItem = NSMenuItem()
  appItem.submenu = NSMenu()
  main.addItem(appItem)
  let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
  let edit = NSMenu(title: "Edit")
  edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
  edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
  edit.addItem(.separator())
  edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
  edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
  editItem.submenu = edit
  main.addItem(editItem)
  NSApp.mainMenu = main
}

// MARK: - Demo session (FOCUS_UI_DEMO=1)

/// A stand-in for the session logic so the menu bar and the sheet can be
/// seen for real before Core drives them. It ticks every second and reaches
/// "Time's up" after FOCUS_UI_DEMO_SHEET_AFTER seconds (20). Pause, Resume,
/// Extend, Stop and Finish work from the menu and the sheet; answers are
/// written to stderr. Also read: FOCUS_UI_DEMO_GOAL ("Demo"),
/// FOCUS_UI_DEMO_SECONDS (1500), FOCUS_UI_DEMO_PAUSED=1 (start paused), and
/// FOCUS_UI_DEMO_RATING / FOCUS_UI_DEMO_NOTE to prefill the sheet for a capture.
final class UIDemo: SessionPresenterDelegate {
  private static var current: UIDemo?

  static func start(_ ui: UIPresenter) {
    let demo = UIDemo(ui: ui, environment: ProcessInfo.processInfo.environment)
    current = demo
    demo.run()
  }

  private let ui: UIPresenter
  private var view: SessionView
  private let sheetAfter: TimeInterval
  private var sheetAt: Date
  private var pausedAt: Date?
  private var pausedTotal: TimeInterval = 0
  private var timer: Timer?
  private let prefill: (rating: Int?, note: String?)

  private init(ui: UIPresenter, environment: [String: String]) {
    self.ui = ui
    let now = Date()
    let seconds = environment["FOCUS_UI_DEMO_SECONDS"].flatMap(Int.init) ?? 1500
    sheetAfter = environment["FOCUS_UI_DEMO_SHEET_AFTER"].flatMap(TimeInterval.init) ?? 20
    sheetAt = now.addingTimeInterval(sheetAfter)
    view = SessionView(
      id: 1, goal: environment["FOCUS_UI_DEMO_GOAL"] ?? "Demo", state: "running", startedAt: now,
      plannedEnd: now.addingTimeInterval(TimeInterval(seconds)), remainingSeconds: seconds, pausedSeconds: 0,
      calendarTitle: "Work", extendOptions: [300, 600, 900, 1500])
    prefill = (environment["FOCUS_UI_DEMO_RATING"].flatMap(Int.init), environment["FOCUS_UI_DEMO_NOTE"])
    if environment["FOCUS_UI_DEMO_PAUSED"] == "1" {
      pausedAt = now
      view.state = "paused"
    }
    ui.delegate = self
  }

  private func say(_ message: String) {
    FileHandle.standardError.write(Data("focus-daemon ui demo: \(message)\n".utf8))
  }

  private func run() {
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    say("started \"\(view.goal)\", sheet in \(Int(sheetAfter)) s")
    tick()
    // For `screencapture -l`: status item windows are not always listed by
    // CGWindowListCopyWindowInfo (menu bar managers park them off screen).
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
      if let window = ui.menuBar.statusItem.button?.window {
        say("status item window \(window.windowNumber) at \(NSStringFromRect(window.frame))")
      }
    }
  }

  private func tick() {
    let now = Date()
    view.pausedSeconds = Int(pausedTotal + (pausedAt.map { now.timeIntervalSince($0) } ?? 0))
    if view.state != "ending" && now >= sheetAt {
      view.plannedEnd = now
      end()
      return
    }
    view.remainingSeconds = view.state == "ending" ? 0 : max(0, Int(view.plannedEnd.timeIntervalSince(now).rounded(.up)))
    ui.update(view)
  }

  private func end() {
    view.state = "ending"
    view.remainingSeconds = 0
    ui.update(view)
    ui.showEndSheet(view)
    if let rating = prefill.rating { ui.endSheet.stars.rating = rating }
    if let note = prefill.note { ui.endSheet.noteField.stringValue = note }
  }

  func presenterPause() {
    say("pause")
    pausedAt = Date()
    view.state = "paused"
    tick()
  }

  func presenterResume() {
    say("resume")
    if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
    pausedAt = nil
    view.state = "running"
    tick()
  }

  func presenterExtend(seconds: Int) {
    say("extend \(seconds) s")
    let now = Date()
    view.plannedEnd = max(view.plannedEnd, now).addingTimeInterval(TimeInterval(seconds))
    if let pausedAt { pausedTotal += now.timeIntervalSince(pausedAt) }
    pausedAt = nil
    view.state = "running"
    sheetAt = now.addingTimeInterval(sheetAfter)
    tick()
  }

  func presenterStop() {
    say("stop")
    end()
  }

  func presenterFinish(rating: Int?, note: String?) {
    say("finish rating=\(rating.map(String.init) ?? "none") note=\(note.map { "\"\($0)\"" } ?? "none")")
    timer?.invalidate()
    timer = nil
    ui.update(nil)
    ui.dismissEndSheet()
  }
}
