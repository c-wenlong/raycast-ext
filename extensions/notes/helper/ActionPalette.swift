import AppKit
import Foundation

// MARK: - Action palette (⌘K)

struct PaletteAction {
  let title: String
  let keys: String
  let symbol: String
  let command: String
  /// More words the search matches besides the title.
  var keywords: String = ""
  /// A setting's current choice: a checkmark in place of the keys.
  var checked: Bool = false

  /// True when every word of `query` (already lowercased and trimmed)
  /// appears in the title or the keywords.
  func matches(_ query: String) -> Bool {
    let haystack = (title + " " + keywords).lowercased()
    return query.split(separator: " ").allSatisfy { haystack.contains($0) }
  }
}

/// Child panel that lets ⌘K close the palette while its search field is key.
final class PalettePanel: NSPanel {
  var onToggleShortcut: (() -> Void)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, event.charactersIgnoringModifiers == "k" {
      onToggleShortcut?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// Search field over a list of actions, shown as a sheet-like child panel.
/// Up/down move, return runs, escape or ⌘K closes, typing filters.
final class ActionPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  private let panel: PalettePanel
  private let search = NSSearchField()
  private let table = NSTableView()
  /// The rows; replaced while hidden when a setting's checkmark moves.
  var actions: [PaletteAction]
  private var visible: [PaletteAction] = []
  private let run: (String) -> Void
  private static let width: CGFloat = 420

  init(actions: [PaletteAction], run: @escaping (String) -> Void) {
    self.actions = actions
    self.run = run
    panel = PalettePanel(
      contentRect: NSRect(x: 0, y: 0, width: ActionPalette.width, height: 380),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.onToggleShortcut = { [weak self] in self?.hide() }

    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovable = false
    panel.isReleasedWhenClosed = false
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let root = NSVisualEffectView(frame: panel.contentView!.bounds)
    root.material = .popover
    root.blendingMode = .behindWindow
    root.state = .active
    root.autoresizingMask = [.width, .height]
    panel.contentView = root

    search.placeholderString = "Search for actions..."
    search.font = NSFont.systemFont(ofSize: 17)
    search.focusRingType = .none
    search.isBordered = false
    search.drawsBackground = false
    search.delegate = self
    search.frame = NSRect(x: 16, y: panel.frame.height - 52, width: ActionPalette.width - 32, height: 34)
    search.autoresizingMask = [.width, .minYMargin]
    if let cell = search.cell as? NSSearchFieldCell {
      cell.searchButtonCell = nil
      cell.cancelButtonCell = nil
    }
    root.addSubview(search)

    let divider = NSBox(frame: NSRect(x: 0, y: panel.frame.height - 62, width: ActionPalette.width, height: 1))
    divider.boxType = .separator
    divider.autoresizingMask = [.width, .minYMargin]
    root.addSubview(divider)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
    column.width = ActionPalette.width - 16
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 40
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.style = .inset
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(rowClicked)

    let scroll = NSScrollView(frame: NSRect(x: 0, y: 8, width: ActionPalette.width, height: panel.frame.height - 72))
    scroll.autoresizingMask = [.width, .height]
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    root.addSubview(scroll)
  }

  var isVisible: Bool { panel.isVisible }

  func show(over parent: NSWindow) {
    search.stringValue = ""
    filter()
    let width = min(ActionPalette.width, parent.frame.width - 40)
    let height = min(CGFloat(visible.count) * (table.rowHeight + 2) + 80, parent.frame.height - 40, 480)
    let origin = NSPoint(
      x: parent.frame.midX - width / 2,
      y: parent.frame.midY - height / 2)
    panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    parent.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(search)
  }

  func hide() {
    guard panel.isVisible else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  private func filter() {
    let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    visible = query.isEmpty ? actions : actions.filter { $0.matches(query) }
    table.reloadData()
    if !visible.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      table.scrollRowToVisible(0)
    }
  }

  private func runSelected() {
    let row = table.selectedRow
    guard row >= 0, row < visible.count else { return }
    let command = visible[row].command
    hide()
    run(command)
  }

  @objc private func rowClicked() {
    runSelected()
  }

  private func moveSelection(by delta: Int) {
    guard !visible.isEmpty else { return }
    let next = (max(table.selectedRow, 0) + delta + visible.count) % visible.count
    table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    table.scrollRowToVisible(next)
  }

  // NSSearchFieldDelegate

  func controlTextDidChange(_ notification: Notification) {
    filter()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveDown(_:)):
      moveSelection(by: 1)
    case #selector(NSResponder.moveUp(_:)):
      moveSelection(by: -1)
    case #selector(NSResponder.insertNewline(_:)):
      runSelected()
    case #selector(NSResponder.cancelOperation(_:)):
      hide()
    default:
      return false
    }
    return true
  }

  // NSTableViewDataSource / Delegate

  func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let action = visible[row]
    let cell = NSView()

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    icon.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: action.title)
    title.font = NSFont.systemFont(ofSize: 15)
    title.translatesAutoresizingMaskIntoConstraints = false

    let keys = NSStackView()
    keys.orientation = .horizontal
    keys.spacing = 4
    keys.translatesAutoresizingMaskIntoConstraints = false
    for key in action.keys {
      let badge = NSTextField(labelWithString: String(key))
      badge.font = NSFont.systemFont(ofSize: 12, weight: .medium)
      badge.textColor = .secondaryLabelColor
      badge.alignment = .center
      badge.wantsLayer = true
      // A layer colour is fixed when set: resolve it in the palette's
      // own appearance (forced light or dark, or the system's).
      tableView.effectiveAppearance.performAsCurrentDrawingAppearance {
        badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
      }
      badge.layer?.cornerRadius = 5
      badge.translatesAutoresizingMaskIntoConstraints = false
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
      badge.heightAnchor.constraint(equalToConstant: 22).isActive = true
      keys.addArrangedSubview(badge)
    }

    if action.checked {
      let check = NSImageView()
      check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current")
      check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
      check.contentTintColor = Markdown.accent
      check.setAccessibilityLabel("Current")
      keys.addArrangedSubview(check)
    }

    cell.addSubview(icon)
    cell.addSubview(title)
    cell.addSubview(keys)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 22),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
      title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      keys.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
      keys.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = NSTableRowView()
    view.isEmphasized = true
    return view
  }
}
