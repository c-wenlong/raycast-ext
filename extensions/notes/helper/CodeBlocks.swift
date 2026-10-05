import AppKit
import Foundation

// MARK: - Code block controls
//
// Each fenced code block gets two small buttons at the top-right of its
// card, as in Raycast Notes: the block's language (opens a searchable
// picker that rewrites the fence's language word) and a copy button that
// puts the body, without fences, on the pasteboard.

struct CodeLanguage {
  let name: String
  /// The word written after the fence; empty for Auto.
  let id: String
}

enum CodeLanguages {
  static let all: [CodeLanguage] = [
    CodeLanguage(name: "Auto", id: ""),
    CodeLanguage(name: "Bash", id: "bash"),
    CodeLanguage(name: "C", id: "c"),
    CodeLanguage(name: "C++", id: "cpp"),
    CodeLanguage(name: "C#", id: "csharp"),
    CodeLanguage(name: "CSS", id: "css"),
    CodeLanguage(name: "Diff", id: "diff"),
    CodeLanguage(name: "Go", id: "go"),
    CodeLanguage(name: "HTML", id: "html"),
    CodeLanguage(name: "Java", id: "java"),
    CodeLanguage(name: "JavaScript", id: "javascript"),
    CodeLanguage(name: "JSON", id: "json"),
    CodeLanguage(name: "Kotlin", id: "kotlin"),
    CodeLanguage(name: "Markdown", id: "markdown"),
    CodeLanguage(name: "Objective-C", id: "objectivec"),
    CodeLanguage(name: "Perl", id: "perl"),
    CodeLanguage(name: "PHP", id: "php"),
    CodeLanguage(name: "Python", id: "python"),
    CodeLanguage(name: "R", id: "r"),
    CodeLanguage(name: "Ruby", id: "ruby"),
    CodeLanguage(name: "Rust", id: "rust"),
    CodeLanguage(name: "SQL", id: "sql"),
    CodeLanguage(name: "Swift", id: "swift"),
    CodeLanguage(name: "TOML", id: "toml"),
    CodeLanguage(name: "TypeScript", id: "typescript"),
    CodeLanguage(name: "YAML", id: "yaml"),
  ]

  /// Other fence words people write for the same languages.
  private static let aliases: [String: String] = [
    "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
    "h": "c", "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
    "cs": "csharp", "c#": "csharp", "patch": "diff", "golang": "go", "htm": "html",
    "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
    "jsonc": "json", "kt": "kotlin", "kts": "kotlin", "md": "markdown",
    "objc": "objectivec", "objective-c": "objectivec", "obj-c": "objectivec",
    "pl": "perl", "py": "python", "python3": "python", "rb": "ruby", "rs": "rust",
    "ts": "typescript", "tsx": "typescript", "yml": "yaml",
  ]

  /// The list entry a fence word stands for, if it is one we know.
  static func language(for word: String) -> CodeLanguage? {
    let lower = word.lowercased()
    let id = aliases[lower] ?? lower
    return all.first { $0.id == id }
  }

  /// What the language button shows: "Auto" for no word, the list name
  /// for a known word, and the word itself (capitalised) otherwise.
  static func displayName(for word: String) -> String {
    if let known = language(for: word) { return known.name }
    return word.prefix(1).uppercased() + word.dropFirst()
  }
}

/// A small rounded button that never takes the caret, shows an arrow
/// cursor over the text view's I-beam, and brightens on hover.
final class CodeBlockButton: NSButton {
  private var hovering = false {
    didSet { needsDisplay = true }
  }
  private var trackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    setButtonType(.momentaryChange)
    refusesFirstResponder = true
    focusRingType = .none
    contentTintColor = .secondaryLabelColor
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }
  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

  override func draw(_ dirtyRect: NSRect) {
    let alpha: CGFloat = isHighlighted ? 0.16 : hovering ? 0.11 : 0.06
    NSColor.labelColor.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    super.draw(dirtyRect)
  }
}

/// The language and copy buttons for one block. Clicks between the two
/// buttons fall through to the text view.
final class CodeBlockControls: NSView {
  let languageButton: CodeBlockButton = {
    let button = CodeBlockButton(frame: .zero)
    button.lineBreakMode = .byTruncatingMiddle
    return button
  }()
  let copyButton = CodeBlockButton(frame: .zero)
  /// Where the block's opening fence line starts; identifies the block.
  var openingLocation = 0
  private(set) var language: String?
  private var languageWidth: CGFloat = 0
  private var copyReset: DispatchWorkItem?

  static let height: CGFloat = 24
  static let copyWidth: CGFloat = 24
  static let spacing: CGFloat = 4
  private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
  private static let copyImage = symbol("doc.on.clipboard", size: 11)
  private static let copiedImage = symbol("checkmark", size: 11)

  private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    languageButton.image = Self.symbol("chevron.down", size: 8)
    languageButton.imagePosition = .imageTrailing
    languageButton.imageHugsTitle = true
    languageButton.toolTip = "Change language"
    copyButton.image = Self.copyImage
    copyButton.imagePosition = .imageOnly
    copyButton.toolTip = "Copy code"
    addSubview(languageButton)
    addSubview(copyButton)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  /// Upper bound for the language button, set by the overlay from the
  /// card width; the title truncates in the middle beyond it.
  var maxLanguageWidth: CGFloat = 200 {
    didSet { if maxLanguageWidth != oldValue { needsLayout = true } }
  }

  var preferredWidth: CGFloat { min(languageWidth, maxLanguageWidth) + Self.spacing + Self.copyWidth }

  func setLanguage(_ word: String) {
    guard word != language else { return }
    language = word
    languageButton.attributedTitle = NSAttributedString(
      string: CodeLanguages.displayName(for: word),
      attributes: [.font: Self.titleFont, .foregroundColor: NSColor.secondaryLabelColor])
    languageWidth = ceil(languageButton.cell?.cellSize.width ?? 60) + 14
  }

  override func layout() {
    super.layout()
    languageButton.frame = NSRect(x: 0, y: 0, width: min(languageWidth, maxLanguageWidth), height: bounds.height)
    copyButton.frame = NSRect(
      x: bounds.width - Self.copyWidth, y: 0, width: Self.copyWidth, height: bounds.height)
  }

  /// Swaps the copy icon for a checkmark briefly.
  func flashCopied() {
    copyReset?.cancel()
    copyButton.image = Self.copiedImage
    let reset = DispatchWorkItem { [weak self] in self?.copyButton.image = Self.copyImage }
    copyReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
  }
}

/// Places a `CodeBlockControls` over every fenced block in a text view.
/// Controls are subviews of the text view, so they scroll with the text;
/// `update()` repositions them after the text, width, or zoom changes and
/// reuses views so nothing flickers.
final class CodeBlockOverlay: NSObject {
  private weak var textView: NSTextView?
  private var controls: [CodeBlockControls] = []
  private let picker = CodeLanguagePicker()
  private var updateScheduled = false
  /// The block whose picker is (or was last) open.
  private var pickerLocation: Int?

  /// Gap between the controls and the card's right edge.
  static let edgeMargin: CGFloat = 6
  /// Gap between the card top and the controls.
  static let topMargin: CGFloat = 5

  init(textView: NSTextView) {
    self.textView = textView
    super.init()
    textView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: textView)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  /// The frame can change in the middle of layout (the text view grows
  /// as text is laid out), so position queries wait for the next turn.
  @objc private func frameChanged(_ notification: Notification) {
    setNeedsUpdate()
  }

  func setNeedsUpdate() {
    guard !updateScheduled else { return }
    updateScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.updateScheduled = false
      self.update()
    }
  }

  func closePicker() {
    picker.hide(restoreFocus: false)
  }

  /// Frames of the visible control strips, in text view coordinates
  /// (for the view tests).
  var visibleControlFrames: [NSRect] { controls.filter { !$0.isHidden }.map(\.frame) }

  func update() {
    guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer
    else { return }
    let blocks = Markdown.codeBlocks(in: textView.string)
    let origin = textView.textContainerOrigin
    // The card spans the text column (the container less its padding).
    let right = origin.x + container.size.width - container.lineFragmentPadding - Self.edgeMargin

    var used = 0
    for block in blocks {
      // A block inside a collapsed toggle is hidden, controls and all.
      if (layoutManager as? TaskBoxLayoutManager)?.isFolded(block.openingLine.location) == true { continue }
      let glyphs = layoutManager.glyphRange(forCharacterRange: block.openingLine, actualCharacterRange: nil)
      guard glyphs.location != NSNotFound, glyphs.length > 0 else { continue }
      // The card's top is the top of the opening line's fragment.
      let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        .offsetBy(dx: origin.x, dy: origin.y)

      let view: CodeBlockControls
      if used < controls.count {
        view = controls[used]
      } else {
        view = makeControls()
        controls.append(view)
        textView.addSubview(view)
      }
      used += 1

      view.openingLocation = block.openingLine.location
      view.setLanguage(block.language)
      let height = CodeBlockControls.height
      // Centred in a tall opening line; never closer than topMargin to the top.
      let top = line.minY + max(Self.topMargin, (line.height - height) / 2)
      // Never wider than the card: a long fence word truncates instead of
      // pushing the controls past the visible edge.
      let cardLeft = origin.x + container.lineFragmentPadding + Self.edgeMargin
      let maxWidth = max(CodeBlockControls.copyWidth + CodeBlockControls.spacing + 40, right - cardLeft)
      view.maxLanguageWidth = maxWidth - CodeBlockControls.copyWidth - CodeBlockControls.spacing
      let width = min(view.preferredWidth, maxWidth)
      let frame = NSRect(x: (right - width).rounded(), y: top.rounded(), width: width, height: height)
      if view.frame != frame {
        view.frame = frame
        view.needsLayout = true
      }
      view.isHidden = false
    }
    for index in used..<controls.count where !controls[index].isHidden {
      controls[index].isHidden = true
    }
  }

  private func makeControls() -> CodeBlockControls {
    let view = CodeBlockControls(frame: .zero)
    view.autoresizingMask = []
    view.languageButton.target = self
    view.languageButton.action = #selector(languageClicked(_:))
    view.copyButton.target = self
    view.copyButton.action = #selector(copyClicked(_:))
    return view
  }

  private func block(at openingLocation: Int) -> Markdown.CodeBlock? {
    guard let textView else { return nil }
    return Markdown.codeBlocks(in: textView.string).first { $0.openingLine.location == openingLocation }
  }

  @objc private func copyClicked(_ sender: NSButton) {
    guard let view = sender.superview as? CodeBlockControls, let textView,
      let block = block(at: view.openingLocation)
    else { return }
    var body = (textView.string as NSString).substring(with: block.body)
    if body.hasSuffix("\n") { body.removeLast() }  // "\r\n" is one Character
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(body, forType: .string)
    view.flashCopied()
  }

  @objc private func languageClicked(_ sender: NSButton) {
    guard let view = sender.superview as? CodeBlockControls, let block = block(at: view.openingLocation)
    else { return }
    let location = view.openingLocation
    // Clicking the button of an open picker closes it: the click makes the
    // note window key, which already hid the picker a moment ago.
    if picker.isVisible || (pickerLocation == location && Date().timeIntervalSince(picker.closedAt) < 0.3) {
      picker.hide(restoreFocus: true)
      return
    }
    pickerLocation = location
    let current = CodeLanguages.language(for: block.language)?.id ?? block.language.lowercased()
    picker.show(below: sender, currentID: current) { [weak self] id in
      self?.setLanguage(id, forBlockAt: location)
    }
  }

  /// Rewrites the fence's language word as one undoable edit.
  private func setLanguage(_ id: String, forBlockAt openingLocation: Int) {
    guard let textView, let storage = textView.textStorage, let block = block(at: openingLocation) else { return }
    guard textView.isEditable else {
      NSSound.beep()
      return
    }
    let range = block.languageRange
    guard (textView.string as NSString).substring(with: range) != id else { return }
    textView.breakUndoCoalescing()
    guard textView.shouldChangeText(in: range, replacementString: id) else { return }
    storage.replaceCharacters(in: range, with: id)
    textView.didChangeText()
    textView.undoManager?.setActionName("Change Language")
    textView.breakUndoCoalescing()
    update()
  }
}

// MARK: - Language picker

/// A small searchable list of languages in a child panel below the
/// language button, styled like the ⌘K action palette. Up/down move,
/// return chooses, escape or clicking elsewhere closes.
final class CodeLanguagePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  private let panel: PalettePanel
  private let search = NSSearchField()
  private let table = NSTableView()
  private var visible: [CodeLanguage] = []
  private var currentID = ""
  private var choose: ((String) -> Void)?
  private(set) var closedAt = Date.distantPast
  private static let width: CGFloat = 220
  private static let rowHeight: CGFloat = 28
  private static let maxHeight: CGFloat = 340

  override init() {
    panel = PalettePanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.maxHeight),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.onToggleShortcut = { [weak self] in self?.hide(restoreFocus: true) }
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovable = false
    panel.isReleasedWhenClosed = false
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let height = Self.maxHeight
    let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
    root.material = .popover
    root.blendingMode = .behindWindow
    root.state = .active
    root.autoresizingMask = [.width, .height]
    panel.contentView = root

    search.placeholderString = "Search languages..."
    search.font = NSFont.systemFont(ofSize: 14)
    search.focusRingType = .none
    search.isBordered = false
    search.drawsBackground = false
    search.delegate = self
    search.frame = NSRect(x: 12, y: height - 40, width: Self.width - 24, height: 26)
    search.autoresizingMask = [.width, .minYMargin]
    if let cell = search.cell as? NSSearchFieldCell {
      cell.searchButtonCell = nil
      cell.cancelButtonCell = nil
    }
    root.addSubview(search)

    let divider = NSBox(frame: NSRect(x: 0, y: height - 48, width: Self.width, height: 1))
    divider.boxType = .separator
    divider.autoresizingMask = [.width, .minYMargin]
    root.addSubview(divider)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
    column.width = Self.width - 16
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = Self.rowHeight
    table.intercellSpacing = NSSize(width: 0, height: 2)
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.style = .inset
    table.refusesFirstResponder = true
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(rowClicked)

    let scroll = NSScrollView(frame: NSRect(x: 0, y: 6, width: Self.width, height: height - 56))
    scroll.autoresizingMask = [.width, .height]
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    root.addSubview(scroll)

    NotificationCenter.default.addObserver(
      self, selector: #selector(resignedKey), name: NSWindow.didResignKeyNotification, object: panel)
  }

  var isVisible: Bool { panel.isVisible }

  func show(below anchor: NSView, currentID: String, choose: @escaping (String) -> Void) {
    guard let parent = anchor.window else { return }
    self.currentID = currentID
    self.choose = choose
    search.stringValue = ""
    filter()
    if let index = visible.firstIndex(where: { $0.id == currentID }) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.scrollRowToVisible(index)
    }

    let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let height = min(CGFloat(CodeLanguages.all.count) * (Self.rowHeight + 2) + 64, Self.maxHeight)
    var frame = NSRect(x: anchorRect.maxX - Self.width, y: anchorRect.minY - 4 - height, width: Self.width, height: height)
    if let screen = (parent.screen ?? NSScreen.main)?.visibleFrame {
      if frame.minY < screen.minY { frame.origin.y = anchorRect.maxY + 4 }
      frame.origin.x = min(max(frame.minX, screen.minX + 4), screen.maxX - Self.width - 4)
    }
    panel.setFrame(frame, display: false)
    if panel.parent !== parent {
      panel.parent?.removeChildWindow(panel)
      parent.addChildWindow(panel, ordered: .above)
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(search)
  }

  /// Closes the picker; `restoreFocus` hands the keyboard back to the
  /// note window (not wanted when the user already clicked elsewhere).
  func hide(restoreFocus: Bool) {
    guard panel.isVisible else { return }
    let parent = panel.parent
    parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    closedAt = Date()
    choose = nil
    if restoreFocus, let parent, parent.isVisible { parent.makeKey() }
  }

  @objc private func resignedKey(_ notification: Notification) {
    hide(restoreFocus: false)
  }

  private func filter() {
    let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    visible = query.isEmpty
      ? CodeLanguages.all
      : CodeLanguages.all.filter { $0.name.lowercased().contains(query) || $0.id.contains(query) }
    table.reloadData()
    if !visible.isEmpty {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      table.scrollRowToVisible(0)
    }
  }

  private func chooseSelected() {
    let row = table.selectedRow
    guard row >= 0, row < visible.count else { return }
    let id = visible[row].id
    let choose = self.choose
    hide(restoreFocus: true)
    choose?(id)
  }

  @objc private func rowClicked() {
    chooseSelected()
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
      chooseSelected()
    case #selector(NSResponder.cancelOperation(_:)):
      hide(restoreFocus: true)
    default:
      return false
    }
    return true
  }

  // NSTableViewDataSource / Delegate

  func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let language = visible[row]
    let cell = NSView()

    let title = NSTextField(labelWithString: language.name)
    title.font = NSFont.systemFont(ofSize: 13)
    title.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(title)

    var constraints = [
      title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ]
    if language.id == currentID {
      let check = NSImageView()
      check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current language")
      check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
      check.contentTintColor = .secondaryLabelColor
      check.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(check)
      constraints += [
        check.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
        check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ]
    }
    NSLayoutConstraint.activate(constraints)
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let view = NSTableRowView()
    view.isEmphasized = true
    return view
  }
}
