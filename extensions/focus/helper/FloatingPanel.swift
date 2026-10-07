import AppKit
import Foundation

// MARK: - Floating countdown panel
//
// The countdown as a small pill that floats over every window and space,
// like Raycast Focus: a rounded time chip ("44:50", monospaced) and the goal
// beside it. The pill fills with green from the left as the session runs
// (elapsed over planned length; an extension lowers the fill). Paused shows
// ⏸ before the digits on a dimmer chip.
//
// On hover the pill swaps to its controls: Pause (a menu: 1, 2, 5, 10
// minutes or indefinitely; Resume while paused), Complete, "…" (Edit,
// Cancel, Move to Menu Bar, Move to Notch, Reset Panel Position) and a drag handle at the
// right edge, the only place the panel can be dragged from. Every action
// goes to `actions` (UIPresenter), which talks to the session logic and to
// config.json.
//
// The panel keeps its top edge when it changes size, and the side nearer
// the screen edge it sits against: a pill on the right half grows to the
// left. Its saved position is the idle pill's top-left.
//
// The pill is dark green liquid glass (Glass.swift): the glass or HUD blur
// behind, the tint and edges painted on. Main thread only.

/// A screen's full frame and the part not covered by the menu bar and the Dock.
struct ScreenGeometry: Equatable {
  var frame: NSRect
  var visibleFrame: NSRect

  /// Every screen, the main one (the one with the key window) first.
  static func current() -> [ScreenGeometry] {
    var screens = NSScreen.screens
    if let main = NSScreen.main, let index = screens.firstIndex(of: main) {
      screens.remove(at: index)
      screens.insert(main, at: 0)
    }
    return screens.map { ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame) }
  }

  /// A rect of `size` at the top centre: centred on the whole screen,
  /// `PanelStyle.margin` below the menu bar. The countdown panel's default
  /// place and the end card's.
  func topCentre(_ size: NSSize) -> NSRect {
    NSRect(
      x: (frame.midX - size.width / 2).rounded(),
      y: (visibleFrame.maxY - PanelStyle.margin - size.height).rounded(), width: size.width, height: size.height)
  }
}

/// Runs work later on the main thread; the tests pass a fake clock instead.
protocol UIScheduler: AnyObject {
  @discardableResult
  func after(_ seconds: TimeInterval, _ body: @escaping () -> Void) -> ScheduledTask
}

/// Something `UIScheduler.after` will run, until it is cancelled.
final class ScheduledTask {
  private var onCancel: (() -> Void)?
  private(set) var isCancelled = false
  init(onCancel: (() -> Void)? = nil) { self.onCancel = onCancel }
  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    onCancel?()
    onCancel = nil
  }
}

final class MainScheduler: UIScheduler {
  @discardableResult
  func after(_ seconds: TimeInterval, _ body: @escaping () -> Void) -> ScheduledTask {
    let item = DispatchWorkItem(block: body)
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
    return ScheduledTask { item.cancel() }
  }
}

/// What the panel's controls ask for. UIPresenter implements it.
protocol FloatingPanelActions: AnyObject {
  /// Pause for `seconds`, then resume by itself; nil pauses until Resume.
  func panelPause(for seconds: Int?)
  func panelResume()
  func panelComplete()
  func panelEdit()
  func panelCancel()
  func panelMoveToMenuBar()
  func panelMoveToNotch()
  func panelResetPosition()
  /// The panel was dragged; `topLeft` is the idle pill's new top-left.
  func panelMoved(topLeft: NSPoint)
}

// MARK: Views

/// Borderless, never key: clicks reach the buttons without taking focus from
/// the app in front.
final class CountdownPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  /// setFrame(_:display:animate:) takes this long: the hover change.
  override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { PanelStyle.animation }
}

/// The idle pill: chip and goal, drawn in one pass.
/// Six dots at the right edge; the only place the panel moves from.
final class DragHandleView: NSView {
  weak var owner: FloatingPanel?
  private var hovering = false {
    didSet { needsDisplay = true }
  }
  private var trackingArea: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  /// AppKit only calls updateTrackingAreas on a geometry change, so the
  /// area goes in as soon as the view is in its window too.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateTrackingAreas()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

  override func mouseDown(with event: NSEvent) {
    NSCursor.closedHand.push()
    owner?.beginDrag(at: NSEvent.mouseLocation)
  }
  override func mouseDragged(with event: NSEvent) { owner?.drag(to: NSEvent.mouseLocation) }
  override func mouseUp(with event: NSEvent) {
    NSCursor.pop()
    owner?.endDrag()
  }

  override func draw(_ dirtyRect: NSRect) {
    (hovering ? PanelStyle.handleHover : PanelStyle.handle).setFill()
    let dot: CGFloat = 2.6
    let gapX: CGFloat = 3.4
    let gapY: CGFloat = 3.4
    let width = dot * 2 + gapX
    let height = dot * 3 + gapY * 2
    let x0 = (bounds.midX - width / 2).rounded()
    let y0 = (bounds.midY - height / 2).rounded()
    for row in 0..<3 {
      for column in 0..<2 {
        let rect = NSRect(
          x: x0 + CGFloat(column) * (dot + gapX), y: y0 + CGFloat(row) * (dot + gapY), width: dot, height: dot)
        NSBezierPath(ovalIn: rect).fill()
      }
    }
  }
}

/// The panel's tint (over the glass, or denser over the older HUD blur) and
/// the hover tracking for the whole panel.
final class PanelChromeView: NSView {
  weak var owner: FloatingPanel?
  var canvas = GlassStyle.tint {
    didSet { needsDisplay = true }
  }
  private var trackingArea: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  /// AppKit only calls updateTrackingAreas on a geometry change, so the
  /// area goes in as soon as the view is in its window too.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateTrackingAreas()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { owner?.pointerMoved(inside: true) }
  override func mouseExited(with event: NSEvent) { owner?.pointerMoved(inside: false) }

  override func draw(_ dirtyRect: NSRect) {
    canvas.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: PanelStyle.radius, yRadius: PanelStyle.radius).fill()
  }
}

// MARK: Panel

final class FloatingPanel: NSObject {
  weak var actions: FloatingPanelActions?
  let panel: CountdownPanel
  /// True when the backdrop is `NSGlassEffectView` (macOS 26), false for the HUD blur.
  let usesGlass: Bool
  /// The window's content view: the glass, or the HUD blur before macOS 26.
  private(set) var backdrop = NSView()
  let chrome = PanelChromeView()
  let pill = CountdownPillView()
  /// The glass's rim, highlight and sheen, over the pill and the controls.
  let edges = GlassEdgesView()
  /// The lava lamp: soft green blobs drifting over the tint, under the rest.
  let lava = LiveBackgroundView()
  let controls = NSView()
  let pauseButton = PanelButton(title: "Pause", symbol: "pause")
  let completeButton = PanelButton(title: "Complete", symbol: "checkmark")
  let moreButton = PanelButton(title: "", symbol: "ellipsis", label: "More")
  let handle = DragHandleView()
  let pauseMenu = NSMenu(title: "Pause")
  let moreMenu = NSMenu(title: "More")

  /// Tests: order the panel in far off screen and skip animations. `frame`
  /// still reports where it would be.
  var headless = false
  /// Shows a menu under a button; the tests record instead.
  var popUpMenu: (NSMenu, NSView) -> Void = { menu, view in
    let y = view.isFlipped ? view.bounds.maxY + 5 : -5
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
  }
  var screens: () -> [ScreenGeometry]
  private let scheduler: UIScheduler

  private(set) var content: PanelContent?
  private(set) var session: SessionView?
  private(set) var isHovering = false
  private(set) var isVisible = false
  /// Where the panel is (headless included): the idle pill, or the controls row on hover.
  private(set) var frame = NSRect.zero
  /// The idle pill's frame; the controls row is laid out from it.
  private(set) var idleFrame = NSRect.zero
  /// True when the pill keeps its right edge as it changes width.
  private(set) var anchoredRight = true
  private var placed = false
  private var exitTask: ScheduledTask?
  private var menuOpen = false
  private var dragStart: (mouse: NSPoint, frame: NSRect)?
  /// Where the pointer was last seen, so enter and exit fire once per crossing.
  private(set) var pointerInside = false
  /// Checks the pointer 10 times a second while the panel shows, next to the
  /// tracking area: entered and exited events are not guaranteed for a
  /// non-activating panel of a background app.
  private var pointerTimer: Timer?
  /// The wall clock the sweep reads; the tests pass a fake one.
  var clock: () -> Date = Date.init
  /// Where the sweep is between updates.
  private(set) var sweep = PanelSweep()
  /// Moves the sweep on about 30 times a second while the countdown moves.
  private var sweepTimer: Timer?
  static let sweepInterval: TimeInterval = 1.0 / 30

  /// `glass` false forces the pre-macOS 26 backdrop (the tests cover both).
  init(
    scheduler: UIScheduler, screens: @escaping () -> [ScreenGeometry] = ScreenGeometry.current,
    glass: Bool = GlassBackdrop.isAvailable
  ) {
    self.scheduler = scheduler
    self.screens = screens
    usesGlass = glass && GlassBackdrop.isAvailable
    panel = CountdownPanel(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: PanelStyle.idleHeight),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    super.init()
    build()
  }

  // MARK: Building

  private func build() {
    panel.level = FloatingPanel.level
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.animationBehavior = .none
    panel.title = "Focus countdown"

    // Glass (or the HUD blur with the tint painted on) behind everything;
    // the chrome holds the lava lamp, then the pill, the controls and the
    // edges on top.
    chrome.owner = self
    chrome.frame = NSRect(x: 0, y: 0, width: 160, height: PanelStyle.idleHeight)
    chrome.autoresizingMask = [.width, .height]
    chrome.canvas = usesGlass ? GlassStyle.tint : GlassStyle.fallbackCanvas
    backdrop = GlassBackdrop.make(radius: PanelStyle.radius, content: chrome, glass: usesGlass)
    backdrop.autoresizingMask = [.width, .height]
    panel.contentView = backdrop

    // Still until the panel shows.
    lava.setRunning(false)
    lava.frame = chrome.bounds
    lava.autoresizingMask = [.width, .height]
    lava.radius = PanelStyle.radius
    chrome.addSubview(lava)

    pill.frame = chrome.bounds
    pill.autoresizingMask = [.width, .height]
    pill.wantsLayer = true
    pill.setAccessibilityElement(true)
    pill.setAccessibilityRole(.staticText)
    chrome.addSubview(pill)

    // The row's own height, pinned to the top: the panel grows downwards
    // into it on hover, and the buttons never move inside it.
    controls.frame = NSRect(
      x: 0, y: chrome.bounds.height - PanelStyle.hoverHeight, width: chrome.bounds.width, height: PanelStyle.hoverHeight)
    controls.autoresizingMask = [.width, .minYMargin]
    controls.wantsLayer = true
    controls.alphaValue = 0
    controls.isHidden = true
    chrome.addSubview(controls)
    for button in [pauseButton, completeButton, moreButton] {
      button.target = self
      controls.addSubview(button)
    }
    pauseButton.action = #selector(pauseClicked)
    completeButton.action = #selector(completeClicked)
    moreButton.action = #selector(moreClicked)
    handle.owner = self
    handle.setAccessibilityElement(true)
    handle.setAccessibilityRole(.handle)
    handle.setAccessibilityLabel("Move")
    controls.addSubview(handle)
    layoutControls()

    edges.frame = chrome.bounds
    edges.autoresizingMask = [.width, .height]
    edges.radius = PanelStyle.radius
    chrome.addSubview(edges)

    pauseMenu.autoenablesItems = false
    pauseMenu.appearance = NSAppearance(named: .darkAqua)
    for (title, seconds) in Self.pauseChoices {
      if seconds < 0 {
        pauseMenu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(title: title, action: #selector(pauseChosen(_:)), keyEquivalent: "")
      item.target = self
      item.tag = seconds
      pauseMenu.addItem(item)
    }

    moreMenu.autoenablesItems = false
    moreMenu.appearance = NSAppearance(named: .darkAqua)
    for (title, symbol, action) in [
      ("Edit", "pencil", #selector(editChosen)),
      ("Cancel", "xmark.circle", #selector(cancelChosen)),
      ("", "", nil),
      ("Move to Menu Bar", "menubar.rectangle", #selector(moveChosen)),
      ("Move to Notch", "macbook", #selector(moveToNotchChosen)),
      ("Reset Panel Position", "arrow.counterclockwise", #selector(resetChosen)),
    ] as [(String, String, Selector?)] {
      guard let action else {
        moreMenu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      moreMenu.addItem(item)
    }
  }

  /// Above ordinary floating windows (the block page among them), so the
  /// countdown stays reachable while an app is blocked; below the end sheet.
  static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

  /// Pause menu titles and seconds; -1 is a separator, 0 is "until Resume".
  static let pauseChoices = CountdownModel.pauseChoices

  /// The controls row's width.
  var controlsWidth: CGFloat {
    PanelStyle.inset + Self.pauseSlot + PanelStyle.buttonGap + completeButton.preferredWidth
      + PanelStyle.buttonGap + moreButton.preferredWidth + 2 + PanelStyle.handleWidth + 4
  }

  private func layoutControls() {
    let y = ((PanelStyle.hoverHeight - PanelStyle.buttonHeight) / 2).rounded()
    var x = PanelStyle.inset
    for button in [pauseButton, completeButton, moreButton] {
      let width = button === pauseButton ? Self.pauseSlot : button.preferredWidth
      button.frame = NSRect(x: x, y: y, width: width, height: PanelStyle.buttonHeight)
      button.autoresizingMask = [.maxXMargin]
      x += width + PanelStyle.buttonGap
    }
    handle.frame = NSRect(x: x - PanelStyle.buttonGap + 2, y: y, width: PanelStyle.handleWidth, height: PanelStyle.buttonHeight)
    handle.autoresizingMask = [.maxXMargin]
  }

  // MARK: Geometry (pure)

  /// The default place: top centre of `screen`, `margin` below the menu
  /// bar, where the end card shows.
  static func defaultFrame(width: CGFloat, on screen: ScreenGeometry) -> NSRect {
    screen.topCentre(NSSize(width: width, height: PanelStyle.idleHeight))
  }

  /// True when `rect` is on a screen: fully inside one vertically and at
  /// least 40 points of it (or all of a narrower one) across.
  static func isOnScreen(_ rect: NSRect, screens: [ScreenGeometry]) -> Bool {
    screens.contains { screen in
      let overlap = screen.frame.intersection(rect)
      return !overlap.isNull && overlap.height >= rect.height - 0.5 && overlap.width >= min(rect.width, 40) - 0.5
    }
  }

  /// The idle pill's frame from a saved top-left, or the default when there
  /// is none or it is off every screen (a display was unplugged).
  static func idleFrame(width: CGFloat, saved: PanelPosition?, screens: [ScreenGeometry]) -> NSRect {
    if let saved {
      let rect = NSRect(
        x: CGFloat(saved.x), y: CGFloat(saved.y) - PanelStyle.idleHeight, width: width, height: PanelStyle.idleHeight)
      if isOnScreen(rect, screens: screens) { return rect }
    }
    guard let main = screens.first else {
      return NSRect(x: 0, y: 0, width: width, height: PanelStyle.idleHeight)
    }
    return defaultFrame(width: width, on: main)
  }

  /// `idle` moved just enough that both the pill and the wider, taller
  /// controls row laid out from it lie in the visible frame (below the menu
  /// bar, clear of the Dock) of the screen it overlaps most, so a
  /// panel parked half off an edge still shows every control on hover.
  static func fitted(_ idle: NSRect, controlsWidth: CGFloat, anchoredRight: Bool, screens: [ScreenGeometry]) -> NSRect {
    let hover = resized(idle, to: NSSize(width: controlsWidth, height: PanelStyle.hoverHeight), anchoredRight: anchoredRight)
    let envelope = idle.union(hover)
    let area = { (screen: ScreenGeometry) -> CGFloat in
      let overlap = screen.frame.intersection(envelope)
      return overlap.isNull ? 0 : overlap.width * overlap.height
    }
    guard let screen = screens.max(by: { area($0) < area($1) }), area(screen) > 0 else { return idle }
    // The visible frame: the panel sits below the menu bar's level, so any
    // part under the menu bar (or the Dock) could not be reached.
    let bounds = screen.visibleFrame
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    if envelope.minX < bounds.minX { dx = bounds.minX - envelope.minX }
    if envelope.maxX > bounds.maxX { dx = bounds.maxX - envelope.maxX }
    if envelope.minY < bounds.minY { dy = bounds.minY - envelope.minY }
    if envelope.maxY > bounds.maxY { dy = bounds.maxY - envelope.maxY }
    return idle.offsetBy(dx: dx, dy: dy)
  }

  /// Right half of its screen (or of the main one) keeps the right edge.
  static func anchorsRight(_ rect: NSRect, screens: [ScreenGeometry]) -> Bool {
    let screen = screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) } ?? screens.first
    guard let screen else { return true }
    return rect.midX >= screen.frame.midX
  }

  /// `rect` resized to `size`, keeping its top edge and its anchored side.
  static func resized(_ rect: NSRect, to size: NSSize, anchoredRight: Bool) -> NSRect {
    NSRect(
      x: anchoredRight ? rect.maxX - size.width : rect.minX, y: rect.maxY - size.height, width: size.width,
      height: size.height)
  }

  // MARK: Showing

  /// Shows (or refreshes) the pill for `view`. The first show places it from
  /// `saved`; later ones keep where it is.
  func show(_ view: SessionView, saved: PanelPosition?) {
    session = view
    let content = PanelContent(view)
    self.content = content
    pill.content = content
    pill.setAccessibilityLabel("Focus: \(content.paused ? "paused, " : "")\(content.clock) left, \(content.goal)")
    panel.setAccessibilityTitle("Focus countdown")
    updateControls(view)

    // The pill takes the controls row's width whatever the goal says, so the
    // panel never changes size on hover; a long goal is truncated inside it.
    let width = controlsWidth
    // A display unplugged under the panel: back to the default place.
    if placed, dragStart == nil, !Self.isOnScreen(idleFrame, screens: screens()) { placed = false }
    if !placed {
      idleFrame = Self.idleFrame(width: width, saved: saved, screens: screens())
      anchoredRight = Self.anchorsRight(idleFrame, screens: screens())
      idleFrame = Self.fitted(idleFrame, controlsWidth: controlsWidth, anchoredRight: anchoredRight, screens: screens())
      placed = true
      apply(isHovering ? hoverFrame() : idleFrame, animated: false)
    } else if idleFrame.width != width {
      idleFrame = Self.resized(idleFrame, to: NSSize(width: width, height: PanelStyle.idleHeight), anchoredRight: anchoredRight)
      if !isHovering { apply(idleFrame, animated: false) }
    }
    if !isVisible {
      isVisible = true
      panel.orderFrontRegardless()
      startPointerPolling()
    }
    // The lamp drifts while the session runs; paused dims and freezes it.
    lava.dimmed = content.paused
    lava.setRunning(!content.paused)

    sweep.update(view, at: clock())
    advanceSweep()
    updateSweepTimer()
  }

  private func startPointerPolling() {
    guard !headless, pointerTimer == nil else { return }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, self.isVisible else { return }
      self.pointerMoved(inside: self.panel.frame.contains(NSEvent.mouseLocation))
    }
    RunLoop.main.add(timer, forMode: .common)
    pointerTimer = timer
  }

  /// Hides the panel; the next show puts it back where it was.
  func hide() {
    exitTask?.cancel()
    exitTask = nil
    pointerTimer?.invalidate()
    pointerTimer = nil
    sweepTimer?.invalidate()
    sweepTimer = nil
    pointerInside = false
    if isHovering { setHovering(false, animated: false) }
    lava.setRunning(false)
    guard isVisible else { return }
    isVisible = false
    panel.orderOut(nil)
  }

  /// Moves the sweep to where the clock says it is now.
  func advanceSweep() {
    pill.progress = sweep.progress(at: clock())
  }

  /// True while the sweep timer should run: shown, the countdown moving,
  /// not yet full.
  var sweepMoves: Bool {
    isVisible && sweep.moving && sweep.progress(at: clock()) < 1
  }

  private func updateSweepTimer() {
    if !sweepMoves || headless {
      sweepTimer?.invalidate()
      sweepTimer = nil
      return
    }
    guard sweepTimer == nil else { return }
    let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.advanceSweep()
      if !self.sweepMoves { self.updateSweepTimer() }
    }
    timer.tolerance = Self.sweepInterval / 4
    RunLoop.main.add(timer, forMode: .common)
    sweepTimer = timer
  }

  /// True while the 30 Hz sweep timer runs (never headless).
  var sweepTimerRunning: Bool { sweepTimer != nil }

  /// Back to the default place (Reset Panel Position).
  func resetPosition() {
    let width = controlsWidth
    idleFrame = Self.idleFrame(width: width, saved: nil, screens: screens())
    anchoredRight = Self.anchorsRight(idleFrame, screens: screens())
    placed = true
    apply(isHovering ? hoverFrame() : idleFrame, animated: true)
  }

  /// Forget the place, so the next show reads the saved position again.
  func forgetPlacement() { placed = false }

  private func hoverFrame() -> NSRect {
    Self.resized(idleFrame, to: NSSize(width: controlsWidth, height: PanelStyle.hoverHeight), anchoredRight: anchoredRight)
  }

  private func apply(_ rect: NSRect, animated: Bool) {
    frame = rect
    let actual = headless ? rect.offsetBy(dx: -40000, dy: -40000) : rect
    // A window's frame does not animate through its animator proxy; this
    // runs the resize over animationResizeTime (0.15 s).
    panel.setFrame(actual, display: true, animate: animated && !headless && panel.isVisible)
    panel.invalidateShadow()
  }

  private func updateControls(_ view: SessionView) {
    let paused = view.state == "paused"
    pauseButton.set(
      title: paused ? "Resume" : "Pause", symbol: paused ? "play" : "pause",
      label: paused ? "Resume" : "Pause")
    completeButton.setAccessibilityLabel("Complete")
  }

  /// Pause and Resume share one width so the row does not jump.
  static let pauseSlot: CGFloat = max(
    PanelButton(title: "Pause", symbol: "pause").preferredWidth,
    PanelButton(title: "Resume", symbol: "play").preferredWidth)

  // MARK: Hover

  /// The pointer crossed the panel's edge (tracking area or poll); repeats are ignored.
  func pointerMoved(inside: Bool) {
    guard inside != pointerInside else { return }
    pointerInside = inside
    if inside { mouseEntered() } else { mouseExited() }
  }

  func mouseEntered() {
    exitTask?.cancel()
    exitTask = nil
    guard isVisible else { return }
    setHovering(true, animated: true)
  }

  func mouseExited() {
    guard !menuOpen, dragStart == nil else { return }
    exitTask?.cancel()
    exitTask = scheduler.after(PanelStyle.hoverExitDelay) { [weak self] in
      guard let self else { return }
      self.exitTask = nil
      self.setHovering(false, animated: true)
    }
  }

  func setHovering(_ hovering: Bool, animated: Bool) {
    guard hovering != isHovering else { return }
    isHovering = hovering
    let target = hovering ? hoverFrame() : idleFrame
    if hovering { controls.isHidden = false } else { pill.isHidden = false }
    if animated && !headless {
      // The two rows cross-fade (layer-backed, so off the main thread)
      // while the window resizes.
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = PanelStyle.animation
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pill.animator().alphaValue = hovering ? 0 : 1
        controls.animator().alphaValue = hovering ? 1 : 0
      }, completionHandler: { [weak self] in
        guard let self else { return }
        // Only if the state did not flip back meanwhile.
        if self.isHovering { self.pill.isHidden = true } else { self.controls.isHidden = true }
      })
      apply(target, animated: true)
    } else {
      pill.alphaValue = hovering ? 0 : 1
      controls.alphaValue = hovering ? 1 : 0
      pill.isHidden = hovering
      controls.isHidden = !hovering
      apply(target, animated: false)
    }
    if !hovering { [pauseButton, completeButton, moreButton].forEach { $0.resetHover() } }
  }

  /// After a menu closes: leave the hover state if the mouse left meanwhile.
  private func recheckHover() {
    guard !headless else { return }
    if !panel.frame.contains(NSEvent.mouseLocation) {
      pointerInside = false
      mouseExited()
    }
  }

  // MARK: Drag

  func beginDrag(at mouse: NSPoint) {
    exitTask?.cancel()
    exitTask = nil
    dragStart = (mouse, frame)
  }

  /// Moves what is on screen (the controls row, normally) with the mouse;
  /// the idle pill follows from it.
  func drag(to mouse: NSPoint) {
    guard let start = dragStart else { return }
    let moved = start.frame.offsetBy(dx: (mouse.x - start.mouse.x).rounded(), dy: (mouse.y - start.mouse.y).rounded())
    idleFrame = idle(from: moved)
    apply(moved, animated: false)
  }

  /// Where the drag ends decides the side the panel grows from; the row
  /// stays where it was dropped and the idle pill is laid out from it.
  func endDrag() {
    guard let start = dragStart else { return }
    dragStart = nil
    if frame == start.frame { return }
    anchoredRight = Self.anchorsRight(frame, screens: screens())
    idleFrame = idle(from: frame)
    // Dropped partly off the screen: slide back so every control shows.
    let fitted = Self.fitted(idleFrame, controlsWidth: controlsWidth, anchoredRight: anchoredRight, screens: screens())
    if fitted != idleFrame {
      idleFrame = fitted
      apply(isHovering ? hoverFrame() : idleFrame, animated: true)
    }
    actions?.panelMoved(topLeft: NSPoint(x: idleFrame.minX, y: idleFrame.maxY))
    recheckHover()
  }

  private func idle(from visible: NSRect) -> NSRect {
    guard isHovering else { return visible }
    return Self.resized(visible, to: NSSize(width: idleFrame.width, height: PanelStyle.idleHeight), anchoredRight: anchoredRight)
  }

  // MARK: Actions

  private func runMenu(_ menu: NSMenu, from view: NSView) {
    menuOpen = true
    exitTask?.cancel()
    exitTask = nil
    popUpMenu(menu, view)
    menuOpen = false
    (view as? PanelButton)?.resetHover()
    recheckHover()
  }

  @objc func pauseClicked() {
    guard let session, session.state != "ending" else { return }
    if session.state == "paused" {
      actions?.panelResume()
    } else {
      runMenu(pauseMenu, from: pauseButton)
    }
  }

  @objc func completeClicked() {
    guard let session, session.state != "ending" else { return }
    actions?.panelComplete()
  }

  @objc func moreClicked() { runMenu(moreMenu, from: moreButton) }

  @objc private func pauseChosen(_ sender: NSMenuItem) {
    guard session?.state == "running" else { return }
    actions?.panelPause(for: sender.tag > 0 ? sender.tag : nil)
  }

  @objc private func editChosen() { actions?.panelEdit() }
  @objc private func cancelChosen() { actions?.panelCancel() }
  @objc private func moveChosen() { actions?.panelMoveToMenuBar() }
  @objc private func moveToNotchChosen() { actions?.panelMoveToNotch() }
  @objc private func resetChosen() { actions?.panelResetPosition() }
}
