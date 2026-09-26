import AppKit
import Foundation

// MARK: - Text view with the Raycast Notes key bindings

final class NoteTextView: NSTextView {
  var onCommand: ((String) -> Bool)?

  // Code block cards reach into the inset margin, outside the clip the
  // layout manager draws in, so the view paints them with its background.
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    (layoutManager as? TaskBoxLayoutManager)?.drawTaskBoxes(in: dirtyRect, origin: textContainerOrigin)
  }

  // MARK: Code blocks behave as one component
  //
  // The caret never rests on a fence line: clicks and arrow keys that land
  // there move into the body or past the block, Backspace on an empty block
  // removes the whole block, and the newline before the closing fence
  // cannot be deleted forward.

  /// Set while a caret is placed programmatically (loading a note, arrow
  /// moves that inspect where the caret landed) so fence lines are not
  /// relocated or edited underneath.
  var suppressFenceRelocation = false
  /// Set while a note loads: the caret may still be redirected off a fence,
  /// but nothing is edited to make room for it.
  var suppressFenceEdits = false

  private func codeBlock(containing location: Int) -> Markdown.CodeBlock? {
    Markdown.codeBlocks(in: string).first { NSLocationInRange(location, $0.range) || location == NSMaxRange($0.range) && $0.closingLine != nil }
  }

  private enum FenceHit { case opening(Markdown.CodeBlock), closing(Markdown.CodeBlock) }

  private func fenceLine(at location: Int) -> FenceHit? {
    guard let block = codeBlock(containing: location) else { return nil }
    if NSLocationInRange(location, block.openingLine) || location == NSMaxRange(block.openingLine) && block.body.length == 0 && block.closingLine == nil {
      return .opening(block)
    }
    if let closing = block.closingLine, NSLocationInRange(location, closing) || location == NSMaxRange(closing) && NSMaxRange(closing) == (string as NSString).length && !string.hasSuffix("\n") {
      return .closing(block)
    }
    return nil
  }

  override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
    if !suppressFenceRelocation, !stillSelecting, ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0,
      let hit = fenceLine(at: range.location) {
      var target: Int
      switch hit {
      case .opening(let block):
        target = block.body.location
      case .closing(let block):
        // The footer belongs to the block: land at the end of its last line.
        target = lastBodyPosition(of: block)
      }
      // A closed block with no body line has nowhere valid to put the
      // caret; give it an empty line first (deferred: no edits from
      // inside a selection change), but only for a real interaction.
      if let block = codeBlock(containing: target), block.closingLine != nil, block.body.length == 0,
        target == block.body.location {
        target = block.openingLine.location
        if !suppressFenceEdits, window?.firstResponder === self {
          DispatchQueue.main.async { [weak self] in self?.insertBodyLine(into: block) }
        }
      }
      super.setSelectedRanges([NSValue(range: NSRange(location: target, length: 0))], affinity: affinity, stillSelecting: stillSelecting)
      return
    }
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
  }

  /// End of the block's last body line (before its newline).
  private func lastBodyPosition(of block: Markdown.CodeBlock) -> Int {
    let ns = string as NSString
    guard block.body.length > 0 else { return block.body.location }
    let end = NSMaxRange(block.body)
    return ns.substring(with: block.body).hasSuffix("\n") ? end - 1 : end
  }

  /// Where the caret is after `move`, with fence relocation switched off
  /// so the caller can see whether it landed on a fence line.
  private func rawMove(_ move: () -> Void) -> Int {
    suppressFenceRelocation = true
    defer { suppressFenceRelocation = false }
    move()
    return selectedRange().location
  }

  private func insertBodyLine(into block: Markdown.CodeBlock) {
    guard let current = codeBlock(containing: block.openingLine.location), current.closingLine != nil, current.body.length == 0 else { return }
    let at = NSRange(location: current.body.location, length: 0)
    guard shouldChangeText(in: at, replacementString: "\n") else { return }
    textStorage?.replaceCharacters(in: at, with: "\n")
    didChangeText()
    setSelectedRange(at)
  }

  override func moveDown(_ sender: Any?) {
    let before = selectedRange().location
    let ns = string as NSString
    let landed = rawMove { super.moveDown(sender) }
    // Landed on a hidden fence line: step over it.
    if case .opening(let block)? = fenceLine(at: landed) {
      setSelectedRange(NSRange(location: block.body.length > 0 ? block.body.location : block.openingLine.location, length: 0))
      return
    }
    // Arrow down out of the last body line leaves the block; add a line
    // after it when the block ends the note.
    guard case .closing(let block)? = fenceLine(at: landed), let closing = block.closingLine,
      NSLocationInRange(before, block.body) || before == block.body.location
    else { return }
    let end = NSMaxRange(closing)
    if end < ns.length {
      setSelectedRange(NSRange(location: end, length: 0))
    } else if ns.hasSuffix("\n") {
      setSelectedRange(NSRange(location: ns.length, length: 0))
    } else if shouldChangeText(in: NSRange(location: ns.length, length: 0), replacementString: "\n") {
      textStorage?.replaceCharacters(in: NSRange(location: ns.length, length: 0), with: "\n")
      didChangeText()
      setSelectedRange(NSRange(location: ns.length + 1, length: 0))
    }
  }

  override func moveUp(_ sender: Any?) {
    let landed = rawMove { super.moveUp(sender) }
    // Arrow up onto the closing fence (from the line below the block):
    // enter the block at the end of its last line.
    if case .closing(let block)? = fenceLine(at: landed) {
      setSelectedRange(NSRange(location: lastBodyPosition(of: block), length: 0))
      return
    }
    // Arrow up onto the opening fence (from the first body line): skip it.
    guard case .opening(let block)? = fenceLine(at: landed) else { return }
    let start = block.openingLine.location
    if start > 0 {
      setSelectedRange(NSRange(location: start - 1, length: 0))
    } else {
      setSelectedRange(NSRange(location: block.body.location, length: 0))
    }
  }

  override func deleteForward(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length == 0, let block = codeBlock(containing: selection.location), let closing = block.closingLine,
      selection.location + 1 == closing.location {
      return  // the newline before the closing fence belongs to the block
    }
    super.deleteForward(sender)
  }

  /// Backspace at the start of an empty code block removes the block.
  private func deleteEmptyCodeBlock(at location: Int) -> Bool {
    guard let block = codeBlock(containing: location), location == block.body.location,
      (string as NSString).substring(with: block.body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    let ns = string as NSString
    var range = NSRange(location: block.openingLine.location, length: NSMaxRange(block.closingLine ?? block.range) - block.openingLine.location)
    if NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range) - 1) != 0x0A {
      // closing fence without its own newline: also take the one that follows
      range.length += 1
    }
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: "") else { return true }
    textStorage?.replaceCharacters(in: range, with: "")
    setSelectedRange(NSRange(location: range.location, length: 0))
    didChangeText()
    breakUndoCoalescing()
    return true
  }

  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    (layoutManager as? TaskBoxLayoutManager)?.drawCodeCards(in: rect, origin: textContainerOrigin)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    // Editing keys act on the note only while it has focus, so the find
    // bar's field keeps its own ⌘V, ⌘A and so on (they reach it via the menu).
    let focused = window?.firstResponder === self

    if flags == [.command, .shift], key == "c" {
      return onCommand?("copy") == true
    }
    if flags == .control, key == "x" {
      return onCommand?("delete") == true
    }
    if flags == [.command, .shift], key == "z" {
      undoManager?.redo()
      return true
    }
    if focused, let format = Self.format(flags: flags, key: key, keyCode: event.keyCode) {
      apply(edit(for: format))
      return true
    }
    if flags == .command {
      switch key {
      case "z": undoManager?.undo(); return true
      case "x" where focused: cut(nil); return true
      case "c" where focused: copy(nil); return true
      case "v" where focused: paste(nil); return true
      case "a" where focused: selectAll(nil); return true
      default: break
      }
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

  // MARK: Formatting keys

  private enum Format {
    case wrap(String)
    case link
    case prefix(ListEditing.LinePrefix)
    case codeBlock
  }

  /// ⌥⌘ and ⇧⌘ digits go by key code: with Option or Shift held the
  /// characters differ by layout (⇧7 is "&" on US keyboards).
  private static func format(flags: NSEvent.ModifierFlags, key: String, keyCode: UInt16) -> Format? {
    if flags == .command {
      switch key {
      case "b": return .wrap("**")
      case "i": return .wrap("_")
      case "e": return .wrap("`")
      case "l": return .link
      default: return nil
      }
    }
    if flags == [.command, .shift] {
      if key == "s" { return .wrap("~~") }
      if key == "b" { return .prefix(.quote) }
      switch keyCode {
      case 26: return .prefix(.ordered)  // 7
      case 28: return .prefix(.bullet)  // 8
      case 25: return .prefix(.task)  // 9
      default: return nil
      }
    }
    if flags == [.command, .option] {
      switch keyCode {
      case 18: return .prefix(.heading(1))
      case 19: return .prefix(.heading(2))
      case 20: return .prefix(.heading(3))
      case 8: return .codeBlock  // c
      default: return nil
      }
    }
    return nil
  }

  private func edit(for format: Format) -> ListEditing.Edit {
    let text = string
    let selection = selectedRange()
    switch format {
    case .wrap(let marker): return ListEditing.toggleWrap(in: text, selection: selection, marker: marker)
    case .link: return ListEditing.link(in: text, selection: selection, url: nil)
    case .prefix(let prefix): return ListEditing.setLinePrefix(in: text, cursor: selection.location, prefix: prefix)
    case .codeBlock: return ListEditing.toggleCodeBlock(in: text, selection: selection)
    }
  }

  // MARK: Typing rules

  override func insertNewline(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length == 0, !hasMarkedText() {
      let text = string
      let edit = ListEditing.codeFence(in: text, cursor: selection.location) ?? ListEditing.newline(in: text, cursor: selection.location)
      if apply(edit) { return }
    }
    super.insertNewline(sender)
  }

  override func insertTab(_ sender: Any?) {
    if indentListItem(by: 1) { return }
    super.insertTab(sender)
  }

  override func insertBacktab(_ sender: Any?) {
    if indentListItem(by: -1) { return }
    super.insertBacktab(sender)
  }

  /// True when the key was used on a list item. An item that cannot move
  /// (the first in its list, or already at the top level) swallows the key
  /// rather than getting a literal tab typed into it.
  private func indentListItem(by delta: Int) -> Bool {
    guard !hasMarkedText() else { return false }
    let text = string
    let ns = text as NSString
    let selection = selectedRange()
    guard ns.substring(with: selection).rangeOfCharacter(from: .newlines) == nil else { return false }
    if apply(ListEditing.indent(in: text, cursor: selection.location, by: delta)) { return true }
    var lineStart = 0
    var contentsEnd = 0
    ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
    let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
    return ListEditing.parse(line: line) != nil && !ListEditing.insideFence(text, cursor: selection.location)
  }

  override func deleteBackward(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length == 0, !hasMarkedText() {
      if deleteEmptyCodeBlock(at: selection.location) { return }
      if let block = codeBlock(containing: selection.location), selection.location == block.body.location {
        return  // keep the opening fence; the block is one component
      }
      if apply(ListEditing.backspace(in: string, cursor: selection.location)) { return }
    }
    super.deleteBackward(sender)
  }

  /// The space goes in first as ordinary typing, then "[] " or "``` " is
  /// rewritten as a separate undo step, so ⌘Z gives back the literal text.
  /// `apply` edits the text storage directly, so this never re-enters.
  override func insertText(_ string: Any, replacementRange: NSRange) {
    super.insertText(string, replacementRange: replacementRange)
    let typed = (string as? String) ?? (string as? NSAttributedString)?.string
    // Programmatic replacements (the task box toggle) pass a non-empty range.
    guard typed == " ", replacementRange.location == NSNotFound || replacementRange.length == 0,
      !hasMarkedText()
    else { return }
    let selection = selectedRange()
    guard selection.length == 0 else { return }
    apply(ListEditing.afterSpace(in: self.string, cursor: selection.location))
  }

  /// Pasting a lone http(s) URL over selected text links the text.
  override func paste(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length > 0, let url = Self.pasteboardURL() {
      let text = string
      let selected = (text as NSString).substring(with: selection)
      let plainText = selected.rangeOfCharacter(from: .newlines) == nil && Self.webURL(selected) == nil
      if plainText, !ListEditing.insideFence(text, cursor: selection.location),
        apply(ListEditing.link(in: text, selection: selection, url: url)) {
        return
      }
    }
    super.paste(sender)
  }

  private static func pasteboardURL() -> String? {
    guard let pasted = NSPasteboard.general.string(forType: .string) else { return nil }
    return webURL(pasted.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// `text` when it is one http(s) URL with a host and no whitespace.
  private static func webURL(_ text: String) -> String? {
    let lower = text.lowercased()
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
      text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      let host = URL(string: text)?.host, !host.isEmpty
    else { return nil }
    return text
  }

  // MARK: Applying an edit

  /// Applies a ListEditing edit as one change with its own undo step.
  /// Returns false only when there was no edit, so callers fall back to
  /// the default behaviour.
  @discardableResult
  private func apply(_ edit: ListEditing.Edit?) -> Bool {
    guard let edit, let storage = textStorage else { return false }
    let ns = string as NSString
    guard NSMaxRange(edit.range) <= ns.length else { return false }
    let newLength = ns.length - edit.range.length + (edit.replacement as NSString).length
    let location = min(max(edit.cursor, 0), newLength)
    let selection = NSRange(location: location, length: min(edit.selectionLength, newLength - location))

    if ns.substring(with: edit.range) == edit.replacement {
      setSelectedRange(selection)
      return true
    }
    // Close the running typing group first so ⌘Z takes back just this rule,
    // and again after so the next keystrokes start a group of their own.
    breakUndoCoalescing()
    guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return true }
    storage.replaceCharacters(in: edit.range, with: edit.replacement)
    // Select before didChangeText so the restyle it triggers keeps this caret.
    setSelectedRange(selection)
    didChangeText()
    breakUndoCoalescing()
    if selectedRange() != selection { setSelectedRange(selection) }
    scrollRangeToVisible(selection)
    return true
  }
}
