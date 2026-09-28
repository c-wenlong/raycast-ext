import AppKit
import Foundation

// MARK: - Session completed: sound and edge glow
//
// When the timer runs out (not on a manual stop or Cancel), like Raycast
// Focus: a short system sound and a soft green glow along every edge of
// every screen. The glow fades in over 0.3 s, holds, and is gone by 2.5 s
// (`duration`). The end card (EndSheet.swift) shows at once, top centre of
// the main screen, one level above the glow. The glow windows ignore the
// mouse, so nothing under them is blocked meanwhile.
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
  /// The edge glow: Raycast's saturated green, #2ECC71.
  static let glow = NSColor(srgbRed: 0x2E / 255, green: 0xCC / 255, blue: 0x71 / 255, alpha: 1)
  /// How far the glow reaches in from each edge.
  static let glowWidth: CGFloat = 170
  /// Its opacity right at the edge.
  static let glowAlpha: CGFloat = 0.85
  /// The glow's level; the end card is one above it.
  static let glowLevel = NSWindow.Level.screenSaver
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

/// A glow window's content: GlowView drawn once per screen size at half a
/// pixel per point and shown as the layer's contents, stretched. The
/// vignette is a smooth gradient, so it looks the same; drawn at full
/// resolution each time, it held the main thread for about 1.5 s on a
/// 2560 × 1440 screen plus a laptop's, which froze the end card showing with
/// it and swallowed the glow's fade-in.
final class GlowImageView: NSView {
  static let scale: CGFloat = 0.5
  private static var cache: [NSSize: CGImage] = [:]
  /// The sizes drawn and kept (the tests read it).
  static var cachedSizes: Set<NSSize> { Set(cache.keys) }

  /// Drops the images of screens that are gone (a display unplugged or its
  /// resolution changed), so a long-running daemon keeps one per screen.
  static func keepOnly(_ sizes: [NSSize]) {
    let keep = Set(sizes)
    cache = cache.filter { keep.contains($0.key) }
  }

  override var isOpaque: Bool { false }
  override var wantsUpdateLayer: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func updateLayer() {
    guard let layer else { return }
    layer.contentsGravity = .resize
    layer.magnificationFilter = .linear
    layer.contents = Self.image(for: bounds.size)
  }

  /// The glow for a screen of `size` points, drawn at `scale`.
  static func image(for size: NSSize) -> CGImage? {
    guard size.width >= 1, size.height >= 1 else { return nil }
    if let cached = cache[size] { return cached }
    let view = GlowView(frame: NSRect(origin: .zero, size: size))
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
      pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = rep.cgImage
    cache[size] = image
    return image
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
  private(set) var isPlaying = false
  /// What happened, in order: "sound", "glow", "fadeOut", "done".
  private(set) var trace: [String] = []
  private var tasks: [ScheduledTask] = []

  init(scheduler: UIScheduler, sound: CompletionSound = SystemCompletionSound()) {
    self.scheduler = scheduler
    self.sound = sound
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

  /// Sound, then the glow on every screen. Ends by itself after `duration`.
  func play(screens: [ScreenGeometry]) {
    stop()
    isPlaying = true
    trace = []
    sound.play()
    trace.append("sound")

    glowFrames = screens.map(\.frame)
    GlowImageView.keepOnly(screens.map(\.frame.size))
    while glowWindows.count < screens.count {
      let window = OverlayWindow(contentRect: .zero, level: CompletionStyle.glowLevel)
      window.title = "Focus session completed glow"
      window.contentView = GlowImageView()
      glowWindows.append(window)
    }
    for (window, frame) in zip(glowWindows, glowFrames) {
      window.alphaValue = 0
      place(window, frame)
      window.orderFrontRegardless()
    }
    trace.append("glow")
    let shown = Array(glowWindows.prefix(screens.count))
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
    trace.append("done")
  }

  /// Ends at once (a new completion, or the daemon going idle).
  func stop() {
    tasks.forEach { $0.cancel() }
    tasks = []
    guard isPlaying else { return }
    isPlaying = false
    glowWindows.forEach { $0.orderOut(nil) }
  }

  var isGlowVisible: Bool { glowWindows.contains { $0.isVisible } }
}
