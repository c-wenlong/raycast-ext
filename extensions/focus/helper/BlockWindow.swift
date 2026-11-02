import AppKit
import Foundation

// MARK: - Block window
//
// What a blocked app gets instead of its windows (PLAN.md "What a block looks
// like"): the same page as the site block page, drawn natively. A borderless
// panel covers the spot the blocked app's front window had (a rounded card,
// at least `minCard` big, kept inside the screen's visible frame), or the
// whole screen the mouse is on when that window is unknown, always under the
// menu bar and the Dock (so the Focus countdown and its Stop stay reachable),
// so the rest of the desktop stays usable: a black canvas with a
// soft radial glow, the app's icon, "<App> has been blocked", one bordered
// flat button "Snooze for N minutes" and the footer "End your focus session
// to access this page". Snooze hands back to the engine (which unhides the
// app); Escape or a click anywhere off the button just closes the page, and
// the app stays hidden.
//
// The look mirrors Raycast Focus's block page (the user's screenshot, 2026-09-27)
// with the end sheet's type and controls (EndSheet.swift): system font,
// semibold for the one headline, 15 pt for the rest, flat boxes with a
// hairline border.

enum BlockStyle {
  /// The canvas at the edges and the glow in the middle.
  static let edge = NSColor(white: 0, alpha: 1)
  static let glow = NSColor(white: 0.085, alpha: 1)
  static let title = NSColor(white: 1, alpha: 0.92)
  static let footer = NSColor(white: 1, alpha: 0.42)
  static let buttonFill = NSColor(white: 1, alpha: 0.08)
  static let buttonHover = NSColor(white: 1, alpha: 0.13)
  static let buttonBorder = NSColor(white: 1, alpha: 0.14)
  static let buttonInk = NSColor(white: 1, alpha: 0.9)

  static let titleSize: CGFloat = 28
  static let iconSide: CGFloat = 72
  static let textWidth: CGFloat = 640
  /// The card's corner radius; the full-screen page has none.
  static let cardRadius: CGFloat = 12
}

/// Borderless, becomes key without activating the daemon, Escape closes.
final class BlockPanel: NSPanel {
  var onCancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The canvas. A click on it (anywhere off the button) closes the page.
final class BlockBackdrop: NSView {
  var onClick: (() -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    BlockStyle.edge.setFill()
    bounds.fill()
    // An elliptical glow: a circular gradient drawn into a square, stretched to the view.
    guard let gradient = NSGradient(colors: [BlockStyle.glow, BlockStyle.glow.withAlphaComponent(0.6), BlockStyle.edge], atLocations: [0, 0.45, 1], colorSpace: .sRGB),
      let context = NSGraphicsContext.current
    else { return }
    context.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: bounds.midX, yBy: bounds.midY)
    transform.scaleX(by: bounds.width * 0.62, yBy: bounds.height * 0.62)
    transform.concat()
    gradient.draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: 1, options: .drawsAfterEndingLocation)
    context.restoreGraphicsState()
  }

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }
}

/// The one button: a flat rounded box with an SF Symbol and a title.
final class BlockButton: NSButton {
  private var hovering = false {
    didSet { needsDisplay = true }
  }
  private var trackingArea: NSTrackingArea?
  private static let symbol = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)?
    .withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [BlockStyle.buttonInk])))

  init(title: String) {
    super.init(frame: .zero)
    isBordered = false
    setButtonType(.momentaryChange)
    refusesFirstResponder = true
    focusRingType = .none
    imagePosition = .noImage
    self.title = title
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: SheetStyle.rowHeight).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var title: String {
    didSet {
      setAccessibilityLabel(title)
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  private var titleText: NSAttributedString {
    NSAttributedString(string: title, attributes: [.font: SheetStyle.body, .foregroundColor: BlockStyle.buttonInk])
  }

  private static let iconGap: CGFloat = 8

  override var intrinsicContentSize: NSSize {
    let icon = (Self.symbol?.size.width ?? 0) + Self.iconGap
    return NSSize(width: (titleText.size().width + icon + 36).rounded(.up), height: SheetStyle.rowHeight)
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
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  override func draw(_ dirtyRect: NSRect) {
    let box = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
    (hovering || isHighlighted ? BlockStyle.buttonHover : BlockStyle.buttonFill).setFill()
    path.fill()
    BlockStyle.buttonBorder.setStroke()
    path.lineWidth = 1
    path.stroke()

    let text = titleText
    let textSize = text.size()
    let icon = Self.symbol
    let iconWidth = icon.map { $0.size.width + Self.iconGap } ?? 0
    var x = ((bounds.width - textSize.width - iconWidth) / 2).rounded()
    if let icon {
      let size = icon.size
      icon.draw(in: NSRect(x: x, y: (bounds.midY - size.height / 2).rounded(), width: size.width, height: size.height))
      x += iconWidth
    }
    // Capitals centred on the box, as SheetButton does.
    let font = SheetStyle.body
    let y = isFlipped
      ? bounds.midY - font.capHeight / 2 - (font.ascender - font.capHeight)
      : bounds.midY - font.capHeight / 2 + font.descender
    text.draw(at: NSPoint(x: x, y: y.rounded()))
  }
}

final class BlockWindow: NSObject {
  let panel: BlockPanel
  let backdrop = BlockBackdrop()
  let iconView = NSImageView()
  let titleLabel = NSTextField(wrappingLabelWithString: "")
  let snoozeButton = BlockButton(title: "")
  let footerLabel = NSTextField(labelWithString: BlockWindow.footer)
  private var footerBottom: NSLayoutConstraint?

  /// Called when Snooze is pressed (the page closes first).
  var onSnooze: (() -> Void)?
  /// Called after the page closes, with why ("escape", "click", "snooze", or the caller's reason).
  var onClose: ((String) -> Void)?
  /// Tests: order the panel in far off screen at a fixed size and never make it key.
  var headless = false
  /// The app the page is showing, while it shows.
  private(set) var bundleId: String?
  private(set) var appName: String?
  private(set) var shownAt = Date.distantPast
  /// Whether the page is a card over the app's window rather than the whole screen.
  private(set) var isCard = false

  /// The smallest card: room for the icon, a two-line title, the button and the footer.
  static let minCard = NSSize(width: 480, height: 400)

  static let footer = "End your focus session to access this page"

  /// "<App> has been blocked"; "This app has been blocked" without a name.
  static func title(appName: String) -> String {
    let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(name.isEmpty ? "This app" : name) has been blocked"
  }

  override init() {
    panel = BlockPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: true)
    super.init()
    build()
  }

  var isVisible: Bool { panel.isVisible }

  private func build() {
    panel.appearance = NSAppearance(named: .darkAqua)
    // Clear, so the card's corners show what is behind; the backdrop paints the page.
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    // Above ordinary windows, below the menu bar and the Dock.
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isMovable = false
    panel.animationBehavior = .none
    panel.title = "Focus"
    panel.onCancel = { [weak self] in self?.close(reason: "escape") }

    backdrop.onClick = { [weak self] in self?.close(reason: "click") }
    panel.contentView = backdrop
    panel.initialFirstResponder = backdrop
    backdrop.wantsLayer = true
    backdrop.layer?.masksToBounds = true

    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.setAccessibilityElement(false)

    titleLabel.font = NSFont.systemFont(ofSize: BlockStyle.titleSize, weight: .semibold)
    titleLabel.textColor = BlockStyle.title
    titleLabel.alignment = .center
    titleLabel.maximumNumberOfLines = 3
    titleLabel.lineBreakMode = .byWordWrapping
    titleLabel.preferredMaxLayoutWidth = BlockStyle.textWidth
    titleLabel.isSelectable = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    snoozeButton.target = self
    snoozeButton.action = #selector(snoozeClicked)

    footerLabel.font = SheetStyle.body
    footerLabel.textColor = BlockStyle.footer
    footerLabel.alignment = .center
    footerLabel.translatesAutoresizingMaskIntoConstraints = false

    let column = NSStackView(views: [iconView, titleLabel, snoozeButton])
    column.orientation = .vertical
    column.alignment = .centerX
    column.spacing = 20
    column.setCustomSpacing(36, after: titleLabel)
    column.translatesAutoresizingMaskIntoConstraints = false

    backdrop.addSubview(column)
    backdrop.addSubview(footerLabel)
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: BlockStyle.iconSide),
      iconView.heightAnchor.constraint(equalToConstant: BlockStyle.iconSide),
      titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: BlockStyle.textWidth),
      column.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
      // A little above the middle, like the web page.
      column.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor, constant: -24),
      column.leadingAnchor.constraint(greaterThanOrEqualTo: backdrop.leadingAnchor, constant: 32),
      column.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -32),
      footerLabel.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
    ])
    let bottom = footerLabel.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -56)
    bottom.isActive = true
    footerBottom = bottom
  }

  // MARK: Placing

  /// Where the page goes, in screen coordinates: over `window` (the blocked
  /// app's front window) as a card, grown to `minCard` around its centre and
  /// kept inside the visible frame of the screen it mostly sits on; nil when
  /// there is no window or it is on no screen (then the page covers a whole
  /// screen). Pure, so the tests can pass any screens.
  static func cardFrame(over window: NSRect?, visibleFrames: [NSRect]) -> NSRect? {
    guard let window, window.width > 0, window.height > 0 else { return nil }
    let overlap = { (frame: NSRect) -> CGFloat in
      let part = frame.intersection(window)
      return part.isNull ? 0 : part.width * part.height
    }
    guard let visible = visibleFrames.max(by: { overlap($0) < overlap($1) }), overlap(visible) > 0 else { return nil }
    var card = window.intersection(visible)
    let width = min(max(card.width, minCard.width), visible.width)
    let height = min(max(card.height, minCard.height), visible.height)
    card = NSRect(x: card.midX - width / 2, y: card.midY - height / 2, width: width, height: height)
    card.origin.x = min(max(card.minX, visible.minX), visible.maxX - width)
    card.origin.y = min(max(card.minY, visible.minY), visible.maxY - height)
    return card.integral
  }

  /// A Core Graphics window rect (top-left origin, y down, from the primary
  /// screen's top) in AppKit screen coordinates (bottom-left origin, y up).
  static func appKitRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> NSRect {
    NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
  }

  private func place(_ frame: NSRect, card: Bool) {
    isCard = card
    backdrop.layer?.cornerRadius = card ? BlockStyle.cardRadius : 0
    footerBottom?.constant = card ? -32 : -56
    // Two lines in a card, so a long name never reaches the footer at minCard.
    titleLabel.maximumNumberOfLines = card ? 2 : 3
    titleLabel.preferredMaxLayoutWidth = min(BlockStyle.textWidth, frame.width - 64)
    panel.setFrame(frame, display: true)
  }

  /// Moves a showing full-screen page over `window` as a card (the app's window turned up after the page appeared).
  func refit(over window: NSRect) {
    guard panel.isVisible, !isCard,
      let card = Self.cardFrame(over: window, visibleFrames: NSScreen.screens.map(\.visibleFrame))
    else { return }
    // Tests keep it off screen at the card's size.
    place(headless ? NSRect(origin: NSPoint(x: -20000, y: -20000), size: card.size) : card, card: true)
  }

  /// Turns a showing card into the whole screen (the app ignored the hide, so any of its windows may show).
  func cover() {
    guard panel.isVisible, isCard else { return }
    if headless {
      place(NSRect(x: -20000, y: -20000, width: 1280, height: 800), card: false)
    } else if let target = Self.screen(under: panel.frame) {
      place(target.frame, card: false)
    }
  }

  // MARK: Showing

  /// Shows (or retargets) the page for one app: a card over `window` (the
  /// app's front window, in screen coordinates) when known, else the whole of
  /// `screen` (the one with the mouse by default). The label is plain text,
  /// so a name is never markup. `visibleFrames` stands in for the screens' in
  /// the tests.
  func show(
    appName: String, bundleId: String?, icon: NSImage?, snoozeSeconds: Int, over window: NSRect? = nil,
    screen: NSScreen? = nil, visibleFrames: [NSRect]? = nil
  ) {
    self.bundleId = bundleId
    self.appName = appName
    titleLabel.stringValue = Self.title(appName: appName)
    snoozeButton.title = Matching.snoozeLabel(seconds: snoozeSeconds)
    iconView.image =
      icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: BlockStyle.iconSide * 0.7, weight: .light))
    iconView.contentTintColor = icon == nil ? BlockStyle.footer : nil
    panel.setAccessibilityTitle(titleLabel.stringValue)
    shownAt = Date()

    let card = Self.cardFrame(over: window, visibleFrames: visibleFrames ?? NSScreen.screens.map(\.visibleFrame))
    if headless {
      // Off screen, at the card's size when there is one.
      let size = card?.size ?? NSSize(width: 1280, height: 800)
      place(NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), card: card != nil)
      panel.orderFrontRegardless()
      return
    }
    if let card {
      place(card, card: true)
    } else if let target = screen ?? Self.screenWithMouse() ?? NSScreen.main ?? NSScreen.screens.first {
      place(target.frame, card: false)
    }
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    panel.makeFirstResponder(backdrop)
  }

  /// The screen a rect mostly sits on; nil when it is on none.
  static func screen(under rect: NSRect) -> NSScreen? {
    let overlap = { (screen: NSScreen) -> CGFloat in
      let part = screen.frame.intersection(rect)
      return part.isNull ? 0 : part.width * part.height
    }
    guard let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return nil }
    return best
  }

  private static func screenWithMouse() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
  }

  /// Closes the page; the app stays hidden.
  func close(reason: String = "closed") {
    let wasVisible = panel.isVisible
    if wasVisible { panel.orderOut(nil) }
    bundleId = nil
    appName = nil
    if wasVisible { onClose?(reason) }
  }

  @objc private func snoozeClicked() {
    let callback = onSnooze
    close(reason: "snooze")
    callback?()
  }
}
