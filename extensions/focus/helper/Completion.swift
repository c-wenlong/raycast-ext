import AppKit
import Foundation

// MARK: - Session completed: sound, edge glow and banner
//
// When the timer runs out (not on a manual stop or Cancel), like Raycast
// Focus: a short system sound, a soft green glow along every edge of every
// screen, and a dark rounded banner top centre of the main screen, "Focus
// session completed" over "You stayed focused." with a green check. Both
// fade in over 0.3 s, hold, and are gone by 2.5 s (`duration`), when
// UIPresenter shows the end sheet. The windows ignore the mouse, so nothing
// under them is blocked meanwhile.
//
// Main thread only; the tests pass a fake scheduler and sound and run it
// headless (windows ordered in far off screen, no animation).

/// Plays the completion sound; the tests count calls instead.
protocol CompletionSound: AnyObject {
  func play()
}

/// A short built-in macOS sound; no bundled file.
final class SystemCompletionSound: CompletionSound {
  private var sound: NSSound?
  func play() {
    // A copy, so a second completion while one plays still sounds.
    sound = (NSSound(named: "Glass")?.copy() as? NSSound) ?? NSSound(named: "Hero")
    sound?.play()
  }
}

enum CompletionStyle {
  /// The check in the banner.
  static let green = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
  /// The edge glow: Raycast's saturated green, #2ECC71.
  static let glow = NSColor(srgbRed: 0x2E / 255, green: 0xCC / 255, blue: 0x71 / 255, alpha: 1)
  /// How far the glow reaches in from each edge.
  static let glowWidth: CGFloat = 170
  /// Its opacity right at the edge.
  static let glowAlpha: CGFloat = 0.85
  static let title = NSColor(white: 1, alpha: 0.95)
  static let subtitle = NSColor(white: 1, alpha: 0.55)
  static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
  static let subtitleFont = NSFont.systemFont(ofSize: 13)
  static let bannerHeight: CGFloat = 56
  static let bannerRadius: CGFloat = 16
}

/// The soft green vignette for one screen, drawn as nested rings from the
/// edge inwards. Each ring is a rounded rectangle whose corner radius grows
/// with its depth (`cornerRadius(at:)`, 120 pt at the inner boundary), so
/// the corners fall off smoothly with no seams. `intensity(at:)` is the
/// falloff: `glowAlpha` at the edge easing to nothing at `glowWidth`.
final class GlowView: NSView {
  override var isOpaque: Bool { false }

  static let step: CGFloat = 2

  /// Opacity of the glow `depth` points in from the edge.
  static func intensity(at depth: CGFloat) -> CGFloat {
    let t = min(1, max(0, depth / CompletionStyle.glowWidth))
    return CompletionStyle.glowAlpha * pow(1 - t, 1.8)
  }

  /// The inner boundary's corner radius: 120 pt at `glowWidth`, and larger
  /// than the depth near the edge so the corners stay creaseless.
  static func cornerRadius(at depth: CGFloat) -> CGFloat {
    120 * pow(max(0, depth) / CompletionStyle.glowWidth, 0.6)
  }

  static func band(_ rect: NSRect, depth: CGFloat) -> NSBezierPath {
    let inner = rect.insetBy(dx: depth, dy: depth)
    let radius = min(cornerRadius(at: depth), inner.width / 2, inner.height / 2)
    return NSBezierPath(roundedRect: inner, xRadius: radius, yRadius: radius)
  }

  /// Nested fills rather than disjoint bands, so no two anti-aliased edges
  /// meet (disjoint bands leave hairlines along the curved corners). Each
  /// fill covers the edge up to depth d and adds just enough opacity that
  /// the stack composites to `intensity(at:)` at every depth.
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds
    let depthLimit = min(CompletionStyle.glowWidth, rect.width / 2, rect.height / 2)
    var depth = (depthLimit / Self.step).rounded(.up) * Self.step
    while depth > 0 {
      let outside = Self.intensity(at: depth - Self.step / 2)
      let inside = Self.intensity(at: depth + Self.step / 2)
      let alpha = 1 - (1 - outside) / max(0.0001, 1 - inside)
      if alpha > 0.0005 {
        let path = NSBezierPath(rect: rect)
        path.append(Self.band(rect, depth: min(depth, depthLimit)).reversed)
        path.windingRule = .evenOdd
        CompletionStyle.glow.withAlphaComponent(alpha).setFill()
        path.fill()
      }
      depth -= Self.step
    }
  }
}

/// The banner's content: the dark rounded canvas (as the floating panel),
/// a green check, the title and the line under it.
final class BannerView: NSView {
  static let title = "Focus session completed"
  static let subtitle = "You stayed focused."
  private static let check = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white, CompletionStyle.green])))

  static var titleText: NSAttributedString {
    NSAttributedString(string: title, attributes: [.font: CompletionStyle.titleFont, .foregroundColor: CompletionStyle.title])
  }
  static var subtitleText: NSAttributedString {
    NSAttributedString(
      string: subtitle, attributes: [.font: CompletionStyle.subtitleFont, .foregroundColor: CompletionStyle.subtitle])
  }

  static let leading: CGFloat = 16
  static let iconGap: CGFloat = 12
  static let trailing: CGFloat = 22

  static var width: CGFloat {
    let text = max(titleText.size().width, subtitleText.size().width)
    return ceil(leading + (check?.size.width ?? 20) + iconGap + text + trailing)
  }

  override func draw(_ dirtyRect: NSRect) {
    let box = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(
      roundedRect: box, xRadius: CompletionStyle.bannerRadius - 0.5, yRadius: CompletionStyle.bannerRadius - 0.5)
    PanelStyle.canvas.setFill()
    path.fill()
    PanelStyle.border.setStroke()
    path.lineWidth = 1
    path.stroke()

    var x = Self.leading
    if let check = Self.check {
      let size = check.size
      check.draw(in: NSRect(x: x, y: (bounds.midY - size.height / 2).rounded(), width: size.width, height: size.height))
      x += size.width + Self.iconGap
    }
    // Two lines centred as a block on the banner's middle.
    let title = Self.titleText
    let subtitle = Self.subtitleText
    let titleFont = CompletionStyle.titleFont
    let subtitleFont = CompletionStyle.subtitleFont
    let gap: CGFloat = 3
    let titleLine = ceil(titleFont.ascender - titleFont.descender)
    let subtitleLine = ceil(subtitleFont.ascender - subtitleFont.descender)
    let top = (bounds.midY + (titleLine + gap + subtitleLine) / 2).rounded()
    title.draw(at: NSPoint(x: x, y: top - titleLine))
    subtitle.draw(at: NSPoint(x: x, y: top - titleLine - gap - subtitleLine))
  }
}

/// A transparent window that never takes the mouse or focus.
final class OverlayWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(contentRect: NSRect, level: NSWindow.Level) {
    super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    self.level = level
    isOpaque = false
    backgroundColor = .clear
    ignoresMouseEvents = true
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    appearance = NSAppearance(named: .darkAqua)
  }
}

final class Completion {
  /// Fade in, hold, fade out: everything is gone at `duration`.
  static let fadeIn: TimeInterval = 0.3
  static let fadeOutAt: TimeInterval = 1.8
  static let duration: TimeInterval = 2.5

  private let scheduler: UIScheduler
  let sound: CompletionSound
  /// Tests: windows go far off screen and alpha changes are immediate.
  var headless = false

  private(set) var glowWindows: [OverlayWindow] = []
  /// Where each glow window is (the screen's frame), headless included.
  private(set) var glowFrames: [NSRect] = []
  let banner: OverlayWindow
  let bannerView = BannerView()
  private(set) var bannerFrame = NSRect.zero
  private(set) var isPlaying = false
  /// What happened, in order: "sound", "glow", "banner", "fadeOut", "done".
  private(set) var trace: [String] = []
  private var tasks: [ScheduledTask] = []

  init(scheduler: UIScheduler, sound: CompletionSound = SystemCompletionSound()) {
    self.scheduler = scheduler
    self.sound = sound
    banner = OverlayWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: CompletionStyle.bannerHeight),
      level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1))
    banner.hasShadow = true
    banner.title = "Focus session completed"
    bannerView.setAccessibilityElement(true)
    bannerView.setAccessibilityRole(.staticText)
    bannerView.setAccessibilityLabel("\(BannerView.title). \(BannerView.subtitle)")
    banner.contentView = bannerView
  }

  /// Top centre of `screen`, `margin` below the menu bar.
  static func bannerFrame(on screen: ScreenGeometry) -> NSRect {
    let width = BannerView.width
    return NSRect(
      x: (screen.frame.midX - width / 2).rounded(),
      y: (screen.visibleFrame.maxY - PanelStyle.margin - CompletionStyle.bannerHeight).rounded(),
      width: width, height: CompletionStyle.bannerHeight)
  }

  private func place(_ window: NSWindow, _ rect: NSRect) {
    window.setFrame(headless ? rect.offsetBy(dx: -40000, dy: -40000) : rect, display: true)
  }

  private func fade(_ windows: [NSWindow], to alpha: CGFloat, over seconds: TimeInterval) {
    if headless {
      windows.forEach { $0.alphaValue = alpha }
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = seconds
      context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
      windows.forEach { $0.animator().alphaValue = alpha }
    }
  }

  /// Sound, glow on every screen, banner on the first (main) one. Ends by itself after `duration`.
  func play(screens: [ScreenGeometry]) {
    stop()
    isPlaying = true
    trace = []
    sound.play()
    trace.append("sound")

    glowFrames = screens.map(\.frame)
    while glowWindows.count < screens.count {
      let window = OverlayWindow(contentRect: .zero, level: .screenSaver)
      window.title = "Focus session completed glow"
      window.contentView = GlowView()
      glowWindows.append(window)
    }
    for (window, frame) in zip(glowWindows, glowFrames) {
      window.alphaValue = 0
      place(window, frame)
      window.orderFrontRegardless()
    }
    trace.append("glow")

    if let main = screens.first {
      bannerFrame = Self.bannerFrame(on: main)
      banner.alphaValue = 0
      place(banner, bannerFrame)
      banner.orderFrontRegardless()
      trace.append("banner")
    }
    let shown = Array(glowWindows.prefix(screens.count)) + (screens.isEmpty ? [] : [banner])
    fade(shown, to: 1, over: Self.fadeIn)

    tasks.append(scheduler.after(Self.fadeOutAt) { [weak self] in
      guard let self else { return }
      self.trace.append("fadeOut")
      self.fade(shown, to: 0, over: Self.duration - Self.fadeOutAt)
    })
    tasks.append(scheduler.after(Self.duration) { [weak self] in
      guard let self else { return }
      self.finish()
    })
  }

  private func finish() {
    tasks = []
    isPlaying = false
    glowWindows.forEach { $0.orderOut(nil) }
    banner.orderOut(nil)
    trace.append("done")
  }

  /// Ends at once (a new completion, or the daemon going idle).
  func stop() {
    tasks.forEach { $0.cancel() }
    tasks = []
    guard isPlaying else { return }
    isPlaying = false
    glowWindows.forEach { $0.orderOut(nil) }
    banner.orderOut(nil)
  }

  var isGlowVisible: Bool { glowWindows.contains { $0.isVisible } }
  var isBannerVisible: Bool { banner.isVisible }
}
