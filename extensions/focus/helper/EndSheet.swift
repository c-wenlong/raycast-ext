import AppKit
import Foundation

// MARK: - End-of-session sheet
//
// A floating panel that appears when a session reaches its end: the goal,
// "Time's up" or "Stopped" with the focused time, five stars, a one-line note,
// then Extend +5 / +10 / +15 / +25 min and a primary Finish (Return). Escape
// does nothing: the sheet stays until it is answered (PLAN.md: blocking stays
// on meanwhile).
//
// The look follows Raycast's own forms (Raycast Focus's start form, measured
// from a screenshot on 2026-09-27) and the notes window's colours: canvas
// #1A1A1A, one type size (15 pt regular) for everything but the goal, fields
// and buttons as flat rounded boxes with a white 5 % fill and a hairline
// border, 24 pt between rows, the primary action as a light pill.

/// Fixed colours: the sheet is always dark, like Raycast Focus.
enum SheetStyle {
  /// Markdown.canvas in dark mode (notes window).
  static let canvas = NSColor(white: 26 / 255, alpha: 1)
  /// Field and button fill: white 5 % over the canvas, as Raycast's fields.
  static let fill = NSColor(white: 1, alpha: 0.05)
  /// Hover wash on top of the fill (ChromeColors.hover in the notes window).
  static let hover = NSColor(white: 1, alpha: 0.06)
  static let border = NSColor(white: 1, alpha: 0.14)
  static let primary = NSColor(white: 0.9, alpha: 1)
  static let primaryHover = NSColor(white: 0.97, alpha: 1)
  static let primaryInk = NSColor(white: 0.1, alpha: 1)
  static let ink = NSColor(white: 1, alpha: 0.92)
  /// Markdown.accent: the notes window's one highlight colour.
  static let accent = NSColor(srgbRed: 0.91, green: 0.36, blue: 0.33, alpha: 1)
  static let starEmpty = NSColor(white: 0.5, alpha: 1)

  static let bodySize: CGFloat = 15
  static var body: NSFont { NSFont.systemFont(ofSize: bodySize) }
  static let rowHeight: CGFloat = 40
  static let radius: CGFloat = 12
  static let rowGap: CGFloat = 24
}

/// Becomes key without activating the app, and ignores Escape.
final class EndSheetPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  /// Escape never dismisses: the sheet waits for Extend or Finish.
  override func cancelOperation(_ sender: Any?) {}
}

/// The sheet's background view; first responder while the note is not being
/// edited, so 1 to 5, Return and typing reach the sheet.
final class SheetContentView: NSView {
  var onKey: ((NSEvent) -> Bool)?
  override var acceptsFirstResponder: Bool { true }
  // Paints the canvas itself too, so an offscreen render (test/ui) matches.
  override func draw(_ dirtyRect: NSRect) {
    SheetStyle.canvas.setFill()
    dirtyRect.fill()
  }
  override func keyDown(with event: NSEvent) {
    if onKey?(event) != true { super.keyDown(with: event) }
  }
}

// MARK: Stars

/// Five stars that fill from the left. Hover previews, a click sets.
final class StarRating: NSView {
  static let count = 5
  static let side: CGFloat = 28
  static let gap: CGFloat = 12

  var rating: Int? {
    didSet {
      guard rating != oldValue else { return }
      needsDisplay = true
      setAccessibilityValue(rating.map { "\($0) of 5" } ?? "none")
    }
  }
  /// The star under the mouse, previewed as if chosen.
  private(set) var hovered: Int? {
    didSet { if hovered != oldValue { needsDisplay = true } }
  }
  private var pressed: Int?
  private var trackingArea: NSTrackingArea?

  /// How many stars are drawn filled right now.
  var shown: Int { hovered ?? rating ?? 0 }

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.levelIndicator)
    setAccessibilityLabel("Rating")
    setAccessibilityValue("none")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var intrinsicContentSize: NSSize {
    NSSize(width: Self.side * CGFloat(Self.count) + Self.gap * CGFloat(Self.count - 1), height: Self.side)
  }

  /// Frame of star `index` (1-based) in view coordinates.
  func starRect(_ index: Int) -> NSRect {
    NSRect(x: CGFloat(index - 1) * (Self.side + Self.gap), y: (bounds.height - Self.side) / 2, width: Self.side, height: Self.side)
  }

  /// The star at `point` (view coordinates); a gap belongs to the nearer star.
  func star(at point: NSPoint) -> Int? {
    guard bounds.contains(point) else { return nil }
    let index = Int(((point.x + Self.gap / 2) / (Self.side + Self.gap)).rounded(.down)) + 1
    return min(max(index, 1), Self.count)
  }

  private func star(for event: NSEvent) -> Int? {
    star(at: convert(event.locationInWindow, from: nil))
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) { pressed = star(for: event) }

  override func mouseUp(with event: NSEvent) {
    defer { pressed = nil }
    guard let index = star(for: event), index == pressed else { return }
    rating = index
  }

  override func mouseEntered(with event: NSEvent) { hovered = star(for: event) }
  override func mouseMoved(with event: NSEvent) { hovered = star(for: event) }
  override func mouseExited(with event: NSEvent) { hovered = nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  private static func image(filled: Bool) -> NSImage? {
    NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: side - 4, weight: .regular)
          .applying(NSImage.SymbolConfiguration(paletteColors: [filled ? SheetStyle.accent : SheetStyle.starEmpty])))
  }

  private static let filledImage = image(filled: true)
  private static let emptyImage = image(filled: false)

  override func draw(_ dirtyRect: NSRect) {
    for index in 1...Self.count {
      guard let image = index <= shown ? Self.filledImage : Self.emptyImage else { continue }
      let cell = starRect(index)
      let size = image.size
      image.draw(in: NSRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height))
    }
  }
}

// MARK: Buttons

/// A flat rounded box like Raycast's fields (white 5 % fill, hairline
/// border), or with `primary` the light pill Raycast uses for its main
/// action. `hint` ("↩") is drawn after the title as a small keycap.
final class SheetButton: NSButton {
  let primary: Bool
  let hint: String?
  private var hovering = false {
    didSet { needsDisplay = true }
  }
  private var trackingArea: NSTrackingArea?

  init(title: String, hint: String? = nil, primary: Bool = false) {
    self.primary = primary
    self.hint = hint
    super.init(frame: .zero)
    isBordered = false
    setButtonType(.momentaryChange)
    refusesFirstResponder = true
    focusRingType = .none
    imagePosition = .noImage
    self.title = title
    setAccessibilityLabel(title)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: SheetStyle.rowHeight).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize {
    NSSize(width: titleText.size().width + 28, height: SheetStyle.rowHeight)
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

  private var ink: NSColor { primary ? SheetStyle.primaryInk : SheetStyle.ink }
  private var titleText: NSAttributedString {
    NSAttributedString(string: title, attributes: [.font: SheetStyle.body, .foregroundColor: ink])
  }

  override func draw(_ dirtyRect: NSRect) {
    let lit = hovering || isHighlighted
    let box = bounds.insetBy(dx: 0.5, dy: 0.5)
    if primary {
      let path = NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2)
      (lit ? SheetStyle.primaryHover : SheetStyle.primary).setFill()
      path.fill()
    } else {
      let path = NSBezierPath(roundedRect: box, xRadius: SheetStyle.radius, yRadius: SheetStyle.radius)
      SheetStyle.fill.setFill()
      path.fill()
      if lit {
        SheetStyle.hover.setFill()
        path.fill()
      }
      SheetStyle.border.setStroke()
      path.lineWidth = 1
      path.stroke()
    }

    // Title, plus the keycap, centred as one line on the capitals' middle.
    let text = titleText
    let textSize = text.size()
    let cap: CGFloat = 20
    let capGap: CGFloat = 8
    let total = textSize.width + (hint == nil ? 0 : capGap + cap)
    let font = SheetStyle.body
    // draw(at:) takes the line's top left in a flipped view (NSButton is),
    // its bottom left otherwise; either way the capitals end up centred.
    let y = isFlipped
      ? bounds.midY - font.capHeight / 2 - (font.ascender - font.capHeight)
      : bounds.midY - font.capHeight / 2 + font.descender
    var x = ((bounds.width - total) / 2).rounded()
    text.draw(at: NSPoint(x: x, y: y.rounded()))
    x += textSize.width + capGap
    if let hint {
      let capRect = NSRect(x: x, y: (bounds.midY - cap / 2).rounded(), width: cap, height: cap).insetBy(dx: 0.5, dy: 0.5)
      let capPath = NSBezierPath(roundedRect: capRect, xRadius: 5, yRadius: 5)
      ink.withAlphaComponent(0.08).setFill()
      capPath.fill()
      ink.withAlphaComponent(0.25).setStroke()
      capPath.lineWidth = 1
      capPath.stroke()
      let glyph = NSAttributedString(
        string: hint, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink.withAlphaComponent(0.7)])
      let glyphSize = glyph.size()
      glyph.draw(at: NSPoint(x: capRect.midX - glyphSize.width / 2, y: capRect.midY - glyphSize.height / 2))
    }
  }
}

/// The rounded box the note field sits in, styled like SheetButton.
final class NoteWell: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: SheetStyle.radius, yRadius: SheetStyle.radius)
    SheetStyle.fill.setFill()
    path.fill()
    SheetStyle.border.setStroke()
    path.lineWidth = 1
    path.stroke()
  }
}

// MARK: Sheet

final class EndSheet: NSObject, NSTextFieldDelegate {
  weak var delegate: SessionPresenterDelegate?
  let panel: EndSheetPanel
  let content = SheetContentView()
  let titleLabel = NSTextField(wrappingLabelWithString: "")
  let statusLabel = NSTextField(labelWithString: "")
  let stars = StarRating(frame: .zero)
  let noteField = NSTextField(string: "")
  let extendRow = NSStackView()
  private(set) var extendButtons: [SheetButton] = []
  let finishButton = SheetButton(title: "Finish", hint: "↩", primary: true)

  /// The session the sheet is (or was last) asking about.
  private(set) var session: SessionView?
  /// Set once Extend or Finish went out, so a double press sends one answer.
  private var answered = false
  private var shownAt = Date.distantPast
  private let clock: () -> Date
  private var shownExtendOptions: [Int]?

  /// Return and 1 to 5 are ignored this long after the sheet appears, so
  /// keys typed into another app at that moment cannot answer it.
  var keyboardGrace: TimeInterval = 0.8
  /// Tests: order the panel in far off screen and never make it key.
  var headless = false

  static let width: CGFloat = 420
  static let sidePadding: CGFloat = 20

  init(clock: @escaping () -> Date = Date.init) {
    self.clock = clock
    panel = EndSheetPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: true)
    super.init()
    buildPanel()
  }

  var isVisible: Bool { panel.isVisible }
  var rating: Int? { stars.rating }
  var note: String? { Self.cleanNote(noteField.stringValue) }

  // MARK: Text

  /// One line, trimmed; nil when nothing is left.
  static func cleanNote(_ text: String) -> String? {
    let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
  }

  /// "Time's up" when the planned end was reached, "Stopped" when ended
  /// early. SessionView carries no end reason, so this reads the clock: the
  /// timer only ends a session once `now` has passed `plannedEnd`, so any
  /// time still ahead (even under a second) means a manual stop.
  static func headline(_ view: SessionView, now: Date) -> String {
    view.remainingSeconds == 0 && view.plannedEnd <= now ? "Time's up" : "Stopped"
  }

  /// "under a minute", "25 min", "1 h", "1 h 5 min".
  static func duration(_ seconds: Int) -> String {
    let minutes = max(0, seconds) / 60
    if minutes == 0 { return "under a minute" }
    if minutes < 60 { return "\(minutes) min" }
    return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
  }

  static func focusedSeconds(_ view: SessionView, now: Date) -> Int {
    max(0, Int(now.timeIntervalSince(view.startedAt)) - view.pausedSeconds)
  }

  static func statusText(_ view: SessionView, now: Date) -> String {
    "\(headline(view, now: now)) · \(duration(focusedSeconds(view, now: now))) focused"
  }

  static func extendTitle(_ seconds: Int) -> String {
    "+" + MenuBar.extendTitle(seconds)
  }

  // MARK: Building

  private func buildPanel() {
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.title = "Focus"
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(kind)?.isHidden = true
    }
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.backgroundColor = SheetStyle.canvas
    panel.isMovableByWindowBackground = true
    panel.level = .modalPanel
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.animationBehavior = .alertPanel

    content.onKey = { [weak self] event in self?.handleKey(event) ?? false }
    panel.contentView = content
    panel.initialFirstResponder = content

    // In the title bar strip, like the notes window's centred title.
    let header = NSTextField(labelWithString: "Focus session")
    header.font = NSFont.systemFont(ofSize: 12)
    header.textColor = .tertiaryLabelColor
    header.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
    titleLabel.textColor = .labelColor
    titleLabel.alignment = .center
    titleLabel.maximumNumberOfLines = 2
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.cell?.truncatesLastVisibleLine = true
    titleLabel.preferredMaxLayoutWidth = Self.width - Self.sidePadding * 2
    titleLabel.isSelectable = false

    statusLabel.font = SheetStyle.body
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .center

    stars.translatesAutoresizingMaskIntoConstraints = false

    let well = NoteWell()
    well.translatesAutoresizingMaskIntoConstraints = false
    noteField.isBordered = false
    noteField.drawsBackground = false
    noteField.focusRingType = .none
    noteField.font = SheetStyle.body
    noteField.textColor = SheetStyle.ink
    noteField.placeholderAttributedString = NSAttributedString(
      string: "Add a note", attributes: [.font: SheetStyle.body, .foregroundColor: NSColor.tertiaryLabelColor])
    noteField.cell?.usesSingleLineMode = true
    noteField.cell?.isScrollable = true
    noteField.cell?.wraps = false
    noteField.maximumNumberOfLines = 1
    noteField.delegate = self
    noteField.setAccessibilityLabel("Note")
    noteField.translatesAutoresizingMaskIntoConstraints = false
    well.addSubview(noteField)

    extendRow.orientation = .horizontal
    extendRow.distribution = .fillEqually
    extendRow.spacing = 10
    extendRow.translatesAutoresizingMaskIntoConstraints = false
    finishButton.target = self
    finishButton.action = #selector(finishClicked)

    let column = NSStackView(views: [titleLabel, statusLabel, stars, well, extendRow, finishButton])
    column.orientation = .vertical
    column.alignment = .centerX
    column.spacing = SheetStyle.rowGap
    column.setCustomSpacing(6, after: titleLabel)
    column.setCustomSpacing(12, after: extendRow)
    column.translatesAutoresizingMaskIntoConstraints = false

    for view in [header, column] as [NSView] { content.addSubview(view) }
    let side = Self.sidePadding
    NSLayoutConstraint.activate([
      content.widthAnchor.constraint(equalToConstant: Self.width),
      header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      header.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),

      column.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
      column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: side),
      column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -side),
      column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -side),
      titleLabel.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
      well.widthAnchor.constraint(equalTo: column.widthAnchor),
      well.heightAnchor.constraint(equalToConstant: SheetStyle.rowHeight),
      noteField.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 14),
      noteField.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -14),
      noteField.centerYAnchor.constraint(equalTo: well.centerYAnchor),
      extendRow.widthAnchor.constraint(equalTo: column.widthAnchor),
      finishButton.widthAnchor.constraint(equalTo: column.widthAnchor),
    ])
    content.nextKeyView = noteField
    noteField.nextKeyView = content
  }

  private func setExtendOptions(_ options: [Int]) {
    guard options != shownExtendOptions else { return }
    shownExtendOptions = options
    for button in extendButtons {
      extendRow.removeArrangedSubview(button)
      button.removeFromSuperview()
    }
    extendButtons = options.map { seconds in
      let button = SheetButton(title: Self.extendTitle(seconds))
      button.tag = seconds
      button.target = self
      button.action = #selector(extendClicked(_:))
      button.setAccessibilityLabel("Extend by \(MenuBar.extendTitle(seconds))")
      return button
    }
    extendButtons.forEach { extendRow.addArrangedSubview($0) }
    extendRow.isHidden = options.isEmpty
  }

  // MARK: Showing

  /// Shows the sheet for `view`, or refreshes it when it is already up. A
  /// different session starts with no stars and no note; the same session
  /// (back after an extend) keeps what was entered.
  func show(_ view: SessionView) {
    if session?.id != view.id {
      stars.rating = nil
      noteField.stringValue = ""
    }
    session = view
    answered = false
    let goal = view.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    titleLabel.stringValue = goal.isEmpty ? "Focus session" : goal
    statusLabel.stringValue = Self.statusText(view, now: clock())
    setExtendOptions(view.extendOptions)

    content.layoutSubtreeIfNeeded()
    let height = ceil(content.fittingSize.height)
    let wasVisible = panel.isVisible
    if panel.frame.size != NSSize(width: Self.width, height: height) {
      let top = panel.frame.maxY
      panel.setContentSize(NSSize(width: Self.width, height: height))
      if wasVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
    }
    guard !wasVisible else { return }

    shownAt = clock()
    if headless {
      panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
      panel.orderFrontRegardless()
    } else {
      place()
      panel.makeKeyAndOrderFront(nil)
      panel.orderFrontRegardless()
    }
    panel.makeFirstResponder(content)
  }

  /// Centred on the main screen, a little above the middle like an alert.
  private func place() {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let area = screen.visibleFrame
    let size = panel.frame.size
    panel.setFrameOrigin(NSPoint(
      x: (area.midX - size.width / 2).rounded(), y: (area.minY + (area.height - size.height) * 0.6).rounded()))
  }

  /// Hides the sheet after an answer; the entered stars and note stay in
  /// case the same session comes back after an extend.
  func hide() {
    panel.makeFirstResponder(content)
    panel.orderOut(nil)
  }

  /// The session is over: hide and forget it.
  func dismiss() {
    hide()
    session = nil
    stars.rating = nil
    noteField.stringValue = ""
  }

  // MARK: Answers

  @objc private func finishClicked() { finish() }

  @objc private func extendClicked(_ sender: NSButton) { extend(seconds: sender.tag) }

  func finish() {
    guard session != nil, !answered else { return }
    answered = true
    let rating = stars.rating
    let note = self.note
    hide()
    delegate?.presenterFinish(rating: rating, note: note)
  }

  func extend(seconds: Int) {
    guard session != nil, !answered, seconds > 0 else { return }
    answered = true
    hide()
    delegate?.presenterExtend(seconds: seconds)
  }

  // MARK: Keys

  private var keysArmed: Bool { clock().timeIntervalSince(shownAt) >= keyboardGrace }

  /// Keys that reach the sheet while the note is not being edited.
  func handleKey(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { return true }  // Escape: waits for an answer
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
    switch event.keyCode {
    case 36, 76:  // Return, keypad Enter
      if keysArmed { finish() }
      return true
    case 48:  // Tab
      panel.makeFirstResponder(noteField)
      return true
    default:
      break
    }
    guard let characters = event.characters, !characters.isEmpty else { return false }
    if let digit = Int(characters), (1...StarRating.count).contains(digit) {
      if keysArmed { stars.rating = digit }
      return true
    }
    // Anything else printable starts the note.
    let printable = characters.unicodeScalars.allSatisfy {
      !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
    }
    guard printable else { return false }
    panel.makeFirstResponder(noteField)
    noteField.currentEditor()?.insertText(characters)
    return true
  }

  // NSTextFieldDelegate: Return in the note finishes, Escape leaves the note.
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      if keysArmed { finish() }
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      panel.makeFirstResponder(content)
      return true
    default:
      return false
    }
  }
}
