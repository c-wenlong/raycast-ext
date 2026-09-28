import AppKit
import QuartzCore

// MARK: - Lava lamp background
//
// Soft pale-green blobs drifting slowly inside the pill, under the glass's
// edges, the sweep and the text, so the panel looks alive: bubbles under
// glass. Each blob is a radial gradient layer (soft by construction, no
// blur filter) whose centre drifts between two points on its own eased
// loops, x and y on different periods so the path never visibly repeats,
// and which swells and shrinks a little on a third. CoreAnimation only: no
// timers, nothing on the main thread once it runs.
//
// The blobs sit in the glass's content, over the painted tint: macOS 26's
// glass draws over any sibling view behind it with its own sample of the
// desktop, so a layer behind the glass would not show (checked on screen).
//
// The whole lamp freezes while the panel is hidden, while the session is
// paused (dimmed too) and when Reduce Motion is on.

enum LavaStyle {
  /// #9BE7B0 and #3FA36A: each blob's colour is somewhere between.
  static let pale = NSColor(srgbRed: 0x9B / 255.0, green: 0xE7 / 255.0, blue: 0xB0 / 255.0, alpha: 1)
  static let deep = NSColor(srgbRed: 0x3F / 255.0, green: 0xA3 / 255.0, blue: 0x6A / 255.0, alpha: 1)
  static let count = 5
  static let alpha: ClosedRange<CGFloat> = 0.25...0.45
  static let diameter: ClosedRange<CGFloat> = 60...120
  /// One way of each drift, seconds (it then eases back).
  static let period: ClosedRange<Double> = 12...25
  /// How much a blob swells and shrinks around its size.
  static let breathe: CGFloat = 0.1
  /// How far in from the pill's edge a blob's centre stays.
  static let inset: CGFloat = 4
  /// The lamp's opacity while the session is paused.
  static let pausedOpacity: Float = 0.45
}

/// One blob: its size and colour, and the two points its centre drifts
/// between (x and y each on their own period), in the pill's coordinates.
struct LavaBlob: Equatable {
  var diameter: CGFloat
  var color: NSColor
  var from: CGPoint
  var to: CGPoint
  var periodX: Double
  var periodY: Double
  var periodScale: Double
  /// Where in its loop it starts, 0 to 1, so the blobs are out of step.
  var phase: Double

  /// The rectangle its centre can reach.
  var travel: CGRect {
    CGRect(
      x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
  }
}

/// A small seedable generator (SplitMix64), so the tests get the same blobs every run.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

enum LavaLayout {
  /// `count` blobs for a pill of `size`. Each starts in its own stretch of
  /// the width and drifts into its neighbours'; every centre stays at least
  /// `LavaStyle.inset` inside the pill. Pure.
  static func blobs<G: RandomNumberGenerator>(in size: CGSize, count: Int = LavaStyle.count, using rng: inout G) -> [LavaBlob] {
    guard count > 0, size.width > LavaStyle.inset * 2, size.height > LavaStyle.inset * 2 else { return [] }
    let minX = LavaStyle.inset
    let maxX = size.width - LavaStyle.inset
    let minY = LavaStyle.inset
    let maxY = size.height - LavaStyle.inset
    let lane = (maxX - minX) / CGFloat(count)
    return (0..<count).map { index in
      // The lane, widened by half a lane each side, so neighbours cross.
      let low = max(minX, minX + lane * (CGFloat(index) - 0.5))
      let high = min(maxX, minX + lane * (CGFloat(index) + 1.5))
      let mix = CGFloat.random(in: 0...1, using: &rng)
      let color = blend(LavaStyle.pale, LavaStyle.deep, mix)
        .withAlphaComponent(CGFloat.random(in: LavaStyle.alpha, using: &rng))
      return LavaBlob(
        diameter: CGFloat.random(in: LavaStyle.diameter, using: &rng).rounded(),
        color: color,
        from: CGPoint(x: CGFloat.random(in: low...high, using: &rng), y: CGFloat.random(in: minY...maxY, using: &rng)),
        to: CGPoint(x: CGFloat.random(in: low...high, using: &rng), y: CGFloat.random(in: minY...maxY, using: &rng)),
        periodX: Double.random(in: LavaStyle.period, using: &rng),
        periodY: Double.random(in: LavaStyle.period, using: &rng),
        periodScale: Double.random(in: LavaStyle.period, using: &rng),
        phase: Double.random(in: 0..<1, using: &rng))
    }
  }

  static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let a = a.usingColorSpace(.sRGB) ?? a
    let b = b.usingColorSpace(.sRGB) ?? b
    return NSColor(
      srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
      green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
      blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
  }
}

/// The lamp: clipped to the pill's rounded shape, never takes the mouse.
final class LiveBackgroundView: NSView {
  var radius: CGFloat = PanelStyle.radius {
    didSet { layer?.cornerRadius = radius }
  }
  /// Read when the lamp would start; true keeps it still (Reduce Motion).
  var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  private(set) var blobs: [LavaBlob] = []
  private(set) var blobLayers: [CAGradientLayer] = []
  /// True while the blobs drift.
  private(set) var isRunning = true
  /// What the panel last asked for; Reduce Motion can still hold it still.
  private(set) var wantsToRun = true
  private var motionObserver: NSObjectProtocol?
  /// Dimmed for a paused session.
  var dimmed = false {
    didSet {
      guard dimmed != oldValue else { return }
      layer?.opacity = dimmed ? LavaStyle.pausedOpacity : 1
    }
  }
  private var generator: SeededGenerator
  private var laidOutSize = CGSize.zero

  /// `seed` fixes the blobs (tests); nil picks new ones each launch.
  init(seed: UInt64? = nil) {
    generator = SeededGenerator(seed: seed ?? UInt64.random(in: 0...UInt64.max))
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = radius
    // Reduce Motion switched in System Settings: stop or start at once
    // rather than at the next countdown refresh.
    motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.motionSettingChanged() }
  }

  deinit {
    if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// Re-reads Reduce Motion against what the panel last asked for.
  func motionSettingChanged() { setRunning(wantsToRun) }

  override var isFlipped: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    rebuildIfNeeded()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    rebuildIfNeeded()
  }

  /// New blobs for a new size (the pill keeps one size, so this is rare).
  private func rebuildIfNeeded() {
    guard let layer, bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else { return }
    laidOutSize = bounds.size
    blobLayers.forEach { $0.removeFromSuperlayer() }
    blobs = LavaLayout.blobs(in: bounds.size, using: &generator)
    blobLayers = blobs.map { blob in
      let disc = Self.discLayer(blob)
      layer.addSublayer(disc)
      Self.addDrift(to: disc, blob)
      return disc
    }
    if !isRunning { freeze(layer) }
  }

  /// A disc that is `color` at the middle and clear at its rim, softly.
  static func discLayer(_ blob: LavaBlob) -> CAGradientLayer {
    let disc = CAGradientLayer()
    disc.type = .radial
    let alpha = blob.color.alphaComponent
    // A bell-like falloff (about exp(-3r²)), so no core or rim shows.
    let falloff: [(CGFloat, CGFloat)] = [(0, 1), (0.2, 0.89), (0.4, 0.62), (0.6, 0.34), (0.8, 0.13), (1, 0)]
    disc.colors = falloff.map { blob.color.withAlphaComponent(alpha * $0.1).cgColor }
    disc.locations = falloff.map { NSNumber(value: Double($0.0)) }
    // A radial gradient's end point gives both radii (x and y), so (1, 1)
    // is a circle of half the side: clear exactly at the inscribed circle.
    disc.startPoint = CGPoint(x: 0.5, y: 0.5)
    disc.endPoint = CGPoint(x: 1, y: 1)
    disc.bounds = CGRect(x: 0, y: 0, width: blob.diameter, height: blob.diameter)
    disc.position = blob.from
    return disc
  }

  /// The drift keys on each disc.
  static let driftKeys = ["lava.x", "lava.y", "lava.scale"]

  /// x and y each ease from `from` to `to` and back on their own period;
  /// the size swells and shrinks on a third. Started part way in (`phase`).
  static func addDrift(to disc: CALayer, _ blob: LavaBlob) {
    func loop(_ keyPath: String, _ from: CGFloat, _ to: CGFloat, _ period: Double) -> CABasicAnimation {
      let animation = CABasicAnimation(keyPath: keyPath)
      animation.fromValue = from
      animation.toValue = to
      animation.duration = period
      animation.autoreverses = true
      animation.repeatCount = .infinity
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animation.timeOffset = blob.phase * period * 2
      animation.isRemovedOnCompletion = false
      return animation
    }
    disc.add(loop("position.x", blob.from.x, blob.to.x, blob.periodX), forKey: driftKeys[0])
    disc.add(loop("position.y", blob.from.y, blob.to.y, blob.periodY), forKey: driftKeys[1])
    disc.add(
      loop("transform.scale", 1 - LavaStyle.breathe, 1 + LavaStyle.breathe, blob.periodScale), forKey: driftKeys[2])
  }

  /// Drift or hold still where the blobs are now. Reduce Motion keeps it still.
  func setRunning(_ running: Bool) {
    wantsToRun = running
    let run = running && !reduceMotion()
    guard run != isRunning else { return }
    isRunning = run
    guard let layer else { return }
    if run {
      // Carry on from where it stopped: move the clock back by the pause.
      let pausedAt = layer.timeOffset
      layer.speed = 1
      layer.timeOffset = 0
      layer.beginTime = 0
      layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
    } else {
      freeze(layer)
    }
  }

  private func freeze(_ layer: CALayer) {
    guard layer.speed != 0 else { return }
    let now = layer.convertTime(CACurrentMediaTime(), from: nil)
    layer.speed = 0
    layer.timeOffset = now
  }
}
