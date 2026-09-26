import AppKit
import Foundation

// MARK: - Window chrome, as in the Raycast Notes window
//
// A pill of three icon buttons at the right of the title bar (⌘K actions,
// Browse Notes, New Note), and at the bottom of the note a character count
// with a round "T" button that opens the formatting picker.

/// Fills that follow the appearance: a faint light wash over dark, a faint
/// dark wash over light.
enum ChromeColors {
  static let pill = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
  }
  static let round = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.93, alpha: 1)
  }
  static let hover = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.07)
  }
  static let border = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)
  }
}

/// An SF Symbol button that never takes focus from the note and draws its
/// own rounded background: `fill` at rest (may be clear), lighter on hover.
final class ChromeButton: NSButton {
  var cornerRadius: CGFloat = 7
  var fill: NSColor = .clear
  var stroke: NSColor?
  private var hovering = false {
    didSet { needsDisplay = true }
  }
  private var trackingArea: NSTrackingArea?

  init(symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .medium, label: String) {
    super.init(frame: .zero)
    setUp(label: label)
    imagePosition = .imageOnly
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
  }

  /// A button showing `glyph` as text (SF Symbols has no plain "T").
  init(glyph: String, font: NSFont, label: String) {
    super.init(frame: .zero)
    setUp(label: label)
    imagePosition = .noImage
    attributedTitle = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
  }

  private func setUp(label: String) {
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    refusesFirstResponder = true
    focusRingType = .none
    contentTintColor = .labelColor
    toolTip = label
    setAccessibilityLabel(label)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  // Clicks here must not drag the (movable-by-background) window.
  override var mouseDownCanMoveWindow: Bool { false }

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
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
    fill.setFill()
    path.fill()
    if hovering || isHighlighted {
      ChromeColors.hover.setFill()
      path.fill()
    }
    if let stroke {
      stroke.setStroke()
      path.lineWidth = 1
      path.stroke()
    }
    super.draw(dirtyRect)
  }
}

/// A capsule background (radius = half the height).
final class PillView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    ChromeColors.pill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
  }

  override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Title bar pill

/// The title bar: the note title centred in secondary colour, and the
/// ⌘ / Browse / + pill at its right end. Both are toolbar items, since a
/// unified toolbar is what gives the title bar Raycast's height and keeps
/// the traffic lights, title and pill on one centred row.
final class TitlebarChrome: NSObject, NSToolbarDelegate {
  private let run: (String) -> Void
  private let titleLabel = PassThroughLabel(labelWithString: "")
  private let pill: PillView

  static let buttonSize: CGFloat = 28
  static let spacing: CGFloat = 4
  static let padding: CGFloat = 6

  private static let titleItem = NSToolbarItem.Identifier("notes.title")
  private static let pillItem = NSToolbarItem.Identifier("notes.pill")

  private static let buttons: [(symbol: String, label: String, command: String)] = [
    ("command", "Actions (⌘K)", "palette"),
    ("square.on.square", "Browse Notes (⌘P)", "browse"),
    ("plus", "New Note (⌘N)", "new"),
  ]

  init(run: @escaping (String) -> Void) {
    self.run = run
    let count = CGFloat(Self.buttons.count)
    let size = NSSize(
      width: Self.padding * 2 + Self.buttonSize * count + Self.spacing * (count - 1),
      height: Self.buttonSize + Self.padding * 2)
    pill = PillView(frame: NSRect(origin: .zero, size: size))
    super.init()

    pill.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      pill.widthAnchor.constraint(equalToConstant: size.width),
      pill.heightAnchor.constraint(equalToConstant: size.height),
    ])
    for (index, item) in Self.buttons.enumerated() {
      let button = ChromeButton(symbol: item.symbol, pointSize: 13, label: item.label)
      button.frame = NSRect(
        x: Self.padding + CGFloat(index) * (Self.buttonSize + Self.spacing), y: Self.padding,
        width: Self.buttonSize, height: Self.buttonSize)
      button.tag = index
      button.target = self
      button.action = #selector(clicked(_:))
      pill.addSubview(button)
    }

    titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.alignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
  }

  /// Gives `window` the toolbar and hides its own title; the centred label
  /// follows `window.title`, so every existing title update still shows.
  func install(in window: NSWindow) {
    let toolbar = NSToolbar(identifier: "notes-panel")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.centeredItemIdentifier = Self.titleItem
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    titleLabel.bind(.value, to: window, withKeyPath: "title", options: nil)
  }

  @objc private func clicked(_ sender: NSButton) {
    run(Self.buttons[sender.tag].command)
  }

  // NSToolbarDelegate

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.titleItem, .flexibleSpace, Self.pillItem]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: identifier)
    switch identifier {
    case Self.titleItem:
      item.view = titleLabel
      item.label = "Title"
    case Self.pillItem:
      item.view = pill
      item.label = "Actions"
    default:
      return nil
    }
    item.isBordered = false
    return item
  }
}

// MARK: - Bottom bar

/// A label that lets clicks through to the note underneath.
private final class PassThroughLabel: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// "2/7 · 1365 characters" centred at the bottom of the note, and the
/// round formatting button at the bottom right.
final class StatusBar {
  /// Space the text needs below its last line so the bar never covers it.
  static let reservedHeight: CGFloat = 36
  private let label: NSTextField = PassThroughLabel(labelWithString: "")
  let formatButton: ChromeButton

  init(onFormat: @escaping () -> Void) {
    label.font = NSFont.systemFont(ofSize: 12)
    label.textColor = .tertiaryLabelColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    formatButton = ChromeButton(glyph: "T", font: NSFont.systemFont(ofSize: 16, weight: .semibold), label: "Formatting")
    formatButton.cornerRadius = 18
    formatButton.fill = ChromeColors.round
    formatButton.stroke = ChromeColors.border
    formatButton.translatesAutoresizingMaskIntoConstraints = false
    self.onFormat = onFormat
    formatButton.target = self
    formatButton.action = #selector(formatClicked)
  }

  private let onFormat: () -> Void

  @objc private func formatClicked() { onFormat() }

  func install(in parent: NSView) {
    parent.addSubview(label)
    parent.addSubview(formatButton)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
      label.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -10),
      formatButton.widthAnchor.constraint(equalToConstant: 36),
      formatButton.heightAnchor.constraint(equalToConstant: 36),
      formatButton.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -14),
      formatButton.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -14),
    ])
  }

  /// `position` is "2/7" or nil when the note is not in the list.
  func update(characters: Int, position: String?) {
    let count = "\(characters) character\(characters == 1 ? "" : "s")"
    label.stringValue = position.map { "\($0)  ·  \(count)" } ?? count
  }
}

// MARK: - Formatting picker

/// The formatting commands of the "T" button, each the same edit as its key.
enum FormatOptions {
  struct Option {
    let id: String
    let title: String
    let keys: String
    let symbol: String
    let format: NoteTextView.Format
  }

  static let all: [Option] = [
    Option(id: "h1", title: "Heading 1", keys: "⌥⌘1", symbol: "textformat.size.larger", format: .prefix(.heading(1))),
    Option(id: "h2", title: "Heading 2", keys: "⌥⌘2", symbol: "textformat.size", format: .prefix(.heading(2))),
    Option(id: "h3", title: "Heading 3", keys: "⌥⌘3", symbol: "textformat.size.smaller", format: .prefix(.heading(3))),
    Option(id: "bold", title: "Bold", keys: "⌘B", symbol: "bold", format: .wrap("**")),
    Option(id: "italic", title: "Italic", keys: "⌘I", symbol: "italic", format: .wrap("_")),
    Option(id: "strike", title: "Strikethrough", keys: "⇧⌘S", symbol: "strikethrough", format: .wrap("~~")),
    Option(id: "code", title: "Code", keys: "⌘E", symbol: "chevron.left.forwardslash.chevron.right", format: .wrap("`")),
    Option(id: "link", title: "Link", keys: "⌘L", symbol: "link", format: .link),
    Option(id: "quote", title: "Quote", keys: "⇧⌘B", symbol: "text.quote", format: .prefix(.quote)),
    Option(id: "ordered", title: "Numbered List", keys: "⇧⌘7", symbol: "list.number", format: .prefix(.ordered)),
    Option(id: "bullet", title: "Bullet List", keys: "⇧⌘8", symbol: "list.bullet", format: .prefix(.bullet)),
    Option(id: "task", title: "Task List", keys: "⇧⌘9", symbol: "checklist", format: .prefix(.task)),
    Option(id: "code-block", title: "Code Block", keys: "⌥⌘C", symbol: "curlybraces", format: .codeBlock),
  ]

  static let commandPrefix = "format:"

  /// Palette rows whose commands are "format:<id>".
  static var paletteActions: [PaletteAction] {
    all.map { PaletteAction(title: $0.title, keys: $0.keys, symbol: $0.symbol, command: commandPrefix + $0.id) }
  }

  static func format(forCommand command: String) -> NoteTextView.Format? {
    guard command.hasPrefix(commandPrefix) else { return nil }
    let id = command.dropFirst(commandPrefix.count)
    return all.first { $0.id == id }?.format
  }
}
