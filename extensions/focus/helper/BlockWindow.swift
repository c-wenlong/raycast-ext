import AppKit
import Foundation

// MARK: - Block window
//
// What a blocked app gets instead of its windows (PLAN.md "What a block looks
// like"): the same page as the site block page, drawn natively. A borderless
// panel covers the screen the mouse is on, under the menu bar and the Dock
// (so the Focus countdown and its Stop stay reachable): a black canvas with a
// soft radial glow, the app's icon, "<App> has been blocked", one bordered
// flat button "Snooze for N minutes" and the footer "End your focus session
// to access this page". Snooze hands back to the engine (which unhides the
// app); Escape or a click anywhere off the button just closes the page, and
// the app stays hidden.
//
// The look mirrors Raycast Focus's block page (Kai's screenshot, 2026-09-27)
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
    panel.backgroundColor = BlockStyle.edge
    panel.isOpaque = true
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
      footerLabel.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -56),
    ])
  }

  // MARK: Showing

  /// Shows (or retargets) the page for one app on `screen` (the one with the
  /// mouse by default). The label is plain text, so a name is never markup.
  func show(appName: String, bundleId: String?, icon: NSImage?, snoozeSeconds: Int, screen: NSScreen? = nil) {
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

    if headless {
      panel.setFrame(NSRect(x: -20000, y: -20000, width: 1280, height: 800), display: true)
      panel.orderFrontRegardless()
      return
    }
    let target = screen ?? Self.screenWithMouse() ?? NSScreen.main ?? NSScreen.screens.first
    if let target { panel.setFrame(target.frame, display: true) }
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    panel.makeFirstResponder(backdrop)
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
