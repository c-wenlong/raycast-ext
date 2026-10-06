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
  private let divider = NSBox()
  private let scroll = NSScrollView()
  private var scale: CGFloat = 1
  /// The rows. Replacing them while the palette is open (a setting
  /// changed over the socket) redraws the list in place.
  var actions: [PaletteAction] {
    didSet { if panel.isVisible { refresh() } }
  }
  private var visible: [PaletteAction] = []
  private let run: (String) -> Void
  private static let width: CGFloat = 420
  /// From the panel's top edge to the list's: search field and divider.
  private static let listTop: CGFloat = 64
  /// The divider's bottom edge sits this far above the list's top.
  private static let dividerGap: CGFloat = 2
  private static let maxHeight: CGFloat = 480
  private weak var parent: NSWindow?

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

    let root = PaletteRootView(frame: panel.contentView!.bounds)
    root.material = .popover
    root.blendingMode = .behindWindow
    root.state = .active
    root.autoresizingMask = [.width, .height]
    panel.contentView = root
    // Key badges hold a layer colour fixed for one appearance: rebuild the
    // rows when the palette's appearance changes, however it changed.
    root.onAppearanceChange = { [weak self] in
      guard let self, self.panel.isVisible else { return }
      self.refresh()
    }

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

    divider.frame = NSRect(x: 0, y: panel.frame.height - 62, width: ActionPalette.width, height: 1)
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

    // The list fills the panel below the divider; `fit` sizes the panel
    // so its bottom margin matches the top one.
    scroll.frame = NSRect(x: 0, y: 0, width: ActionPalette.width, height: panel.frame.height - Self.listTop)
    scroll.autoresizingMask = [.width, .height]
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    root.addSubview(scroll)
  }

  var isVisible: Bool { panel.isVisible }

  func show(over parent: NSWindow) {
    search.stringValue = ""
    self.parent = parent
    applyZoom()
    filter()
    // Centred on the window for the full list; filtering then keeps the
    // top edge still and moves only the bottom.
    var frame = panel.frame
    frame.origin.y = parent.frame.midY - frame.height / 2
    panel.setFrame(frame, display: false)
    parent.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(search)
  }

  /// Applies the note's zoom without clearing the query or selected action.
  func updateZoom() {
    applyZoom()
    refresh()
  }

  private func applyZoom() {
    scale = Markdown.zoom
    search.font = NSFont.systemFont(ofSize: 17 * scale)
    // The field editor is already active when zoom changes over the socket.
    (search.currentEditor() as? NSTextView)?.font = search.font
    table.rowHeight = 40 * scale
    table.intercellSpacing = NSSize(width: 0, height: 2 * scale)
    var frame = panel.frame
    frame.size.width = min(Self.width * scale, max(1, (parent?.frame.width ?? Self.width * scale) - 40))
    if let parent { frame.origin.x = parent.frame.midX - frame.width / 2 }
    panel.setFrame(frame, display: false)
    layoutContents()
  }

  private func layoutContents() {
    guard let root = panel.contentView else { return }
    let width = root.bounds.width
    let height = root.bounds.height
    search.frame = NSRect(x: 16 * scale, y: height - 52 * scale,
      width: max(0, width - 32 * scale), height: 34 * scale)
    divider.frame = NSRect(x: 0, y: height - 62 * scale, width: width, height: 1)
    scroll.frame = NSRect(x: 0, y: 0, width: width, height: max(0, height - Self.listTop * scale))
    table.tableColumns.first?.width = max(0, width - 16 * scale)
  }

  /// Zoom metrics exposed for the headless view regression tests.
  var zoomMetrics: (fontSize: CGFloat, rowHeight: CGFloat, width: CGFloat) {
    (search.font?.pointSize ?? 0, table.rowHeight, panel.frame.width)
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
    fit()
    if !visible.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      table.scrollRowToVisible(0)
    }
  }

  /// Rebuilds the rows for the current query, keeping the selected
  /// action selected (by command) when it is still listed.
  private func refresh() {
    let selected = table.selectedRow >= 0 && table.selectedRow < visible.count ? visible[table.selectedRow].command : nil
    filter()
    if let selected, let row = visible.firstIndex(where: { $0.command == selected }) {
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      table.scrollRowToVisible(row)
    }
  }

  /// The rows as listed now, for the view tests.
  var shownRows: [PaletteAction] { visible }

  /// The background of the first key badge on `row`, for the view tests.
  func badgeColor(atRow row: Int) -> CGColor? {
    guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true),
      let keys = cell.subviews.first(where: { $0 is NSStackView }) as? NSStackView
    else { return nil }
    return keys.arrangedSubviews.first(where: { $0 is NSTextField })?.layer?.backgroundColor
  }

  /// The panel height that shows every row with the gap under the last
  /// row equal to the gap between the divider and the first one (the
  /// table's own top inset plus `dividerGap`), whatever the row count;
  /// capped to fit the parent window, past which the list scrolls.
  var fittedHeight: CGFloat {
    let rows = table.numberOfRows
    let topInset = rows > 0 ? table.rect(ofRow: 0).minY : 0
    let rowsBottom = rows > 0 ? table.rect(ofRow: rows - 1).maxY : 0
    let natural = Self.listTop * scale + rowsBottom + Self.dividerGap * scale + topInset
    return max(1, min(natural, (parent?.frame.height ?? .greatestFiniteMagnitude) - 40, Self.maxHeight * scale))
  }

  /// Resizes the panel to `fittedHeight`, keeping its top edge in place.
  private func fit() {
    var frame = panel.frame
    let height = fittedHeight
    guard abs(frame.height - height) > 0.5 else { layoutContents(); return }
    frame.origin.y = frame.maxY - height
    frame.size.height = height
    panel.setFrame(frame, display: panel.isVisible)
    layoutContents()
  }

  /// The gaps above the first row (from the divider) and below the last
  /// row (to the panel's bottom edge), in points; for the view tests.
  var listGaps: (top: CGFloat, bottom: CGFloat)? {
    let rows = table.numberOfRows
    guard rows > 0, let content = panel.contentView else { return nil }
    let first = content.convert(table.rect(ofRow: 0), from: table)
    let last = content.convert(table.rect(ofRow: rows - 1), from: table)
    let dividerBottom = content.bounds.height - Self.listTop * scale + Self.dividerGap * scale
    // The content view is not flipped: larger y is higher.
    return (dividerBottom - first.maxY, last.minY)
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
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15 * scale, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    icon.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: action.title)
    title.font = NSFont.systemFont(ofSize: 15 * scale)
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    title.translatesAutoresizingMaskIntoConstraints = false

    let keys = NSStackView()
    keys.orientation = .horizontal
    keys.spacing = 4 * scale
    keys.translatesAutoresizingMaskIntoConstraints = false
    for key in action.keys {
      let badge = NSTextField(labelWithString: String(key))
      badge.font = NSFont.systemFont(ofSize: 12 * scale, weight: .medium)
      badge.textColor = .secondaryLabelColor
      badge.alignment = .center
      badge.wantsLayer = true
      // A layer colour is fixed when set: resolve it in the palette's
      // own appearance (forced light or dark, or the system's).
      tableView.effectiveAppearance.performAsCurrentDrawingAppearance {
        badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
      }
      badge.layer?.cornerRadius = 5 * scale
      badge.translatesAutoresizingMaskIntoConstraints = false
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22 * scale).isActive = true
      badge.heightAnchor.constraint(equalToConstant: 22 * scale).isActive = true
      keys.addArrangedSubview(badge)
    }

    if action.checked {
      let check = NSImageView()
      check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current")
      check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13 * scale, weight: .semibold)
      check.contentTintColor = Markdown.accent
      check.setAccessibilityLabel("Current")
      keys.addArrangedSubview(check)
    }

    cell.addSubview(icon)
    cell.addSubview(title)
    cell.addSubview(keys)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10 * scale),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 22 * scale),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10 * scale),
      title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      title.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -10 * scale),
      keys.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10 * scale),
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

/// The palette's background, which reports appearance changes.
final class PaletteRootView: NSVisualEffectView {
  var onAppearanceChange: (() -> Void)?

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearanceChange?()
  }
}
