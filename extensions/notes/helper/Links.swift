import AppKit
import Foundation

// MARK: - Editing links without showing their markdown
//
// Resting the mouse on an http(s) link shows a small bubble below it with
// the address and Open / Edit / Copy buttons; right-clicking any link offers
// Edit, Copy, Open and Remove. Edit opens a small panel with the link's text
// and address, and saving rewrites the whole `[text](url)` (or bare URL) as
// one undoable change. Clicking a link still opens it, as before.

final class LinkController: NSObject {
  /// One link's markdown source.
  struct Span: Equatable {
    /// All of it: `[text](url)`, or the bare URL.
    let range: NSRange
    /// The part shown on screen: the text, or the bare URL itself.
    let textRange: NSRange
    let text: String
    let url: String
    let isBare: Bool
  }

  static let showDelay: TimeInterval = 0.25
  static let hideDelay: TimeInterval = 0.3
  /// Sentence punctuation that ends a bare URL (as in Markdown.apply).
  private static let trailingPunctuation: Set<unichar> = Set(".,;:!?'\"".utf16)

  // MARK: Finding and rewriting links (pure)

  /// The link whose markdown contains `index`, found the way Markdown.apply
  /// finds it: `Markdown.link` first, then `Markdown.bareURL` with trailing
  /// punctuation trimmed, both run over the index's line only.
  static func span(in text: String, at index: Int) -> Span? {
    let ns = text as NSString
    guard index >= 0, index < ns.length else { return nil }
    let line = ns.lineRange(for: NSRange(location: index, length: 0))
    if let match = Markdown.link.matches(in: text, range: line).first(where: { NSLocationInRange(index, $0.range) }) {
      return Span(
        range: match.range, textRange: match.range(at: 2), text: ns.substring(with: match.range(at: 2)),
        url: ns.substring(with: match.range(at: 4)), isBare: false)
    }
    for match in Markdown.bareURL.matches(in: text, range: line) {
      var range = match.range
      while range.length > 0, trailingPunctuation.contains(ns.character(at: NSMaxRange(range) - 1)) {
        range.length -= 1
      }
      guard NSLocationInRange(index, range) else { continue }
      let url = ns.substring(with: range)
      return Span(range: range, textRange: range, text: url, url: url, isBare: true)
    }
    return nil
  }

  /// The address as typed, trimmed, with `https://` added when it has no
  /// scheme, and with the characters that would end a markdown target
  /// early (whitespace, ")") percent-encoded. Empty stays empty.
  static func normalizedURL(_ raw: String) -> String {
    var url = raw.components(separatedBy: .newlines).joined().trimmingCharacters(in: .whitespaces)
    guard !url.isEmpty else { return "" }
    if url.hasPrefix("//") {
      url = "https:" + url
    } else if url.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:(?![0-9])"#, options: .regularExpression) == nil {
      // "example.com", "localhost:3000/x" (a port is not a scheme)
      url = "https://" + url
    }
    return url.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "\t", with: "%09")
      .replacingOccurrences(of: ")", with: "%29")
  }

  /// Link text on one line, without the "]" that would end it early.
  private static func cleanedText(_ raw: String) -> String {
    raw.components(separatedBy: .newlines).joined(separator: " ")
      .replacingOccurrences(of: "]", with: "")
      .trimmingCharacters(in: .whitespaces)
  }

  /// True when `url` written on its own is picked up whole as a bare link.
  private static func isBareLinkable(_ url: String) -> Bool {
    let whole = NSRange(location: 0, length: (url as NSString).length)
    guard let last = url.utf16.last, !trailingPunctuation.contains(last),
      let match = Markdown.bareURL.firstMatch(in: url, range: whole)
    else { return false }
    return match.range == whole
  }

  /// The edit that gives the link at `index` the text `newText` and the
  /// address `newURL`. Empty text keeps the old text; an empty address
  /// removes the link and keeps its text. A bare URL whose text was left
  /// alone stays bare (just the new address); with new text it becomes
  /// `[text](url)`. The caret goes after the rewritten span.
  static func rewrite(in text: String, at index: Int, text newText: String, url newURL: String) -> ListEditing.Edit? {
    guard let span = span(in: text, at: index) else { return nil }
    var label = cleanedText(newText)
    if label.isEmpty { label = span.text }
    let url = normalizedURL(newURL)
    let replacement: String
    if url.isEmpty {
      // Remove Link. A bare URL is its own text, so unless the text was
      // changed it stays as it is.
      replacement = label
    } else if span.isBare && (label == span.text || label == url) {
      replacement = isBareLinkable(url) ? url : "[\(url)](\(url))"
    } else {
      replacement = "[\(label)](\(url))"
    }
    return ListEditing.Edit(
      range: span.range, replacement: replacement, cursor: span.range.location + (replacement as NSString).length)
  }

  /// Remove Link: `[text](url)` becomes `text`; a bare URL is left alone.
  static func removal(in text: String, at index: Int) -> ListEditing.Edit? {
    rewrite(in: text, at: index, text: "", url: "")
  }

  // MARK: State

  private weak var textView: NoteTextView?
  private let bubble = LinkBubble()
  private let editor = LinkEditor()
  /// The link the bubble shows.
  private var bubbleSpan: Span?
  /// The character the bubble hangs from, inside `bubbleSpan`'s text: on a
  /// link that wraps, the bubble goes by the line this character is on.
  private var bubbleAnchor = 0
  /// The link the mouse rests on, shown when `showTimer` fires, and the
  /// character under the mouse on it.
  private var pendingSpan: Span?
  private var pendingAnchor = 0
  /// The link the editor is open for, and the character it hangs from; the
  /// editor follows it when the note scrolls or re-wraps.
  private var editingSpan: Span?
  private var editingAnchor = 0
  private var showTimer: Timer?
  private var hideTimer: Timer?
  private var fadingOut = false
  private var fadeGeneration = 0

  init(textView: NoteTextView) {
    self.textView = textView
    super.init()
    bubble.isHidden = true
    bubble.onOpen = { [weak self] in self?.openBubbleLink() }
    bubble.onEdit = { [weak self] in self?.editBubbleLink() }
    bubble.onCopy = { [weak self] in self?.copyBubbleLink() }
    textView.addSubview(bubble)
    textView.onMouseMoved = { [weak self] event in self?.mouseMoved(event) ?? false }
    textView.onMouseExited = { [weak self] in
      self?.cancelShow()
      self?.scheduleHide()
    }
    textView.linkMenu = { [weak self] event in self?.menu(for: event) }

    let center = NotificationCenter.default
    if let clip = textView.enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      center.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }
    if let storage = textView.textStorage {
      center.addObserver(
        self, selector: #selector(storageEdited), name: NSTextStorage.didProcessEditingNotification, object: storage)
    }
    textView.postsFrameChangedNotifications = true
    center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: textView)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    showTimer?.invalidate()
    hideTimer?.invalidate()
  }

  /// Hides the bubble and cancels the editor (the panel is hiding).
  func close() {
    hideBubble(animated: false)
    editor.hide(restoreFocus: false)
  }

  /// The hover bubble goes (the mouse is somewhere else in the text now);
  /// the editor stays open and follows its link, so nothing typed is lost.
  @objc private func scrolled(_ notification: Notification) {
    hideBubble(animated: false)
    if editor.isVisible { positionEditor() }
  }

  @objc private func storageEdited(_ notification: Notification) {
    guard let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
    close()
  }

  /// Width changes re-wrap the text; follow the link. Waits a turn, as the
  /// frame changes in the middle of layout.
  @objc private func frameChanged(_ notification: Notification) {
    guard !bubble.isHidden || editor.isVisible else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if !self.bubble.isHidden, !self.positionBubble() { self.hideBubble(animated: false) }
      if self.editor.isVisible { self.positionEditor() }
    }
  }

  // MARK: Hit testing

  /// Character index of the link glyph under `point` (text view
  /// coordinates). `webOnly` limits it to http(s) links; task boxes never
  /// count.
  private func linkIndex(at point: NSPoint, webOnly: Bool) -> Int? {
    guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
      let storage = textView.textStorage, storage.length > 0
    else { return nil }
    let origin = textView.textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    let glyph = layoutManager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
    guard glyph < layoutManager.numberOfGlyphs,
      layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local)
    else { return nil }
    let index = layoutManager.characterIndexForGlyph(at: glyph)
    guard index < storage.length else { return nil }
    let value = storage.attribute(.link, at: index, effectiveRange: nil)
    guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)),
      let scheme = url.scheme?.lowercased(), scheme != Markdown.taskScheme
    else { return nil }
    if webOnly, scheme != "http", scheme != "https" { return nil }
    return index
  }

  /// The http(s) link under `point` and the character of it there.
  private func hoveredLink(at point: NSPoint) -> (span: Span, index: Int)? {
    guard let textView, let index = linkIndex(at: point, webOnly: true),
      let span = Self.span(in: textView.string, at: index)
    else { return nil }
    return (span, index)
  }

  /// The part of the link's visible text on the same line as character
  /// `index`, in text view coordinates. A link that wraps is measured on
  /// that one line, so whatever hangs from it stays by the pointer.
  private func linkRect(_ span: Span, near index: Int) -> NSRect? {
    guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
      NSMaxRange(span.textRange) <= (textView.string as NSString).length
    else { return nil }
    let glyphs = layoutManager.glyphRange(forCharacterRange: span.textRange, actualCharacterRange: nil)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return nil }
    let character = NSLocationInRange(index, span.textRange) ? index : span.textRange.location
    let glyph = min(max(layoutManager.glyphIndexForCharacter(at: character), glyphs.location), NSMaxRange(glyphs) - 1)
    var line = NSRange(location: NSNotFound, length: 0)
    layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
    var onLine = line.location == NSNotFound ? glyphs : NSIntersectionRange(glyphs, line)
    if onLine.length == 0 { onLine = glyphs }
    let origin = textView.textContainerOrigin
    return layoutManager.boundingRect(forGlyphRange: onLine, in: container).offsetBy(dx: origin.x, dy: origin.y)
  }

  private func mouseIsOverLinkOrBubble() -> Bool {
    guard let textView, let window = textView.window else { return false }
    let point = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard textView.visibleRect.contains(point) else { return false }
    if !bubble.isHidden, bubble.frame.contains(point) { return true }
    return bubbleSpan != nil && hoveredLink(at: point)?.span == bubbleSpan
  }

  // MARK: Hover bubble

  /// Returns true while the mouse is over the bubble, so the text view
  /// shows an arrow there rather than its I-beam.
  private func mouseMoved(_ event: NSEvent) -> Bool {
    guard let textView, !editor.isVisible else { return false }
    let point = textView.convert(event.locationInWindow, from: nil)
    if !bubble.isHidden, bubble.frame.contains(point) {
      cancelHide()
      return true
    }
    guard let (span, index) = hoveredLink(at: point) else {
      cancelShow()
      scheduleHide()
      return false
    }
    if span == bubbleSpan, !bubble.isHidden {
      cancelShow()
      cancelHide()
      return false
    }
    // Over another link: the current bubble (if any) stays until this one
    // has been rested on long enough.
    cancelHide()
    pendingAnchor = index
    if span != pendingSpan || showTimer == nil {
      pendingSpan = span
      showTimer?.invalidate()
      showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in
        guard let self else { return }
        let anchor = self.pendingAnchor
        self.showTimer = nil
        self.pendingSpan = nil
        self.show(for: anchor)
      }
    }
    return false
  }

  /// Shows the bubble for the link at character `index` right away, below
  /// the line that character is on.
  func show(for index: Int) {
    guard let textView, textView.window != nil, !editor.isVisible,
      let span = Self.span(in: textView.string, at: index)
    else { return }
    cancelShow()
    cancelHide()
    bubbleSpan = span
    bubbleAnchor = index
    bubble.setURL(span.url)
    // Above the code block controls, which are subviews too.
    if textView.subviews.last !== bubble {
      textView.addSubview(bubble, positioned: .above, relativeTo: nil)
    }
    guard positionBubble() else {
      hideBubble(animated: false)
      return
    }
    guard bubble.isHidden else { return }
    fadeGeneration += 1
    bubble.alphaValue = 0
    bubble.isHidden = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      bubble.animator().alphaValue = 1
    }
  }

  /// The part of the note the text shows in: the visible rect, less the
  /// header and bottom bar that float over it.
  private func visibleTextRect() -> NSRect {
    guard let textView else { return .zero }
    var visible = textView.visibleRect
    if let insets = textView.enclosingScrollView?.contentInsets {
      visible.origin.y += insets.top
      visible.size.height -= insets.top + insets.bottom
    }
    return visible
  }

  /// Just below the hovered line of the link, or above it when there is no
  /// room below; always inside the visible part of the note (clear of the
  /// bottom bar).
  @discardableResult
  private func positionBubble() -> Bool {
    guard let span = bubbleSpan, let rect = linkRect(span, near: bubbleAnchor) else { return false }
    let visible = visibleTextRect()
    // Never wider than the note: a long address truncates in its middle
    // rather than pushing the bubble's start off the left edge.
    let size = bubble.size(fitting: visible.width - 16)
    var origin = NSPoint(x: rect.minX - 6, y: rect.maxY + 2)
    if origin.y + size.height > visible.maxY - 4 {
      origin.y = rect.minY - 2 - size.height
    }
    origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
    origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
    let frame = NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    if bubble.frame != frame {
      bubble.frame = frame
      bubble.needsLayout = true
    }
    return true
  }

  private func cancelShow() {
    showTimer?.invalidate()
    showTimer = nil
    pendingSpan = nil
  }

  private func scheduleHide() {
    guard !bubble.isHidden, !fadingOut, hideTimer == nil else { return }
    hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideDelay, repeats: false) { [weak self] _ in
      guard let self else { return }
      self.hideTimer = nil
      if self.mouseIsOverLinkOrBubble() { return }
      self.hideBubble(animated: true)
    }
  }

  private func cancelHide() {
    hideTimer?.invalidate()
    hideTimer = nil
    guard fadingOut else { return }
    // Came back while it was fading: bring it back.
    fadingOut = false
    fadeGeneration += 1
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.08
      bubble.animator().alphaValue = 1
    }
  }

  private func hideBubble(animated: Bool) {
    cancelShow()
    hideTimer?.invalidate()
    hideTimer = nil
    guard !bubble.isHidden else { return }
    fadeGeneration += 1
    let generation = fadeGeneration
    guard animated else {
      fadingOut = false
      bubble.isHidden = true
      bubble.alphaValue = 1
      bubbleSpan = nil
      return
    }
    fadingOut = true
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.15
      bubble.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      guard let self, self.fadeGeneration == generation else { return }
      self.fadingOut = false
      self.bubble.isHidden = true
      self.bubbleSpan = nil
    })
  }

  /// Opens it as a click on the link would (the default browser).
  private func openBubbleLink() {
    guard let textView, let span = bubbleSpan, let url = URL(string: span.url) else {
      NSSound.beep()
      return
    }
    let index = bubbleAnchor
    hideBubble(animated: false)
    textView.clicked(onLink: url, at: index)
  }

  private func editBubbleLink() {
    guard bubbleSpan != nil else { return }
    beginEditing(at: bubbleAnchor)
  }

  private func copyBubbleLink() {
    guard let span = bubbleSpan else { return }
    Self.copy(span.url)
    bubble.flashCopied()
  }

  private static func copy(_ url: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url, forType: .string)
  }

  // MARK: Context menu

  private func menu(for event: NSEvent) -> NSMenu? {
    guard let textView else { return nil }
    let point = textView.convert(event.locationInWindow, from: nil)
    guard let index = linkIndex(at: point, webOnly: false), let span = Self.span(in: textView.string, at: index)
    else { return nil }
    hideBubble(animated: false)
    let menu = NSMenu()
    menu.autoenablesItems = false
    func add(_ title: String, _ action: Selector, enabled: Bool = true) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      // The clicked character, so the editor opens by the clicked line.
      item.representedObject = index
      item.isEnabled = enabled
      menu.addItem(item)
    }
    add("Edit Link…", #selector(editLinkItem(_:)), enabled: textView.isEditable)
    add("Copy Link", #selector(copyLinkItem(_:)))
    add("Open Link", #selector(openLinkItem(_:)))
    if !span.isBare {
      add("Remove Link", #selector(removeLinkItem(_:)), enabled: textView.isEditable)
    }
    return menu
  }

  private func span(for item: NSMenuItem) -> Span? {
    guard let textView, let index = item.representedObject as? Int else { return nil }
    return Self.span(in: textView.string, at: index)
  }

  @objc private func editLinkItem(_ item: NSMenuItem) {
    guard span(for: item) != nil, let index = item.representedObject as? Int else { return }
    beginEditing(at: index)
  }

  @objc private func copyLinkItem(_ item: NSMenuItem) {
    guard let span = span(for: item) else { return }
    Self.copy(span.url)
  }

  /// Opens it as a click on the link would.
  @objc private func openLinkItem(_ item: NSMenuItem) {
    guard let textView, let span = span(for: item), let url = URL(string: span.url) else {
      NSSound.beep()
      return
    }
    textView.clicked(onLink: url, at: span.textRange.location)
  }

  @objc private func removeLinkItem(_ item: NSMenuItem) {
    guard let span = span(for: item) else { return }
    rewriteLink(at: span.textRange.location, text: "", url: "", actionName: "Remove Link")
  }

  // MARK: Editing

  /// Opens the editor under the line of the link that character `index`
  /// is on.
  func beginEditing(at index: Int) {
    guard let textView, let window = textView.window, textView.isEditable else {
      NSSound.beep()
      return
    }
    guard let span = Self.span(in: textView.string, at: index), let anchor = editorAnchor(span, near: index)
    else { return }
    hideBubble(animated: false)
    editingSpan = span
    editingAnchor = index
    editor.show(below: anchor, in: window, text: span.text, url: span.url) { [weak self] text, url in
      guard let self, let textView = self.textView,
        Self.span(in: textView.string, at: span.textRange.location) == span
      else { return }
      self.rewriteLink(at: span.textRange.location, text: text, url: url, actionName: "Edit Link")
    }
  }

  /// The link's line in screen coordinates, kept inside the visible part of
  /// the note so the editor stays by the note when the link scrolls away.
  private func editorAnchor(_ span: Span, near index: Int) -> NSRect? {
    guard let textView, let window = textView.window, var rect = linkRect(span, near: index) else { return nil }
    let visible = visibleTextRect()
    rect.origin.y = max(min(rect.minY, visible.maxY - rect.height), visible.minY)
    return window.convertToScreen(textView.convert(rect, to: nil))
  }

  /// Moves the open editor to follow its link after a scroll or re-wrap.
  /// It stays where it is when the link can no longer be found.
  private func positionEditor() {
    guard let span = editingSpan, let anchor = editorAnchor(span, near: editingAnchor) else { return }
    editor.move(below: anchor)
  }

  /// Rewrites the link at `index` as one undoable change. The caret stays
  /// where it was unless it was inside the link, which puts it after it.
  /// A rewrite that changes nothing leaves the text, the caret and the undo
  /// stack alone.
  func rewriteLink(at index: Int, text: String, url: String, actionName: String = "Edit Link") {
    guard let textView, textView.isEditable,
      var edit = Self.rewrite(in: textView.string, at: index, text: text, url: url),
      (textView.string as NSString).substring(with: edit.range) != edit.replacement
    else { return }
    let caret = textView.selectedRange()
    let delta = (edit.replacement as NSString).length - edit.range.length
    if NSMaxRange(caret) <= edit.range.location {
      edit = ListEditing.Edit(range: edit.range, replacement: edit.replacement, cursor: caret.location, selectionLength: caret.length)
    } else if caret.location >= NSMaxRange(edit.range) {
      edit = ListEditing.Edit(
        range: edit.range, replacement: edit.replacement, cursor: caret.location + delta, selectionLength: caret.length)
    }
    textView.window?.makeFirstResponder(textView)
    textView.apply(edit)
    textView.undoManager?.setActionName(actionName)
  }
}

// MARK: - Hover bubble

/// The address in secondary text with Open, Edit and Copy buttons, in an
/// opaque capsule tinted like the title bar pill. A subview of the text
/// view, so it scrolls with the text; clicks on it never reach the text.
final class LinkBubble: NSView {
  var onOpen: (() -> Void)?
  var onEdit: (() -> Void)?
  var onCopy: (() -> Void)?
  private let wash = PillView()
  private let label = NSTextField(labelWithString: "")
  private let openButton = ChromeButton(symbol: "arrow.up.right.square", pointSize: 12, label: "Open")
  private let editButton = ChromeButton(symbol: "pencil", pointSize: 12, label: "Edit")
  private let copyButton = ChromeButton(symbol: "doc.on.doc", pointSize: 12, label: "Copy")
  private var buttons: [ChromeButton] { [openButton, editButton, copyButton] }
  /// The address's own width (up to maxURLWidth), and the width it gets
  /// after `size(fitting:)`.
  private var naturalLabelWidth: CGFloat = 0
  private var labelWidth: CGFloat = 0
  private var copyReset: DispatchWorkItem?

  static let height: CGFloat = 32
  static let maxURLWidth: CGFloat = 320
  private static let buttonSize: CGFloat = 26
  private static let leading: CGFloat = 12
  private static let gap: CGFloat = 6
  private static let buttonGap: CGFloat = 2
  private static let trailing: CGFloat = 3
  private static let copyImage = symbol("doc.on.doc")
  private static let copiedImage = symbol("checkmark")

  private static func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
  }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Self.height))
    wantsLayer = true
    autoresizingMask = []
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 8
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    self.shadow = shadow

    addSubview(wash)
    label.font = NSFont.systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.usesSingleLineMode = true
    label.maximumNumberOfLines = 1
    addSubview(label)
    let actions = [#selector(openClicked), #selector(editClicked), #selector(copyClicked)]
    for (button, action) in zip(buttons, actions) {
      button.cornerRadius = Self.buttonSize / 2
      button.contentTintColor = .secondaryLabelColor
      button.target = self
      button.action = action
      addSubview(button)
    }
    setAccessibilityRole(.group)
    setAccessibilityLabel("Link")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var acceptsFirstResponder: Bool { false }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  // Swallowed, so a click on the bubble never moves the note's caret.
  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

  /// Everything but the address: padding, gap and the buttons.
  private var chromeWidth: CGFloat {
    Self.leading + Self.gap + Self.buttonSize * CGFloat(buttons.count)
      + Self.buttonGap * CGFloat(buttons.count - 1) + Self.trailing
  }

  /// The bubble's size when it may be at most `maxWidth` wide: the address
  /// gives up width first (it truncates in the middle), the buttons never.
  func size(fitting maxWidth: CGFloat) -> NSSize {
    let width = max(0, min(naturalLabelWidth, floor(maxWidth - chromeWidth)))
    if width != labelWidth {
      labelWidth = width
      needsLayout = true
    }
    return NSSize(width: chromeWidth + labelWidth, height: Self.height)
  }

  func setURL(_ url: String) {
    guard url != label.stringValue else { return }
    label.stringValue = url
    label.toolTip = url
    let natural = (url as NSString).size(withAttributes: [.font: label.font!]).width
    naturalLabelWidth = min(ceil(natural) + 4, Self.maxURLWidth)
    labelWidth = naturalLabelWidth
    copyReset?.cancel()
    copyButton.image = Self.copyImage
    needsLayout = true
  }

  /// Swaps the copy icon for a checkmark briefly.
  func flashCopied() {
    copyReset?.cancel()
    copyButton.image = Self.copiedImage
    let reset = DispatchWorkItem { [weak self] in self?.copyButton.image = Self.copyImage }
    copyReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
  }

  override func layout() {
    super.layout()
    wash.frame = bounds
    let labelHeight = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(
      x: Self.leading, y: ((bounds.height - labelHeight) / 2).rounded(), width: labelWidth, height: labelHeight)
    let buttonY = ((bounds.height - Self.buttonSize) / 2).rounded()
    var x = label.frame.maxX + Self.gap
    for button in buttons {
      button.frame = NSRect(x: x, y: buttonY, width: Self.buttonSize, height: Self.buttonSize)
      x = button.frame.maxX + Self.buttonGap
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    // An opaque base, so the note never shows through; the pill on top
    // gives it the title bar pill's tint.
    let radius = (bounds.height - 1) / 2
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    NSColor.windowBackgroundColor.setFill()
    path.fill()
    ChromeColors.border.setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  @objc private func openClicked() { onOpen?() }
  @objc private func editClicked() { onEdit?() }
  @objc private func copyClicked() { onCopy?() }
}

// MARK: - Link editor

/// "Text" and "URL" fields in a small child panel under the link, styled
/// like the language picker. Return or Save applies, Tab moves between the
/// fields, Escape or clicking elsewhere cancels.
final class LinkEditor: NSObject, NSTextFieldDelegate {
  private let panel: PalettePanel
  private let textField = NSTextField(string: "")
  private let urlField = NSTextField(string: "")
  private let saveButton = NSButton(title: "Save", target: nil, action: nil)
  private var save: ((String, String) -> Void)?
  private static let width: CGFloat = 340
  private static let height: CGFloat = 116

  override init() {
    panel = PalettePanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
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

    let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
    root.material = .popover
    root.blendingMode = .behindWindow
    root.state = .active
    root.autoresizingMask = [.width, .height]
    panel.contentView = root

    let fieldX: CGFloat = 52
    let rows: [(String, NSTextField, String, CGFloat)] = [
      ("Text", textField, "Link text", Self.height - 14 - 24),
      ("URL", urlField, "https://", Self.height - 14 - 24 - 8 - 24),
    ]
    for (title, field, placeholder, y) in rows {
      let caption = NSTextField(labelWithString: title)
      caption.font = NSFont.systemFont(ofSize: 12, weight: .medium)
      caption.textColor = .secondaryLabelColor
      caption.alignment = .right
      caption.frame = NSRect(x: 8, y: y + 4, width: fieldX - 16, height: 16)
      root.addSubview(caption)

      field.placeholderString = placeholder
      field.font = NSFont.systemFont(ofSize: 13)
      field.isBezeled = true
      field.bezelStyle = .roundedBezel
      field.usesSingleLineMode = true
      field.lineBreakMode = .byTruncatingTail
      field.cell?.isScrollable = true
      field.delegate = self
      field.frame = NSRect(x: fieldX, y: y, width: Self.width - fieldX - 14, height: 24)
      root.addSubview(field)
    }

    saveButton.bezelStyle = .rounded
    saveButton.keyEquivalent = "\r"
    saveButton.refusesFirstResponder = true
    saveButton.target = self
    saveButton.action = #selector(saveClicked)
    saveButton.frame = NSRect(x: Self.width - 14 - 76 + 6, y: 8, width: 76, height: 32)
    root.addSubview(saveButton)

    NotificationCenter.default.addObserver(
      self, selector: #selector(resignedKey), name: NSWindow.didResignKeyNotification, object: panel)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  var isVisible: Bool { panel.isVisible }

  /// Shows the editor under `anchor` (screen coordinates), or above it
  /// when the screen ends first. `save` gets the two fields as typed.
  func show(below anchor: NSRect, in parent: NSWindow, text: String, url: String, save: @escaping (String, String) -> Void) {
    self.save = save
    textField.stringValue = text
    urlField.stringValue = url
    panel.setFrame(frame(below: anchor, on: parent.screen), display: false)
    if panel.parent !== parent {
      panel.parent?.removeChildWindow(panel)
      parent.addChildWindow(panel, ordered: .above)
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(urlField)
  }

  /// Moves the open editor to a new `anchor` (screen coordinates), keeping
  /// what has been typed.
  func move(below anchor: NSRect) {
    guard panel.isVisible else { return }
    let frame = frame(below: anchor, on: panel.parent?.screen)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
  }

  private func frame(below anchor: NSRect, on screen: NSScreen?) -> NSRect {
    var frame = NSRect(x: anchor.minX - 8, y: anchor.minY - 6 - Self.height, width: Self.width, height: Self.height)
    if let visible = (screen ?? NSScreen.main)?.visibleFrame {
      if frame.minY < visible.minY { frame.origin.y = anchor.maxY + 6 }
      frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - Self.width - 4)
    }
    return NSRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width, height: frame.height)
  }

  /// Closes the editor without saving; `restoreFocus` hands the keyboard
  /// back to the note window (not wanted when the user clicked elsewhere).
  func hide(restoreFocus: Bool) {
    save = nil
    guard panel.isVisible else { return }
    let parent = panel.parent
    parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    if restoreFocus, let parent, parent.isVisible { parent.makeKey() }
  }

  @objc private func resignedKey(_ notification: Notification) {
    hide(restoreFocus: false)
  }

  @objc private func saveClicked() {
    commit()
  }

  private func commit() {
    let save = self.save
    let text = textField.stringValue
    let url = urlField.stringValue
    hide(restoreFocus: true)
    save?(text, url)
  }

  // NSTextFieldDelegate

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      commit()
    case #selector(NSResponder.cancelOperation(_:)):
      hide(restoreFocus: true)
    case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
      panel.makeFirstResponder(control === textField ? urlField : textField)
    default:
      return false
    }
    return true
  }
}
