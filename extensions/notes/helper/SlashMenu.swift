import AppKit
import Foundation

// MARK: - Slash menu
//
// The menu that "/" opens under the caret: every block format the note
// knows, filtered by what is typed after the slash. NoteTextView owns
// one and drives it (filter, move, pick); it is a subview of the text
// view, so it scrolls with the note.

final class SlashMenu: NSView, NSTableViewDataSource, NSTableViewDelegate {
  struct Entry {
    let id: String
    let title: String
    /// The markdown the entry stands for, shown at the right.
    let hint: String
    let symbol: String
    let format: NoteTextView.Format
    /// Extra words the entry answers to ("todo" for the task list).
    let aliases: [String]
  }

  static let entries: [Entry] = [
    Entry(id: "text", title: "Text", hint: "", symbol: "textformat", format: .plain, aliases: ["plain", "paragraph"]),
    Entry(id: "h1", title: "Heading 1", hint: "#", symbol: "textformat.size.larger", format: .prefix(.heading(1)), aliases: ["h1", "title"]),
    Entry(id: "h2", title: "Heading 2", hint: "##", symbol: "textformat.size", format: .prefix(.heading(2)), aliases: ["h2"]),
    Entry(id: "h3", title: "Heading 3", hint: "###", symbol: "textformat.size.smaller", format: .prefix(.heading(3)), aliases: ["h3"]),
    Entry(id: "h4", title: "Heading 4", hint: "####", symbol: "textformat.size.smaller", format: .prefix(.heading(4)), aliases: ["h4"]),
    Entry(id: "bullet", title: "Bulleted list", hint: "-", symbol: "list.bullet", format: .prefix(.bullet), aliases: ["ul", "unordered"]),
    Entry(id: "ordered", title: "Numbered list", hint: "1.", symbol: "list.number", format: .prefix(.ordered), aliases: ["ol", "ordered"]),
    Entry(id: "task", title: "To-do list", hint: "[]", symbol: "checklist", format: .prefix(.task), aliases: ["todo", "checkbox", "task", "check"]),
    Entry(id: "quote", title: "Quote", hint: ">", symbol: "text.quote", format: .prefix(.quote), aliases: ["blockquote"]),
    Entry(id: "callout", title: "Callout", hint: ">>", symbol: "rectangle.on.rectangle", format: .prefix(.callout), aliases: ["box", "note", "highlight"]),
    Entry(id: "code-block", title: "Code block", hint: "```", symbol: "curlybraces", format: .codeBlock, aliases: ["code", "fence"]),
  ]

  /// The entries matching `query`: every word of the query is a prefix
  /// of a word in the title or of an alias. An empty query matches all.
  static func matches(_ query: String) -> [Entry] {
    let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
    guard !words.isEmpty else { return entries }
    return entries.filter { entry in
      let haystack = entry.title.lowercased().split(separator: " ").map(String.init) + entry.aliases
      return words.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
    }
  }

  static let width: CGFloat = 250
  static let rowHeight: CGFloat = 30
  static let maxRows = 8
  private static let padding: CGFloat = 6
  private static let headerHeight: CGFloat = 24

  private let table = NSTableView()
  private let scroll = NSScrollView()
  private let header = NSTextField(labelWithString: "Blocks")
  private var visible: [Entry] = entries
  private let onPick: (Entry) -> Void

  init(pick: @escaping (Entry) -> Void) {
    self.onPick = pick
    super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
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
    column.width = Self.width - Self.padding * 2
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
    setAccessibilityLabel("Block formats")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var acceptsFirstResponder: Bool { false }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {}
  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

  var selected: Entry? {
    let row = table.selectedRow
    return row >= 0 && row < visible.count ? visible[row] : nil
  }

  /// Shows the entries matching `query`, first one selected. False when
  /// nothing matches (the caller closes the menu).
  @discardableResult
  func filter(_ query: String) -> Bool {
    visible = Self.matches(query)
    table.reloadData()
    guard !visible.isEmpty else { return false }
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    table.scrollRowToVisible(0)
    needsLayout = true
    return true
  }

  func move(by delta: Int) {
    guard !visible.isEmpty else { return }
    let next = (max(table.selectedRow, 0) + delta + visible.count) % visible.count
    table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    table.scrollRowToVisible(next)
  }

  func pick() {
    guard let entry = selected else { return }
    onPick(entry)
  }

  @objc private func rowClicked() {
    guard table.clickedRow >= 0, table.clickedRow < visible.count else { return }
    onPick(visible[table.clickedRow])
  }

  /// The menu's size for the current entries: up to `maxRows` rows.
  var menuSize: NSSize {
    let rows = CGFloat(min(visible.count, Self.maxRows))
    return NSSize(width: Self.width, height: Self.padding * 2 + Self.headerHeight + rows * Self.rowHeight)
  }

  /// Puts the menu under `anchor` (the caret's line, in the superview's
  /// coordinates), or above it when there is no room below inside
  /// `visible`; never past the container's right edge.
  func place(below anchor: NSRect, within visible: NSRect, container: NSTextContainer) {
    var size = menuSize
    let below = visible.maxY - 8 - (anchor.maxY + 4)
    let above = (anchor.minY - 4) - (visible.minY + 8)
    var origin = NSPoint(x: anchor.minX - 4, y: anchor.maxY + 4)
    if size.height > below, above > below {
      // No room under the caret: hang the menu above it instead.
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

  func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let entry = visible[row]
    let cell = NSView()

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    icon.contentTintColor = .secondaryLabelColor
    icon.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: entry.title)
    title.font = NSFont.systemFont(ofSize: 13)
    title.translatesAutoresizingMaskIntoConstraints = false

    let hint = NSTextField(labelWithString: entry.hint)
    hint.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    hint.textColor = .tertiaryLabelColor
    hint.translatesAutoresizingMaskIntoConstraints = false

    cell.addSubview(icon)
    cell.addSubview(title)
    cell.addSubview(hint)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      hint.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
      hint.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = SlashRowView()
    view.isEmphasized = true
    return view
  }
}

/// A row with a rounded highlight, so the selection reads as a menu item.
final class SlashRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard isSelected else { return }
    ChromeColors.hover.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
  }
}
