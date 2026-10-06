import AppKit
import Foundation

// MARK: - Window attachment
//
// Where the notes window hangs: the floating panel (default, the original
// behaviour), a menu bar item whose click drops an editor under it, or the
// notch — a black island like Focus's that expands into the same editor,
// sharing the notch with Focus's session when it is live there. Picked
// from the ⌘K palette (or `attachment-floating`, `attachment-menuBar`,
// `attachment-notch` over the socket) and remembered in UserDefaults next
// to the zoom and theme.

/// The window's attachment.
enum NoteAttachment: String, CaseIterable {
  case floating, menuBar, notch

  var title: String {
    switch self {
    case .floating: return "Floating Window"
    case .menuBar: return "Menu Bar"
    case .notch: return "Notch"
    }
  }

  var command: String { "attachment-" + rawValue }
  /// Shown in the zoom HUD's bubble after a change.
  var announcement: String {
    switch self {
    case .floating: return "Floating window"
    case .menuBar: return "Menu bar attachment"
    case .notch: return "Notch attachment"
    }
  }
  var symbol: String {
    switch self {
    case .floating: return "macwindow"
    case .menuBar: return "menubar.rectangle"
    case .notch: return "inset.filled.topthird.square"
    }
  }

  /// Extra words the palette search matches.
  var keywords: String { "attach attachment window position " + rawValue }
}

// MARK: - Notch geometry
//
// The same shape as Focus's island: a black strip whose top meets the top
// of the screen, small outward flares where it joins the menu bar and
// rounded bottom corners, one point taller than the bar. This mirrors
// focus/helper/NotchPanel.swift (NotchScreen/NotchStyle/NotchLayout.path)
// so the two helpers read as one piece; it is a deliberate copy — the
// helpers share no code and only talk over the focus socket.

/// The screen the island hangs from.
struct NotesNotchScreen: Equatable {
  var frame: NSRect
  /// The notch in global coordinates; nil on a screen without one.
  var notch: NSRect?
  /// The menu bar's height there (the notch's height on a notched screen).
  var barHeight: CGFloat

  /// The screen with a notch (the built-in display), else the main screen;
  /// nil when there is no screen at all.
  static func current() -> NotesNotchScreen? {
    let screens = NSScreen.screens
    if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) { return from(notched) }
    guard let main = NSScreen.main ?? screens.first else { return nil }
    return from(main)
  }

  static func from(_ screen: NSScreen) -> NotesNotchScreen {
    let frame = screen.frame
    let top = screen.safeAreaInsets.top
    var notch: NSRect?
    if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
      let width = frame.width - left.width - right.width
      if width > 0 { notch = NSRect(x: frame.minX + left.width, y: frame.maxY - top, width: width, height: top) }
    }
    let bar = top > 0 ? top : frame.maxY - screen.visibleFrame.maxY
    return NotesNotchScreen(frame: frame, notch: notch, barHeight: bar > 0 ? bar : NotchMetrics.fallbackBarHeight)
  }

  /// Where the island is centred: on the notch, else on the screen.
  var centreX: CGFloat { notch?.midX ?? frame.midX }
  /// What the two wings sit either side of: the notch, or a small gap.
  var gap: CGFloat { notch?.width ?? NotchMetrics.noNotchGap }
}

enum NotchMetrics {
  /// Same level as Focus's island: above the menu bar and its items,
  /// below menus and Focus's end card.
  static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
  static let ear: CGFloat = 8
  static let earHeight: CGFloat = 10
  static let stripRadius: CGFloat = 11
  static let cardRadius: CGFloat = 15
  static let extraHeight: CGFloat = 1
  static let noNotchGap: CGFloat = 12
  static let fallbackBarHeight: CGFloat = 24
  static let wingOuter: CGFloat = 12
  static let wingInner: CGFloat = 10
  /// The strip shows the notes symbol; a live Focus session adds the clock.
  static let iconFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
  static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
  static let clock = NSColor(white: 1, alpha: 0.92)
  static let clockPaused = NSColor(white: 1, alpha: 0.55)
  static let focusGreen = NSColor(srgbRed: 0.36, green: 0.86, blue: 0.52, alpha: 1)

  /// Black under the menu bar band, easing to the dark canvas below.
  static let canvas = NSColor(white: 0.10, alpha: 1)
  static let canvasFade: CGFloat = 36

  /// Resting this long on the island opens the editor, like Focus's card.
  static let enterDelay: TimeInterval = 0.5
  /// Away this long closes a hover-opened editor.
  static let exitDelay: TimeInterval = 0.15
  /// Growing and shrinking, eased.
  static let animation: TimeInterval = 0.25
}

/// Where everything goes, in global coordinates. Pure.
enum NotchGeometry {
  /// A wing's width: its content plus the padding on each side.
  static func wing(contentWidth: CGFloat) -> CGFloat {
    max(ceil(contentWidth), 14) + NotchMetrics.wingOuter + NotchMetrics.wingInner
  }

  /// The collapsed island (flares aside): the gap plus a wing each side,
  /// hanging from the top edge, one point taller than the menu bar.
  static func strip(leftWing: CGFloat, rightWing: CGFloat, on screen: NotesNotchScreen) -> NSRect {
    let width = screen.gap + leftWing + rightWing
    let height = screen.barHeight + NotchMetrics.extraHeight
    return NSRect(
      x: (screen.centreX - width / 2).rounded(), y: screen.frame.maxY - height, width: width, height: height)
  }

  /// The open card: as wide as the strip or `size`, whichever is wider,
  /// from the top edge down past the content.
  static func card(size: NSSize, strip: NSRect, on screen: NotesNotchScreen) -> NSRect {
    let width = max(strip.width, size.width)
    let height = screen.barHeight + size.height
    return NSRect(
      x: (strip.midX - width / 2).rounded(), y: screen.frame.maxY - height, width: width, height: height)
  }

  /// The window: the card and the strip with room for the flares.
  static func window(card: NSRect, strip: NSRect) -> NSRect {
    card.union(strip).insetBy(dx: -NotchMetrics.ear, dy: 0)
  }

  /// Where the pointer opens the editor: the strip or the notch.
  static func hoverRect(strip: NSRect, on screen: NotesNotchScreen) -> NSRect {
    screen.notch.map { strip.union($0) } ?? strip
  }

  /// The body between `from` and `to` at `t` (0 to 1), and its corner radius.
  static func interpolate(_ from: NSRect, _ to: NSRect, _ t: CGFloat) -> (rect: NSRect, radius: CGFloat) {
    let mix = { (a: CGFloat, b: CGFloat) in a + (b - a) * t }
    let rect = NSRect(
      x: mix(from.minX, to.minX), y: mix(from.minY, to.minY), width: mix(from.width, to.width),
      height: mix(from.height, to.height))
    return (rect, mix(NotchMetrics.stripRadius, NotchMetrics.cardRadius))
  }

  /// The island's outline around `body` (its top on the top edge): the
  /// same flares and smooth bottom corners as Focus's, so they join.
  static func path(body: NSRect, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let top = body.maxY
    let bottom = body.minY
    let ear = NotchMetrics.ear
    let earHeight = min(NotchMetrics.earHeight, body.height / 2)
    let extent = min(radius * 1.25, body.height - earHeight, body.width / 2)
    let pull = extent * 0.36
    path.move(to: NSPoint(x: body.minX - ear, y: top))
    path.curve(
      to: NSPoint(x: body.minX, y: top - earHeight), controlPoint1: NSPoint(x: body.minX - ear * 0.35, y: top),
      controlPoint2: NSPoint(x: body.minX, y: top - earHeight * 0.4))
    path.line(to: NSPoint(x: body.minX, y: bottom + extent))
    path.curve(
      to: NSPoint(x: body.minX + extent, y: bottom), controlPoint1: NSPoint(x: body.minX, y: bottom + pull),
      controlPoint2: NSPoint(x: body.minX + pull, y: bottom))
    path.line(to: NSPoint(x: body.maxX - extent, y: bottom))
    path.curve(
      to: NSPoint(x: body.maxX, y: bottom + extent), controlPoint1: NSPoint(x: body.maxX - pull, y: bottom),
      controlPoint2: NSPoint(x: body.maxX, y: bottom + pull))
    path.line(to: NSPoint(x: body.maxX, y: top - earHeight))
    path.curve(
      to: NSPoint(x: body.maxX + ear, y: top), controlPoint1: NSPoint(x: body.maxX, y: top - earHeight * 0.4),
      controlPoint2: NSPoint(x: body.maxX + ear * 0.35, y: top))
    path.close()
    return path
  }

  /// Ease out for growing, ease in and out for shrinking.
  static func eased(_ t: CGFloat, growing: Bool) -> CGFloat {
    let x = min(1, max(0, t))
    if growing { return 1 - pow(1 - x, 3) }
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
  }
}
