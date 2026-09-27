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

  // MARK: Hidden markers are not editable
  //
  // Markdown markers (`**`, `_`, backticks, `# `, `- `...) are collapsed on
  // screen. The caret never rests inside one: it snaps to the run's edge
  // in the direction it was moving. Backspace and Delete look through a
  // run to the character beyond it, and a pair left empty disappears.

  private struct HiddenRun {
    let range: NSRange
    let role: Markdown.HiddenRole
  }

  /// The collapsed run covering character `index`, if any. Touching runs
  /// with different roles, or made of different marker characters (the
  /// `_` and `**` closers of `**a _b_**`), are reported separately.
  private func hiddenRun(at index: Int) -> HiddenRun? {
    guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
    var run = NSRange(location: NSNotFound, length: 0)
    guard let raw = storage.attribute(Markdown.hiddenRun, at: index, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) as? String,
      let role = Markdown.HiddenRole(rawValue: raw)
    else { return nil }
    if role != .line {
      let ns = string as NSString
      let marker = ns.character(at: index)
      var start = index
      while start > run.location, ns.character(at: start - 1) == marker { start -= 1 }
      var end = index + 1
      while end < NSMaxRange(run), ns.character(at: end) == marker { end += 1 }
      run = NSRange(location: start, length: end - start)
    }
    return HiddenRun(range: run, role: role)
  }

  /// The collapsed run that `location` is strictly inside, if any.
  private func hiddenRun(strictlyContaining location: Int) -> NSRange? {
    guard location > 0, let run = hiddenRun(at: location), run.range.location < location else { return nil }
    return run.range
  }

  /// The collapsed run that ends exactly at `location`, if any.
  private func hiddenRun(endingAt location: Int) -> HiddenRun? {
    guard location > 0, let run = hiddenRun(at: location - 1), NSMaxRange(run.range) == location else { return nil }
    return run
  }

  /// The collapsed run that starts exactly at `location`, if any.
  private func hiddenRun(startingAt location: Int) -> HiddenRun? {
    guard let run = hiddenRun(at: location), run.range.location == location else { return nil }
    return run
  }

  /// The inline marker runs inside `range`, in order, split the way
  /// `hiddenRun(at:)` splits them: by role and by marker character, so the
  /// `_**` closers of `**a _b_**` are two runs.
  private func markerRuns(in range: NSRange) -> [HiddenRun] {
    guard let storage = textStorage, range.length > 0 else { return [] }
    var runs: [HiddenRun] = []
    storage.enumerateAttribute(Markdown.hiddenRun, in: range) { value, merged, _ in
      guard let raw = value as? String, let role = Markdown.HiddenRole(rawValue: raw), role != .line else { return }
      var index = merged.location
      while index < NSMaxRange(merged), let run = hiddenRun(at: index) {
        runs.append(run)
        index = NSMaxRange(run.range)
      }
    }
    return runs
  }

  /// The partner of an opening or closing run on the same line: the
  /// matching run with the same marker text, skipping nested pairs of that
  /// text in between (`_a **b** c_` pairs the underscores, not `_` with `**`).
  private func partner(of run: HiddenRun) -> NSRange? {
    guard run.role != .line else { return nil }
    let ns = string as NSString
    let line = ns.lineRange(for: run.range)
    let marker = ns.substring(with: run.range)
    let wanted: Markdown.HiddenRole = run.role == .open ? .close : .open
    let scan = run.role == .open
      ? NSRange(location: NSMaxRange(run.range), length: NSMaxRange(line) - NSMaxRange(run.range))
      : NSRange(location: line.location, length: run.range.location - line.location)
    var candidates = markerRuns(in: scan).filter { ns.substring(with: $0.range) == marker }
    if run.role == .close { candidates.reverse() }
    var depth = 0
    for candidate in candidates {
      if candidate.role == wanted {
        if depth == 0 { return candidate.range }
        depth -= 1
      } else {
        depth += 1
      }
    }
    return nil
  }

  /// A selection about to be replaced grows to cover any marker run it
  /// touches and that run's partner, so no half of a pair survives alone.
  private func selectionCoveringPairs(_ selection: NSRange) -> NSRange {
    guard selection.length > 0 else { return selection }
    var result = selection
    var changed = true
    while changed {
      changed = false
      for run in markerRuns(in: result) {
        for extra in [run.range, partner(of: run)].compactMap({ $0 }) {
          let union = NSUnionRange(result, extra)
          if union != result { result = union; changed = true }
        }
      }
    }
    return result
  }

  /// Deletes the visible character that ends at `location`, or nothing at
  /// a line start. When it was the only content of a pair, the pair's
  /// markers go with it. Returns the range that was removed.
  private func deleteVisibleCharacter(before location: Int) -> NSRange? {
    guard let storage = textStorage else { return nil }
    let ns = string as NSString
    guard location > ns.lineRange(for: NSRange(location: location, length: 0)).location else { return nil }
    var remove = ns.rangeOfComposedCharacterSequence(at: location - 1)
    if let opener = hiddenRun(endingAt: remove.location), opener.role == .open,
      let closer = hiddenRun(startingAt: location), closer.role == .close
    {
      remove = NSRange(location: opener.range.location, length: NSMaxRange(closer.range) - opener.range.location)
    }
    guard shouldChangeText(in: remove, replacementString: "") else { return nil }
    storage.replaceCharacters(in: remove, with: "")
    didChangeText()
    return remove
  }

  private var lastCaret = 0

  /// Removes an empty marker pair (`****`, `__`...) touching `location`
  /// after a deletion emptied it.
  private func removeEmptyPair(around location: Int) {
    let ns = string as NSString
    let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
    for match in Markdown.emptyPair.matches(in: string, range: line).reversed()
    where match.range.location <= location && location <= NSMaxRange(match.range) {
      guard shouldChangeText(in: match.range, replacementString: "") else { return }
      textStorage?.replaceCharacters(in: match.range, with: "")
      didChangeText()
      setSelectedRange(NSRange(location: match.range.location, length: 0))
      return
    }
  }

  override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
    defer { lastCaret = selectedRange().location }
    // Every way out of here (including a caret relocated off a marker or
    // fence line) tells the slash menu where the caret ended up.
    defer { if slashMenuIsOpen, !stillSelecting { syncSlashMenu(caretMoved: true) } }
    if !stillSelecting, ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0,
      let run = hiddenRun(strictlyContaining: range.location) {
      let forward = range.location >= lastCaret
      let target = forward ? NSMaxRange(run) : run.location
      super.setSelectedRanges([NSValue(range: NSRange(location: target, length: 0))], affinity: affinity, stillSelecting: stillSelecting)
      return
    }
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
    if selection.length > 0 {
      setSelectedRange(selectionCoveringPairs(selection))
      super.deleteForward(sender)
      return
    }
    if let run = hiddenRun(startingAt: selection.location) {
      // Look through the marker: delete the first character after it.
      let after = NSMaxRange(run.range)
      if after >= (string as NSString).length || hiddenRun(startingAt: after)?.role == .close {
        // Nothing but the pair itself: remove it.
        removeEmptyPair(around: selection.location)
        return
      }
      setSelectedRange(NSRange(location: after, length: 0))
      super.deleteForward(sender)
      removeEmptyPair(around: selectedRange().location)
      return
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
    (layoutManager as? TaskBoxLayoutManager)?.drawQuoteBars(in: rect, origin: textContainerOrigin)
    (layoutManager as? TaskBoxLayoutManager)?.drawCalloutBoxes(in: rect, origin: textContainerOrigin)
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
      // A held key repeats; without a confirmation each repeat would
      // trash the next note, so only the first press counts.
      if event.isARepeat { return true }
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

  // MARK: Link hover and context menu (LinkController in Links.swift)

  /// Returns true when the mouse is over the link bubble (arrow cursor).
  var onMouseMoved: ((NSEvent) -> Bool)?
  var onMouseExited: (() -> Void)?
  /// A menu for a right-click on a link; nil elsewhere.
  var linkMenu: ((NSEvent) -> NSMenu?)?
  private var hoverArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    if onMouseMoved?(event) == true {
      NSCursor.arrow.set()
      return
    }
    super.mouseMoved(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    onMouseExited?()
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    linkMenu?(event) ?? super.menu(for: event)
  }

  override func keyDown(with event: NSEvent) {
    if slashMenuHandles(event) { return }
    if event.keyCode == 53 {  // escape
      _ = onCommand?("hide")
      return
    }
    super.keyDown(with: event)
  }

  // MARK: Formatting keys

  enum Format {
    case wrap(String)
    case link
    case prefix(ListEditing.LinePrefix)
    case codeBlock
    /// Plain text: drops the line's block prefix, if any.
    case plain
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
      case 21: return .prefix(.heading(4))
      case 8: return .codeBlock  // c
      default: return nil
      }
    }
    return nil
  }

  /// Runs a formatting edit as if its key had been pressed (the ⌘K and
  /// "T" button formatting pickers use this).
  func applyFormat(_ format: Format) {
    apply(edit(for: format))
  }

  private func edit(for format: Format) -> ListEditing.Edit? {
    let text = string
    let selection = selectedRange()
    switch format {
    case .wrap(let marker): return ListEditing.toggleWrap(in: text, selection: selection, marker: marker)
    case .link: return ListEditing.link(in: text, selection: selection, url: nil)
    case .prefix(let prefix): return ListEditing.setLinePrefix(in: text, cursor: selection.location, prefix: prefix)
    case .codeBlock: return ListEditing.toggleCodeBlock(in: text, selection: selection)
    case .plain: return ListEditing.clearLinePrefix(in: text, cursor: selection.location)
    }
  }

  // MARK: Slash menu
  //
  // Typing "/" at the start of a line, or after a space, opens a menu of
  // block formats under the caret. Typing on filters it; up/down, return
  // and escape go to it while it is open. Picking an entry removes the
  // "/query" and applies the format to the line, as one undo step.

  private lazy var slashMenu = SlashMenu { [weak self] entry in self?.pickSlashEntry(entry) }
  /// Offset of the "/" that opened the menu, while it is open.
  private var slashStart: Int?

  var slashMenuIsOpen: Bool { slashStart != nil }

  private func openSlashMenu(at slash: Int) {
    slashStart = slash
    slashEnd = slash + 1
    slashTextLength = (string as NSString).length
    if slashMenu.superview == nil { addSubview(slashMenu, positioned: .above, relativeTo: nil) }
    slashMenu.filter("")
    positionSlashMenu()
    slashMenu.isHidden = false
  }

  func closeSlashMenu() {
    slashStart = nil
    slashMenu.isHidden = true
  }

  /// Keeps the menu in step with the text: filters on what follows the
  /// "/", closes when the caret leaves it or nothing matches.
  private func syncSlashMenu(caretMoved: Bool = false) {
    guard let slash = slashStart else { return }
    let ns = string as NSString
    let caret = selectedRange().location
    // The query is everything typed after the "/"; a caret that moves
    // anywhere else (even back inside the query) closes the menu, so a
    // pick never leaves part of the query behind.
    // An edit moves the caret before didChangeText runs; only a move
    // with the text unchanged counts as leaving.
    let moved = caretMoved && caret != slashEnd && ns.length == slashTextLength
    guard selectedRange().length == 0, slash < ns.length, ns.character(at: slash) == 0x2F, caret > slash, !moved else {
      closeSlashMenu()
      return
    }
    let query = ns.substring(with: NSRange(location: slash + 1, length: caret - slash - 1))
    guard query.rangeOfCharacter(from: .newlines) == nil, slashMenu.filter(query) else {
      closeSlashMenu()
      return
    }
    slashEnd = caret
    slashTextLength = ns.length
    positionSlashMenu()
  }

  /// End of the query (the caret) and the text length as of the last
  /// edit while the menu is open.
  private var slashEnd = 0
  private var slashTextLength = 0

  /// The menu hangs under the caret's line, at the caret, so it follows
  /// a query that grows or wraps.
  private func positionSlashMenu() {
    guard let layoutManager, let textContainer else { return }
    let caret = selectedRange().location
    let count = layoutManager.numberOfGlyphs
    let glyph = min(layoutManager.glyphIndexForCharacter(at: min(caret, max(0, string.utf16.count - 1))), max(0, count - 1))
    var anchor: NSRect
    if count == 0 {
      anchor = NSRect(x: 0, y: 0, width: 1, height: Markdown.baseFont.ascender - Markdown.baseFont.descender)
    } else if caret >= string.utf16.count, layoutManager.extraLineFragmentTextContainer != nil {
      anchor = NSRect(x: 0, y: layoutManager.extraLineFragmentRect.minY, width: 1, height: layoutManager.extraLineFragmentRect.height)
    } else {
      let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let x = fragment.minX + layoutManager.location(forGlyphAt: glyph).x
      anchor = NSRect(x: x, y: fragment.minY, width: 1, height: fragment.height)
    }
    anchor = anchor.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    let visible = enclosingScrollView?.documentVisibleRect ?? bounds
    slashMenu.place(below: anchor, within: visible, container: textContainer)
  }

  private func pickSlashEntry(_ entry: SlashMenu.Entry) {
    guard let slash = slashStart, let storage = textStorage else { return }
    let caret = selectedRange().location
    closeSlashMenu()
    let typed = NSRange(location: slash, length: max(0, caret - slash))
    guard NSMaxRange(typed) <= storage.length else { return }
    // The "/" began its own typing group (insertText breaks coalescing
    // just before it), so undoing takes the "/query" back out and leaves
    // the text as it was before the slash: usually one group, a few when
    // the query was edited (a deletion coalesces apart from typing). The
    // format then goes on as the only step above that: one ⌘Z after a
    // pick lands before the slash, ⇧⌘Z brings the pick back.
    let withoutQuery = (string as NSString).replacingCharacters(in: typed, with: "")
    if let undoManager, undoManager.canUndo {
      var steps = 0
      while string != withoutQuery, undoManager.canUndo, steps < 8,
        (string as NSString).length > (withoutQuery as NSString).length
      {
        undoManager.undo()
        steps += 1
      }
      if string == withoutQuery {
        setSelectedRange(NSRange(location: slash, length: 0))
        apply(edit(for: entry.format))
        return
      }
      // Not the groups we expected: put them back and take the plain route.
      while steps > 0, undoManager.canRedo {
        undoManager.redo()
        steps -= 1
      }
    }
    breakUndoCoalescing()
    undoManager?.beginUndoGrouping()
    if shouldChangeText(in: typed, replacementString: "") {
      storage.replaceCharacters(in: typed, with: "")
      setSelectedRange(NSRange(location: slash, length: 0))
      didChangeText()
    }
    apply(edit(for: entry.format))
    undoManager?.endUndoGrouping()
  }

  /// Keys the open menu takes before the text view sees them.
  private func slashMenuHandles(_ event: NSEvent) -> Bool {
    guard slashMenuIsOpen else { return false }
    switch event.keyCode {
    case 125: slashMenu.move(by: 1)
    case 126: slashMenu.move(by: -1)
    case 36, 48: slashMenu.pick()  // return, tab
    case 53: closeSlashMenu()  // escape
    default: return false
    }
    return true
  }

  override func didChangeText() {
    super.didChangeText()
    syncSlashMenu()
    // Quote bars and code cards reach outside the lines that changed.
    needsDisplay = true
  }

  // MARK: Typing rules

  override func insertNewline(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length == 0, !hasMarkedText() {
      let text = string
      let edit = ListEditing.codeFence(in: text, cursor: selection.location)
        ?? ListEditing.quoteNewline(in: text, cursor: selection.location)
        ?? ListEditing.newline(in: text, cursor: selection.location)
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
      // Deleting the only character of a pair from inside it (`k` in
      // `` `k` ``) takes the markers too, as deleting from after it does.
      if selection.location > 0, hiddenRun(endingAt: selection.location - 1)?.role == .open,
        hiddenRun(startingAt: selection.location)?.role == .close,
        let removed = deleteVisibleCharacter(before: selection.location)
      {
        setSelectedRange(NSRange(location: removed.location, length: 0))
        return
      }
      if let run = hiddenRun(endingAt: selection.location) {
        switch run.role {
        case .line:
          // A line-start marker (heading): remove the whole marker.
          guard shouldChangeText(in: run.range, replacementString: "") else { return }
          textStorage?.replaceCharacters(in: run.range, with: "")
          didChangeText()
          setSelectedRange(NSRange(location: run.range.location, length: 0))
        case .open, .close:
          if run.role == .close, hiddenRun(endingAt: run.range.location)?.role == .open {
            removeEmptyPair(around: run.range.location)  // caret after an empty pair
            return
          }
          // Look through the marker (and any markers touching it, as in
          // `**one****two**`) and delete the last visible character before
          // it. After a closing marker the caret stays inside the span;
          // after an opening one it stays just past the marker.
          var target = run.range.location
          while let touching = hiddenRun(endingAt: target), touching.role != .line {
            target = touching.range.location
          }
          guard let removed = deleteVisibleCharacter(before: target) else { return }
          let caret = run.role == .close ? removed.location : selection.location - removed.length
          setSelectedRange(NSRange(location: caret, length: 0))
        }
        return
      }
    } else if selection.length > 0, !hasMarkedText() {
      setSelectedRange(selectionCoveringPairs(selection))
    }
    super.deleteBackward(sender)
  }

  /// The space goes in first as ordinary typing, then "[] " or "``` " is
  /// rewritten as a separate undo step, so ⌘Z gives back the literal text.
  /// `apply` edits the text storage directly, so this never re-enters.
  override func insertText(_ string: Any, replacementRange: NSRange) {
    // Typing over a selection: the selection takes whole marker pairs with it.
    if replacementRange.location == NSNotFound, selectedRange().length > 0, !hasMarkedText() {
      setSelectedRange(selectionCoveringPairs(selectedRange()))
    }
    let typed = (string as? String) ?? (string as? NSAttributedString)?.string
    // A "/" at a line start or after a space opens the block menu. It is
    // decided before the insert, and starts a fresh undo group, so a pick
    // can take the whole "/query" back out with one undo.
    var opensMenu = false
    if typed == "/", !slashMenuIsOpen, !hasMarkedText(), replacementRange.location == NSNotFound {
      let pre = selectedRange()
      let ns = self.string as NSString
      let lineStart = ns.lineRange(for: NSRange(location: pre.location, length: 0)).location
      let previous = pre.location > lineStart ? ns.character(at: pre.location - 1) : 0x20
      opensMenu = (previous == 0x20 || previous == 0x09) && !ListEditing.insideFence(self.string, cursor: pre.location)
      if opensMenu { breakUndoCoalescing() }
    }
    super.insertText(string, replacementRange: replacementRange)
    if opensMenu {
      openSlashMenu(at: selectedRange().location - 1)
      return
    }
    // Programmatic replacements (the task box toggle) pass a non-empty range.
    guard replacementRange.location == NSNotFound || replacementRange.length == 0, !hasMarkedText() else { return }
    let selection = selectedRange()
    guard selection.length == 0 else { return }
    guard typed == " " else { return }
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
  /// the default behaviour. LinkController applies its rewrites through it.
  @discardableResult
  func apply(_ edit: ListEditing.Edit?) -> Bool {
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
