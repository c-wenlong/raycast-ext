// notes-panel: a floating, always-on-top markdown editor over the notes
// folder, in the spirit of the Raycast Notes window.
//
//   notes-panel [toggle|show|hide|new|open <path>] [--dir <folder>]
//
// The first invocation becomes a small server on a unix socket and shows
// the panel; later invocations just forward their command to it and exit.
// Built with: swiftc -O -swift-version 5 -o assets/notes-panel helper/main.swift

import AppKit
import Foundation

// MARK: - Arguments

let diskFiles = FileManager.default
var notesDir = NSString(string: "~/.raycast/notes").expandingTildeInPath
var arguments = Array(CommandLine.arguments.dropFirst())
if let flag = arguments.firstIndex(of: "--dir"), flag + 1 < arguments.count {
  notesDir = NSString(string: arguments[flag + 1]).expandingTildeInPath
  arguments.removeSubrange(flag...(flag + 1))
}
let requestedCommand = arguments.isEmpty ? "toggle" : arguments.joined(separator: " ")

let supportDir = NSString(string: "~/Library/Application Support/notes-panel")
  .expandingTildeInPath
let socketPath = supportDir + "/notes-panel.sock"

// MARK: - Unix socket plumbing

func withSocketAddress(
  _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
) -> Int32 {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8CString)
  withUnsafeMutablePointer(to: &address.sun_path) { field in
    field.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
      for (offset, byte) in bytes.prefix(103).enumerated() {
        destination[offset] = byte
      }
    }
  }
  let length = socklen_t(MemoryLayout<sockaddr_un>.size)
  return withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
  }
}

/// Forwards a command (and the notes folder) to a running instance.
/// Returns the connect() errno when nobody is listening.
func forwardToRunningInstance(_ line: String) -> Int32? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return errno }
  defer { close(fd) }
  guard withSocketAddress(socketPath, { connect(fd, $0, $1) }) == 0 else {
    return errno
  }
  let payload = Array((line + "\u{0}" + notesDir).utf8)
  _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
  var reply = [UInt8](repeating: 0, count: 16)
  _ = reply.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 16, 0) }
  return nil
}

final class CommandServer {
  private let fd: Int32

  /// `staleSocket` is true when connect() got ECONNREFUSED: a leftover
  /// file from a dead instance that has to be removed before binding.
  /// bind() failing with EADDRINUSE means another launch got there first.
  init?(staleSocket: Bool) {
    try? diskFiles.createDirectory(
      atPath: supportDir, withIntermediateDirectories: true)
    if staleSocket { unlink(socketPath) }
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard withSocketAddress(socketPath, { bind(fd, $0, $1) }) == 0,
      listen(fd, 8) == 0
    else {
      close(fd)
      return nil
    }
  }

  func run(_ handler: @escaping (String) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async { [fd] in
      while true {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { continue }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes {
          recv(client, $0.baseAddress, 4096, 0)
        }
        let line =
          count > 0
          ? String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          : ""
        let parts = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        DispatchQueue.main.async {
          if parts.count == 2, !parts[1].isEmpty { notesDir = parts[1] }
          handler(parts.first ?? "")
        }
        _ = "ok\n".withCString { send(client, $0, 3, 0) }
        close(client)
      }
    }
  }
}

// MARK: - Notes on disk

struct Note {
  let path: String
  let modified: Date
  var filename: String { (path as NSString).lastPathComponent }
}

let generatedNamePattern = try! NSRegularExpression(
  pattern: #"^(\d{4}-\d{2}-\d{2} \d{4}) - (.+)\.md$"#)
let dailyNamePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}\.md$"#)
let headingPattern = try! NSRegularExpression(pattern: #"^#\s+(.+?)\s*$"#, options: .anchorsMatchLines)
let taskPattern = try! NSRegularExpression(pattern: #"^(\s*[-*+]\s+)\[([ xX])\]"#)

func fullRange(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

func listNotes() -> [Note] {
  try? diskFiles.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
  let names = (try? diskFiles.contentsOfDirectory(atPath: notesDir)) ?? []
  return names
    .filter { $0.lowercased().hasSuffix(".md") && !$0.hasPrefix(".") }
    .compactMap { name -> Note? in
      let path = (notesDir as NSString).appendingPathComponent(name)
      guard let attributes = try? diskFiles.attributesOfItem(atPath: path),
        (attributes[.type] as? FileAttributeType) == .typeRegular
      else { return nil }
      let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
      return Note(path: path, modified: modified)
    }
    .sorted { $0.modified > $1.modified }
}

/// Mirrors slugify() in src/lib/notes.ts so both editors name files alike.
func slugify(_ title: String) -> String {
  let folded = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
  let kept = folded.unicodeScalars.filter {
    ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == " " || $0 == "-"
  }
  let words = String(String.UnicodeScalarView(kept)).split(whereSeparator: { $0 == " " || $0 == "-" })
  let slug = words.joined(separator: "-")
  return slug.isEmpty ? "untitled" : slug
}

func humanize(_ slug: String) -> String {
  slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
    .joined(separator: " ")
}

func title(of text: String, filename: String) -> String {
  if let match = headingPattern.firstMatch(in: text, range: fullRange(text)) {
    return (text as NSString).substring(with: match.range(at: 1))
  }
  let base = (filename as NSString).deletingPathExtension
  if let match = generatedNamePattern.firstMatch(in: filename, range: fullRange(filename)) {
    return humanize((filename as NSString).substring(with: match.range(at: 2)))
  }
  return humanize(base)
}

func timestampPrefix(_ date: Date = Date()) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd HHmm"
  return formatter.string(from: date)
}

/// First free path for `filename` in `directory`, adding -2, -3, ...
func uniquePath(for filename: String, in directory: String = notesDir) -> String {
  let base = (filename as NSString).deletingPathExtension
  var attempt = 1
  while true {
    let candidate = attempt == 1 ? filename : "\(base)-\(attempt).md"
    let path = (directory as NSString).appendingPathComponent(candidate)
    if !diskFiles.fileExists(atPath: path) { return path }
    attempt += 1
  }
}


// MARK: - Markdown styling
//
// The text stays raw markdown so files never change shape; only display
// attributes are layered on. Markers are dimmed, headings enlarged, links
// clickable, task boxes clickable (notes-task:// links) and done tasks
// struck through.

enum Markdown {
  static let baseFont = NSFont.systemFont(ofSize: 15)
  static let monoFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
  static let headingFonts = [
    NSFont.systemFont(ofSize: 24, weight: .bold),
    NSFont.systemFont(ofSize: 20, weight: .bold),
    NSFont.systemFont(ofSize: 17, weight: .semibold),
  ]
  static let taskScheme = "notes-task"

  static let heading = try! NSRegularExpression(pattern: #"^(#{1,3})[ \t]+(.*)$"#, options: .anchorsMatchLines)
  static let task = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+(\[[ xX]\])(?:[ \t]+(.*))?$"#, options: .anchorsMatchLines)
  static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+\.)[ \t]+(?!\[[ xX]\])"#, options: .anchorsMatchLines)
  static let quote = try! NSRegularExpression(pattern: #"^(>)[ \t]?(.*)$"#, options: .anchorsMatchLines)
  static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(?:(`{3,})|(~{3,}))[^\n]*\n[\s\S]*?(?:^ {0,3}(?:\1`*|\2~*)[ \t]*$|\z)"#, options: .anchorsMatchLines)
  static let rule = try! NSRegularExpression(pattern: #"^(?:-{3,}|_{3,}|\*{3,})[ \t]*$"#, options: .anchorsMatchLines)
  static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
  static let italic = try! NSRegularExpression(pattern: #"(?<![\*\w])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![\*\w])"#)
  static let strike = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)\1"#)
  static let code = try! NSRegularExpression(pattern: #"(`)([^`\n]+)\1"#)
  static let link = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^)\s]+)(\))"#)
  static let bareURL = try! NSRegularExpression(pattern: #"(?<![\(\w])https?://[^\s<>\)\]]+"#)

  static func apply(to storage: NSTextStorage) {
    let text = storage.string
    let all = fullRange(text)
    let dim = NSColor.tertiaryLabelColor
    let accent = NSColor.controlAccentColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    paragraph.paragraphSpacing = 4

    storage.beginEditing()
    storage.setAttributes(
      [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: all)

    var codeRanges: [NSRange] = []
    for match in fence.matches(in: text, range: all) {
      storage.addAttributes([.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor], range: match.range)
      codeRanges.append(match.range)
    }
    func inCode(_ range: NSRange) -> Bool {
      codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    for match in heading.matches(in: text, range: all) where !inCode(match.range) {
      let level = min(match.range(at: 1).length, 3) - 1
      storage.addAttribute(.font, value: headingFonts[level], range: match.range)
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
    }
    for match in task.matches(in: text, range: all) where !inCode(match.range) {
      let box = match.range(at: 3)
      let done = (text as NSString).substring(with: box).lowercased() == "[x]"
      storage.addAttributes(
        [.foregroundColor: accent, .font: monoFont,
         .link: URL(string: "\(taskScheme)://toggle/\(box.location)")!], range: box)
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 2))
      let body = match.range(at: 4)
      if done, body.location != NSNotFound {
        storage.addAttributes(
          [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
           .foregroundColor: NSColor.secondaryLabelColor], range: body)
      }
    }
    for match in bullet.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttribute(.foregroundColor, value: accent, range: match.range(at: 2))
    }
    for match in quote.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttributes(
        [.foregroundColor: NSColor.secondaryLabelColor,
         .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)], range: match.range(at: 2))
    }
    for match in rule.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttribute(.foregroundColor, value: dim, range: match.range)
    }
    for match in bold.matches(in: text, range: all) where !inCode(match.range) {
      let current = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont ?? baseFont
      storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask), range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range.location + match.range.length - match.range(at: 1).length, length: match.range(at: 1).length))
    }
    for match in italic.matches(in: text, range: all) where !inCode(match.range) {
      let current = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont ?? baseFont
      storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask), range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range.location + match.range.length - 1, length: 1))
    }
    for match in strike.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range.location + match.range.length - 2, length: 2))
    }
    for match in code.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttributes(
        [.font: monoFont, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)], range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range.location + match.range.length - 1, length: 1))
    }
    for match in link.matches(in: text, range: all) where !inCode(match.range) {
      let target = (text as NSString).substring(with: match.range(at: 4))
      for index in [1, 3, 5] {
        storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: index))
      }
      storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 4))
      if let url = URL(string: target) {
        storage.addAttribute(.link, value: url, range: match.range(at: 2))
      }
    }
    for match in bareURL.matches(in: text, range: all) where !inCode(match.range) {
      let target = (text as NSString).substring(with: match.range)
      guard let url = URL(string: target) else { continue }
      storage.addAttributes(
        [.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
    }
    storage.endEditing()
  }
}

// MARK: - Text view with the Raycast Notes key bindings

final class NoteTextView: NSTextView {
  var onCommand: ((String) -> Bool)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" {
      return onCommand?("copy") == true
    }
    if flags == .control, event.charactersIgnoringModifiers == "x" {
      return onCommand?("delete") == true
    }
    if flags == .command, let key = event.charactersIgnoringModifiers {
      let command: String?
      switch key {
      case "[": command = "prev"
      case "]": command = "next"
      case "n": command = "new"
      case "p": command = "browse"
      case "w": command = "hide"
      case "k": command = "palette"
      case "f": command = "find"
      case "d": command = "duplicate"
      case "\r": command = "toggle-task"
      default: command = nil
      }
      if let command, onCommand?(command) == true { return true }
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {  // escape
      _ = onCommand?("hide")
      return
    }
    super.keyDown(with: event)
  }
}


// MARK: - Action palette (⌘K)

struct PaletteAction {
  let title: String
  let keys: String
  let symbol: String
  let command: String
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
  private let actions: [PaletteAction]
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
    visible = query.isEmpty
      ? actions
      : actions.filter { action in
        let words = query.split(separator: " ")
        let haystack = action.title.lowercased()
        return words.allSatisfy { haystack.contains($0) }
      }
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
      badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
      badge.layer?.cornerRadius = 5
      badge.translatesAutoresizingMaskIntoConstraints = false
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
      badge.heightAnchor.constraint(equalToConstant: 22).isActive = true
      keys.addArrangedSubview(badge)
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

// MARK: - Controller

final class PanelController: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate {
  private var panel: NSPanel!
  private var textView: NoteTextView!
  private var notes: [Note] = []
  private var currentPath: String?
  private var loadedText = ""
  private var saveTimer: Timer?
  private var watcher: DispatchSourceFileSystemObject?
  private var pendingCommand: String
  private var palette: ActionPalette!

  init(initialCommand: String) {
    pendingCommand = initialCommand
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildPanel()
    handle(pendingCommand)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  private func buildPanel() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
      styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.setFrameAutosaveName("notes-panel")
    panel.delegate = self
    if panel.frame.origin == .zero { panel.center() }

    let scroll = NSScrollView(frame: panel.contentView!.bounds)
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false

    textView = NoteTextView(frame: scroll.bounds)
    textView.autoresizingMask = [.width]
    textView.isRichText = false
    textView.font = Markdown.baseFont
    textView.linkTextAttributes = [:]
    textView.isAutomaticLinkDetectionEnabled = false
    textView.textContainerInset = NSSize(width: 18, height: 16)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.delegate = self
    textView.onCommand = { [weak self] command in
      self?.handle(command)
      return true
    }
    textView.minSize = NSSize(width: 0, height: scroll.bounds.height)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true

    scroll.documentView = textView
    panel.contentView?.addSubview(scroll)

    palette = ActionPalette(actions: [
      PaletteAction(title: "New Note", keys: "⌘N", symbol: "plus", command: "new"),
      PaletteAction(title: "Duplicate Note", keys: "⌘D", symbol: "doc.on.doc", command: "duplicate"),
      PaletteAction(title: "Browse Notes", keys: "⌘P", symbol: "square.grid.2x2", command: "browse"),
      PaletteAction(title: "Previous Note", keys: "⌘[", symbol: "arrow.left.circle", command: "prev"),
      PaletteAction(title: "Next Note", keys: "⌘]", symbol: "arrow.right.circle", command: "next"),
      PaletteAction(title: "Toggle Task", keys: "⌘↩", symbol: "checkmark.circle", command: "toggle-task"),
      PaletteAction(title: "Find in Note", keys: "⌘F", symbol: "magnifyingglass", command: "find"),
      PaletteAction(title: "Copy Note", keys: "⇧⌘C", symbol: "doc.on.clipboard", command: "copy"),
      PaletteAction(title: "Reveal in Finder", keys: "", symbol: "folder", command: "reveal"),
      PaletteAction(title: "Delete Note", keys: "⌃X", symbol: "trash", command: "delete"),
      PaletteAction(title: "Hide Window", keys: "⎋", symbol: "eye.slash", command: "hide"),
    ]) { [weak self] command in
      self?.handle(command)
    }
  }

  // MARK: Commands

  func handle(_ command: String) {
    switch command {
    case "toggle":
      panel.isVisible ? hide() : show()
    case "show":
      show()
    case "hide":
      hide()
    case "new":
      newNote()
      show()
    case "prev":
      move(by: 1)
    case "next":
      move(by: -1)
    case "browse":
      hide()
      NSWorkspace.shared.open(URL(string: "raycast://extensions/c-wenlong/notes/browseNotes")!)
    case "toggle-task":
      toggleTaskOnCurrentLine()
    case "palette":
      palette.isVisible ? palette.hide() : palette.show(over: panel)
    case "duplicate":
      duplicateNote()
    case "find":
      let item = NSMenuItem()
      item.tag = NSFindPanelAction.showFindPanel.rawValue
      textView.performFindPanelAction(item)
    case "copy":
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(textView.string, forType: .string)
    case "reveal":
      if let path = currentPath {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }
    case "delete":
      deleteNote()
    default:
      if command.hasPrefix("open ") {
        let path = String(command.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        open(path)
        show()
      }
    }
  }

  private func show() {
    refreshList()
    if currentPath == nil {
      if let first = notes.first { load(first.path) } else { newNote() }
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(textView)
  }

  private func hide() {
    palette.hide()
    saveNow()
    panel.orderOut(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }

  // MARK: Note list and navigation

  /// Re-reads the folder so the order reflects the latest edits, keeping
  /// the open note selected even if it moved.
  private func refreshList() {
    notes = listNotes()
    if let current = currentPath, !notes.contains(where: { $0.path == current }) {
      currentPath = nil
      loadedText = ""
    }
    updateTitle()
  }

  private var currentIndex: Int? {
    guard let current = currentPath else { return nil }
    return notes.firstIndex(where: { $0.path == current })
  }

  private func move(by delta: Int) {
    saveNow()
    guard !notes.isEmpty else { return }
    let index = ((currentIndex ?? 0) + delta + notes.count) % notes.count
    load(notes[index].path)
  }

  private func open(_ path: String) {
    saveNow()
    refreshList()
    if !notes.contains(where: { $0.path == path }) {
      notes.insert(Note(path: path, modified: Date()), at: 0)
    }
    load(path)
  }

  /// Copies the open note. The heading gets " copy" appended and a
  /// generated filename follows that heading's slug, so the title-driven
  /// rename on the next save leaves the copy's name alone.
  private func duplicateNote() {
    saveNow()
    guard let path = currentPath else { return }
    let filename = (path as NSString).lastPathComponent
    let directory = (path as NSString).deletingLastPathComponent
    var text = loadedText
    var copyName = "\((filename as NSString).deletingPathExtension) copy.md"

    if let heading = headingPattern.firstMatch(in: text, range: fullRange(text)) {
      let headingRange = heading.range(at: 1)
      let copyTitle = (text as NSString).substring(with: headingRange) + " copy"
      text = (text as NSString).replacingCharacters(in: headingRange, with: copyTitle)
      if let match = generatedNamePattern.firstMatch(in: filename, range: fullRange(filename)) {
        let prefix = (filename as NSString).substring(with: match.range(at: 1))
        copyName = "\(prefix) - \(slugify(copyTitle)).md"
      }
    }

    let copyPath = uniquePath(for: copyName, in: directory)
    do {
      try text.write(toFile: copyPath, atomically: false, encoding: .utf8)
    } catch {
      NSSound.beep()
      return
    }
    refreshList()
    load(copyPath)
  }

  /// Moves the open note to the Trash after confirming, then shows the
  /// newest remaining note.
  private func deleteNote() {
    guard let path = currentPath else { return }
    let alert = NSAlert()
    alert.messageText = "Move note to Trash?"
    alert.informativeText = (path as NSString).lastPathComponent
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    saveNow()
    watcher?.cancel()
    watcher = nil
    do {
      try diskFiles.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    } catch {
      NSSound.beep()
      watch(path)
      return
    }
    currentPath = nil
    loadedText = ""
    refreshList()
    if let first = notes.first { load(first.path) } else { newNote() }
  }

  private func newNote() {
    saveNow()
    let path = uniquePath(for: "\(timestampPrefix()) - untitled.md")
    do {
      try diskFiles.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
      try "# \n".write(toFile: path, atomically: false, encoding: .utf8)
    } catch {
      NSSound.beep()
      panel.title = "Cannot write to \(notesDir)"
      return
    }
    refreshList()
    load(path)
    textView.setSelectedRange(NSRange(location: 2, length: 0))
  }

  // MARK: Loading and saving

  private func load(_ path: String) {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    currentPath = path
    loadedText = text
    textView.string = text
    restyle()
    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    textView.undoManager?.removeAllActions()
    textView.scrollToEndOfDocument(nil)
    watch(path)
    updateTitle()
  }

  func textDidChange(_ notification: Notification) {
    restyle()
    saveTimer?.invalidate()
    saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
      self?.saveNow()
    }
    updateTitle()
  }

  private func saveNow() {
    saveTimer?.invalidate()
    guard let path = currentPath else { return }
    let text = textView.string
    guard text != loadedText else { return }
    do {
      try text.write(toFile: path, atomically: false, encoding: .utf8)
      loadedText = text
      renameToMatchTitleIfNeeded()
      updateTitle()
    } catch {
      NSSound.beep()
    }
  }

  /// Generated filenames follow the heading, as the Raycast extension does.
  private func renameToMatchTitleIfNeeded() {
    guard let path = currentPath else { return }
    let filename = (path as NSString).lastPathComponent
    guard let match = generatedNamePattern.firstMatch(in: filename, range: fullRange(filename)),
      let heading = headingPattern.firstMatch(in: loadedText, range: fullRange(loadedText))
    else { return }
    let headingText = (loadedText as NSString).substring(with: heading.range(at: 1))
    let currentSlug = (filename as NSString).substring(with: match.range(at: 2))
    let nextSlug = slugify(headingText)
    guard !headingText.trimmingCharacters(in: .whitespaces).isEmpty, nextSlug != currentSlug else { return }
    let prefix = (filename as NSString).substring(with: match.range(at: 1))
    let nextPath = uniquePath(for: "\(prefix) - \(nextSlug).md", in: (path as NSString).deletingLastPathComponent)
    guard (try? diskFiles.moveItem(atPath: path, toPath: nextPath)) != nil else { return }
    currentPath = nextPath
    if let index = notes.firstIndex(where: { $0.path == path }) {
      notes[index] = Note(path: nextPath, modified: Date())
    }
    watch(nextPath)
    updateTitle()
  }

  /// Reloads when another program edits the open note and we have no
  /// unsaved changes of our own.
  private func watch(_ path: String) {
    watcher?.cancel()
    watcher = nil
    let fd = Darwin.open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      guard let self, self.currentPath == path else { return }
      if source.data.contains(.delete) || source.data.contains(.rename) {
        let unsaved = self.textView.string != self.loadedText
        if diskFiles.fileExists(atPath: path) {
          // Replaced in place (editors that save via rename): our fd points
          // at the old inode, so watch the new file and pick up its text.
          self.watch(path)
          if !unsaved { self.reloadFromDisk(path) }
          return
        }
        if unsaved {
          // Gone while we still hold edits: write them back rather than
          // dropping them, then keep editing the recreated file.
          do {
            try self.textView.string.write(toFile: path, atomically: false, encoding: .utf8)
            self.loadedText = self.textView.string
            self.watch(path)
          } catch {
            NSSound.beep()  // still dirty; the next save retries
          }
          self.updateTitle()
          return
        }
        self.currentPath = nil
        self.refreshList()
        if let first = self.notes.first { self.load(first.path) } else { self.newNote() }
        return
      }
      self.reloadFromDisk(path)
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    watcher = source
  }

  /// Takes the on-disk text when it changed and we have nothing unsaved.
  private func reloadFromDisk(_ path: String) {
    let onDisk = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    guard onDisk != loadedText, textView.string == loadedText else { return }
    let selection = textView.selectedRange()
    loadedText = onDisk
    textView.string = onDisk
    restyle()
    let length = (onDisk as NSString).length
    textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    updateTitle()
  }

  // MARK: Editing helpers

  private func restyle() {
    guard let storage = textView.textStorage else { return }
    let selection = textView.selectedRange()
    Markdown.apply(to: storage)
    textView.setSelectedRange(selection)
    textView.typingAttributes = [.font: Markdown.baseFont, .foregroundColor: NSColor.labelColor]
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url = link as? URL, url.scheme == Markdown.taskScheme,
      let location = Int(url.lastPathComponent)
    else { return false }
    toggleTask(atBox: location)
    return true
  }

  private func toggleTask(atBox location: Int) {
    let text = textView.string as NSString
    guard location + 3 <= text.length,
      text.substring(with: NSRange(location: location, length: 1)) == "["
    else { return }
    let markRange = NSRange(location: location + 1, length: 1)
    let mark = text.substring(with: markRange).lowercased() == "x" ? " " : "x"
    textView.insertText(mark, replacementRange: markRange)
  }

  private func toggleTaskOnCurrentLine() {
    let text = textView.string as NSString
    let lineRange = text.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
    let line = text.substring(with: lineRange)
    if let match = taskPattern.firstMatch(in: line, range: fullRange(line)) {
      let markRange = NSRange(location: lineRange.location + match.range(at: 2).location, length: 1)
      let mark = text.substring(with: markRange).lowercased() == "x" ? " " : "x"
      textView.insertText(mark, replacementRange: markRange)
    } else {
      let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
      let insertAt = NSRange(location: lineRange.location + indent.count, length: 0)
      textView.insertText("- [ ] ", replacementRange: insertAt)
    }
  }

  private func updateTitle() {
    guard let path = currentPath else {
      panel.title = "Notes"
      return
    }
    let noteTitle = title(of: textView.string, filename: (path as NSString).lastPathComponent)
    let position = currentIndex.map { "\($0 + 1)/\(notes.count)" } ?? ""
    let unsaved = textView.string != loadedText ? " •" : ""
    panel.title = position.isEmpty ? noteTitle + unsaved : "\(noteTitle)\(unsaved)  ·  \(position)"
  }
}

// MARK: - Entry point

var connectError = forwardToRunningInstance(requestedCommand)
if connectError == nil { exit(0) }

var server = CommandServer(staleSocket: connectError == ECONNREFUSED)
if server == nil {
  // Lost a race with another launch that is now listening: hand over.
  usleep(200_000)
  connectError = forwardToRunningInstance(requestedCommand)
  if connectError == nil { exit(0) }
  server = CommandServer(staleSocket: connectError == ECONNREFUSED)
}
guard let server else {
  FileHandle.standardError.write("notes-panel: could not listen on \(socketPath)\n".data(using: .utf8)!)
  exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PanelController(initialCommand: requestedCommand == "hide" ? "show" : requestedCommand)
app.delegate = controller
server.run { command in controller.handle(command) }
app.run()
