import AppKit
import Foundation

// MARK: - The presenter behind the session logic
//
// UIPresenter is what the session logic (Core) drives through
// SessionPresenter. It owns the two countdown displays, the floating panel
// (FloatingPanel.swift, the default) and the menu bar item (MenuBar.swift),
// and shows exactly one of them per `countdownDisplay` in config.json, read
// again whenever the file changes. It also owns the end sheet (EndSheet.swift),
// the completion sequence (Completion.swift) played when the timer runs out
// before the sheet appears, the timer behind "Pause for N minutes", and the
// two config writes the panel makes (display and position). Main thread only.

final class UIPresenter: SessionPresenter, FloatingPanelActions {
  weak var delegate: SessionPresenterDelegate? {
    didSet {
      menuBar.delegate = delegate
      endSheet.delegate = delegate
    }
  }
  let menuBar: MenuBar
  let endSheet: EndSheet
  let floating: FloatingPanel
  let completion: Completion
  /// config.json; nil uses the defaults (the panel) and writes nothing.
  let settings: ConfigFile?
  let scheduler: UIScheduler
  /// Plays the completion when the timer runs out. The UI demo turns it off
  /// unless FOCUS_UI_DEMO_COMPLETE=1.
  var completionEnabled = true
  /// Opens Focus Today for the panel's Edit; the tests record instead.
  var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
  var log: (String) -> Void

  private let clock: () -> Date
  private let screens: () -> [ScreenGeometry]
  /// The last view Core sent (nil while idle).
  private(set) var lastView: SessionView?
  /// The last session seen running or paused: only such a session plays the
  /// completion, so a daemon restarted at the end sheet does not replay it.
  private var liveSessionId: Int?
  /// The end sheet waiting for the completion to finish.
  private(set) var pendingSheet: (id: Int, task: ScheduledTask)?
  /// "Pause for N minutes": resumes the session when it fires.
  private(set) var timedPause: (sessionId: Int, task: ScheduledTask, seenPaused: Bool, armedAt: Date)?
  private var positionWrite: ScheduledTask?
  private var cachedConfig = FocusConfig()
  private var cachedStamp: [FileAttributeKey: AnyHashable]?

  /// Edit in the panel's "…" menu opens this.
  static let editURL = URL(string: "raycast://extensions/c-wenlong/focus/focusToday")!
  /// A timed pause that has not shown as paused this long after it was asked for was refused.
  static let pauseGrace: TimeInterval = 3
  /// A dragged panel's position is written this long after the drag ends.
  static let positionDelay: TimeInterval = 0.4

  /// The tests pass a private NSStatusBar, a fixed clock, a config file in a
  /// temp folder, a fake scheduler, a fake sound and fixed screens.
  init(
    statusBar: NSStatusBar = .system, clock: @escaping () -> Date = Date.init, settings: ConfigFile? = nil,
    scheduler: UIScheduler = MainScheduler(), sound: CompletionSound = SystemCompletionSound(),
    screens: @escaping () -> [ScreenGeometry] = ScreenGeometry.current, log: @escaping (String) -> Void = { _ in }
  ) {
    self.clock = clock
    self.settings = settings
    self.scheduler = scheduler
    self.screens = screens
    self.log = log
    menuBar = MenuBar(statusBar: statusBar)
    endSheet = EndSheet(clock: clock)
    floating = FloatingPanel(scheduler: scheduler, screens: screens)
    completion = Completion(scheduler: scheduler, sound: sound)
    floating.actions = self
    menuBar.onMoveToPanel = { [weak self] in self?.setDisplay(.panel) }
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

  // MARK: Config

  /// config.json as it is now; parsed again only when the file changed.
  func currentConfig() -> FocusConfig {
    guard let settings else { return cachedConfig }
    let attributes = (try? FileManager.default.attributesOfItem(atPath: settings.path)) ?? [:]
    var stamp: [FileAttributeKey: AnyHashable] = [:]
    for key in [FileAttributeKey.modificationDate, .size, .systemFileNumber] {
      if let value = attributes[key] as? AnyHashable { stamp[key] = value }
    }
    if cachedStamp == nil || stamp.isEmpty || cachedStamp! != stamp {
      cachedConfig = settings.load()
      cachedStamp = stamp.isEmpty ? nil : stamp
    }
    return cachedConfig
  }

  var display: CountdownDisplay { currentConfig().countdownDisplay }

  private func write(_ changes: [String: JSONValue]) -> Bool {
    guard let settings else { return false }
    do {
      try settings.update(changes)
      cachedStamp = nil
      return true
    } catch {
      log("could not update \(settings.path): \((error as? FocusError)?.message ?? error.localizedDescription)")
      return false
    }
  }

  /// Writes the display and switches to it at once.
  func setDisplay(_ display: CountdownDisplay) {
    onMain { [self] in
      _ = write(["countdownDisplay": .string(display.rawValue)])
      if settings == nil { cachedConfig.countdownDisplay = display }
      refresh(lastView)
    }
  }

  // MARK: SessionPresenter

  func update(_ view: SessionView?) {
    onMain { [self] in refresh(view) }
  }

  /// Shows `view` on the display config asks for and hides the other.
  private func refresh(_ view: SessionView?) {
    lastView = view
    let config = currentConfig()
    let usePanel = config.countdownDisplay == .panel
    menuBar.update(usePanel ? nil : view)
    followTimedPause(view)
    guard let view else {
      // No session left, so nothing for a sheet to ask about.
      liveSessionId = nil
      cancelPendingSheet()
      floating.hide()
      if endSheet.isVisible { endSheet.dismiss() }
      return
    }
    if view.state == "running" || view.state == "paused" { liveSessionId = view.id }
    // The panel is for a live session: hidden at the end sheet and while
    // the completion plays.
    if usePanel && view.state != "ending" && pendingSheet == nil {
      floating.show(view, saved: config.panelPosition)
    } else {
      floating.hide()
    }
    // Extended (or finished) while the banner was up: no sheet after it.
    if let pending = pendingSheet, pending.id != view.id || view.state != "ending" {
      cancelPendingSheet()
      if usePanel && view.state != "ending" { floating.show(view, saved: config.panelPosition) }
    }
    // Back to running or paused (extended from the menu, say): the
    // question is answered.
    if endSheet.isVisible, endSheet.session?.id == view.id, view.state != "ending", view.remainingSeconds > 0 {
      endSheet.hide()
    }
  }

  func showEndSheet(_ view: SessionView) {
    onMain { [self] in
      lastView = view
      menuBar.update(display == .panel ? nil : view)
      floating.hide()
      if pendingSheet?.id == view.id { return }  // shown once the completion is over
      let timerRanOut = EndSheet.headline(view, now: clock()) == "Time's up"
      if completionEnabled, timerRanOut, liveSessionId == view.id, !endSheet.isVisible {
        liveSessionId = nil
        completion.play(screens: screens())
        let task = scheduler.after(Completion.duration) { [weak self] in self?.showPendingSheet() }
        pendingSheet = (view.id, task)
        return
      }
      endSheet.show(view)
    }
  }

  func dismissEndSheet() {
    onMain { [self] in
      cancelPendingSheet()
      endSheet.dismiss()
    }
  }

  private func showPendingSheet() {
    guard let pending = pendingSheet else { return }
    pendingSheet = nil
    guard let view = lastView, view.id == pending.id, view.state == "ending" else { return }
    endSheet.show(view)
  }

  private func cancelPendingSheet() {
    pendingSheet?.task.cancel()
    pendingSheet = nil
  }

  // MARK: Timed pause

  /// Drops the timer once the session is no longer the paused one it was
  /// set for: resumed from anywhere, stopped, finished, or never paused.
  private func followTimedPause(_ view: SessionView?) {
    guard var pause = timedPause else { return }
    guard let view, view.id == pause.sessionId else { return cancelTimedPause() }
    if view.state == "paused" {
      pause.seenPaused = true
      timedPause = pause
    } else if pause.seenPaused || clock().timeIntervalSince(pause.armedAt) > Self.pauseGrace {
      cancelTimedPause()
    }
  }

  private func cancelTimedPause() {
    timedPause?.task.cancel()
    timedPause = nil
  }

  // MARK: FloatingPanelActions

  func panelPause(for seconds: Int?) {
    cancelTimedPause()
    guard let view = lastView, view.state == "running" else { return }
    delegate?.presenterPause()
    guard let seconds, seconds > 0 else { return }
    let id = view.id
    let task = scheduler.after(TimeInterval(seconds)) { [weak self] in
      guard let self, let pause = self.timedPause, pause.sessionId == id else { return }
      self.timedPause = nil
      guard let view = self.lastView, view.id == id, view.state == "paused" else { return }
      self.delegate?.presenterResume()
    }
    timedPause = (id, task, false, clock())
  }

  func panelResume() {
    cancelTimedPause()
    delegate?.presenterResume()
  }

  func panelComplete() { delegate?.presenterStop() }

  func panelEdit() { openURL(Self.editURL) }

  /// Ends the session now: no rating, no note, no end sheet.
  func panelCancel() {
    cancelTimedPause()
    delegate?.presenterFinish(rating: nil, note: nil)
  }

  func panelMoveToMenuBar() { setDisplay(.menuBar) }

  func panelResetPosition() {
    positionWrite?.cancel()
    positionWrite = nil
    _ = write(["panelPosition": .null])
    if settings == nil { cachedConfig.panelPosition = nil }
    floating.resetPosition()
  }

  func panelMoved(topLeft: NSPoint) {
    let position = PanelPosition(x: Double(topLeft.x), y: Double(topLeft.y))
    if settings == nil { cachedConfig.panelPosition = position }
    positionWrite?.cancel()
    positionWrite = scheduler.after(Self.positionDelay) { [weak self] in
      self?.positionWrite = nil
      _ = self?.write(["panelPosition": position.json])
    }
  }
}

/// Gives the daemon its UI. Called once from runServer() on the main thread,
/// before any request is served. `configPath` is config.json, read for the
/// countdown display and written by the panel.
func attachPresenter(to core: AnyObject, configPath: String? = nil, log: @escaping (String) -> Void = { _ in }) {
  let ui = UIPresenter(settings: configPath.map { ConfigFile(path: $0, log: log) }, log: log)
  if ProcessInfo.processInfo.environment["FOCUS_UI_DEMO"] == "1" {
    // Debug only: a fake session drives the UI instead of Core.
    UIDemo.start(ui)
    return
  }
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
/// FOCUS_UI_DEMO_SECONDS (1500), FOCUS_UI_DEMO_PAUSED=1 (start paused),
/// FOCUS_UI_DEMO_RATING / FOCUS_UI_DEMO_NOTE to prefill the sheet for a
/// capture, FOCUS_UI_DEMO_COMPLETE=1 to play the completion (sound, edge
/// glow, banner) before the sheet, as when a real timer runs out, and
/// FOCUS_UI_DEMO_CAPTURE=<folder> to write what the live windows draw every
/// half second (panel.png, banner.png, glow.png at a quarter size, and
/// state.txt), for a shell without Screen Recording.
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
  private var menuLog: [String] = []

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
    ui.completionEnabled = environment["FOCUS_UI_DEMO_COMPLETE"] == "1"
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
    if let folder = ProcessInfo.processInfo.environment["FOCUS_UI_DEMO_CAPTURE"] {
      // Menus cannot be captured without Screen Recording: log them, and
      // close each after 2 s so a check never leaves one open.
      NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) {
        [weak self] note in
        guard let menu = note.object as? NSMenu else { return }
        self?.menuLog.append("\(menu.title): \(menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "|"))")
        let close = Timer(timeInterval: 2, repeats: false) { _ in menu.cancelTracking() }
        RunLoop.main.add(close, forMode: .common)
      }
      let capture = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.capture(to: folder) }
      RunLoop.main.add(capture, forMode: .common)
    }
    tick()
    // For `screencapture -l`: status item windows are not always listed by
    // CGWindowListCopyWindowInfo (menu bar managers park them off screen).
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
      if let window = ui.menuBar.statusItem.button?.window {
        say("status item window \(window.windowNumber) at \(NSStringFromRect(window.frame))")
      }
    }
  }

  /// Writes the live views as they draw now: no blur behind the panel and
  /// no window shadow (those come from the window server), everything else
  /// as on screen, at the screen's scale.
  private func capture(to folder: String) {
    func write(_ view: NSView, _ name: String, scale: CGFloat, background: NSColor, pad: CGFloat) {
      let bounds = view.bounds
      guard bounds.width > 0,
        let inner = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0),
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int((bounds.width + pad * 2) * scale),
          pixelsHigh: Int((bounds.height + pad * 2) * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      else { return }
      inner.size = bounds.size
      rep.size = NSSize(width: bounds.width + pad * 2, height: bounds.height + pad * 2)
      view.cacheDisplay(in: bounds, to: inner)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      background.setFill()
      NSRect(origin: .zero, size: rep.size).fill()
      inner.draw(
        in: NSRect(x: pad, y: pad, width: bounds.width, height: bounds.height), from: .zero, operation: .sourceOver,
        fraction: 1, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name))
    }
    let grey = NSColor(white: 0.42, alpha: 1)
    let panel = ui.floating
    let scale = panel.panel.screen?.backingScaleFactor ?? 2
    if panel.isVisible { write(panel.chrome, "panel.png", scale: scale, background: grey, pad: 12) }
    if ui.completion.isBannerVisible {
      write(ui.completion.bannerView, "banner.png", scale: scale, background: grey, pad: 12)
      if let glow = ui.completion.glowWindows.first?.contentView {
        write(glow, "glow.png", scale: 0.25, background: grey, pad: 0)
      }
    }
    let mouse = NSEvent.mouseLocation
    let lines = [
      "time \(ISO.local(Date()))", "state \(view.state)", "panelVisible \(panel.isVisible)",
      "hovering \(panel.isHovering)", "frame \(NSStringFromRect(panel.panel.frame))",
      "mouse \(NSStringFromPoint(mouse)) inside \(panel.panel.frame.contains(mouse))",
      "title \(panel.content?.titleText ?? "")", "progress \(panel.content?.progress ?? 0)",
      "pauseButton \(panel.pauseButton.title)", "menuBarVisible \(ui.menuBar.statusItem.isVisible)",
      "completion \(ui.completion.trace.joined(separator: ","))", "glowVisible \(ui.completion.isGlowVisible)",
      "glowFrames \(ui.completion.glowWindows.filter(\.isVisible).map { NSStringFromRect($0.frame) })",
      "bannerVisible \(ui.completion.isBannerVisible) \(NSStringFromRect(ui.completion.banner.frame))",
      "sheetVisible \(ui.endSheet.isVisible)", "menus \(menuLog.joined(separator: " / "))",
    ]
    try? (lines.joined(separator: "\n") + "\n").write(toFile: folder + "/state.txt", atomically: true, encoding: .utf8)
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
