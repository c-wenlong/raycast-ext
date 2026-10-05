import AppKit
import Foundation

// MARK: - Inline picker
//
// The small menu that opens under the caret while typing: the "/" block
// menu, the ":" emoji picker and the "[[" note picker. It shows the items its source returns for
// the query, keeps one selected, and hands the pick back. NoteTextView owns
// each picker and drives it (filter, move, pick, place); it is a subview of
// the text view, so it scrolls with the note. What a pick does to the text
// is up to the owner.

class InlinePicker: NSView, NSTableViewDataSource, NSTableViewDelegate {
  struct Item {
    let id: String
    let title: String
    /// Shown at the right in a small monospaced font ("##" for Heading 2).
    var hint = ""
    /// An SF Symbol drawn at the left, or...
    var symbol: String? = nil
    /// ...a character drawn there instead (an emoji).
    var glyph: String? = nil
  }

  static let rowHeight: CGFloat = 30
  static let maxRows = 8
  private static let padding: CGFloat = 6
  private static let headerHeight: CGFloat = 24

  let width: CGFloat
  private let table = NSTableView()
  private let scroll = NSScrollView()
  private let header: NSTextField
  private let source: (String) -> [Item]
  private let onPick: (Item) -> Void
  private(set) var items: [Item] = []

  /// `title` heads the list; `source` gives the items for a query, best
  /// first; `pick` runs on Return, Tab or a click.
  init(title: String, accessibilityLabel: String, width: CGFloat = 250,
    source: @escaping (String) -> [Item], pick: @escaping (Item) -> Void)
  {
    self.width = width
    self.source = source
    self.onPick = pick
    self.header = NSTextField(labelWithString: title)
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    wantsLayer = true
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    self.shadow = shadow

    header.font = NSFont.systemFont(ofSize: 11, weight: .medium)
    header.textColor = .tertiaryLabelColor
    addSubview(header)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
    column.width = width - Self.padding * 2
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = Self.rowHeight
    table.intercellSpacing = .zero
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.style = .plain
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(rowClicked)
    table.refusesFirstResponder = true
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = table
    addSubview(scroll)
    setAccessibilityRole(.menu)
    setAccessibilityLabel(accessibilityLabel)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var acceptsFirstResponder: Bool { false }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {}
  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

  var selectedItem: Item? {
    let row = table.selectedRow
    return row >= 0 && row < items.count ? items[row] : nil
  }

  /// Shows the items for `query`, first one selected. False when nothing
  /// matches (the caller closes the picker).
  @discardableResult
  func filter(_ query: String) -> Bool {
    items = source(query)
    table.reloadData()
    guard !items.isEmpty else { return false }
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    table.scrollRowToVisible(0)
    needsLayout = true
    return true
  }

  func move(by delta: Int) {
    guard !items.isEmpty else { return }
    let next = (max(table.selectedRow, 0) + delta + items.count) % items.count
    table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    table.scrollRowToVisible(next)
  }

  func pick() {
    guard let item = selectedItem else { return }
    onPick(item)
  }

  @objc private func rowClicked() {
    guard table.clickedRow >= 0, table.clickedRow < items.count else { return }
    onPick(items[table.clickedRow])
  }

  /// The picker's size for the current items: up to `maxRows` rows.
  var menuSize: NSSize {
    let rows = CGFloat(min(items.count, Self.maxRows))
    return NSSize(width: width, height: Self.padding * 2 + Self.headerHeight + rows * Self.rowHeight)
  }

  /// Puts the picker under `anchor` (the caret's line, in the superview's
  /// coordinates), or above it when there is no room below inside
  /// `visible`; never past the container's right edge.
  func place(below anchor: NSRect, within visible: NSRect, container: NSTextContainer) {
    var size = menuSize
    let below = visible.maxY - 8 - (anchor.maxY + 4)
    let above = (anchor.minY - 4) - (visible.minY + 8)
    var origin = NSPoint(x: anchor.minX - 4, y: anchor.maxY + 4)
    if size.height > below, above > below {
      // No room under the caret: hang the picker above it instead.
      origin.y = anchor.minY - 4 - size.height
    }
    // A short window shows fewer rows (the list scrolls), never less than two.
    let room = max(below, above)
    if size.height > room {
      let rows = max(2, floor((room - Self.padding * 2 - Self.headerHeight) / Self.rowHeight))
      size.height = Self.padding * 2 + Self.headerHeight + rows * Self.rowHeight
      origin.y = above > below ? anchor.minY - 4 - size.height : anchor.maxY + 4
    }
    let rightEdge = (superview?.bounds.width ?? visible.maxX) - 8
    origin.x = max(8, min(origin.x, rightEdge - size.width))
    frame = NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    header.frame = NSRect(
      x: Self.padding + 8, y: Self.padding + 4, width: bounds.width - Self.padding * 2 - 16, height: Self.headerHeight - 8)
    scroll.frame = NSRect(
      x: Self.padding, y: Self.padding + Self.headerHeight,
      width: bounds.width - Self.padding * 2, height: bounds.height - Self.padding * 2 - Self.headerHeight)
  }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let radius: CGFloat = 10
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    NSColor.windowBackgroundColor.setFill()
    path.fill()
    ChromeColors.pill.setFill()
    path.fill()
    ChromeColors.border.setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  // NSTableViewDataSource / Delegate

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let item = items[row]
    let cell = NSView()

    let icon: NSView
    if let glyph = item.glyph {
      let label = NSTextField(labelWithString: glyph)
      label.font = NSFont.systemFont(ofSize: 15)
      label.alignment = .center
      icon = label
    } else {
      let image = NSImageView()
      image.image = item.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
      image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
      image.contentTintColor = .secondaryLabelColor
      icon = image
    }
    icon.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: item.title)
    title.font = NSFont.systemFont(ofSize: 13)
    title.lineBreakMode = .byTruncatingTail
    title.translatesAutoresizingMaskIntoConstraints = false
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let hint = NSTextField(labelWithString: item.hint)
    hint.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    hint.textColor = .tertiaryLabelColor
    hint.translatesAutoresizingMaskIntoConstraints = false
    hint.setContentCompressionResistancePriority(.required, for: .horizontal)

    cell.addSubview(icon)
    cell.addSubview(title)
    cell.addSubview(hint)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      title.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -8),
      hint.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
      hint.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = PickerRowView()
    view.isEmphasized = true
    return view
  }
}

/// A row with a rounded highlight, so the selection reads as a menu item.
final class PickerRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard isSelected else { return }
    ChromeColors.hover.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
  }
}
