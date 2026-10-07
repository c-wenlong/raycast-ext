// The countdown's chrome: the palette (`PanelStyle`), the pill with its
// progress sweep (`CountdownPillView`) and the flat bordered button
// (`PanelButton`). Shared by the floating panel, the notch island and
// Notes' hosted Focus tab. Moved out of FloatingPanel.swift unchanged.

import AppKit

enum PanelStyle {
  /// The end card's canvas over its blur (the pill itself is glass, see
  /// GlassStyle): close to #1A1A1A, a touch lighter, with a 10 % hairline.
  static let canvas = NSColor(white: 0.115, alpha: 0.93)
  static let border = NSColor(white: 1, alpha: 0.10)
  static let digits = NSColor(white: 1, alpha: 0.62)
  static let digitsPaused = NSColor(white: 1, alpha: 0.45)
  static let digitsOnProgress = NSColor(white: 1, alpha: 0.96)
  static let goal = NSColor(white: 1, alpha: 0.94)
  static let ink = NSColor(white: 1, alpha: 0.9)
  static let icon = NSColor(white: 1, alpha: 0.6)
  static let handle = NSColor(white: 1, alpha: 0.38)
  static let handleHover = NSColor(white: 1, alpha: 0.7)

  /// One size for both states: the pill is as tall and as wide as the
  /// controls row, so hovering swaps the content without resizing.
  static let idleHeight: CGFloat = 40
  static let hoverHeight: CGFloat = 40
  static let inset: CGFloat = 6
  static let chipRadius: CGFloat = 8
  /// Concentric with the chip: its radius plus the inset.
  static let radius: CGFloat = 14
  static let chipPadding: CGFloat = 9
  static let goalGap: CGFloat = 10
  static let goalTrailing: CGFloat = 14
  static let goalMaxWidth: CGFloat = 220
  static let buttonHeight: CGFloat = 28
  static let buttonGap: CGFloat = 6
  static let handleWidth: CGFloat = 18

  static let chipFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  static let goalFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
  static let buttonFont = NSFont.systemFont(ofSize: 13, weight: .medium)

  /// The margin from the menu bar and the screen's right edge by default.
  static let margin: CGFloat = 12
  static let animation: TimeInterval = 0.15
  static let hoverExitDelay: TimeInterval = 0.15
}

final class CountdownPillView: NSView {
  var content = PanelContent(clock: "00:00", paused: false, progress: 0, goal: "") {
    didSet { if content != oldValue { needsDisplay = true } }
  }

  /// How much of the sweep is drawn, 0 to 1: `content.progress` at an
  /// update, then moved on by the panel between updates. Redraws only when
  /// the fill's edge moves by a device pixel.
  var progress: Double = 0 {
    didSet { if Self.fillWidth(progress, of: bounds.width, scale: scale) != Self.fillWidth(oldValue, of: bounds.width, scale: scale) { needsDisplay = true } }
  }

  private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

  /// The fill's width for `progress` of `width`, on whole device pixels.
  static func fillWidth(_ progress: Double, of width: CGFloat, scale: CGFloat) -> CGFloat {
    (width * CGFloat(min(1, max(0, progress))) * scale).rounded() / scale
  }

  private static let pauseGlyph = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))

  static func clockText(_ content: PanelContent, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: content.clock, attributes: [.font: PanelStyle.chipFont, .foregroundColor: color])
  }

  static func pauseWidth(_ content: PanelContent) -> CGFloat {
    content.paused ? ceil(pauseGlyph?.size.width ?? 8) + 5 : 0
  }

  static func chipWidth(_ content: PanelContent) -> CGFloat {
    ceil(clockText(content, color: .white).size().width) + pauseWidth(content) + PanelStyle.chipPadding * 2
  }

  static func goalWidth(_ content: PanelContent) -> CGFloat {
    guard !content.goal.isEmpty else { return 0 }
    let text = NSAttributedString(string: content.goal, attributes: [.font: PanelStyle.goalFont])
    return min(ceil(text.size().width), PanelStyle.goalMaxWidth)
  }

  /// The pill's width for `content`.
  static func width(_ content: PanelContent) -> CGFloat {
    let chip = PanelStyle.inset + chipWidth(content)
    guard !content.goal.isEmpty else { return chip + PanelStyle.inset }
    return chip + PanelStyle.goalGap + goalWidth(content) + PanelStyle.goalTrailing
  }

  /// The chip in view coordinates.
  var chipRect: NSRect {
    let height = PanelStyle.idleHeight - PanelStyle.inset * 2
    return NSRect(
      x: PanelStyle.inset, y: ((bounds.height - height) / 2).rounded(), width: Self.chipWidth(content), height: height)
  }

  /// The green part: it sweeps the whole pill from the left as time passes,
  /// chip and goal included, clipped to the pill's rounded shape.
  var progressRect: NSRect {
    var rect = bounds
    rect.size.width = Self.fillWidth(progress, of: rect.width, scale: scale)
    return rect
  }

  /// The sweep's lit leading edge: a 1 pt line at the fill's right end,
  /// nil at no fill and at a full pill.
  var progressEdgeRect: NSRect? {
    let fill = progressRect
    guard fill.width >= 1, fill.width < bounds.width else { return nil }
    return NSRect(x: fill.maxX - 1, y: fill.minY, width: 1, height: fill.height)
  }

  /// The chip's 1 pt border, inside the chip.
  var chipBorder: (rect: NSRect, radius: CGFloat) { GlassEdges.insetBorder(chipRect, radius: PanelStyle.chipRadius) }

  override func draw(_ dirtyRect: NSRect) {
    let chip = chipRect
    let pillPath = NSBezierPath(roundedRect: bounds, xRadius: PanelStyle.radius, yRadius: PanelStyle.radius)
    let fill = progressRect
    if fill.width > 0 {
      // Green glass filling the slab: translucent, lighter at the top, with
      // a lit leading edge, so the tint and the rim still read through it.
      NSGraphicsContext.saveGraphicsState()
      pillPath.addClip()
      let alpha = content.paused ? GlassStyle.progressPausedAlpha : 1
      NSGradient(
        starting: GlassStyle.progressBottom.withAlphaComponent(GlassStyle.progressBottom.alphaComponent * alpha),
        ending: GlassStyle.progressTop.withAlphaComponent(GlassStyle.progressTop.alphaComponent * alpha))?
        .draw(in: fill, angle: 90)
      if let edge = progressEdgeRect {
        GlassStyle.progressEdge.withAlphaComponent(GlassStyle.progressEdge.alphaComponent * alpha).setFill()
        edge.fill()
      }
      NSGraphicsContext.restoreGraphicsState()
    }
    // The chip: a lighter glass inset with a thin light border, translucent
    // so the green reads through it.
    let chipPath = NSBezierPath(roundedRect: chip, xRadius: PanelStyle.chipRadius, yRadius: PanelStyle.chipRadius)
    (content.paused ? GlassStyle.chipFillPaused : GlassStyle.chipFill).setFill()
    chipPath.fill()
    let border = chipBorder
    let borderPath = NSBezierPath(roundedRect: border.rect, xRadius: border.radius, yRadius: border.radius)
    borderPath.lineWidth = 1
    (content.paused ? GlassStyle.chipBorderPaused : GlassStyle.chipBorder).setStroke()
    borderPath.stroke()

    // Digits (and the pause glyph) centred in the chip; drawn once in grey,
    // then again in white over the green part so they stay readable.
    let font = PanelStyle.chipFont
    let clockWidth = ceil(Self.clockText(content, color: .white).size().width)
    let pauseWidth = Self.pauseWidth(content)
    let startX = chip.minX + ((chip.width - clockWidth - pauseWidth) / 2).rounded()
    let baseline = (chip.midY - font.capHeight / 2 + font.descender).rounded()
    func drawInk(_ color: NSColor) {
      if content.paused, let glyph = Self.pauseGlyph?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
      {
        let size = glyph.size
        glyph.draw(in: NSRect(x: startX, y: (chip.midY - size.height / 2).rounded(), width: size.width, height: size.height))
      }
      Self.clockText(content, color: color).draw(at: NSPoint(x: startX + pauseWidth, y: baseline))
    }
    drawInk(content.paused ? PanelStyle.digitsPaused : PanelStyle.digits)
    if fill.width > 0 {
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: fill).addClip()
      drawInk(PanelStyle.digitsOnProgress)
      NSGraphicsContext.restoreGraphicsState()
    }

    guard !content.goal.isEmpty else { return }
    // A soft dark shadow keeps the white goal legible once the green sweep
    // reaches it (white on the fill alone is about 3.6:1).
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -0.5)
    shadow.shadowBlurRadius = 2
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    Self.goalText(content).draw(with: goalRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], context: nil)
    NSGraphicsContext.restoreGraphicsState()
  }

  /// The goal as drawn: one line, cut with an ellipsis at the pill's end.
  static func goalText(_ content: PanelContent) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    return NSAttributedString(
      string: content.goal,
      attributes: [.font: PanelStyle.goalFont, .foregroundColor: PanelStyle.goal, .paragraphStyle: style])
  }

  /// Where the goal is drawn: after the chip, up to the pill's trailing
  /// inset, one line tall, capitals on the chip's middle. The width is
  /// whatever the fixed pill leaves, so a long goal is cut here.
  var goalRect: NSRect {
    let chip = chipRect
    let goalFont = PanelStyle.goalFont
    let x = chip.maxX + PanelStyle.goalGap
    let width = max(0, bounds.width - x - PanelStyle.goalTrailing + 2)
    let lineHeight = ceil(goalFont.ascender - goalFont.descender)
    let y = (chip.midY - goalFont.capHeight / 2 + goalFont.descender).rounded()
    return NSRect(x: x, y: y, width: width, height: lineHeight)
  }

  /// True when the goal does not fit `goalRect` and is truncated.
  var goalIsTruncated: Bool {
    ceil(Self.goalText(content).size().width) > goalRect.width
  }
}

/// A flat bordered button: title then a small symbol ("Pause ⏸"), or the
/// symbol alone ("…"). Like the end sheet's SheetButton, smaller.
final class PanelButton: NSButton {
  let symbolName: String
  private var hovering = false {
    didSet { needsDisplay = true }
  }
  private var trackingArea: NSTrackingArea?

  init(title: String, symbol: String, label: String? = nil) {
    symbolName = symbol
    super.init(frame: .zero)
    isBordered = false
    setButtonType(.momentaryChange)
    refusesFirstResponder = true
    focusRingType = .none
    imagePosition = .noImage
    self.title = title
    setAccessibilityLabel(label ?? title)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func set(title: String, symbol: String, label: String) {
    self.title = title
    symbolOverride = symbol
    setAccessibilityLabel(label)
    needsDisplay = true
  }

  private var symbolOverride: String?
  var currentSymbol: String { symbolOverride ?? symbolName }

  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  private var titleText: NSAttributedString {
    NSAttributedString(string: title, attributes: [.font: PanelStyle.buttonFont, .foregroundColor: PanelStyle.ink])
  }

  /// The glyph in a 16 pt circle outline, in the secondary grey (Raycast's
  /// hover row): pause.circle, play.circle, checkmark.circle, ellipsis.circle.
  private func symbolImage() -> NSImage? {
    NSImage(systemSymbolName: currentSymbol + ".circle", accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
          .applying(NSImage.SymbolConfiguration(paletteColors: [PanelStyle.icon])))
  }

  static let iconGap: CGFloat = 6
  static let padding: CGFloat = 10
  static let iconSide: CGFloat = 16

  /// Fixed per title: the width does not change between Pause and Resume's symbols.
  var preferredWidth: CGFloat {
    if title.isEmpty { return PanelStyle.buttonHeight }
    return ceil(titleText.size().width) + Self.iconGap + Self.iconSide + Self.padding * 2
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
  /// A menu took the mouse; the button is no longer under it for our purposes.
  func resetHover() { hovering = false }

  override func draw(_ dirtyRect: NSRect) {
    // A small glass pill: light fill, a lighter hairline.
    let box = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: box, xRadius: PanelStyle.chipRadius, yRadius: PanelStyle.chipRadius)
    GlassStyle.buttonFill.setFill()
    path.fill()
    if hovering || isHighlighted {
      GlassStyle.buttonHover.setFill()
      path.fill()
    }
    GlassStyle.buttonBorder.setStroke()
    path.lineWidth = 1
    path.stroke()

    let image = symbolImage()
    let imageSize = image.map { size in
      let scale = Self.iconSide / max(size.size.width, size.size.height)
      return NSSize(width: size.size.width * scale, height: size.size.height * scale)
    } ?? .zero
    if title.isEmpty {
      image?.draw(in: NSRect(
        x: (bounds.midX - imageSize.width / 2).rounded(), y: (bounds.midY - imageSize.height / 2).rounded(),
        width: imageSize.width, height: imageSize.height))
      return
    }
    let text = titleText
    let textWidth = ceil(text.size().width)
    let total = textWidth + Self.iconGap + imageSize.width
    let font = PanelStyle.buttonFont
    var x = ((bounds.width - total) / 2).rounded()
    // NSButton is flipped: draw(at:) takes the line's top left.
    let y = isFlipped
      ? bounds.midY - font.capHeight / 2 - (font.ascender - font.capHeight)
      : bounds.midY - font.capHeight / 2 + font.descender
    text.draw(at: NSPoint(x: x, y: y.rounded()))
    x += textWidth + Self.iconGap
    image?.draw(in: NSRect(
      x: x, y: (bounds.midY - imageSize.height / 2).rounded(), width: imageSize.width, height: imageSize.height))
  }
}

