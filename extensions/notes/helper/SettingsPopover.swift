import AppKit

/// Persistent note choices, kept apart from the keyboard command palette.
final class SettingsPopover: NSObject {
  private let settings: SettingsController
  let popover = NSPopover()
  let contentView = NSView()
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
      label.textColor = .secondaryLabelColor
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


/// Keep AppKit's selection, keyboard handling and accessibility, while painting
/// each row as one continuous glass pill instead of standard segmented chrome.
final class SettingsPillControl: NSSegmentedControl {
  var pillBounds: NSRect { bounds.insetBy(dx: 2 * Markdown.zoom, dy: 2 * Markdown.zoom) }

  func segment(at point: NSPoint) -> Int? {
    let row = pillBounds
    guard segmentCount > 0, row.width > 0, row.height > 0,
      NSBezierPath(roundedRect: row, xRadius: row.height / 2, yRadius: row.height / 2).contains(point)
    else { return nil }
    return min(segmentCount - 1, Int((point.x - row.minX) / (row.width / CGFloat(segmentCount))))
  }

  private var pressedSegment: Int?

  // Native bezel padding differs from the painted pill, so track the
  // completed click against our geometry without committing on press.
  override func mouseDown(with event: NSEvent) {
    pressedSegment = nil
    guard isEnabled, let index = segment(at: convert(event.locationInWindow, from: nil)),
      isEnabled(forSegment: index) else { return }
    window?.makeFirstResponder(self)
    pressedSegment = index
  }

  override func mouseDragged(with event: NSEvent) {
    // Selection remains unchanged while tracking; releasing elsewhere cancels.
  }

  override func mouseUp(with event: NSEvent) {
    let pressed = pressedSegment
    pressedSegment = nil
    guard isEnabled, let index = pressed, isEnabled(forSegment: index),
      segment(at: convert(event.locationInWindow, from: nil)) == index else { return }
    selectedSegment = index
    needsDisplay = true
    sendAction(action, to: target)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard segmentCount > 0 else { return }
    let scale = Markdown.zoom
    let row = pillBounds
    let shape = NSBezierPath(roundedRect: row, xRadius: row.height / 2, yRadius: row.height / 2)
    let slotWidth = row.width / CGFloat(segmentCount)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.30, green: 0.83, blue: 0.56, alpha: 0.18)
    shadow.shadowBlurRadius = 4 * scale
    shadow.shadowOffset = .zero
    shadow.set()
    NSColor(white: 0.075, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // One shared clipping path rounds only the ends of the entire row.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    for index in 0..<segmentCount {
      let selected = isSelected(forSegment: index)
      let rect = NSRect(x: row.minX + CGFloat(index) * slotWidth,
                        y: row.minY, width: slotWidth, height: row.height)
      let top = selected
        ? NSColor(srgbRed: 0.15, green: 0.37, blue: 0.26, alpha: 1)
        : NSColor(srgbRed: 0.12, green: 0.18, blue: 0.15, alpha: 1)
      NSGradient(starting: NSColor(white: 0.075, alpha: 1), ending: top)?.draw(in: rect, angle: 90)
      let text = label(forSegment: index) ?? ""
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12 * scale, weight: selected ? .semibold : .medium),
        .foregroundColor: selected ? NSColor.white : NSColor(white: 0.78, alpha: 1),
      ]
      let size = (text as NSString).size(withAttributes: attributes)
      (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                             withAttributes: attributes)
      if index > 0 {
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: rect.minX, y: row.minY))
        divider.line(to: NSPoint(x: rect.minX, y: row.maxY))
        NSColor(srgbRed: 0.47, green: 0.80, blue: 0.62, alpha: 0.25).setStroke()
        divider.lineWidth = scale
        divider.stroke()
      }
    }
    NSGraphicsContext.restoreGraphicsState()
    let focused = window?.firstResponder === self
    NSColor(srgbRed: 0.47, green: 0.80, blue: 0.62, alpha: focused ? 0.95 : 0.45).setStroke()
    shape.lineWidth = focused ? 1.5 * scale : scale
    shape.stroke()
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
