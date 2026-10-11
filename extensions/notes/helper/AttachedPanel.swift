import AppKit
import Foundation

// MARK: - The attached window
//
// One key-capable, borderless, nonactivating NSPanel hosts the same editor
// root as the floating window: under the menu bar item for `menuBar`
// (a rounded dark card under the status button) or at the notch for
// `notch` (a black island like Focus's, a strip at rest that grows down
// into the editor). A slim header replaces the floating window's toolbar
// (title or Focus/Notes tabs, the Focus clock, and the Actions / Browse /
// New buttons). Hover, outside clicks, Esc, ⌘W and the socket commands
// all funnel into `expand`/`collapse`; expansion is explicit state, never
// inferred from isVisible.

/// The keys the attached window routes to PanelController's commands:
/// Esc and ⌘W collapse, ⌘K opens the palette, ⌘M collapses.
final class AttachedWindow: NSPanel {
  var onCommand: ((String) -> Void)?

  /// Unlike Focus's island this window takes the keyboard: it is an editor.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if super.performKeyEquivalent(with: event) { return true }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    guard flags == .command else { return false }
    switch key {
    case "w", "m": onCommand?("hide"); return true
    case "k": onCommand?("palette"); return true
    default: return false
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {  // escape
      onCommand?("hide")
      return
    }
    super.keyDown(with: event)
  }
}

/// Clicks count only inside the island's outline, so the clear corners
/// and flares of an open card never react (Focus's NotchRootView rule).
final class AttachedRootView: NSView {
  weak var island: IslandShapeView?
  var capturesClick: () -> Bool = { false }
  var onClick: () -> Void = {}

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { onClick() }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let island, !island.isHidden else { return super.hitTest(point) }
    let local = island.convert(point, from: superview)
    guard island.path.contains(local) else { return nil }
    if capturesClick() { return self }
    return super.hitTest(point)
  }
}

/// The black shape, at whatever size the animation has reached: black
/// under the menu bar band, easing to the editor's dark canvas below.
final class IslandShapeView: NSView {
  var body = NSRect.zero { didSet { if body != oldValue { needsDisplay = true } } }
  var radius: CGFloat = NotchMetrics.stripRadius { didSet { if radius != oldValue { needsDisplay = true } } }
  var barHeight: CGFloat = 32

  var path: NSBezierPath { NotchGeometry.path(body: body, radius: radius) }

  override func draw(_ dirtyRect: NSRect) {
    guard body.width > 0, body.height > 0 else { return }
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSColor.black.setFill()
    bounds.fill()
    let fadeTop = bounds.maxY - barHeight - 2
    let fade = NSRect(
      x: bounds.minX, y: fadeTop - NotchMetrics.canvasFade, width: bounds.width, height: NotchMetrics.canvasFade)
    NSGradient(starting: Markdown.canvas, ending: .black)?.draw(in: fade, angle: 90)
    Markdown.canvas.setFill()
    NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, fade.minY - bounds.minY)).fill()
    NSGraphicsContext.restoreGraphicsState()
  }
}

/// The collapsed strip's content: the notes symbol in the left wing and,
/// while a Focus session is shared, its clock in the right wing (green
/// running, dimmed paused, like Focus's own strip).
final class IslandStripView: NSView {
  var leftWing: CGFloat = 40
  var rightWing: CGFloat = 40
  var barHeight: CGFloat = 32
  var clockText: String? { didSet { if clockText != oldValue { needsDisplay = true } } }
  var paused = false { didSet { if paused != oldValue { needsDisplay = true } } }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// The wing widths for the current content.
  static func wings(clock: String?) -> (left: CGFloat, right: CGFloat) {
    let icon = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notes")?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    let left = NotchGeometry.wing(contentWidth: icon?.size.width ?? 13)
    guard let clock else { return (left, left) }
    let text = NSAttributedString(string: clock, attributes: [.font: NotchMetrics.clockFont])
    return (left, NotchGeometry.wing(contentWidth: text.size().width))
  }

  /// Where the clock's text starts in a strip `stripWidth` wide: centred
  /// in the right wing between its padding, the inner side (by the notch)
  /// on the wing's left.
  static func clockX(textWidth: CGFloat, stripWidth: CGFloat, rightWing: CGFloat) -> CGFloat {
    let minX = stripWidth - rightWing + NotchMetrics.wingInner
    let width = rightWing - NotchMetrics.wingOuter - NotchMetrics.wingInner
    return (minX + (width - textWidth) / 2).rounded()
  }

  override func draw(_ dirtyRect: NSRect) {
    let bandMidY = bounds.maxY - barHeight / 2
    if let icon = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notes")?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    {
      let tint = NSImage(size: icon.size, flipped: false) { rect in
        NSColor(white: 1, alpha: 0.92).set()
        icon.draw(in: rect)
        rect.fill(using: .sourceAtop)
        return true
      }
      let area = NSRect(x: NotchMetrics.wingOuter, y: 0, width: leftWing - NotchMetrics.wingOuter - NotchMetrics.wingInner, height: 0)
      let x = (area.minX + (area.width - icon.size.width) / 2).rounded()
      tint.draw(at: NSPoint(x: x, y: (bandMidY - icon.size.height / 2).rounded()), from: .zero, operation: .sourceOver, fraction: 1)
    }
    guard let clockText else { return }
    let color = paused ? NotchMetrics.clockPaused : NotchMetrics.focusGreen
    let text = NSAttributedString(
      string: clockText, attributes: [.font: NotchMetrics.clockFont, .foregroundColor: color])
    let x = Self.clockX(textWidth: ceil(text.size().width), stripWidth: bounds.width, rightWing: rightWing)
    let font = NotchMetrics.clockFont
    text.draw(at: NSPoint(x: x, y: (bandMidY - font.capHeight / 2 + font.descender).rounded()))
  }
}

/// The header the attached window has instead of the floating window's
/// toolbar: Focus and Notes tabs when a session is shared (or the note's
/// title when not), the compact Focus countdown, and the Actions /
/// Browse / Settings / New buttons at the right.
final class AttachedHeaderView: NSView {
  static let height: CGFloat = 40

  enum Tab: Int { case focus, notes }

  private let titleLabel = NSTextField(labelWithString: "Notes")
  private let clockLabel = NSTextField(labelWithString: "")
  let focusTab = ChromeButton(glyph: "Focus", font: NSFont.systemFont(ofSize: 12, weight: .semibold), label: "Focus tab")
  let notesTab = ChromeButton(glyph: "Notes", font: NSFont.systemFont(ofSize: 12, weight: .semibold), label: "Notes tab")
  private let actionsButton = ChromeButton(symbol: "command", pointSize: 13, label: "Actions (⌘K)")
  var settingsAnchor: NSView { settingsButton }
  private let settingsButton = ChromeButton(symbol: "gearshape", pointSize: 13, label: "Settings")
  private let browseButton = ChromeButton(symbol: "square.on.square", pointSize: 13, label: "Browse Notes (⌘P)")
  private let newButton = ChromeButton(symbol: "plus", pointSize: 13, label: "New Note (⌘N)")
  private let tabUnderline = NSView()
  /// Second arg pins the card open: clicks pin, hover selection does not.
  var onTab: ((Tab, Bool) -> Void)?
  var onSettings: ((NSView) -> Void)?
  var run: ((String) -> Void)?

  private(set) var tab: Tab = .notes
  private var tabsVisible = false
  private var pendingHoverTab: Tab?

  override init(frame: NSRect) {
    super.init(frame: frame)
    titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.lineBreakMode = .byTruncatingTail

    clockLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    clockLabel.textColor = NotchMetrics.focusGreen

    for button in [focusTab, notesTab] {
      button.cornerRadius = 6
      button.fill = .clear
      addSubview(button)
    }
    focusTab.target = self
    focusTab.action = #selector(focusClicked)
    notesTab.target = self
    notesTab.action = #selector(notesClicked)
    focusTab.onHover = { [weak self] entered in self?.tabHover(.focus, entered: entered) }
    notesTab.onHover = { [weak self] entered in self?.tabHover(.notes, entered: entered) }

    tabUnderline.wantsLayer = true
    tabUnderline.layer?.backgroundColor = Markdown.accent.cgColor
    tabUnderline.isHidden = true
    addSubview(tabUnderline)

    for (button, command) in [(actionsButton, "palette"), (browseButton, "browse"), (newButton, "new")] {
      button.cornerRadius = 7
      button.fill = ChromeColors.pill
      button.target = self
      button.action = #selector(command(_:))
      button.tag = command == "palette" ? 0 : command == "browse" ? 1 : 2
      addSubview(button)
    }
    settingsButton.cornerRadius = 7
    settingsButton.fill = ChromeColors.pill
    settingsButton.target = self
    settingsButton.action = #selector(settingsClicked(_:))
    addSubview(settingsButton)
    addSubview(titleLabel)
    addSubview(clockLabel)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @objc private func settingsClicked(_ sender: ChromeButton) { onSettings?(sender) }
  @objc private func focusClicked() { onTab?(.focus, true) }
  @objc private func notesClicked() { onTab?(.notes, true) }

  /// Tabs switch on hover: resting the pointer on a tab for 0.15 s selects
  /// it (the same dwell the card uses before closing), so a pointer passing
  /// over on the way elsewhere doesn't flick the panel. Leaving the tab or
  /// entering the other one cancels or supersedes the pending switch.
  /// Hover selection passes `pinned: false` so a card the pointer opened
  /// still closes on its own; only a click pins it.
  private func tabHover(_ hovered: Tab, entered: Bool) {
    if entered {
      guard tabsVisible, hovered != tab else { return }
      pendingHoverTab = hovered
      NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(commitHoverTab), object: nil)
      perform(#selector(commitHoverTab), with: nil, afterDelay: 0.15)
    } else {
      guard pendingHoverTab == hovered else { return }
      pendingHoverTab = nil
      NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(commitHoverTab), object: nil)
    }
  }

  @objc private func commitHoverTab() {
    guard tabsVisible, let hovered = pendingHoverTab else { return }
    pendingHoverTab = nil
    if hovered != tab { onTab?(hovered, false) }
  }
  @objc private func command(_ sender: ChromeButton) {
    run?(["palette", "browse", "new"][sender.tag])
  }

  /// `tabs` shows Focus/Notes (a shared session); `title` is the note
  /// title; `clock` is the compact Focus countdown or nil. The goal stays
  /// in the Focus card; the header shows only the countdown.
  func update(tabs: Bool, title: String, clock: String?, paused: Bool) {
    tabsVisible = tabs
    titleLabel.stringValue = title
    clockLabel.stringValue = clock ?? ""
    clockLabel.textColor = paused ? NotchMetrics.clockPaused : NotchMetrics.focusGreen
    set(tab: tab)
    needsLayout = true
  }

  func set(tab: Tab) {
    self.tab = tab
    updateTabAppearance()
    needsLayout = true
  }

  private func updateTabAppearance() {
    focusTab.isHidden = !tabsVisible
    notesTab.isHidden = !tabsVisible
    focusTab.contentTintColor = tab == .focus ? NSColor.labelColor : .secondaryLabelColor
    notesTab.contentTintColor = tab == .notes ? NSColor.labelColor : .secondaryLabelColor
    layoutTabUnderline()
  }

  private func layoutTabUnderline() {
    let selected = tab == .focus ? focusTab : notesTab
    tabUnderline.isHidden = !tabsVisible
    if tabsVisible {
      let width = (tab == .focus ? focusTab : notesTab).frame.width - 12
      tabUnderline.frame = NSRect(x: selected.frame.minX + 6, y: 4, width: width, height: 2)
    }
  }

  override func layout() {
    super.layout()
    let pad: CGFloat = 12
    // Leave a gap before all four controls, including Settings.
    let contentRight = max(pad, bounds.width - pad - (4 * 28 + 3 * 6) - 10)
    var x = pad
    let tabY = (bounds.height - 24) / 2
    if tabsVisible {
      focusTab.frame = NSRect(x: x, y: tabY, width: 52, height: 24)
      x += 52 + 4
      notesTab.frame = NSRect(x: x, y: tabY, width: 52, height: 24)
      x += 52 + 12
      titleLabel.isHidden = true
    } else {
      titleLabel.isHidden = false
      titleLabel.sizeToFit()
      let width = max(0, min(titleLabel.frame.width, bounds.width * 0.4, contentRight - x))
      titleLabel.frame = NSRect(x: x, y: (bounds.height - 17) / 2, width: width, height: 17)
      x += width + 10
    }
    // The compact countdown sits after the tabs/title.
    clockLabel.isHidden = clockLabel.stringValue.isEmpty
    clockLabel.sizeToFit()
    let clockWidth = max(0, min(clockLabel.frame.width, contentRight - x))
    clockLabel.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: clockWidth, height: 15)

    var right = bounds.width - pad
    for button in [newButton, browseButton, settingsButton, actionsButton] {
      button.frame = NSRect(x: right - 28, y: (bounds.height - 28) / 2, width: 28, height: 28)
      right -= 28 + 6
    }
    layoutTabUnderline()
  }
}

/// The Focus tab's content: the original countdown card shared with the
/// floating panel and the native island: the glass pill with its green
/// sweep over the dark green slab, then Pause/Resume, Complete and More.
/// Session state stays with the daemon; every control dispatches through
/// the bridge. The card is always dark, whatever the Notes theme.
final class FocusTabView: NSView {
  /// gap 8 + pill 40 + gap 8 + controls 28 + bottom 14.
  static let naturalHeight: CGFloat = 98

  /// The dark green slab under the pill (the card's black background
  /// cannot show the window server's glass, so the tint is painted).
  private final class SlabView: NSView {
    override func draw(_ dirtyRect: NSRect) {
      GlassStyle.tint.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: PanelStyle.radius, yRadius: PanelStyle.radius).fill()
    }
  }

  private let slab = SlabView()
  private let pill = CountdownPillView()
  private let edges = GlassEdgesView()
  let pauseButton = PanelButton(title: "Pause", symbol: "pause", label: "Pause")
  let completeButton = PanelButton(title: "Complete", symbol: "checkmark", label: "Complete")
  let moreButton = PanelButton(title: "", symbol: "ellipsis", label: "More")
  private(set) var sweep = PanelSweep()
  private var sweepTimer: Timer?
  /// The host's word on visibility: the card is expanded, on the Focus
  /// tab and showing.
  private var active = false
  /// True while the 30 Hz sweep timer runs (tests).
  var sweepRunning: Bool { sweepTimer != nil }
  /// The verbs the daemon advertised in its last reply.
  private(set) var actions: Set<String> = []
  private(set) var session: FocusSession?

  /// Bridge verbs ("pause", "resume", "stop", "extend", "pauseFor",
  /// "edit", "cancel", "moveToPanel", "moveToMenuBar") and seconds.
  var onAction: ((String, Int?) -> Void)?
  /// A menu is opening: pin the card so leaving the hover cannot close it.
  var onEngage: () -> Void = {}
  /// Tests record the menu instead of popping it.
  var popUpMenu: (NSMenu, NSView) -> Void = { menu, view in
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
  }
  var now: () -> Date = Date.init

  override init(frame: NSRect) {
    super.init(frame: frame)
    // The Focus card is always dark, even under a light Notes theme.
    appearance = NSAppearance(named: .darkAqua)
    for view in [slab, pill, edges, pauseButton, completeButton, moreButton] { addSubview(view) }
    pill.wantsLayer = true
    pill.setAccessibilityElement(true)
    pill.setAccessibilityRole(.staticText)
    edges.radius = PanelStyle.radius
    pauseButton.target = self
    pauseButton.action = #selector(pauseClicked)
    completeButton.target = self
    completeButton.action = #selector(completeClicked)
    moreButton.target = self
    moreButton.action = #selector(moreClicked)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  deinit { sweepTimer?.invalidate() }

  /// Detached from its window: the sweep stops (the host re-arms it).
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { setActive(false) }
  }

  override func draw(_ dirtyRect: NSRect) {
    // The Focus card's fixed dark canvas (independent of the Notes theme).
    NSColor(white: 0.10, alpha: 1).setFill()
    dirtyRect.fill()
  }

  /// A button width for `title`, matching PanelButton.preferredWidth.
  private static func width(ofTitle title: String) -> CGFloat {
    let text = NSAttributedString(string: title, attributes: [.font: PanelStyle.buttonFont])
    return ceil(text.size().width) + PanelButton.iconGap + PanelButton.iconSide + PanelButton.padding * 2
  }

  /// The Pause slot is as wide as the widest of Pause, Resume and the
  /// break's "Start now", so the row does not shift when the state flips.
  static var pauseSlot: CGFloat {
    max(width(ofTitle: "Pause"), width(ofTitle: "Resume"), width(ofTitle: "Start now"))
  }

  /// The controls row's width.
  private var rowWidth: CGFloat {
    Self.pauseSlot + PanelStyle.buttonGap + completeButton.preferredWidth
      + PanelStyle.buttonGap + moreButton.preferredWidth
  }

  /// The daemon's session as a SessionView for the shared model views.
  static func adapter(_ session: FocusSession, at now: Date) -> SessionView {
    SessionView(
      id: session.id, goal: session.goal, state: session.isOnBreak ? "break" : session.state,
      startedAt: session.startedAt, plannedEnd: session.plannedEnd,
      remainingSeconds: session.remaining(at: now), pausedSeconds: session.pausedSeconds,
      calendarTitle: session.calendarTitle, extendOptions: session.extendOptions,
      pauseStopsClock: session.pauseStopsClock,
      breakUntil: session.breakUntil, nextFocusSeconds: session.nextFocusSeconds)
  }

  /// The bridge's latest session and capabilities: the pill content and
  /// the sweep update; buttons keep their identity (never rebuilt).
  func update(session: FocusSession?, actions: Set<String>, at now: Date) {
    self.session = session
    self.actions = actions
    for button in [pauseButton, completeButton, moreButton] { button.isEnabled = session != nil }
    // Finish on a break is the new `finishBreak` verb: an old daemon only
    // has the legacy four, so the button is disabled rather than sending a
    // refused action.
    if let session, session.isOnBreak, !actions.contains("finishBreak") {
      completeButton.isEnabled = false
    }
    guard let session else {
      sweep = PanelSweep()
      pill.content = PanelContent(clock: "00:00", paused: false, progress: 0, goal: "")
      pill.progress = 0
      pill.setAccessibilityLabel("")
      updateSweepTimer()
      needsLayout = true
      return
    }
    let view = Self.adapter(session, at: now)
    sweep.update(view, at: now)
    var content = PanelContent(view)
    content.progress = sweep.progress(at: now)
    pill.content = content
    pill.progress = content.progress
    pill.setAccessibilityLabel(content.titleText)
    let paused = session.state == "paused" && !session.isOnBreak
    let onBreak = session.isOnBreak
    pauseButton.set(
      title: onBreak ? "Start now" : paused ? "Resume" : "Pause",
      symbol: onBreak || paused ? "play" : "pause",
      label: onBreak ? "Start the next focus block" : paused ? "Resume" : "Pause")
    completeButton.set(
      title: onBreak ? "Finish" : "Complete", symbol: "checkmark",
      label: onBreak ? "Finish" : "Complete")
    updateSweepTimer()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let pad: CGFloat = 16
    // Pill and controls sit at the top, left-aligned as one compact card
    // even when the scroll view is taller (a tiny screen scrolls).
    let width = min(max(rowWidth, 300), max(0, bounds.width - pad * 2))
    let x = (bounds.width - width) / 2
    let pillY = bounds.height - CGFloat(8) - PanelStyle.idleHeight
    slab.frame = NSRect(x: x, y: pillY, width: width, height: PanelStyle.idleHeight)
    pill.frame = slab.frame
    edges.frame = slab.frame
    let rowY = pillY - CGFloat(8) - PanelStyle.buttonHeight
    var bx = x + (width - rowWidth) / 2
    pauseButton.frame = NSRect(x: bx, y: rowY, width: Self.pauseSlot, height: PanelStyle.buttonHeight)
    bx += Self.pauseSlot + PanelStyle.buttonGap
    completeButton.frame = NSRect(x: bx, y: rowY, width: completeButton.preferredWidth, height: PanelStyle.buttonHeight)
    bx += completeButton.preferredWidth + PanelStyle.buttonGap
    moreButton.frame = NSRect(x: bx, y: rowY, width: moreButton.preferredWidth, height: PanelStyle.buttonHeight)
  }

  // MARK: Sweep

  /// The host calls this when the tab's visibility or selection changes:
  /// the sweep interpolates at 30 Hz only while the card can be seen and
  /// the fill is actually moving. Under Reduce Motion the timer stays off
  /// and the 1 Hz updates still refresh the digits and fill.
  func setActive(_ active: Bool) {
    self.active = active
    updateSweepTimer()
  }

  private func updateSweepTimer() {
    let wantsTimer = active && session != nil && sweep.moving
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if !wantsTimer {
      sweepTimer?.invalidate()
      sweepTimer = nil
      return
    }
    if sweepTimer == nil {
      let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.advanceSweep() }
      RunLoop.main.add(timer, forMode: .common)
      sweepTimer = timer
    }
  }

  /// Moves the pill's fill on with the shared sweep math. Snapshots only
  /// come from `update`, like the native panel: this just advances to now.
  func advanceSweep() {
    guard session != nil else { sweepTimer?.invalidate(); sweepTimer = nil; return }
    let t = now()
    pill.progress = sweep.progress(at: t)
    if !sweep.moving { sweepTimer?.invalidate(); sweepTimer = nil }
  }

  // MARK: Controls

  @objc private func pauseClicked() {
    guard let session, session.state == "running" || session.state == "paused" || session.isOnBreak else { return }
    // On a break this is "Start now": the legacy resume verb starts the
    // next block early.
    if session.isOnBreak || session.state == "paused" {
      onAction?("resume", nil)
    } else {
      onEngage()
      popUpMenu(pauseMenu(), pauseButton)
    }
  }

  @objc private func completeClicked() {
    guard let session else { return }
    // On a break this is Finish: the final finish through the new verb.
    if session.isOnBreak {
      guard actions.contains("finishBreak") else { return }
      onAction?("finishBreak", nil)
      return
    }
    onAction?("stop", nil)
  }

  @objc private func moreClicked() {
    guard session != nil else { return }
    onEngage()
    popUpMenu(moreMenu(), moreButton)
  }

  /// The panel's Pause choices: a timed pause per item (pauseFor), a
  /// separator, then Indefinitely (the legacy pause verb). Timed items are
  /// disabled when the daemon does not advertise them.
  private func pauseMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.appearance = NSAppearance(named: .darkAqua)
    let timedOK = actions.contains("pauseFor")
    for (title, seconds) in CountdownModel.pauseChoices {
      if seconds < 0 {
        menu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(title: title, action: #selector(pauseChosen(_:)), keyEquivalent: "")
      item.target = self
      item.tag = seconds
      item.representedObject = session?.id
      item.isEnabled = seconds == 0 || timedOK
      menu.addItem(item)
    }
    return menu
  }

  /// A menu item only acts for the session the menu was built for, and a
  /// new verb only while the daemon still advertises it.
  private func allowed(_ sender: NSMenuItem, verb: String? = nil) -> Bool {
    guard sender.isEnabled, (sender.representedObject as? Int) == session?.id else { return false }
    return verb.map { actions.contains($0) } ?? true
  }

  @objc private func pauseChosen(_ sender: NSMenuItem) {
    guard session?.state == "running" else { return }
    if sender.tag > 0 {
      guard allowed(sender, verb: "pauseFor") else { return }
      onAction?("pauseFor", sender.tag)
    } else {
      guard allowed(sender) else { return }
      onAction?("pause", nil)
    }
  }

  /// The panel's "…" menu: Edit and Cancel, the display moves, then the
  /// Extend submenu from the live session's options. New verbs are
  /// disabled when the daemon did not advertise them.
  private func moreMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.appearance = NSAppearance(named: .darkAqua)
    func add(_ title: String, _ symbol: String, _ sel: Selector, _ verb: String, legacy: Bool = false) {
      let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
      item.target = self
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      item.representedObject = session?.id
      item.isEnabled = legacy || actions.contains(verb)
      menu.addItem(item)
    }
    add("Edit", "pencil", #selector(editChosen(_:)), "edit")
    add("Cancel", "xmark.circle", #selector(cancelChosen(_:)), "cancel")
    menu.addItem(.separator())
    add("Move to Floating Panel", "macwindow", #selector(movePanelChosen(_:)), "moveToPanel")
    add("Move to Menu Bar", "menubar.rectangle", #selector(moveMenuBarChosen(_:)), "moveToMenuBar")
    menu.addItem(.separator())
    // On a break the only extension is more rest; the pause choices and the
    // focus Extend list do not apply.
    if session?.isOnBreak == true {
      add("+5 min break", "plus.circle", #selector(extendBreakChosen(_:)), "extendBreak")
      return menu
    }
    let extend = NSMenuItem(title: "Extend", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    for seconds in session?.extendOptions ?? [] {
      let item = NSMenuItem(title: "+\(seconds / 60) min", action: #selector(extendChosen(_:)), keyEquivalent: "")
      item.target = self
      item.tag = seconds
      item.representedObject = session?.id
      submenu.addItem(item)
    }
    extend.submenu = submenu
    extend.isEnabled = !(session?.extendOptions.isEmpty ?? true)
    menu.addItem(extend)
    return menu
  }

  @objc private func editChosen(_ sender: NSMenuItem) { if allowed(sender, verb: "edit") { onAction?("edit", nil) } }
  @objc private func cancelChosen(_ sender: NSMenuItem) { if allowed(sender, verb: "cancel") { onAction?("cancel", nil) } }
  @objc private func movePanelChosen(_ sender: NSMenuItem) { if allowed(sender, verb: "moveToPanel") { onAction?("moveToPanel", nil) } }
  @objc private func moveMenuBarChosen(_ sender: NSMenuItem) { if allowed(sender, verb: "moveToMenuBar") { onAction?("moveToMenuBar", nil) } }
  @objc private func extendChosen(_ sender: NSMenuItem) { if allowed(sender) { onAction?("extend", sender.tag) } }
  @objc private func extendBreakChosen(_ sender: NSMenuItem) { if allowed(sender, verb: "extendBreak") { onAction?("extendBreak", 300) } }
}

// MARK: - The panel

/// The attached host: a menu bar card or the notch island, sharing the
/// editor root with the floating window. Main thread only.
final class AttachedPanel: NSObject, NSWindowDelegate {
  let mode: NoteAttachment
  let window: AttachedWindow
  let header = AttachedHeaderView(frame: .zero)
  let focusView = FocusTabView(frame: .zero)
  private let focusScroll = NSScrollView()
  private let root = AttachedRootView()
  private let island = IslandShapeView()
  private let strip = IslandStripView()
  /// Clips the card's content to the island as it grows and shrinks.
  private let clip = NSView()
  private let contentMask = CAShapeLayer()
  private let content = NSView()
  /// The editor root while hosted here; goes back to the floating panel.
  private(set) var editorRoot: NSView?
  /// Where the status button is on screen (menu bar mode).
  var anchor: () -> NSRect? = { nil }
  /// Commands to PanelController ("hide", "palette", "browse", "new", ...).
  var run: (String) -> Void = { _ in }
  var onSettings: ((NSView) -> Void)?
  /// Focus controls to PanelController ("pause", "resume", "stop", "extend").
  var onFocusAction: (String, Int?) -> Void = { _, _ in }
  /// An outside click asks the controller to collapse.
  var onResign: () -> Void = {}
  /// Where the pointer is, for the hover poll; tests pass a fixed point.
  var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
  var screen: () -> NotesNotchScreen? = NotesNotchScreen.current
  /// The wall clock the strip reads; tests pass a fake one.
  var now: () -> Date = Date.init

  private(set) var expanded = false
  private(set) var tab: AttachedHeaderView.Tab = .notes
  /// Click, tab pick or shortcut pins the card open; hover does not.
  private(set) var pinned = false
  private(set) var session: FocusSession?
  /// The verbs the daemon advertised; the Focus tab enables extras by it.
  private(set) var actions: Set<String> = []
  private var expansion: CGFloat = 0
  private var stripRect = NSRect.zero
  private var cardRect = NSRect.zero
  private var layoutScreen: NotesNotchScreen?
  private var pointerTimer: Timer?
  private var animationTimer: Timer?
  private var enterTask: DispatchWorkItem?
  private var exitTask: DispatchWorkItem?
  private var pointerInside = false

  /// The editor's size below the header, before screen clamping.
  static let contentSize = NSSize(width: 560, height: 640)

  init(mode: NoteAttachment) {
    self.mode = mode
    window = AttachedWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.contentSize.width, height: Self.contentSize.height),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    super.init()
    build()
  }

  private func build() {
    window.level = NotchMetrics.level
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.hidesOnDeactivate = false
    window.isMovableByWindowBackground = false
    window.isReleasedWhenClosed = false
    window.becomesKeyOnlyIfNeeded = false
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = mode == .menuBar
    window.animationBehavior = .none
    window.title = "Notes"
    window.delegate = self
    window.onCommand = { [weak self] command in self?.run(command) }

    window.contentView = root
    root.autoresizingMask = [.width, .height]
    island.isHidden = mode != .notch
    island.autoresizingMask = [.width, .height]
    root.island = island
    root.capturesClick = { [weak self] in self?.expanded == false }
    root.onClick = { [weak self] in self?.expand(pinned: true) }
    root.addSubview(island)
    strip.isHidden = mode != .notch
    root.addSubview(strip)

    clip.wantsLayer = true
    clip.layer?.masksToBounds = true
    if mode == .notch { clip.layer?.mask = contentMask }
    root.addSubview(clip)
    content.wantsLayer = true
    clip.addSubview(content)

    content.addSubview(header)
    header.onTab = { [weak self] tab, pinned in
      guard let self else { return }
      // Hover selection only acts on a live session while expanded; the
      // click path keeps its pin and works collapsed as the fallback.
      if !pinned {
        guard self.expanded, self.session != nil else { return }
      }
      self.select(tab: tab, pinned: pinned)
    }
    header.run = { [weak self] command in self?.run(command) }
    header.onSettings = { [weak self] sender in self?.onSettings?(sender) }
    focusScroll.drawsBackground = false
    focusScroll.hasVerticalScroller = true
    focusScroll.autohidesScrollers = true
    focusScroll.documentView = focusView
    content.addSubview(focusScroll)
    focusView.onAction = { [weak self] action, seconds in self?.focusAction(action, seconds: seconds) }
    focusView.onEngage = { [weak self] in self?.pinned = true }

    if mode == .menuBar {
      // The card under the status item: a plain rounded dark panel.
      let background = NSView()
      background.wantsLayer = true
      background.layer?.backgroundColor = Markdown.canvas.cgColor
      background.layer?.cornerRadius = 14
      background.frame = root.bounds
      background.autoresizingMask = [.width, .height]
      root.addSubview(background, positioned: .below, relativeTo: clip)
    }

    updateChrome()
  }

  // MARK: Hosting the editor

  /// Moves the editor root under the header (no reload, no re-read).
  func attach(root editor: NSView) {
    editorRoot = editor
    editor.removeFromSuperview()
    content.addSubview(editor)
    layoutContent()
  }

  /// Stop pending host animations from laying out an editor that moved away.
  func detachEditor() {
    focusView.setActive(false)
    editorRoot?.removeFromSuperview()
    editorRoot = nil
  }

  /// The editor's frame in `content`: everything below the header.
  private var editorRect: NSRect {
    NSRect(x: 0, y: 0, width: content.bounds.width, height: max(0, content.bounds.height - AttachedHeaderView.height))
  }

  private func layoutContent() {
    header.frame = NSRect(
      x: 0, y: content.bounds.height - AttachedHeaderView.height, width: content.bounds.width,
      height: AttachedHeaderView.height)
    focusScroll.frame = editorRect
    // Keep the compact controls usable even when the screen leaves less
    // room than their minimum layout; only Focus scrolls, not the card.
    focusView.frame = NSRect(x: 0, y: 0, width: focusScroll.contentSize.width,
      height: max(FocusTabView.naturalHeight, editorRect.height))
    focusView.autoresizingMask = [.width]
    if tab == .focus {
      // Hidden and off autoresizing: the host can resize without the
      // editor's frame, scroll position or selection moving at all.
      editorRoot?.isHidden = true
      editorRoot?.autoresizingMask = []
    } else {
      editorRoot?.frame = editorRect
      editorRoot?.autoresizingMask = [.width, .height]
      editorRoot?.isHidden = false
    }
    focusScroll.isHidden = tab != .focus || session == nil
    focusView.setActive(expanded && tab == .focus && !focusScroll.isHidden && window.isVisible)
  }

  // MARK: Session

  /// The bridge's latest session: drives the strip clock, the tabs, the
  /// header readout and the Focus tab. Losing the session returns the
  /// Focus tab to Notes.
  func update(session: FocusSession?, actions: Set<String> = []) {
    let hadSession = self.session != nil
    self.session = session
    self.actions = actions
    if session == nil, hadSession, tab == .focus { select(tab: .notes, pinned: pinned) }
    updateChrome()
  }

  /// Refreshes the clock text and the tab content every second.
  func updateChrome() {
    let now = self.now()
    strip.clockText = session?.clock(at: now)
    // A break draws like a pause: muted clock, no green fill.
    strip.paused = session?.state == "paused" || session?.isOnBreak == true
    focusView.update(session: session, actions: actions, at: now)
    let shared = mode == .notch && session != nil
    header.update(
      tabs: shared, title: windowTitle, clock: shared ? session?.clock(at: now) : nil,
      paused: session?.state == "paused" || session?.isOnBreak == true)
    if mode == .notch { relayout() }
    layoutContent()
  }

  /// The note title the header shows when there are no tabs.
  var windowTitle = "Notes" {
    didSet { if windowTitle != oldValue { updateChrome() } }
  }

  // MARK: Expansion

  /// The full open card for the current screen and content size.
  private func cardSize(on screen: NotesNotchScreen) -> NSSize {
    let visible = NSScreen.screens.first(where: { NSRect(origin: $0.frame.origin, size: $0.frame.size) == screen.frame })?.visibleFrame
      ?? screen.frame.insetBy(dx: 0, dy: screen.barHeight)
    // Halve the full expanded island, including its menu bar band.
    let width = min(Self.contentSize.width, visible.width - 8)
    if tab == .focus {
      // The Focus card is compact: header plus the countdown's natural
      // height (the card's own height includes the menu bar band), never
      // taller than the screen leaves. A shorter screen still fits the
      // card; its Focus body scrolls.
      let natural = AttachedHeaderView.height + FocusTabView.naturalHeight - screen.barHeight
      let height = min(natural, visible.height - 8 - screen.barHeight)
      return NSSize(width: width, height: max(8, height))
    }
    // Halve the full expanded island, including its menu bar band.
    let fullHeight = min(Self.contentSize.height + AttachedHeaderView.height, visible.height - 8)
    let height = (fullHeight - screen.barHeight) / 2
    return NSSize(width: width, height: height)
  }

  /// Lays the island out for the current session on the current screen.
  private func relayout() {
    guard mode == .notch, let screen = screen() else { return }
    let wings = IslandStripView.wings(clock: strip.clockText)
    stripRect = NotchGeometry.strip(leftWing: wings.left, rightWing: wings.right, on: screen)
    cardRect = NotchGeometry.card(size: cardSize(on: screen), strip: stripRect, on: screen)
    layoutScreen = screen
    let frame = NotchGeometry.window(card: cardRect, strip: stripRect)
    window.setFrame(frame, display: false, animate: false)
    island.frame = root.bounds
    island.barHeight = screen.barHeight
    strip.frame = local(stripRect)
    strip.leftWing = wings.left
    strip.rightWing = wings.right
    strip.barHeight = screen.barHeight
    content.frame = local(cardRect).offsetBy(dx: 0, dy: 0)
    drawExpansion()
  }

  /// A global rect in the window's coordinates.
  private func local(_ rect: NSRect) -> NSRect {
    let frame = window.frame
    return rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
  }

  /// The top centre of the main screen when the status item's frame is
  /// not available yet.
  private func topAnchor() -> NSRect? {
    guard let screen = NSScreen.main else { return nil }
    return NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 0, height: 0)
  }

  /// Lays the menu bar card under the status item.
  private func relayoutMenuBar() {
    guard let anchor = anchor() ?? topAnchor() else { return }
    let size = NSSize(
      width: Self.contentSize.width,
      height: tab == .focus ? AttachedHeaderView.height + FocusTabView.naturalHeight : Self.contentSize.height)
    var frame = NSRect(x: anchor.midX - size.width / 2, y: anchor.minY - size.height, width: size.width, height: size.height)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) ?? NSScreen.main {
      let visible = screen.visibleFrame
      frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
      frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
    }
    window.setFrame(frame, display: false, animate: false)
    content.frame = root.bounds
  }

  /// Shows the editor: the island grows (or the card appears), `tab`
  /// selected. `pinned` opens are click/shortcut driven and stay until an
  /// explicit close; hover opens unpinned (Focus tab when a session is
  /// shared, Notes otherwise).
  func expand(tab requested: AttachedHeaderView.Tab? = nil, pinned: Bool) {
    self.pinned = self.pinned || pinned
    let tab = requested ?? (session != nil && !pinned ? .focus : .notes)
    select(tab: tab, pinned: pinned)
    guard !expanded else { return }
    expanded = true
    if mode == .notch { relayout() } else { relayoutMenuBar() }
    window.makeKeyAndOrderFront(nil)
    setExpansion(1, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    startPointerPolling()
  }

  /// Orders the collapsed state in: the strip at the notch, or nothing at
  /// all for the menu bar (the status item is its visible part).
  func begin() {
    if mode == .notch {
      relayout()
      window.orderFrontRegardless()
      startPointerPolling()
    }
  }

  /// Back to the strip (notch) or fully away (menu bar).
  func collapse() {
    enterTask?.cancel()
    exitTask?.cancel()
    enterTask = nil
    exitTask = nil
    pinned = false
    pointerInside = false
    focusView.setActive(false)
    guard expanded else { return }
    expanded = false
    if mode == .notch {
      setExpansion(0, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
      window.resignKey()
    } else {
      window.orderOut(nil)
    }
  }

  /// Draws the island at `expansion`; the clip grows with it and the
  /// content fades in over the last half, the strip fading out.
  private func setExpansion(_ target: CGFloat, animated: Bool) {
    animationTimer?.invalidate()
    animationTimer = nil
    if !animated || target == expansion {
      expansion = target
      drawExpansion()
      return
    }
    let start = expansion
    let duration = NotchMetrics.animation * Double(abs(target - start))
    let began = CACurrentMediaTime()
    let growing = target > start
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      let t = duration > 0 ? CGFloat((CACurrentMediaTime() - began) / duration) : 1
      self.expansion = start + (target - start) * NotchGeometry.eased(t, growing: growing)
      self.drawExpansion()
      if t >= 1 { timer.invalidate(); self.animationTimer = nil }
    }
    RunLoop.main.add(timer, forMode: .common)
    animationTimer = timer
  }

  private func drawExpansion() {
    if mode != .notch {
      clip.frame = root.bounds
      content.frame = clip.bounds
      strip.isHidden = true
      layoutContent()
      return
    }
    let shape = NotchGeometry.interpolate(stripRect, cardRect, expansion)
    island.body = local(shape.rect)
    island.radius = shape.radius
    clip.frame = island.body
    // The editor paints its own canvas and footer, so clip those to the
    // same outline as the island instead of covering its rounded corners.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentMask.frame = clip.bounds
    contentMask.path = NotchGeometry.path(body: clip.bounds, radius: shape.radius).cgPath
    CATransaction.commit()
    content.frame = local(cardRect).offsetBy(dx: -clip.frame.minX, dy: -clip.frame.minY)
    strip.alphaValue = max(0, 1 - expansion * 3)
    strip.isHidden = expansion >= 1
    content.alphaValue = max(0, expansion * 2 - 1)
    content.isHidden = expansion <= 0
    layoutContent()
  }

  // MARK: Tabs and actions

  /// Picks a tab: the editor or the Focus controls. Focus without a
  /// session falls back to Notes.
  func select(tab requested: AttachedHeaderView.Tab, pinned: Bool) {
    let tab = requested == .focus && session == nil ? .notes : requested
    self.pinned = self.pinned || pinned
    guard tab != self.tab else { header.set(tab: tab); return }
    // The editor freezes before the host resizes, and unfreezes only after
    // the host is back at the Notes size, so the hidden shrink never moves
    // its frame, scroll position, caret or undo.
    if tab == .focus {
      editorRoot?.isHidden = true
      editorRoot?.autoresizingMask = []
    }
    self.tab = tab
    header.set(tab: tab)
    // Relayout even collapsed: the card's geometry tracks the tab, so a
    // later expand must not hand the editor the stale compact frame first.
    if mode == .notch { relayout() } else { relayoutMenuBar() }
    layoutContent()
  }

  private func focusAction(_ action: String, seconds: Int?) {
    guard let session else { return }
    pinned = true
    switch action {
    case "togglePause": onFocusAction(session.state == "paused" || session.isOnBreak ? "resume" : "pause", nil)
    default: onFocusAction(action, seconds)
    }
  }

  // MARK: Hover and outside clicks

  /// The strip or the card in global coordinates: where the pointer
  /// counts as on the island.
  var hoverRect: NSRect {
    guard mode == .notch, let screen = layoutScreen else { return window.frame }
    return expanded ? cardRect : NotchGeometry.hoverRect(strip: stripRect, on: screen)
  }

  private func startPointerPolling() {
    guard mode == .notch, pointerTimer == nil else { return }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkPointer() }
    RunLoop.main.add(timer, forMode: .common)
    pointerTimer = timer
  }

  func checkPointer() {
    guard mode == .notch, window.isVisible else { return }
    pointerMoved(inside: hoverRect.contains(pointerLocation()))
  }

  /// The pointer crossed the island's edge. Resting 0.5 s on the strip
  /// opens it (unpinned); a hover-opened card closes 0.15 s after the
  /// pointer leaves, but a pinned one never moves on its own.
  func pointerMoved(inside: Bool) {
    guard inside != pointerInside else { return }
    pointerInside = inside
    if inside {
      exitTask?.cancel()
      exitTask = nil
      guard !expanded, enterTask == nil else { return }
      let task = DispatchWorkItem { [weak self] in
        guard let self, self.pointerInside, !self.expanded else { return }
        self.expand(tab: self.session != nil ? .focus : .notes, pinned: false)
      }
      enterTask = task
      DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.enterDelay, execute: task)
    } else {
      enterTask?.cancel()
      enterTask = nil
      guard expanded, !pinned, exitTask == nil else { return }
      let task = DispatchWorkItem { [weak self] in
        guard let self, self.expanded, !self.pinned, !self.pointerInside else { return }
        self.collapse()
      }
      exitTask = task
      DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.exitDelay, execute: task)
    }
  }

  /// The window lost key status. The palette and pickers are children, so
  /// give the key window a beat to settle before calling it an outside click.
  func windowDidResignKey(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.expanded else { return }
      if let key = NSApp.keyWindow, key === self.window || key.parent === self.window { return }
      self.onResign()
    }
  }

  /// The screens changed under us: re-anchor, collapse first if the card
  /// no longer fits where it was.
  func screensChanged() {
    if mode == .notch {
      let screen = screen()
      if screen != layoutScreen { relayout() }
    } else if expanded {
      relayoutMenuBar()
    }
  }
}
