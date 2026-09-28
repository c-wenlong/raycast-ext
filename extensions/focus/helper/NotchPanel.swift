import AppKit
import Foundation

// MARK: - Notch countdown
//
// The countdown as an island at the notch, like HeyClicky's: a pure black
// shape whose top meets the top of the screen, with small outward flares
// where it joins the menu bar and rounded bottom corners, one point taller
// than the menu bar and wider than the notch by a wing on each side, so the
// notch and the island read as one piece. The left wing holds the time left
// (`mm:ss`, monospaced digits), the right wing a small green progress ring;
// paused dims both and puts ⏸ inside the ring.
//
// Resting the pointer on the island (or the notch) for `enterDelay` grows it
// downwards, eased over `animation`, into a card with the floating panel's
// content: the pill (time chip, goal, green sweep) on a dark green slab and
// the controls row below it (Pause, Complete, "…"; no drag handle, the
// island does not move). Leaving it for `exitDelay` shrinks it back.
//
// The window never changes size: it is as large as the card (plus the
// flares) and pinned to the top centre of the screen with the notch (the
// main screen's top centre without one); the island is drawn inside it and
// animated by redrawing. Until the card is fully open the window ignores
// the mouse, so its clear part never takes a click (the pointer is polled
// instead); once open, only the island's outline reacts.
// Hidden while idle and at the end sheet. Main thread only.

/// The screen the island hangs from.
struct NotchScreen: Equatable {
  var frame: NSRect
  /// The notch in global coordinates; nil on a screen without one.
  var notch: NSRect?
  /// The menu bar's height there (the notch's height on a notched screen).
  var barHeight: CGFloat

  /// The screen with a notch (the built-in display), else the main screen;
  /// nil when there is no screen at all.
  static func current() -> NotchScreen? {
    let screens = NSScreen.screens
    if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) { return from(notched) }
    guard let main = NSScreen.main ?? screens.first else { return nil }
    return from(main)
  }

  /// The notch lies between the two auxiliary top areas, as tall as the top
  /// safe area inset. Only their widths are used, so it does not matter
  /// whether AppKit reports them in global or screen coordinates.
  static func from(_ screen: NSScreen) -> NotchScreen {
    let frame = screen.frame
    let top = screen.safeAreaInsets.top
    var notch: NSRect?
    if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
      let width = frame.width - left.width - right.width
      if width > 0 { notch = NSRect(x: frame.minX + left.width, y: frame.maxY - top, width: width, height: top) }
    }
    let bar = top > 0 ? top : frame.maxY - screen.visibleFrame.maxY
    return NotchScreen(frame: frame, notch: notch, barHeight: bar > 0 ? bar : NotchStyle.fallbackBarHeight)
  }

  /// Where the island is centred: on the notch, else on the screen.
  var centreX: CGFloat { notch?.midX ?? frame.midX }
  /// What the two wings sit either side of: the notch, or a small gap.
  var gap: CGFloat { notch?.width ?? NotchStyle.noNotchGap }
}

enum NotchStyle {
  /// HeyClicky's level (26): above the menu bar and its status items,
  /// below menus, the completion glow and the end card.
  static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

  /// The flares where the island meets the top edge: this far out at the
  /// top, curving in over `earHeight` (HeyClicky: about 7 by 8 to 10).
  static let ear: CGFloat = 8
  static let earHeight: CGFloat = 10
  /// The strip's bottom corners (the notch's own are about this) and the card's.
  static let stripRadius: CGFloat = 11
  static let cardRadius: CGFloat = 15
  /// The strip reaches this far below the menu bar, hiding the notch's own
  /// lower corners (HeyClicky: 33 on a 32 pt menu bar).
  static let extraHeight: CGFloat = 1
  /// Without a notch, the wings sit this far apart.
  static let noNotchGap: CGFloat = 12
  /// A menu bar that reports no height (auto-hidden).
  static let fallbackBarHeight: CGFloat = 24

  /// Inside a wing: from the outer edge (clear of the corner) and from the notch.
  static let wingOuter: CGFloat = 12
  static let wingInner: CGFloat = 10
  static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
  static let clock = NSColor(white: 1, alpha: 0.92)
  static let clockPaused = NSColor(white: 1, alpha: 0.55)
  static let ringDiameter: CGFloat = 14
  static let ringWidth: CGFloat = 2
  static let ringTrack = NSColor(white: 1, alpha: 0.18)
  static let ring = NSColor(srgbRed: 0.36, green: 0.86, blue: 0.52, alpha: 1)
  static let ringPausedAlpha: CGFloat = 0.45

  /// The card: below the menu bar band, `topGap`, the pill, `rowGap`, the
  /// buttons, `bottom`; `padding` either side.
  static let padding: CGFloat = 16
  static let topGap: CGFloat = 8
  static let rowGap: CGFloat = 8
  static let bottom: CGFloat = 14
  /// Black under the menu bar band, easing to the dark canvas below it
  /// (HeyClicky's card: black header, #1C1C1B body).
  static let canvas = NSColor(white: 0.10, alpha: 1)
  static let canvasFade: CGFloat = 36

  /// Resting this long on the island opens the card (HeyClicky waits about
  /// 0.6 s), so passing the pointer along the menu bar never opens it.
  static let enterDelay: TimeInterval = 0.5
  /// Away this long closes it (HeyClicky about 0.1 s).
  static let exitDelay: TimeInterval = 0.15
  /// Growing and shrinking, eased.
  static let animation: TimeInterval = 0.25
}

/// Where everything goes, in global coordinates. Pure.
enum NotchLayout {
  /// A wing's width for `content`: the clock and its padding. Pausing
  /// never changes it (the pause glyph goes in the ring); only an hour or
  /// more does.
  static func wing(_ content: PanelContent) -> CGFloat {
    let text = NSAttributedString(string: content.clock, attributes: [.font: NotchStyle.clockFont])
    return max(ceil(text.size().width), NotchStyle.ringDiameter) + NotchStyle.wingOuter + NotchStyle.wingInner
  }

  /// The collapsed island (flares aside): the gap plus a wing each side,
  /// hanging from the top edge, one point taller than the menu bar.
  static func strip(wing: CGFloat, on screen: NotchScreen) -> NSRect {
    let width = screen.gap + wing * 2
    let height = screen.barHeight + NotchStyle.extraHeight
    return NSRect(
      x: (screen.centreX - width / 2).rounded(), y: screen.frame.maxY - height, width: width, height: height)
  }

  /// The card's content: the pill over the controls row.
  static func contentSize(rowWidth: CGFloat, strip: NSRect) -> NSSize {
    NSSize(
      width: max(rowWidth, strip.width - NotchStyle.padding * 2),
      height: PanelStyle.idleHeight + NotchStyle.rowGap + PanelStyle.buttonHeight)
  }

  /// The open card: as wide as the strip or the content, whichever is
  /// wider, from the top edge down past the content.
  static func card(content: NSSize, strip: NSRect, on screen: NotchScreen) -> NSRect {
    let width = max(strip.width, content.width + NotchStyle.padding * 2)
    let height = screen.barHeight + NotchStyle.topGap + content.height + NotchStyle.bottom
    return NSRect(
      x: (strip.midX - width / 2).rounded(), y: screen.frame.maxY - height, width: width, height: height)
  }

  /// The window: the card and the strip with room for the flares.
  static func window(card: NSRect, strip: NSRect) -> NSRect {
    card.union(strip).insetBy(dx: -NotchStyle.ear, dy: 0)
  }

  /// Where the pointer opens the card: the strip or the notch.
  static func hoverRect(strip: NSRect, on screen: NotchScreen) -> NSRect {
    screen.notch.map { strip.union($0) } ?? strip
  }

  /// The body between `from` and `to` at `t` (0 to 1), and its corner radius.
  static func interpolate(_ from: NSRect, _ to: NSRect, _ t: CGFloat) -> (rect: NSRect, radius: CGFloat) {
    let mix = { (a: CGFloat, b: CGFloat) in a + (b - a) * t }
    let rect = NSRect(
      x: mix(from.minX, to.minX), y: mix(from.minY, to.minY), width: mix(from.width, to.width),
      height: mix(from.height, to.height))
    return (rect, mix(NotchStyle.stripRadius, NotchStyle.cardRadius))
  }

  /// The island's outline around `body` (its top on the top edge): flares
  /// out at the top, rounded bottom corners with a smooth (not circular)
  /// curve. The same elements at every size, so it interpolates cleanly.
  static func path(body: NSRect, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let top = body.maxY
    let bottom = body.minY
    let ear = NotchStyle.ear
    let earHeight = min(NotchStyle.earHeight, body.height / 2)
    // The corner reaches a little further than its radius and bends late,
    // like the notch's own.
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

  /// Ease out for growing (quick start, soft landing), ease in and out for shrinking.
  static func eased(_ t: CGFloat, growing: Bool) -> CGFloat {
    let x = min(1, max(0, t))
    if growing { return 1 - pow(1 - x, 3) }
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
  }
}

/// How full the sweep is: `SweepClock`, plus what a pause does to it.
///
/// An ad-hoc session's pause stops its clock: the time left holds and the
/// planned end moves on with the wall clock (see Session.swift), so a
/// length read as `plannedEnd - startedAt` would grow and drain the fill.
/// Here a pause freezes the fill where it was. The same time left `settle`
/// or more after the pause began (while still paused, or at the resume)
/// marks the session as one whose pause stops the clock; from then on its
/// length leaves out the time spent paused (`pausedSeconds`), so the fill
/// resumes from where it froze instead of jumping ahead. A calendar
/// session's time left keeps falling while paused (the pause is a break
/// inside the event): its fill keeps moving with it, over the whole span.
/// A pause shorter than `settle` stays unclassified and is off by less than
/// that; a pause the notch never saw (it was on another display then) counts
/// over the whole span, as the floating panel shows it. Pure.
struct NotchSweep: Equatable {
  private(set) var sessionId: Int?
  private(set) var clock: SweepClock?
  /// The fill held while paused.
  private(set) var frozen: Double?
  /// Seen for this session: its pause holds the time left.
  private(set) var pauseStopsClock = false
  /// Seen for this session: its time left falls while paused.
  private(set) var pauseKeepsClock = false
  /// The first paused update of the current pause: time left and when.
  private var pausedSince: (remaining: Int, at: Date)?

  /// How long after the pause began the time left tells the two kinds
  /// apart: whole seconds rounded down, so a clock that runs has dropped at
  /// least one by then (the pause's own update and the next tick can share
  /// a second).
  static let settle: TimeInterval = 1.05

  static func == (a: NotchSweep, b: NotchSweep) -> Bool {
    a.sessionId == b.sessionId && a.clock == b.clock && a.frozen == b.frozen && a.pauseStopsClock == b.pauseStopsClock
      && a.pauseKeepsClock == b.pauseKeepsClock && a.pausedSince?.remaining == b.pausedSince?.remaining
      && a.pausedSince?.at == b.pausedSince?.at
  }

  /// `view` with its start moved later by the time spent paused when the
  /// pause stops its clock, so `plannedEnd - startedAt` is the focused length.
  private func focused(_ view: SessionView) -> SessionView {
    guard pauseStopsClock else { return view }
    var view = view
    view.startedAt = view.startedAt.addingTimeInterval(TimeInterval(view.pausedSeconds))
    return view
  }

  mutating func update(_ view: SessionView, at now: Date) {
    if view.id != sessionId { self = NotchSweep(sessionId: view.id) }
    switch view.state {
    case "running":
      // A pause just ended: the time left says what kind it was.
      if let since = pausedSince { classify(view, since: since, at: now) }
      pausedSince = nil
      frozen = nil
      let view = focused(view)
      clock = clock?.updated(with: view, at: now) ?? SweepClock(view, at: now)
    case "paused":
      if let since = pausedSince {
        classify(view, since: since, at: now)
      } else {
        pausedSince = (view.remainingSeconds, now)
        frozen = clock?.progress(at: now) ?? PanelContent.progress(focused(view))
      }
      if pauseKeepsClock && !pauseStopsClock {
        // A break inside the event: the fill keeps pace with the time left.
        frozen = nil
        clock = clock?.updated(with: view, at: now) ?? SweepClock(view, at: now)
      } else {
        clock = nil
      }
    default:
      frozen = 1
      clock = nil
    }
  }

  /// The time left `settle` or more after the pause began: held, the pause
  /// stops the clock; fallen, it does not.
  private mutating func classify(_ view: SessionView, since: (remaining: Int, at: Date), at now: Date) {
    guard now.timeIntervalSince(since.at) >= Self.settle else { return }
    if view.remainingSeconds == since.remaining { pauseStopsClock = true }
    if view.remainingSeconds < since.remaining { pauseKeepsClock = true }
  }

  private init(sessionId: Int) { self.sessionId = sessionId }
  init() {}

  func progress(at time: Date) -> Double {
    if let frozen { return frozen }
    return clock?.progress(at: time) ?? 0
  }

  /// True while the fill moves on its own.
  var moving: Bool { frozen == nil && clock?.moving == true }
}

// MARK: Views

/// The window's content: clicks count only inside the island's outline, so
/// the clear corners and flares of an open card never react.
final class NotchRootView: NSView {
  weak var island: NotchIslandView?

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let island else { return super.hitTest(point) }
    let local = island.convert(point, from: superview)
    guard island.path.contains(local) else { return nil }
    return super.hitTest(point)
  }
}

/// Never key, never main; the frame is never moved to fit the screen.
final class NotchWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The island itself: the black shape, at whatever size the animation has
/// reached, black under the menu bar band and easing to the dark canvas below.
final class NotchIslandView: NSView {
  /// The body in view coordinates (flares aside) and its corner radius.
  var body = NSRect.zero {
    didSet { if body != oldValue { needsDisplay = true } }
  }
  var radius: CGFloat = NotchStyle.stripRadius {
    didSet { if radius != oldValue { needsDisplay = true } }
  }
  /// The menu bar band's height, black whatever the size.
  var barHeight: CGFloat = 32

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  var path: NSBezierPath { NotchLayout.path(body: body, radius: radius) }

  override func draw(_ dirtyRect: NSRect) {
    guard body.width > 0, body.height > 0 else { return }
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSColor.black.setFill()
    bounds.fill()
    // The canvas below the band, faded in so the band's black runs on into it.
    let fadeTop = bounds.maxY - barHeight - 2
    let fade = NSRect(x: bounds.minX, y: fadeTop - NotchStyle.canvasFade, width: bounds.width, height: NotchStyle.canvasFade)
    NSGradient(starting: NotchStyle.canvas, ending: .black)?.draw(in: fade, angle: 90)
    NotchStyle.canvas.setFill()
    NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, fade.minY - bounds.minY)).fill()
    NSGraphicsContext.restoreGraphicsState()
  }
}

/// The collapsed strip's content: the clock in the left wing, the progress
/// ring in the right one, both on the menu bar band's middle.
final class NotchStripView: NSView {
  var content = PanelContent(clock: "00:00", paused: false, progress: 0, goal: "") {
    didSet { if content != oldValue { needsDisplay = true } }
  }
  /// The ring's fill, 0 to 1.
  var progress: Double = 0 {
    didSet { if progress != oldValue { needsDisplay = true } }
  }
  var wing: CGFloat = 60
  var barHeight: CGFloat = 32

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// The band's middle, where the digits' capitals and the ring are centred.
  var bandMidY: CGFloat { bounds.maxY - barHeight / 2 }

  var clockRect: NSRect {
    NSRect(x: 0, y: bounds.maxY - barHeight, width: wing, height: barHeight)
  }

  var ringRect: NSRect {
    let side = NotchStyle.ringDiameter
    return NSRect(x: (bounds.maxX - wing / 2 - side / 2).rounded(), y: (bandMidY - side / 2).rounded(), width: side, height: side)
  }

  /// ⏸ small enough to sit inside the ring, in `color`. (A second
  /// `withSymbolConfiguration` would replace the size, so both go in one.)
  static func pauseGlyph(_ color: NSColor) -> NSImage? {
    NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 6, weight: .black).applying(NSImage.SymbolConfiguration(paletteColors: [color])))
  }

  override func draw(_ dirtyRect: NSRect) {
    let font = NotchStyle.clockFont
    let color = content.paused ? NotchStyle.clockPaused : NotchStyle.clock
    let text = NSAttributedString(string: content.clock, attributes: [.font: font, .foregroundColor: color])
    let textWidth = ceil(text.size().width)
    // Centred in the left wing, between the outer edge's padding and the notch's.
    let area = NSRect(x: NotchStyle.wingOuter, y: 0, width: wing - NotchStyle.wingOuter - NotchStyle.wingInner, height: 0)
    let x = (area.minX + (area.width - textWidth) / 2).rounded()
    text.draw(at: NSPoint(x: x, y: (bandMidY - font.capHeight / 2 + font.descender).rounded()))

    if content.paused, let glyph = Self.pauseGlyph(color) {
      let size = glyph.size
      let ring = ringRect
      glyph.draw(in: NSRect(x: (ring.midX - size.width / 2).rounded(), y: (ring.midY - size.height / 2).rounded(), width: size.width, height: size.height))
    }

    // The ring: a faint track, the elapsed part in green from twelve o'clock, clockwise.
    let ring = ringRect.insetBy(dx: NotchStyle.ringWidth / 2, dy: NotchStyle.ringWidth / 2)
    let dim: CGFloat = content.paused ? NotchStyle.ringPausedAlpha : 1
    let track = NSBezierPath(ovalIn: ring)
    track.lineWidth = NotchStyle.ringWidth
    NotchStyle.ringTrack.withAlphaComponent(NotchStyle.ringTrack.alphaComponent * dim).setStroke()
    track.stroke()
    let fraction = CGFloat(min(1, max(0, progress)))
    guard fraction > 0 else { return }
    let arc = NSBezierPath()
    arc.appendArc(
      withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: 90,
      endAngle: 90 - 360 * fraction, clockwise: true)
    arc.lineWidth = NotchStyle.ringWidth
    arc.lineCapStyle = .round
    NotchStyle.ring.withAlphaComponent(dim).setStroke()
    arc.stroke()
  }
}

/// The pill's slab in the card: the floating panel's dark green tint (the
/// window server's glass cannot show through a black card, so it is painted).
final class NotchSlabView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    GlassStyle.tint.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: PanelStyle.radius, yRadius: PanelStyle.radius).fill()
  }
}

/// What the notch's controls ask for. UIPresenter implements it.
protocol NotchPanelActions: AnyObject {
  func panelPause(for seconds: Int?)
  func panelResume()
  func panelComplete()
  func panelEdit()
  func panelCancel()
  /// "Move to Floating Panel" or "Move to Menu Bar".
  func notchMove(to display: CountdownDisplay)
}

// MARK: Panel

final class NotchPanel: NSObject {
  weak var actions: NotchPanelActions?
  let window: NotchWindow
  let root = NotchRootView()
  let island = NotchIslandView()
  let strip = NotchStripView()
  /// Clips the card's content to the island as it grows and shrinks.
  let clip = NSView()
  /// The open card's content: the slab with the pill and its edges, then the controls.
  let card = NSView()
  let slab = NotchSlabView()
  let pill = CountdownPillView()
  let edges = GlassEdgesView()
  let pauseButton = PanelButton(title: "Pause", symbol: "pause")
  let completeButton = PanelButton(title: "Complete", symbol: "checkmark")
  let moreButton = PanelButton(title: "", symbol: "ellipsis", label: "More")
  let pauseMenu = NSMenu(title: "Pause")
  let moreMenu = NSMenu(title: "More")

  /// Tests: order the window in far off screen, no animation, no timers.
  /// `frame` and the rects still say where things would be.
  var headless = false
  /// Shows a menu under a button; the tests record instead.
  var popUpMenu: (NSMenu, NSView) -> Void = { menu, view in
    let y = view.isFlipped ? view.bounds.maxY + 5 : -5
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
  }
  var screen: () -> NotchScreen?
  /// Where the pointer is, for the hover poll; the tests pass a fixed point.
  var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
  /// The wall clock the sweep reads; the tests pass a fake one.
  var clock: () -> Date = Date.init
  private let scheduler: UIScheduler

  private(set) var content: PanelContent?
  private(set) var session: SessionView?
  private(set) var isVisible = false
  /// True once the card is (or is growing) open.
  private(set) var isExpanded = false
  /// How open the island is drawn, 0 (strip) to 1 (card).
  private(set) var expansion: CGFloat = 0
  /// The window's frame (headless included), global.
  private(set) var frame = NSRect.zero
  /// The strip, the card and the screen they were laid out for, global.
  private(set) var stripRect = NSRect.zero
  private(set) var cardRect = NSRect.zero
  private(set) var layoutScreen: NotchScreen?
  /// Where the card's content sits in the window, whatever the clip's size.
  private var contentRect = NSRect.zero
  private(set) var sweep = NotchSweep()
  private(set) var pointerInside = false
  private var enterTask: ScheduledTask?
  private var exitTask: ScheduledTask?
  private var menuOpen = false
  private var pointerTimer: Timer?
  private var sweepTimer: Timer?
  private var animationTimer: Timer?

  init(scheduler: UIScheduler, screen: @escaping () -> NotchScreen? = NotchScreen.current) {
    self.scheduler = scheduler
    self.screen = screen
    window = NotchWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 130), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: true)
    super.init()
    build()
  }

  // MARK: Building

  private func build() {
    window.level = NotchStyle.level
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.hidesOnDeactivate = false
    window.isMovableByWindowBackground = false
    window.isReleasedWhenClosed = false
    window.becomesKeyOnlyIfNeeded = true
    window.backgroundColor = .clear
    window.isOpaque = false
    // The notch has no shadow, and a shadow would outline the clear window.
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.animationBehavior = .none
    window.title = "Focus countdown"

    root.frame = NSRect(x: 0, y: 0, width: 300, height: 130)
    root.island = island
    window.contentView = root
    island.autoresizingMask = [.width, .height]
    root.addSubview(island)
    strip.setAccessibilityElement(true)
    strip.setAccessibilityRole(.staticText)
    root.addSubview(strip)

    clip.wantsLayer = true
    clip.layer?.masksToBounds = true
    root.addSubview(clip)
    card.wantsLayer = true
    card.alphaValue = 0
    card.isHidden = true
    clip.addSubview(card)
    card.addSubview(slab)
    pill.wantsLayer = true
    pill.setAccessibilityElement(true)
    pill.setAccessibilityRole(.staticText)
    card.addSubview(pill)
    edges.radius = PanelStyle.radius
    card.addSubview(edges)
    for button in [pauseButton, completeButton, moreButton] {
      button.target = self
      card.addSubview(button)
    }
    pauseButton.action = #selector(pauseClicked)
    completeButton.action = #selector(completeClicked)
    moreButton.action = #selector(moreClicked)

    pauseMenu.autoenablesItems = false
    pauseMenu.appearance = NSAppearance(named: .darkAqua)
    for (title, seconds) in FloatingPanel.pauseChoices {
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
      ("Move to Floating Panel", "macwindow", #selector(moveToPanelChosen)),
      ("Move to Menu Bar", "menubar.rectangle", #selector(moveToMenuBarChosen)),
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

  /// The controls row's width: Pause (one width for Resume too), Complete, "…".
  var rowWidth: CGFloat {
    FloatingPanel.pauseSlot + PanelStyle.buttonGap + completeButton.preferredWidth + PanelStyle.buttonGap
      + moreButton.preferredWidth
  }

  /// Lays the island out for `wing` on `screen`: the window, the strip and
  /// the card, and the views inside the window.
  private func layout(wing: CGFloat, on screen: NotchScreen) {
    stripRect = NotchLayout.strip(wing: wing, on: screen)
    let content = NotchLayout.contentSize(rowWidth: rowWidth, strip: stripRect)
    cardRect = NotchLayout.card(content: content, strip: stripRect, on: screen)
    frame = NotchLayout.window(card: cardRect, strip: stripRect)
    layoutScreen = screen
    let actual = headless ? frame.offsetBy(dx: -40000, dy: -40000) : frame
    window.setFrame(actual, display: false, animate: false)
    root.frame = NSRect(origin: .zero, size: frame.size)
    island.frame = root.bounds
    island.barHeight = screen.barHeight
    strip.frame = local(stripRect)
    strip.wing = wing
    strip.barHeight = screen.barHeight
    let cardLocal = local(cardRect)
    contentRect = NSRect(
      x: cardLocal.midX - content.width / 2, y: cardLocal.minY + NotchStyle.bottom, width: content.width,
      height: content.height)
    card.frame = contentRect
    let slabRect = NSRect(
      x: 0, y: content.height - PanelStyle.idleHeight, width: content.width, height: PanelStyle.idleHeight)
    slab.frame = slabRect
    pill.frame = slabRect
    edges.frame = slabRect
    var x = ((content.width - rowWidth) / 2).rounded()
    for button in [pauseButton, completeButton, moreButton] {
      let width = button === pauseButton ? FloatingPanel.pauseSlot : button.preferredWidth
      button.frame = NSRect(x: x, y: 0, width: width, height: PanelStyle.buttonHeight)
      x += width + PanelStyle.buttonGap
    }
    drawExpansion()
  }

  /// A global rect in the window's coordinates.
  func local(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }

  /// The island's body as drawn now, global.
  var islandRect: NSRect { NotchLayout.interpolate(stripRect, cardRect, expansion).rect }

  /// Where the pointer counts as on the island: the strip or the notch
  /// while collapsed, the card once open.
  var hoverRect: NSRect {
    guard let screen = layoutScreen else { return .zero }
    return isExpanded ? cardRect : NotchLayout.hoverRect(strip: stripRect, on: screen)
  }

  // MARK: Showing

  /// Shows (or refreshes) the island for `view`.
  func show(_ view: SessionView) {
    session = view
    var content = PanelContent(view)
    sweep.update(view, at: clock())
    content.progress = sweep.progress(at: clock())
    self.content = content
    strip.content = content
    strip.progress = content.progress
    pill.content = content
    pill.progress = content.progress
    let label = "Focus: \(content.paused ? "paused, " : "")\(content.clock) left, \(content.goal)"
    strip.setAccessibilityLabel(label)
    pill.setAccessibilityLabel(label)
    let paused = view.state == "paused"
    pauseButton.set(title: paused ? "Resume" : "Pause", symbol: paused ? "play" : "pause", label: paused ? "Resume" : "Pause")
    completeButton.setAccessibilityLabel("Complete")

    guard let screen = screen() else { return }
    let wing = NotchLayout.wing(content)
    if screen != layoutScreen || wing != strip.wing { layout(wing: wing, on: screen) }
    if !isVisible {
      isVisible = true
      window.orderFrontRegardless()
      startPointerPolling()
    }
    updateSweepTimer()
  }

  /// Hides the island (idle, the end sheet, another display), closed.
  func hide() {
    enterTask?.cancel()
    enterTask = nil
    exitTask?.cancel()
    exitTask = nil
    pointerTimer?.invalidate()
    pointerTimer = nil
    sweepTimer?.invalidate()
    sweepTimer = nil
    pointerInside = false
    setExpanded(false, animated: false)
    guard isVisible else { return }
    isVisible = false
    window.orderOut(nil)
  }

  private func startPointerPolling() {
    guard !headless, pointerTimer == nil else { return }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkPointer() }
    RunLoop.main.add(timer, forMode: .common)
    pointerTimer = timer
  }

  /// The poll: is the pointer on the island (or the notch) now?
  func checkPointer() {
    guard isVisible else { return }
    pointerMoved(inside: hoverRect.contains(pointerLocation()))
  }

  /// Moves the pill's sweep on to now.
  func advanceSweep() {
    pill.progress = sweep.progress(at: clock())
  }

  /// True while the 30 Hz sweep timer should run: the card open on a running session.
  var sweepMoves: Bool { isVisible && isExpanded && sweep.moving && sweep.progress(at: clock()) < 1 }

  private func updateSweepTimer() {
    if !sweepMoves || headless {
      sweepTimer?.invalidate()
      sweepTimer = nil
      return
    }
    guard sweepTimer == nil else { return }
    let timer = Timer(timeInterval: FloatingPanel.sweepInterval, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.advanceSweep()
      if !self.sweepMoves { self.updateSweepTimer() }
    }
    timer.tolerance = FloatingPanel.sweepInterval / 4
    RunLoop.main.add(timer, forMode: .common)
    sweepTimer = timer
  }

  // MARK: Hover

  /// The pointer crossed the island's edge; repeats are ignored. Resting on
  /// it `enterDelay` opens the card, leaving it `exitDelay` closes it.
  func pointerMoved(inside: Bool) {
    guard inside != pointerInside else { return }
    pointerInside = inside
    if inside {
      exitTask?.cancel()
      exitTask = nil
      guard isVisible, !isExpanded, enterTask == nil else { return }
      enterTask = scheduler.after(NotchStyle.enterDelay) { [weak self] in
        guard let self else { return }
        self.enterTask = nil
        if self.pointerInside, self.isVisible { self.setExpanded(true, animated: true) }
      }
    } else {
      enterTask?.cancel()
      enterTask = nil
      scheduleExit()
    }
  }

  /// Closes the card `exitDelay` from now unless the pointer comes back.
  private func scheduleExit() {
    guard isExpanded, !menuOpen, exitTask == nil else { return }
    exitTask = scheduler.after(NotchStyle.exitDelay) { [weak self] in
      guard let self else { return }
      self.exitTask = nil
      if !self.pointerInside, !self.menuOpen { self.setExpanded(false, animated: true) }
    }
  }

  /// Opens or closes the card: the island grows or shrinks over
  /// `animation`, the strip's content fading out as the card's fades in.
  func setExpanded(_ expanded: Bool, animated: Bool) {
    let target: CGFloat = expanded ? 1 : 0
    guard expanded != isExpanded || expansion != target else { return }
    isExpanded = expanded
    // Only the card takes clicks, once fully open: until then the clear
    // part of the window below the growing island would swallow them.
    window.ignoresMouseEvents = true
    if expanded { card.isHidden = false }
    if !expanded { [pauseButton, completeButton, moreButton].forEach { $0.resetHover() } }
    animationTimer?.invalidate()
    animationTimer = nil
    if !animated || headless || !isVisible {
      expansion = target
      drawExpansion()
      window.ignoresMouseEvents = !expanded
      updateSweepTimer()
      return
    }
    // From wherever it is now, so a reversal mid-way does not jump.
    let start = expansion
    let duration = NotchStyle.animation * Double(abs(target - start))
    let began = CACurrentMediaTime()
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
      guard let self else { return timer.invalidate() }
      let t = duration > 0 ? CGFloat((CACurrentMediaTime() - began) / duration) : 1
      let eased = NotchLayout.eased(t, growing: expanded)
      self.expansion = start + (target - start) * eased
      self.drawExpansion()
      if t >= 1 {
        timer.invalidate()
        self.animationTimer = nil
        self.window.ignoresMouseEvents = !expanded
        self.updateSweepTimer()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    animationTimer = timer
    advanceSweep()
  }

  /// Draws the island at `expansion`: its shape, the strip's content fading
  /// out over the first third, the card's fading in over the last half.
  private func drawExpansion() {
    let shape = NotchLayout.interpolate(stripRect, cardRect, expansion)
    island.body = local(shape.rect)
    island.radius = shape.radius
    // The content stays put; the clip grows with the island around it.
    clip.frame = island.body
    card.frame = contentRect.offsetBy(dx: -clip.frame.minX, dy: -clip.frame.minY)
    strip.alphaValue = max(0, 1 - expansion * 3)
    strip.isHidden = expansion >= 1
    card.alphaValue = max(0, expansion * 2 - 1)
    card.isHidden = expansion <= 0
  }

  // MARK: Actions

  private func runMenu(_ menu: NSMenu, from view: NSView) {
    menuOpen = true
    exitTask?.cancel()
    exitTask = nil
    popUpMenu(menu, view)
    menuOpen = false
    (view as? PanelButton)?.resetHover()
    // The menu held the pointer: close if it left meanwhile.
    if !headless { checkPointer() }
    if !pointerInside { scheduleExit() }
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
  @objc private func moveToPanelChosen() { actions?.notchMove(to: .panel) }
  @objc private func moveToMenuBarChosen() { actions?.notchMove(to: .menuBar) }
}
