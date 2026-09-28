import AppKit
import Foundation

// MARK: - The presenter behind the session logic
//
// UIPresenter is what the session logic (Core) drives through
// SessionPresenter. It owns the two countdown displays, the floating panel
// (FloatingPanel.swift, the default) and the menu bar item (MenuBar.swift),
// and shows exactly one of them per `countdownDisplay` in config.json, read
// again whenever the file changes. It also owns the end sheet (EndSheet.swift)
// and its auto-finish (the end card: its timer, hover polling and whether it
// was used), the completion sound and glow (Completion.swift) played with the
// card when the timer runs out, the timer behind "Pause for N minutes", and
// the two config writes the panel makes (display and position). Main thread
// only.

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
  /// Where the pointer is, for the end card's hover poll; the tests and the
  /// UI demo pass a fixed or synthetic point.
  var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
  var log: (String) -> Void

  private let clock: () -> Date
  private let screens: () -> [ScreenGeometry]
  /// The last view Core sent (nil while idle).
  private(set) var lastView: SessionView?
  /// The last session seen running or paused: only such a session plays the
  /// completion, so a daemon restarted at the end sheet does not replay it.
  private var liveSessionId: Int?
  /// The end card's auto-finish while the sheet shows: `engaged` once
  /// anything on it was used (then it waits for Finish or Extend),
  /// `pointerInside` while hovered (the countdown is paused).
  private(set) var endCard: (sessionId: Int, engaged: Bool, pointerInside: Bool)?
  /// The countdown: the fade's start, its steps (headless), the finish.
  private var endCardTasks: [ScheduledTask] = []
  private var endCardPoll: ScheduledTask?
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
  /// How often the pointer is checked over the end card, as for the panel.
  static let pointerPoll: TimeInterval = 0.1

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
    endSheet.onEngage = { [weak self] in self?.endCardEngaged() }
    endSheet.onHide = { [weak self] in self?.stopEndCard() }
    endSheet.onPointer = { [weak self] inside in self?.endCardPointerMoved(inside: inside) }
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
      floating.hide()
      if endSheet.isVisible { endSheet.dismiss() }
      return
    }
    if view.state == "running" || view.state == "paused" { liveSessionId = view.id }
    // The panel is for a live session: hidden at the end sheet.
    if usePanel && view.state != "ending" {
      floating.show(view, saved: config.panelPosition)
    } else {
      floating.hide()
    }
    // Back to running or paused (extended from the menu, say): the
    // question is answered.
    if endSheet.isVisible, endSheet.session?.id == view.id, view.state != "ending", view.remainingSeconds > 0 {
      endSheet.hide()
    }
  }

  /// The sheet shows at once as the end card, top centre of the main screen
  /// (the glow's screen rule). When the timer ran out on a session this UI
  /// saw live, the sound and glow play with it.
  func showEndSheet(_ view: SessionView) {
    onMain { [self] in
      lastView = view
      menuBar.update(display == .panel ? nil : view)
      floating.hide()
      let timerRanOut = EndSheet.headline(view, now: clock()) == "Time's up"
      if completionEnabled, timerRanOut, liveSessionId == view.id, !endSheet.isVisible {
        liveSessionId = nil
        completion.play(screens: screens())
      }
      // A refresh of the card already up keeps its countdown.
      let fresh = !endSheet.isVisible || endSheet.session?.id != view.id
      endSheet.show(view, on: screens().first)
      if fresh { startEndCard(view.id) }
    }
  }

  func dismissEndSheet() {
    onMain { [self] in endSheet.dismiss() }
  }

  // MARK: End card (auto-finish)

  /// A new card: opaque, fading out and finishing by itself over `autoFinishAfter`.
  private func startEndCard(_ id: Int) {
    stopEndCard()
    endCard = (id, false, false)
    armEndCard()
    pollEndCardPointer()
  }

  /// The card went away: no countdown, no poll.
  private func stopEndCard() {
    cancelEndCardCountdown()
    endCardPoll?.cancel()
    endCardPoll = nil
    endCard = nil
  }

  private func cancelEndCardCountdown() {
    endCardTasks.forEach { $0.cancel() }
    endCardTasks = []
  }

  /// The whole 5 s again, from now: opaque, then one continuous linear fade
  /// to clear over `autoFinishAfter` (an animation live, 60 steps a second
  /// on the scheduler headless), then the finish. Only showing the card and
  /// the pointer leaving it start this; `update` never does.
  private func armEndCard() {
    cancelEndCardCountdown()
    let window = endSheet.panel
    let life = EndSheet.autoFinishAfter
    window.alphaValue = 1
    if endSheet.headless {
      let steps = Int(life * 60)
      for step in 1...steps {
        let alpha = 1 - CGFloat(step) / CGFloat(steps)
        endCardTasks.append(scheduler.after(life * Double(step) / Double(steps)) { window.alphaValue = alpha })
      }
    } else {
      // Replaces any snap back to opaque still running.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = life
        context.timingFunction = CAMediaTimingFunction(name: .linear)
        window.animator().alphaValue = 0
      }
    }
    endCardTasks.append(scheduler.after(life) { [weak self] in self?.autoFinish() })
  }

  /// Left alone: the same as Finish with nothing filled in (EndSheet.finish
  /// sends what the card shows, which is nothing unless this session's card
  /// came back after an extend with a rating or note on it).
  private func autoFinish() {
    guard let card = endCard, !card.engaged, !card.pointerInside, endSheet.isVisible,
      endSheet.session?.id == card.sessionId
    else { return }
    endSheet.panel.alphaValue = 0
    endSheet.finish()
  }

  /// Snaps back to fully opaque, cutting a fade short.
  private func setEndCardOpaque() {
    let window = endSheet.panel
    if endSheet.headless || !window.isVisible {
      window.alphaValue = 1
      return
    }
    // A new animation on the same key replaces the running fade.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.1
      window.animator().alphaValue = 1
    }
  }

  /// Something on the card was used: no auto-finish for this card.
  private func endCardEngaged() {
    guard var card = endCard, !card.engaged else { return }
    card.engaged = true
    endCard = card
    cancelEndCardCountdown()
    endCardPoll?.cancel()
    endCardPoll = nil
    setEndCardOpaque()
  }

  /// The pointer crossed the card's edge (tracking area or poll); repeats
  /// are ignored. Inside pauses the countdown at full opacity; leaving
  /// starts the whole window again.
  func endCardPointerMoved(inside: Bool) {
    onMain { [self] in
      guard var card = endCard, inside != card.pointerInside else { return }
      card.pointerInside = inside
      endCard = card
      guard !card.engaged else { return }
      if inside {
        cancelEndCardCountdown()
        setEndCardOpaque()
      } else {
        armEndCard()
      }
    }
  }

  /// Checks the pointer 10 times a second while the card counts down: the
  /// tracking area's entered and exited events are not guaranteed for a
  /// non-activating panel of a background app.
  private func pollEndCardPointer() {
    endCardPoll = scheduler.after(Self.pointerPoll) { [weak self] in
      guard let self, let card = self.endCard, !card.engaged, self.endSheet.isVisible else { return }
      self.endCardPointerMoved(inside: self.endSheet.frame.contains(self.pointerLocation()))
      self.pollEndCardPointer()
    }
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
/// glow) with the card, as when a real timer runs out,
/// FOCUS_UI_DEMO_HOVER=<from>-<to> (seconds after the card shows) to report
/// the pointer over the card in that window and far from it otherwise (a
/// synthetic hover through the real poll; the real pointer's crossings are
/// only logged), and FOCUS_UI_DEMO_CAPTURE=<folder> to write what the live
/// windows draw every half second (panel.png, glow.png at a quarter size,
/// state.txt) and, while the card shows, every quarter second: card-<ms>.png
/// (the card at its current alpha over grey), screen-<ms>.png (the main
/// screen at half size: the glow and the card where they are) and a line in
/// card.txt, <ms> being the time since the card appeared. For a shell
/// without Screen Recording.
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
  /// When the card last appeared, for the hover window and the captures.
  private var cardShownAt: Date?
  private let hoverWindow: ClosedRange<TimeInterval>?

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
    let hover = (environment["FOCUS_UI_DEMO_HOVER"] ?? "").split(separator: "-").compactMap { TimeInterval($0) }
    hoverWindow = hover.count == 2 && hover[0] <= hover[1] ? hover[0]...hover[1] : nil
    ui.delegate = self
    // Tracking-area crossings go to stderr; with a synthetic hover they are
    // not passed on, so the real pointer cannot disturb a capture.
    let synthetic = hoverWindow != nil
    ui.endSheet.onPointer = { [weak self, weak ui] inside in
      self?.say("tracking area: pointer \(inside ? "entered" : "left") the card\(synthetic ? " (ignored)" : "")")
      if !synthetic { ui?.endCardPointerMoved(inside: inside) }
    }
    if let hoverWindow {
      // The poll asks where the pointer is: over the card's middle inside
      // the window, far away otherwise.
      ui.pointerLocation = { [weak self, weak ui] in
        guard let self, let ui, let shown = self.cardShownAt,
          hoverWindow.contains(Date().timeIntervalSince(shown))
        else { return NSPoint(x: -100_000, y: -100_000) }
        let frame = ui.endSheet.frame
        return NSPoint(x: frame.midX, y: frame.midY)
      }
    }
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
      let card = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.captureCard(to: folder) }
      RunLoop.main.add(card, forMode: .common)
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
    if ui.completion.isGlowVisible, let window = ui.completion.glowWindows.first,
      let glow = GlowImageView.image(for: window.frame.size)
    {
      try? NSBitmapImageRep(cgImage: glow).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: folder + "/glow.png"))
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
      "sheetVisible \(ui.endSheet.isVisible) \(NSStringFromRect(ui.endSheet.frame)) alpha \(ui.endSheet.panel.alphaValue)",
      "menus \(menuLog.joined(separator: " / "))",
    ]
    try? (lines.joined(separator: "\n") + "\n").write(toFile: folder + "/state.txt", atomically: true, encoding: .utf8)
  }

  /// While the card shows: the card at its alpha over grey, the main screen
  /// at half size with the glow and the card where they are, and a line in
  /// card.txt. What the window server adds (shadow, rounded corners, the
  /// desktop) is not in them.
  private func captureCard(to folder: String) {
    guard let shown = cardShownAt, ui.endSheet.isVisible else { return }
    let elapsed = Date().timeIntervalSince(shown)
    let stamp = String(format: "%05d", Int((elapsed * 1000).rounded()))
    let card = ui.endSheet
    let cardAlpha = card.panel.alphaValue
    let grey = NSColor(white: 0.42, alpha: 1)
    func bitmap(_ size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      rep?.size = size
      return rep
    }
    func snapshot(_ view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
      guard view.bounds.width > 0, let rep = bitmap(view.bounds.size, scale: scale) else { return nil }
      view.cacheDisplay(in: view.bounds, to: rep)
      return rep
    }
    func save(_ rep: NSBitmapImageRep, _ name: String) {
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name))
    }
    let scale = card.panel.screen?.backingScaleFactor ?? 2
    // The card alone, padded, at its current alpha.
    if let inner = snapshot(card.content, scale: scale) {
      let pad: CGFloat = 16
      let size = NSSize(width: card.content.bounds.width + pad * 2, height: card.content.bounds.height + pad * 2)
      if let rep = bitmap(size, scale: scale) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        grey.setFill()
        NSRect(origin: .zero, size: size).fill()
        inner.draw(
          in: NSRect(x: pad, y: pad, width: card.content.bounds.width, height: card.content.bounds.height), from: .zero,
          operation: .sourceOver, fraction: cardAlpha, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        save(rep, "card-\(stamp).png")
      }
    }
    // The main screen at half size: grey, the glow, the card.
    let glowWindow = ui.completion.glowWindows.first { $0.isVisible }
    if let screen = ScreenGeometry.current().first, let rep = bitmap(screen.frame.size, scale: 0.5) {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      grey.setFill()
      NSRect(origin: .zero, size: screen.frame.size).fill()
      if let glowWindow, let glow = GlowImageView.image(for: glowWindow.frame.size) {
        NSBitmapImageRep(cgImage: glow).draw(
          in: NSRect(origin: .zero, size: screen.frame.size), from: .zero, operation: .sourceOver,
          fraction: glowWindow.alphaValue, respectFlipped: true, hints: nil)
      }
      if let inner = snapshot(card.content, scale: 1) {
        let at = card.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        inner.draw(in: at, from: .zero, operation: .sourceOver, fraction: cardAlpha, respectFlipped: true, hints: nil)
      }
      NSGraphicsContext.restoreGraphicsState()
      save(rep, "screen-\(stamp).png")
    }
    let pointer = NSEvent.mouseLocation
    let state = (ui.endCard.map { "engaged \($0.engaged) hovering \($0.pointerInside)" } ?? "no card")
      + " realPointer \(NSStringFromPoint(pointer)) inside \(card.frame.contains(pointer))"
    let line = String(
      format: "%@ ms alpha %.3f frame %@ screen %@ %@ glow %@ %.3f\n", stamp, Double(cardAlpha),
      NSStringFromRect(card.frame), ScreenGeometry.current().first.map { NSStringFromRect($0.frame) } ?? "-", state,
      glowWindow == nil ? "off" : "on", Double(glowWindow?.alphaValue ?? 0))
    let path = folder + "/card.txt"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      handle.closeFile()
    } else {
      try? line.write(toFile: path, atomically: true, encoding: .utf8)
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
    cardShownAt = Date()
    ui.showEndSheet(view)
    if let folder = ProcessInfo.processInfo.environment["FOCUS_UI_DEMO_CAPTURE"] { captureCard(to: folder) }
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
    cardShownAt = nil
    say("finish rating=\(rating.map(String.init) ?? "none") note=\(note.map { "\"\($0)\"" } ?? "none")")
    timer?.invalidate()
    timer = nil
    ui.update(nil)
    ui.dismissEndSheet()
  }
}
