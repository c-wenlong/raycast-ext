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

/// A small floating pill, like Raycast's, that reports the current zoom
/// level. Lives at the top centre of a content view and fades in, holds,
/// then fades out; a repeat call restarts the timer instead of stacking.
final class ZoomHUD {
  let view: NSView
  private let label: NSTextField
  private var hideWorkItem: DispatchWorkItem?

  init() {
    let container = NSView(frame: .zero)
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
    container.layer?.masksToBounds = true
    container.alphaValue = 0
    container.translatesAutoresizingMaskIntoConstraints = false

    let dot = NSView(frame: .zero)
    dot.wantsLayer = true
    dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
    dot.layer?.cornerRadius = 3
    dot.translatesAutoresizingMaskIntoConstraints = false

    let text = NSTextField(labelWithString: "")
    text.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    text.textColor = .white
    text.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(dot)
    container.addSubview(text)

    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 6),
      dot.heightAnchor.constraint(equalToConstant: 6),
      dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
      dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),

      text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
      text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
      text.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])

    view = container
    label = text
  }

  /// Adds the HUD centred near the top of `parent`, once.
  func install(in parent: NSView) {
    guard view.superview !== parent else { return }
    view.removeFromSuperview()
    parent.addSubview(view)
    NSLayoutConstraint.activate([
      view.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
      view.topAnchor.constraint(equalTo: parent.topAnchor, constant: 24),
    ])
  }

  /// Shows (or updates) the pill with `text`, restarting the auto-hide timer.
  func show(text: String) {
    label.stringValue = text
    view.layoutSubtreeIfNeeded()
    view.layer?.cornerRadius = view.bounds.height / 2
    hideWorkItem?.cancel()

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      view.animator().alphaValue = 1
    }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        self.view.animator().alphaValue = 0
      }
    }
    hideWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
  }
}
