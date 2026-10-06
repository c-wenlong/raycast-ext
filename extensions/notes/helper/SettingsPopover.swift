import AppKit

/// Persistent note choices, kept apart from the keyboard command palette.
final class SettingsPopover: NSObject {
  private let settings: SettingsController
  let popover = NSPopover()
  let contentView: NSView = SettingsGlassView()
  let appearanceControl = SettingsPillControl(
    labels: NoteAppearance.allCases.map { $0.title }, trackingMode: .selectOne,
    target: nil, action: nil)
  let fontControl = SettingsPillControl(
    labels: NoteFont.allCases.map { $0.title }, trackingMode: .selectOne,
    target: nil, action: nil)
  let attachmentControl = SettingsPillControl(
    labels: NoteAttachment.allCases.map { $0 == .floating ? "Floating" : $0.title }, trackingMode: .selectOne,
    target: nil, action: nil)
  private let labels = ["Appearance", "Font", "Attach"].map {
    NSTextField(labelWithString: $0)
  }
  var run: (String) -> Void = { _ in }

  init(settings: SettingsController) {
    self.settings = settings
    super.init()
    let controller = NSViewController()
    controller.view = contentView
    popover.contentViewController = controller
    popover.behavior = .transient
    popover.animates = false
    let controls = [appearanceControl, fontControl, attachmentControl]
    for (label, control) in zip(labels, controls) {
      label.textColor = NSColor(srgbRed: 0.68, green: 0.80, blue: 0.73, alpha: 1)
      contentView.addSubview(label)
      control.segmentStyle = .rounded
      control.focusRingType = .none
      control.target = self
      control.action = #selector(choose(_:))
      control.setAccessibilityLabel(label.stringValue)
      contentView.addSubview(control)
    }
    appearanceControl.nextKeyView = fontControl
    fontControl.nextKeyView = attachmentControl
    attachmentControl.nextKeyView = appearanceControl
    refresh()
  }

  func toggle(relativeTo anchor: NSView) {
    if popover.isShown {
      close()
      return
    }
    guard anchor.window != nil else { return }
    refresh()
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
  }

  func close() { popover.close() }

  /// Also called for socket changes and zoom changes while the popover is open.
  func refresh() {
    appearanceControl.selectedSegment = NoteAppearance.allCases.firstIndex(of: settings.appearance) ?? 0
    fontControl.selectedSegment = NoteFont.allCases.firstIndex(of: Markdown.font) ?? 0
    attachmentControl.selectedSegment = NoteAttachment.allCases.firstIndex(of: settings.attachment) ?? 0
    let scale = Markdown.zoom
    let padding = 16 * scale
    let width = 300 * scale
    let rowHeight = 70 * scale
    let size = NSSize(width: width, height: padding * 2 + rowHeight * 3 - 10 * scale)
    contentView.setFrameSize(size)
    for (index, control) in [appearanceControl, fontControl, attachmentControl].enumerated() {
      let top = size.height - padding - CGFloat(index) * rowHeight
      let label = labels[index]
      label.font = .systemFont(ofSize: 11 * scale, weight: .semibold)
      label.frame = NSRect(x: padding, y: top - 16 * scale, width: width - padding * 2, height: 16 * scale)
      control.font = .systemFont(ofSize: 13 * scale)
      control.frame = NSRect(x: padding, y: top - 52 * scale, width: width - padding * 2, height: 30 * scale)
      for segment in 0..<control.segmentCount {
        control.setWidth((width - padding * 2 - 8 * scale) / 3, forSegment: segment)
      }
    }
    contentView.needsDisplay = true
    [appearanceControl, fontControl, attachmentControl].forEach { $0.needsDisplay = true }
    popover.contentSize = size
  }

  @objc private func choose(_ sender: NSSegmentedControl) {
    let index = sender.selectedSegment
    let command: String
    if sender === appearanceControl, NoteAppearance.allCases.indices.contains(index) {
      command = NoteAppearance.allCases[index].command
    } else if sender === fontControl, NoteFont.allCases.indices.contains(index) {
      command = NoteFont.allCases[index].command
    } else if sender === attachmentControl, NoteAttachment.allCases.indices.contains(index) {
      command = NoteAttachment.allCases[index].command
      // Attachment can reparent the anchor into a different window.
      close()
    } else {
      return
    }
    run(command)
    refresh()
  }
}


/// The same dark glass and soft green light used by the transient zoom pill.
private final class SettingsGlassView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor(white: 0.065, alpha: 1),
               ending: NSColor(srgbRed: 0.10, green: 0.23, blue: 0.17, alpha: 1))?
      .draw(in: bounds, angle: 90)
    let glow = NSColor(srgbRed: 0.30, green: 0.83, blue: 0.56, alpha: 0.14)
    NSGradient(starting: glow, ending: glow.withAlphaComponent(0))?
      .draw(fromCenter: NSPoint(x: bounds.minX, y: bounds.maxY), radius: 0,
            toCenter: NSPoint(x: bounds.minX, y: bounds.maxY), radius: bounds.width, options: [])
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.47, green: 0.80, blue: 0.62, alpha: 0.28).setStroke()
    shape.stroke()
  }
}

/// Keep AppKit's selection, keyboard handling and accessibility, while painting
/// the choices as individual glass pills instead of standard segmented chrome.
final class SettingsPillControl: NSSegmentedControl {
  override func draw(_ dirtyRect: NSRect) {
    guard segmentCount > 0 else { return }
    let scale = Markdown.zoom
    let slotWidth = bounds.width / CGFloat(segmentCount)
    for index in 0..<segmentCount {
      let selected = isSelected(forSegment: index)
      let rect = NSRect(x: CGFloat(index) * slotWidth + 2 * scale,
                        y: 2 * scale, width: slotWidth - 4 * scale,
                        height: bounds.height - 4 * scale)
      let shape = NSBezierPath(roundedRect: rect, xRadius: 9 * scale, yRadius: 9 * scale)
      NSGraphicsContext.saveGraphicsState()
      if selected {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.30, green: 0.83, blue: 0.56, alpha: 0.24)
        shadow.shadowBlurRadius = 5 * scale
        shadow.shadowOffset = .zero
        shadow.set()
      }
      NSColor(white: 0.075, alpha: 0.92).setFill()
      shape.fill()
      NSGraphicsContext.restoreGraphicsState()
      NSGraphicsContext.saveGraphicsState()
      shape.addClip()
      let top = selected
        ? NSColor(srgbRed: 0.15, green: 0.37, blue: 0.26, alpha: 1)
        : NSColor(srgbRed: 0.12, green: 0.18, blue: 0.15, alpha: 1)
      NSGradient(starting: NSColor(white: 0.075, alpha: 1), ending: top)?.draw(in: rect, angle: 90)
      NSGraphicsContext.restoreGraphicsState()
      NSColor(srgbRed: 0.47, green: 0.80, blue: 0.62, alpha: selected ? 0.65 : 0.16).setStroke()
      shape.lineWidth = scale
      shape.stroke()
      let text = label(forSegment: index) ?? ""
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12 * scale, weight: selected ? .semibold : .medium),
        .foregroundColor: selected ? NSColor.white : NSColor(white: 0.78, alpha: 1),
      ]
      let size = (text as NSString).size(withAttributes: attributes)
      (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                             withAttributes: attributes)
    }
    if window?.firstResponder === self {
      let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: 11 * scale, yRadius: 11 * scale)
      NSColor(srgbRed: 0.32, green: 0.82, blue: 0.59, alpha: 0.95).setStroke()
      focus.lineWidth = scale
      focus.stroke()
    }
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    needsDisplay = true
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    needsDisplay = true
    return accepted
  }
}
