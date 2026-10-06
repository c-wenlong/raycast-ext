import AppKit
import Foundation

// MARK: - Zoom levels

/// The discrete zoom steps ⌘+ / ⌘- move through, matching Raycast Notes.
enum ZoomLevels {
  static let steps: [CGFloat] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
  static let `default`: CGFloat = 1.0

  /// The step at or after `value`'s nearest match, one notch up.
  static func next(after value: CGFloat) -> CGFloat {
    steps[min(closestIndex(to: value) + 1, steps.count - 1)]
  }

  /// The step at or before `value`'s nearest match, one notch down.
  static func previous(before value: CGFloat) -> CGFloat {
    steps[max(closestIndex(to: value) - 1, 0)]
  }

  static func percentageString(for value: CGFloat) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  private static func closestIndex(to value: CGFloat) -> Int {
    if let exact = steps.firstIndex(where: { abs($0 - value) < 0.001 }) { return exact }
    var bestIndex = 0
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for (index, step) in steps.enumerated() {
      let distance = abs(step - value)
      if distance < bestDistance {
        bestDistance = distance
        bestIndex = index
      }
    }
    return bestIndex
  }
}

// MARK: - Zoom HUD

/// Dark green glass with a softly lit rim, matching Focus's floating panel.
/// Drawing colours here avoids caching appearance-dependent layer colours.
private final class ZoomPillView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let bottom = NSColor(white: dark ? 0.065 : 0.10, alpha: 0.97)
    let top = NSColor(srgbRed: 0.10, green: 0.23, blue: 0.17, alpha: 0.97)
    NSGradient(starting: bottom, ending: top)?.draw(in: bounds, angle: 90)
    let glow = NSColor(srgbRed: 0.30, green: 0.83, blue: 0.56, alpha: 0.17)
    NSGradient(starting: glow, ending: glow.withAlphaComponent(0))?
      .draw(fromCenter: NSPoint(x: 19, y: bounds.midY), radius: 0,
            toCenter: NSPoint(x: 19, y: bounds.midY), radius: 38, options: [])
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.47, green: 0.80, blue: 0.62, alpha: 0.22).setStroke()
    shape.lineWidth = 1
    shape.stroke()
    NSColor(srgbRed: 0.32, green: 0.82, blue: 0.59, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 13, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

/// One transient announcement at the top of the note. Each update replaces
/// the text and restarts its one-second lifetime.
final class ZoomHUD {
  let view: NSView
  private let label: NSTextField
  private var hideWorkItem: DispatchWorkItem?
  private var topConstraint: NSLayoutConstraint?
  private var topInset: CGFloat = 52
  private var generation = 0
  private(set) var isShowing = false
  var text: String { label.stringValue }

  init() {
    let container = ZoomPillView(frame: .zero)
    container.wantsLayer = true
    container.alphaValue = 0
    container.isHidden = true
    container.translatesAutoresizingMaskIntoConstraints = false

    let text = NSTextField(labelWithString: "")
    text.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    text.textColor = .white
    text.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 29),
      text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
      text.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    view = container
    label = text
  }

  deinit { hideWorkItem?.cancel() }

  func install(in parent: NSView) {
    guard view.superview !== parent else { return }
    topConstraint?.isActive = false
    view.removeFromSuperview()
    parent.addSubview(view)
    let top = view.topAnchor.constraint(equalTo: parent.topAnchor, constant: topInset)
    topConstraint = top
    NSLayoutConstraint.activate([
      view.centerXAnchor.constraint(equalTo: parent.centerXAnchor), top,
    ])
  }

  func setTopInset(_ inset: CGFloat) {
    topInset = inset
    topConstraint?.constant = inset
  }

  func showZoom(_ zoom: CGFloat) {
    show(text: "Zoomed to \(ZoomLevels.percentageString(for: zoom))")
  }

  /// Fully hidden one second after the most recent call, including the fade.
  func show(text: String) {
    hideWorkItem?.cancel()
    generation += 1
    let currentGeneration = generation
    label.stringValue = text
    if let parent = view.superview {
      parent.addSubview(view, positioned: .above, relativeTo: nil)
      parent.layoutSubtreeIfNeeded()
    }
    view.layer?.removeAllAnimations()
    view.isHidden = false
    view.alphaValue = 1
    isShowing = true

    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.generation == currentGeneration else { return }
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.15
        self.view.animator().alphaValue = 0
      }, completionHandler: { [weak self] in
        guard let self, self.generation == currentGeneration else { return }
        self.view.isHidden = true
        self.isShowing = false
      })
    }
    hideWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
  }
}
