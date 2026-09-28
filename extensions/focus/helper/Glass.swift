import AppKit

// MARK: - Liquid glass for the floating panel
//
// The countdown pill as a slab of tinted glass, like Raycast Focus: on macOS
// 26 a clear `NSGlassEffectView` blurs and bends the desktop behind the
// panel; older systems get the HUD blur. The dark green is painted on top
// by the chrome (`GlassStyle.tint`) rather than set as the glass's
// `tintColor`: AppKit greys a glass tint out in a window that is not key,
// and this panel is never key. `GlassEdgesView` draws what makes it read as thick glass:
// a bright rim on the top and left, a darker one along the bottom, a short
// inner highlight under the top edge and a faint diagonal sheen across the
// top third. The chip and the hover buttons are lighter glass insets.
//
// The shapes are pure (`GlassEdges`) so the headless tests can check them;
// the window server's glass itself only renders on screen.

enum GlassStyle {
  /// The tint painted over the glass: a dark green slab. A little more
  /// saturated than Raycast's #1F3A2E so it lands near it over the glass's
  /// own grey.
  static let tint = NSColor(srgbRed: 0.10, green: 0.26, blue: 0.19, alpha: 0.72)
  /// Before macOS 26 the tint goes over the HUD blur, denser since that
  /// blur is greyer and flatter than the glass.
  static let fallbackCanvas = NSColor(srgbRed: 0.11, green: 0.22, blue: 0.17, alpha: 0.88)

  /// The inner highlight under the top edge: this at the edge, 0 `highlightDepth` below.
  static let highlight = NSColor(white: 1, alpha: 0.35)
  static let highlightDepth: CGFloat = 6
  /// The 1 pt rim: bright along the top, faint down the sides, dark along
  /// the bottom; the left end is lit a little more (light from the top left).
  static let rimTop = NSColor(white: 1, alpha: 0.42)
  static let rimMiddle = NSColor(white: 1, alpha: 0.10)
  static let rimBottom = NSColor(white: 0, alpha: 0.25)
  static let rimLeft = NSColor(white: 1, alpha: 0.22)
  /// How far in from the left the extra light on the rim reaches.
  static let rimLeftReach: CGFloat = 36
  /// The specular sheen: a diagonal white wash over the top third.
  static let sheen = NSColor(white: 1, alpha: 0.08)
  /// A faint dark shade over the bottom `shadeDepth` points: the slab's thickness.
  static let shade = NSColor(white: 0, alpha: 0.14)
  static let shadeDepth: CGFloat = 9

  /// The chip: lighter glass set into the slab.
  static let chipFill = NSColor(white: 1, alpha: 0.12)
  static let chipFillPaused = NSColor(white: 1, alpha: 0.07)
  static let chipBorder = NSColor(white: 1, alpha: 0.22)
  static let chipBorderPaused = NSColor(white: 1, alpha: 0.14)

  /// The green sweep: translucent green glass, lighter at the top, with a
  /// lit leading edge.
  static let progressTop = NSColor(srgbRed: 0.36, green: 0.86, blue: 0.52, alpha: 0.42)
  static let progressBottom = NSColor(srgbRed: 0.22, green: 0.66, blue: 0.38, alpha: 0.34)
  static let progressEdge = NSColor(srgbRed: 0.70, green: 1, blue: 0.80, alpha: 0.32)
  /// Paused dims the sweep.
  static let progressPausedAlpha: CGFloat = 0.5

  /// The hover row's buttons: small glass pills.
  static let buttonFill = NSColor(white: 1, alpha: 0.10)
  static let buttonHover = NSColor(white: 1, alpha: 0.08)
  static let buttonBorder = NSColor(white: 1, alpha: 0.20)
}

/// Where the glass edges go for a pill of `bounds` with corner `radius`.
/// Pure: every rect lies inside `bounds`.
struct GlassEdges: Equatable {
  var bounds: NSRect
  var radius: CGFloat

  /// The rim is a 1 pt line on the pill's edge, inside it.
  static let rimWidth: CGFloat = 1

  /// The rounded rect the rim is stroked on: half a line in from the edge.
  var rimRect: NSRect { bounds.insetBy(dx: Self.rimWidth / 2, dy: Self.rimWidth / 2) }
  var rimRadius: CGFloat { max(0, radius - Self.rimWidth / 2) }

  /// The band under the top edge the inner highlight fades across (y up).
  var highlightRect: NSRect {
    let depth = min(GlassStyle.highlightDepth, bounds.height / 2)
    return NSRect(x: bounds.minX, y: bounds.maxY - depth, width: bounds.width, height: depth)
  }

  /// The band above the bottom edge the shade fades across.
  var shadeRect: NSRect {
    NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(GlassStyle.shadeDepth, bounds.height / 2))
  }

  /// The top third, where the sheen falls.
  var sheenRect: NSRect {
    let height = (bounds.height / 3).rounded()
    return NSRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
  }

  /// The left stretch of the rim that is lit a little more.
  var leftLightRect: NSRect {
    NSRect(x: bounds.minX, y: bounds.minY, width: min(GlassStyle.rimLeftReach, bounds.width), height: bounds.height)
  }

  /// The pill's outline, for clipping.
  var shapePath: NSBezierPath { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius) }
  var rimPath: NSBezierPath { NSBezierPath(roundedRect: rimRect, xRadius: rimRadius, yRadius: rimRadius) }

  /// The rim's colours from the top of the pill to the bottom, with where
  /// each sits (0 = bottom, 1 = top, as `NSGradient` at 90°).
  static let rimStops: [(NSColor, CGFloat)] = [
    (GlassStyle.rimBottom, 0), (GlassStyle.rimMiddle, 0.45), (GlassStyle.rimMiddle, 0.6), (GlassStyle.rimTop, 1),
  ]

  /// A chip-like inset: its 1 pt border's rect and radius, inside `rect`.
  static func insetBorder(_ rect: NSRect, radius: CGFloat) -> (rect: NSRect, radius: CGFloat) {
    (rect.insetBy(dx: 0.5, dy: 0.5), max(0, radius - 0.5))
  }

  /// Draws the sheen, the inner highlight and the rim into the current context.
  func draw() {
    guard bounds.width > 2, bounds.height > 2, let context = NSGraphicsContext.current?.cgContext else { return }
    NSGraphicsContext.saveGraphicsState()
    shapePath.addClip()
    // The sheen: strongest at the top left, fading along the diagonal and,
    // in a second pass that keeps only what the vertical fade lets through,
    // downwards, so it has no hard lower edge.
    let sheen = sheenRect
    context.saveGState()
    context.clip(to: sheen)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSGradient(colors: [GlassStyle.sheen, GlassStyle.sheen.withAlphaComponent(0)])?.draw(in: sheen, angle: -12)
    context.setBlendMode(.destinationIn)
    NSGradient(starting: NSColor(white: 0, alpha: 0), ending: NSColor(white: 0, alpha: 1))?.draw(in: sheen, angle: 90)
    context.endTransparencyLayer()
    context.restoreGState()
    // A faint shade above the bottom edge: the slab's thickness.
    NSGradient(starting: GlassStyle.shade, ending: GlassStyle.shade.withAlphaComponent(0))?.draw(in: shadeRect, angle: 90)
    // The inner highlight just under the top edge.
    NSGradient(starting: GlassStyle.highlight.withAlphaComponent(0), ending: GlassStyle.highlight)?
      .draw(in: highlightRect, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // The rim: stroke the outline into a clip and fill it with gradients.
    context.saveGState()
    context.addPath(rimPath.cgPath)
    context.setLineWidth(Self.rimWidth)
    context.replacePathWithStrokedPath()
    context.clip()
    let colors = Self.rimStops.map(\.0)
    var locations = Self.rimStops.map(\.1)
    NSGradient(colors: colors, atLocations: &locations, colorSpace: .sRGB)?.draw(in: bounds, angle: 90)
    NSGradient(starting: GlassStyle.rimLeft, ending: GlassStyle.rimLeft.withAlphaComponent(0))?
      .draw(in: leftLightRect, angle: 0)
    context.restoreGState()
  }
}

/// The edges on top of everything in the pill and the hover row. It never
/// takes the mouse.
final class GlassEdgesView: NSView {
  var radius: CGFloat = PanelStyle.radius {
    didSet { needsDisplay = true }
  }
  var edges: GlassEdges { GlassEdges(bounds: bounds, radius: radius) }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) { edges.draw() }
}

/// The panel's backdrop: real glass on macOS 26, the HUD blur before.
enum GlassBackdrop {
  /// True when this Mac has `NSGlassEffectView`.
  static var isAvailable: Bool {
    if #available(macOS 26, *) { return true }
    return false
  }

  /// A view for the window's content: `NSGlassEffectView` with `content`
  /// as its content view, or an `NSVisualEffectView` cut to the pill's shape
  /// with `content` on it.
  static func make(radius: CGFloat, content: NSView, glass: Bool) -> NSView {
    if glass, #available(macOS 26, *) {
      let view = NSGlassEffectView()
      // Clear lets the desktop's light through (the regular style is a
      // nearly opaque dark frost in dark mode); no tintColor, see above.
      view.style = .clear
      view.cornerRadius = radius
      view.contentView = content
      return view
    }
    let effect = NSVisualEffectView()
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.maskImage = maskImage(radius: radius)
    content.frame = effect.bounds
    content.autoresizingMask = [.width, .height]
    effect.addSubview(content)
    return effect
  }

  /// A stretchable rounded-rect mask.
  static func maskImage(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}
