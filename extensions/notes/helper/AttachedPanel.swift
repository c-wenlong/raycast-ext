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
    let textWidth = ceil(text.size().width)
    let area = NSRect(
      x: bounds.maxX - rightWing + NotchMetrics.wingOuter, y: 0,
      width: rightWing - NotchMetrics.wingOuter - NotchMetrics.wingInner, height: 0)
    let x = (area.minX + (area.width - textWidth) / 2).rounded()
    let font = NotchMetrics.clockFont
    text.draw(at: NSPoint(x: x, y: (bandMidY - font.capHeight / 2 + font.descender).rounded()))
  }
}

/// The header the attached window has instead of the floating window's
/// toolbar: Focus and Notes tabs when a session is shared (or the note's
/// title when not), the compact Focus clock and goal, and the Actions /
/// Browse / New buttons at the right.
final class AttachedHeaderView: NSView {
  static let height: CGFloat = 40

  enum Tab: Int { case focus, notes }

  private let titleLabel = NSTextField(labelWithString: "Notes")
  private let clockLabel = NSTextField(labelWithString: "")
  private let goalLabel = NSTextField(labelWithString: "")
  private let focusTab = ChromeButton(glyph: "Focus", font: NSFont.systemFont(ofSize: 12, weight: .semibold), label: "Focus tab")
  private let notesTab = ChromeButton(glyph: "Notes", font: NSFont.systemFont(ofSize: 12, weight: .semibold), label: "Notes tab")
  private let actionsButton = ChromeButton(symbol: "command", pointSize: 13, label: "Actions (⌘K)")
  var settingsAnchor: NSView { settingsButton }
  private let settingsButton = ChromeButton(symbol: "gearshape", pointSize: 13, label: "Settings")
  private let browseButton = ChromeButton(symbol: "square.on.square", pointSize: 13, label: "Browse Notes (⌘P)")
  private let newButton = ChromeButton(symbol: "plus", pointSize: 13, label: "New Note (⌘N)")
  private let tabUnderline = NSView()
  var onTab: ((Tab) -> Void)?
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
    goalLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
    goalLabel.textColor = .secondaryLabelColor
    goalLabel.lineBreakMode = .byTruncatingTail

    for button in [focusTab, notesTab] {
      button.cornerRadius = 6
      button.fill = .clear
      addSubview(button)
    }
    focusTab.target = self
    focusTab.action = #selector(focusClicked)
    focusTab.onHover = { [weak self] entered in self?.tabHover(.focus, entered: entered) }
    notesTab.target = self
    notesTab.action = #selector(notesClicked)
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
    addSubview(goalLabel)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @objc private func settingsClicked(_ sender: ChromeButton) { onSettings?(sender) }
  @objc private func focusClicked() { onTab?(.focus) }
  @objc private func notesClicked() { onTab?(.notes) }

  /// Tabs switch on hover: resting the pointer on a tab for 0.15 s selects
  /// it (the same dwell the card uses before closing), so a pointer passing
  /// over on the way elsewhere doesn't flick the panel. Leaving the tab or
  /// entering the other one cancels or supersedes the pending switch.
  private func tabHover(_ hovered: Tab, entered: Bool) {
    if entered {
      guard hovered != tab else { return }
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
    guard let hovered = pendingHoverTab else { return }
    pendingHoverTab = nil
    if hovered != tab { onTab?(hovered) }
  }
  @objc private func command(_ sender: ChromeButton) {
    run?(["palette", "browse", "new"][sender.tag])
  }

  /// `tabs` shows Focus/Notes (a shared session); `title` is the note
  /// title; `clock`/`goal` are the compact Focus readout or nil.
  func update(tabs: Bool, title: String, clock: String?, goal: String?, paused: Bool) {
    tabsVisible = tabs
    titleLabel.stringValue = title
    clockLabel.stringValue = clock ?? ""
    clockLabel.textColor = paused ? NotchMetrics.clockPaused : NotchMetrics.focusGreen
    goalLabel.stringValue = goal ?? ""
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
    // The compact clock and goal sit after the tabs/title.
    clockLabel.isHidden = clockLabel.stringValue.isEmpty
    goalLabel.isHidden = goalLabel.stringValue.isEmpty
    clockLabel.sizeToFit()
    goalLabel.sizeToFit()
    let clockWidth = max(0, min(clockLabel.frame.width, contentRight - x))
    clockLabel.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: clockWidth, height: 15)
    x += clockWidth + (goalLabel.stringValue.isEmpty ? 0 : 6)
    let goalWidth = max(0, min(goalLabel.frame.width, contentRight - x))
    goalLabel.frame = NSRect(x: x, y: (bounds.height - 15) / 2, width: goalWidth, height: 15)

    var right = bounds.width - pad
    for button in [newButton, browseButton, settingsButton, actionsButton] {
      button.frame = NSRect(x: right - 28, y: (bounds.height - 28) / 2, width: 28, height: 28)
      right -= 28 + 6
    }
    layoutTabUnderline()
  }
}

/// The Focus tab's content: the goal and a big countdown over the
/// session's controls. Everything dispatches through the bridge; the
/// daemon keeps the rules.
final class FocusTabView: NSView {
  private let clockLabel = NSTextField(labelWithString: "")
  private let goalLabel = NSTextField(labelWithString: "")
  private let pauseButton = ChromeButton(glyph: "Pause", font: NSFont.systemFont(ofSize: 12, weight: .semibold), label: "Pause")
  private let completeButton = ChromeButton(glyph: "Complete", font: NSFont.systemFont(ofSize: 12, weight: .semibold), label: "Complete")
  private var extendButtons: [ChromeButton] = []
  var onAction: ((String, Int?) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    clockLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
    clockLabel.textColor = NotchMetrics.focusGreen
    clockLabel.alignment = .center
    goalLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
    goalLabel.textColor = .labelColor
    goalLabel.alignment = .center
    goalLabel.lineBreakMode = .byTruncatingTail
    for button in [pauseButton, completeButton] {
      button.cornerRadius = 8
      button.fill = ChromeColors.pill
      button.stroke = ChromeColors.border
      button.target = self
      button.action = #selector(control(_:))
      addSubview(button)
    }
    pauseButton.tag = 0
    completeButton.tag = 1
    let extendTitle = NSTextField(labelWithString: "Extend")
    extendTitle.font = NSFont.systemFont(ofSize: 11)
    extendTitle.textColor = .tertiaryLabelColor
    extendTitle.frame = NSRect(x: 0, y: 8, width: bounds.width, height: 14)
    extendTitle.alignment = .center
    extendTitle.autoresizingMask = [.width, .maxYMargin]
    addSubview(extendTitle)
    addSubview(clockLabel)
    addSubview(goalLabel)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @objc private func control(_ sender: ChromeButton) {
    if sender === pauseButton { onAction?("togglePause", nil) }
    if sender === completeButton { onAction?("stop", nil) }
  }

  @objc private func extend(_ sender: ChromeButton) { onAction?("extend", sender.tag) }

  /// Rebuilds the labels and the Extend row for `session`.
  func update(session: FocusSession?, at now: Date) {
    guard let session else { return }
    clockLabel.stringValue = session.clock(at: now)
    clockLabel.textColor = session.state == "paused" ? NotchMetrics.clockPaused : NotchMetrics.focusGreen
    goalLabel.stringValue = session.goal
    pauseButton.attributedTitle = NSAttributedString(
      string: session.state == "paused" ? "Resume" : "Pause",
      attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
    extendButtons.forEach { $0.removeFromSuperview() }
    extendButtons = session.extendOptions.map { seconds in
      let button = ChromeButton(
        glyph: "+\(seconds / 60)", font: NSFont.systemFont(ofSize: 11, weight: .medium),
        label: "Extend by \(seconds / 60) minutes")
      button.cornerRadius = 6
      button.fill = ChromeColors.pill
      button.tag = seconds
      button.target = self
      button.action = #selector(extend(_:))
      addSubview(button)
      return button
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    // Keep the controls above the fixed Extend row on short screens.
    let controlY = max(68, bounds.height * 0.58 - 78)
    let goalY = controlY + 48
    let clockY = goalY + 30
    clockLabel.sizeToFit()
    clockLabel.frame = NSRect(
      x: (bounds.width - clockLabel.frame.width) / 2, y: clockY, width: clockLabel.frame.width, height: clockLabel.frame.height)
    goalLabel.frame = NSRect(x: 24, y: goalY, width: bounds.width - 48, height: 18)
    let rowWidth: CGFloat = 96 * 2 + 10
    pauseButton.frame = NSRect(x: (bounds.width - rowWidth) / 2, y: controlY, width: 96, height: 30)
    completeButton.frame = NSRect(x: (bounds.width - rowWidth) / 2 + 106, y: controlY, width: 96, height: 30)
    var x = (bounds.width - CGFloat(extendButtons.count) * 44 - CGFloat(max(0, extendButtons.count - 1)) * 6) / 2
    for button in extendButtons {
      button.frame = NSRect(x: x, y: 34, width: 44, height: 24)
      x += 50
    }
  }
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
    header.onTab = { [weak self] tab in self?.select(tab: tab, pinned: true) }
    header.run = { [weak self] command in self?.run(command) }
    header.onSettings = { [weak self] sender in self?.onSettings?(sender) }
    focusScroll.drawsBackground = false
    focusScroll.hasVerticalScroller = true
    focusScroll.autohidesScrollers = true
    focusScroll.documentView = focusView
    content.addSubview(focusScroll)
    focusView.onAction = { [weak self] action, seconds in self?.focusAction(action, seconds: seconds) }

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
    editorRoot?.frame = editorRect
    editorRoot?.autoresizingMask = [.width, .height]
    focusScroll.frame = editorRect
    // Keep the compact controls usable even when the screen leaves less
    // room than their minimum layout; only Focus scrolls, not the card.
    focusView.frame = NSRect(x: 0, y: 0, width: focusScroll.contentSize.width,
      height: max(194, editorRect.height))
    focusView.autoresizingMask = [.width]
    editorRoot?.isHidden = tab == .focus
    focusScroll.isHidden = tab != .focus || session == nil
  }

  // MARK: Session

  /// The bridge's latest session: drives the strip clock, the tabs, the
  /// header readout and the Focus tab. Losing the session returns the
  /// Focus tab to Notes.
  func update(session: FocusSession?) {
    let hadSession = self.session != nil
    self.session = session
    if session == nil, hadSession, tab == .focus { select(tab: .notes, pinned: pinned) }
    updateChrome()
  }

  /// Refreshes the clock text and the tab content every second.
  func updateChrome() {
    let now = self.now()
    strip.clockText = session?.clock(at: now)
    strip.paused = session?.state == "paused"
    focusView.update(session: session, at: now)
    let shared = mode == .notch && session != nil
    header.update(
      tabs: shared, title: windowTitle, clock: shared ? session?.clock(at: now) : nil,
      goal: shared ? session?.goal : nil, paused: session?.state == "paused")
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
    let fullHeight = min(Self.contentSize.height + AttachedHeaderView.height, visible.height - 8)
    let height = (fullHeight - screen.barHeight) / 2
    let width = min(Self.contentSize.width, visible.width - 8)
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
    let size = Self.contentSize
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
    self.tab = tab
    header.set(tab: tab)
    layoutContent()
  }

  private func focusAction(_ action: String, seconds: Int?) {
    guard let session else { return }
    pinned = true
    switch action {
    case "togglePause": onFocusAction(session.state == "paused" ? "resume" : "pause", nil)
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
