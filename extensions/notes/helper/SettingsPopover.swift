import AppKit

/// Persistent note choices, kept apart from the keyboard command palette.
final class SettingsPopover: NSObject {
  private let settings: SettingsController
  let popover = NSPopover()
  let contentView = NSView()
  let appearanceControl = NSSegmentedControl(
    labels: NoteAppearance.allCases.map { $0.title }, trackingMode: .selectOne,
    target: nil, action: nil)
  let fontControl = NSSegmentedControl(
    labels: NoteFont.allCases.map { $0.title }, trackingMode: .selectOne,
    target: nil, action: nil)
  let attachmentControl = NSSegmentedControl(
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
