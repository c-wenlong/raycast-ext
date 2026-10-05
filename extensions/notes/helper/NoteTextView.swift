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
  /// Set while `apply` places the caret an editing rule chose, so the
  /// caret rules (hidden runs, line markers, folds) leave it alone.
  private var suppressCaretRules = false

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
    // fence line) tells the open picker where the caret ended up.
    defer { if pickerIsOpen, !stillSelecting { syncPicker(caretMoved: true) } }
    if !suppressCaretRules, !stillSelecting, ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0 {
      let target = caretTarget(range.location, forward: range.location >= lastCaret)
      if target != range.location {
        super.setSelectedRanges([NSValue(range: NSRange(location: target, length: 0))], affinity: affinity, stillSelecting: stillSelecting)
        return
      }
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

  /// Where a caret put at `location` really goes: never inside a hidden
  /// run (it snaps to the edge it was moving towards), never before a
  /// line's hidden block markers (it goes to their end, where the text
  /// starts, unless it was stepping left out of there, when it goes on to
  /// the line before), and never in a collapsed toggle's children (it
  /// goes past them, or back to the end of the title).
  private func caretTarget(_ location: Int, forward: Bool) -> Int {
    var target = location
    for _ in 0..<4 {
      let before = target
      if let run = hiddenRun(strictlyContaining: target) {
        target = forward ? NSMaxRange(run) : run.location
      }
      if let run = lineStartRun(at: target) {
        target = !forward && lastCaret == NSMaxRange(run) && target > 0 ? target - 1 : NSMaxRange(run)
      }
      if let fold = foldedRange(containingCaret: target) {
        let length = (string as NSString).length
        let after = NSMaxRange(fold)
        let visibleAfter = after < length || (length > 0 && [0x0A, 0x0D].contains((string as NSString).character(at: length - 1)))
        target = forward && visibleAfter ? after : max(0, fold.location - 1)
      }
      if target == before { break }
    }
    return target
  }

  /// The hidden block-marker run (indent, "| ", "> ", "# "...) that starts
  /// the line beginning at `location`, if any.
  private func lineStartRun(at location: Int) -> NSRange? {
    let ns = string as NSString
    guard location < ns.length, ns.lineRange(for: NSRange(location: location, length: 0)).location == location,
      let run = hiddenRun(startingAt: location), run.role == .line
    else { return nil }
    return run.range
  }

  /// The collapsed children a caret at `location` would sit in, if any.
  private func foldedRange(containingCaret location: Int) -> NSRange? {
    guard let storage = textStorage else { return nil }
    let ns = string as NSString
    var index = location
    if location == ns.length {
      // The very end: hidden when the last line is a folded child.
      guard location > 0, ![0x0A, 0x0D].contains(ns.character(at: location - 1)) else { return nil }
      index = location - 1
    }
    guard index >= 0, index < storage.length else { return nil }
    var fold = NSRange(location: NSNotFound, length: 0)
    guard storage.attribute(Markdown.folded, at: index, longestEffectiveRange: &fold, in: NSRange(location: 0, length: storage.length)) != nil
    else { return nil }
    return fold
  }

  /// Every run of collapsed children, in order.
  private var foldedRanges: [NSRange] {
    guard let storage = textStorage, storage.length > 0 else { return [] }
    var ranges: [NSRange] = []
    storage.enumerateAttribute(Markdown.folded, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      if value != nil { ranges.append(range) }
    }
    return ranges
  }

  /// The range deleting `selection` should remove: whole marker pairs,
  /// whole block markers, whole collapsed children (ListEditing.deletionRange).
  private func deletionRange(for selection: NSRange) -> NSRange {
    ListEditing.deletionRange(in: string, range: selectionCoveringPairs(selection), folded: foldedRanges)
  }

  // MARK: Toggles

  /// Runs the note's restyle (PanelController's, which also keeps the
  /// caret and the code block controls in step); Markdown.apply without one.
  var onRestyle: (() -> Void)?

  /// True when the toggle on the line holding `location` is collapsed.
  func isCollapsedToggle(at location: Int) -> Bool {
    guard let storage = textStorage, storage.length > 0 else { return false }
    let line = (string as NSString).lineRange(for: NSRange(location: min(location, storage.length), length: 0))
    var found = false
    storage.enumerateAttribute(Markdown.toggleCollapsed, in: line) { value, _, stop in
      if value != nil {
        found = true
        stop.pointee = true
      }
    }
    return found
  }

  /// Text set wholesale (loading a note) takes the old first character's
  /// attributes, a collapsed ">" included; a new text starts with every
  /// toggle open.
  override var string: String {
    get { super.string }
    set {
      textGeneration += 1
      super.string = newValue
      if let storage = textStorage, storage.length > 0 {
        storage.removeAttribute(Markdown.toggleCollapsed, range: NSRange(location: 0, length: storage.length))
      }
    }
  }

  /// Collapses or expands the toggle whose ">" is at `marker`. Nothing in
  /// the file changes: the state is an attribute on the ">" (kept while
  /// the window shows the note) and the children are only laid out away.
  func toggleCollapse(atMarker marker: Int) {
    guard let storage = textStorage, marker < storage.length,
      storage.attribute(Markdown.toggleChevron, at: marker, effectiveRange: nil) != nil
    else { return }
    let range = NSRange(location: marker, length: 1)
    if storage.attribute(Markdown.toggleCollapsed, at: marker, effectiveRange: nil) != nil {
      storage.removeAttribute(Markdown.toggleCollapsed, range: range)
    } else {
      storage.addAttribute(Markdown.toggleCollapsed, value: true, range: range)
    }
    if let onRestyle { onRestyle() } else { Markdown.apply(to: storage) }
    // A caret inside children that just folded goes to the end of the title.
    let caret = selectedRange()
    if caret.length == 0, let fold = foldedRange(containingCaret: caret.location) {
      setSelectedRange(NSRange(location: max(0, fold.location - 1), length: 0))
    } else if caret.length > 0, foldedRanges.contains(where: { NSIntersectionRange($0, caret).length > 0 }) {
      let title = (string as NSString).lineRange(for: NSRange(location: marker, length: 0))
      var end = 0
      (string as NSString).getLineStart(nil, end: nil, contentsEnd: &end, for: title)
      setSelectedRange(NSRange(location: end, length: 0))
    }
    needsDisplay = true
  }

  /// A key for each collapsed toggle, to collapse it again when the note
  /// is shown again: its title line's text and which toggle with that
  /// text it is (first, second...). Lines added or removed elsewhere, or
  /// toggles moved around, do not move a fold to another toggle; a toggle
  /// whose title changed loses its fold.
  func collapsedToggleKeys() -> Set<String> {
    guard let storage = textStorage, storage.length > 0 else { return [] }
    var keys = Set<String>()
    for (key, marker) in toggleKeys() where storage.attribute(Markdown.toggleCollapsed, at: marker, effectiveRange: nil) != nil {
      keys.insert(key)
    }
    return keys
  }

  /// Collapses the toggles these keys (from collapsedToggleKeys) name;
  /// keys that match no toggle are dropped. Restyle after.
  func restoreCollapsedToggles(_ keys: Set<String>) {
    guard let storage = textStorage, storage.length > 0 else { return }
    // Text set wholesale takes the old first character's attributes, a
    // collapsed ">" included; start from nothing collapsed.
    storage.removeAttribute(Markdown.toggleCollapsed, range: NSRange(location: 0, length: storage.length))
    for (key, marker) in toggleKeys() where keys.contains(key) {
      storage.addAttribute(Markdown.toggleCollapsed, value: true, range: NSRange(location: marker, length: 1))
    }
  }

  /// Every toggle's key and the location of its ">".
  private func toggleKeys() -> [(String, Int)] {
    let ns = string as NSString
    var seen: [String: Int] = [:]
    return ListEditing.toggleLayout(in: string).toggles.compactMap { toggle in
      let title = ns.substring(with: toggle.title)
      guard let unit = ListEditing.blockPrefix(of: title).unit(.toggle) else { return nil }
      let occurrence = seen[title, default: 0]
      seen[title] = occurrence + 1
      return ("\(occurrence)\u{1}\(title)", toggle.title.location + unit.range.location)
    }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
      let marker = (layoutManager as? TaskBoxLayoutManager)?.toggleMarker(at: point, origin: textContainerOrigin)
    {
      toggleCollapse(atMarker: marker)
      return
    }
    super.mouseDown(with: event)
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
      if !hasMarkedText() { setSelectedRange(deletionRange(for: selection)) }
      super.deleteForward(sender)
      return
    }
    if !hasMarkedText(), apply(ListEditing.dividerDelete(in: string, cursor: selection.location)) { return }
    if !hasMarkedText(), let edit = forwardJoin(at: selection.location) {
      apply(edit)
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

  /// Delete at the end of a line, when plain deletion of the line break
  /// would go wrong: at the end of a collapsed toggle's title it joins the
  /// line after the hidden children (or does nothing at the end of the
  /// note); before a line with hidden markers the markers go with the
  /// break, so they never land mid-line as raw text. Nil otherwise.
  private func forwardJoin(at location: Int) -> ListEditing.Edit? {
    let ns = string as NSString
    guard location < ns.length, [0x0A, 0x0D].contains(ns.character(at: location)) else { return nil }
    let lineBreak = ns.rangeOfComposedCharacterSequence(at: location)
    if isCollapsedToggle(at: location), let fold = foldedRange(containingCaret: NSMaxRange(lineBreak)),
      fold.location == NSMaxRange(lineBreak)
    {
      let after = NSMaxRange(fold)
      guard after < ns.length else { return ListEditing.Edit(range: NSRange(location: location, length: 0), replacement: "", cursor: location) }
      return ListEditing.joinLine(in: string, lineStart: after, onto: location)
    }
    let range = deletionRange(for: lineBreak)
    guard range != lineBreak else { return nil }
    return ListEditing.Edit(range: range, replacement: "", cursor: location)
  }

  /// Backspace at the start of the line after a collapsed toggle joins
  /// that line onto the title, not onto the hidden last child.
  private func backwardJoin(at location: Int) -> ListEditing.Edit? {
    let ns = string as NSString
    guard location > 0, location <= ns.length, [0x0A, 0x0D].contains(ns.character(at: location - 1)),
      let fold = foldedRange(containingCaret: location - 1), NSMaxRange(fold) == location, fold.location > 0
    else { return nil }
    var titleEnd = 0
    ns.getLineStart(nil, end: nil, contentsEnd: &titleEnd, for: NSRange(location: fold.location - 1, length: 0))
    return ListEditing.joinLine(in: string, lineStart: location, onto: titleEnd)
  }

  /// A word or line deletion: from the caret to where `extend` takes the
  /// selection's far end, keeping markers whole. With a selection, marked
  /// text, or nothing that way, `plain` runs instead.
  private func deleteExtended(extend: () -> Void, plain: () -> Void) {
    let selection = selectedRange()
    guard selection.length == 0, !hasMarkedText() else {
      plain()
      return
    }
    extend()
    let extended = selectedRange()
    guard extended.length > 0 else {
      setSelectedRange(selection)
      plain()
      return
    }
    let range = deletionRange(for: extended)
    apply(ListEditing.Edit(range: range, replacement: "", cursor: range.location))
  }

  override func deleteWordBackward(_ sender: Any?) {
    deleteExtended(extend: { super.moveWordBackwardAndModifySelection(sender) }, plain: { deleteBackward(sender) })
  }

  override func deleteWordForward(_ sender: Any?) {
    deleteExtended(extend: { super.moveWordForwardAndModifySelection(sender) }, plain: { deleteForward(sender) })
  }

  override func deleteToBeginningOfLine(_ sender: Any?) {
    deleteExtended(extend: { super.moveToBeginningOfLineAndModifySelection(sender) }, plain: { deleteBackward(sender) })
  }

  override func deleteToEndOfLine(_ sender: Any?) {
    deleteExtended(extend: { super.moveToEndOfLineAndModifySelection(sender) }, plain: { deleteForward(sender) })
  }

  override func deleteToBeginningOfParagraph(_ sender: Any?) {
    deleteExtended(extend: { super.moveToBeginningOfParagraphAndModifySelection(sender) }, plain: { deleteBackward(sender) })
  }

  override func deleteToEndOfParagraph(_ sender: Any?) {
    deleteExtended(extend: { super.moveToEndOfParagraphAndModifySelection(sender) }, plain: { deleteForward(sender) })
  }

  override func cut(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length > 0, !hasMarkedText() { setSelectedRange(deletionRange(for: selection)) }
    super.cut(sender)
  }

  override func delete(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length > 0, !hasMarkedText() { setSelectedRange(deletionRange(for: selection)) }
    super.delete(sender)
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
    (layoutManager as? TaskBoxLayoutManager)?.drawDividers(in: rect, origin: textContainerOrigin)
    (layoutManager as? TaskBoxLayoutManager)?.drawDateChips(in: rect, origin: textContainerOrigin)
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
    if pickerHandles(event) { return }
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

  // MARK: Inline pickers
  //
  // Menus that open under the caret while typing:
  // - "/" at the start of a line or after a space: block formats, applied
  //   to the line.
  // - ":" and two letters (":cl"), where a name can start: emoji, inserted
  //   in place of ":query".
  // They share one InlinePicker look and these rules: typing filters it;
  // up/down, return, tab and escape go to it while it is open; the caret
  // leaving the query, an invalid query or nothing matching closes it;
  // escape keeps the text. A pick removes the trigger and the query and
  // makes its edit as one undo step.

  enum PickerKind {
    case slash, emoji
  }

  private struct OpenPicker {
    let kind: PickerKind
    /// Offset of the trigger's first character.
    let start: Int
    let trigger: String
    /// End of the query (the caret) and the text length as of the last
    /// edit while the picker is open.
    var end: Int
    var textLength: Int
    var queryStart: Int { start + (trigger as NSString).length }
  }

  private var openPicker: OpenPicker?
  /// The trigger last closed with escape: typing on after it does not
  /// open the picker again (until a new trigger character is typed).
  private var dismissedTrigger: Int?

  private lazy var slashMenu = SlashMenu { [weak self] entry in self?.pickSlashEntry(entry) }
  private lazy var emojiPicker = InlinePicker(
    title: "Emoji", accessibilityLabel: "Emoji",
    source: { query in Emoji.matches(query).map { InlinePicker.Item(id: $0.emoji, title: $0.name, glyph: $0.emoji) } },
    pick: { [weak self] item in self?.pickEmoji(item) })

  var slashMenuIsOpen: Bool { openPicker?.kind == .slash }
  var emojiPickerIsOpen: Bool { openPicker?.kind == .emoji }
  var pickerIsOpen: Bool { openPicker != nil }

  private func picker(for kind: PickerKind) -> InlinePicker {
    switch kind {
    case .slash: return slashMenu
    case .emoji: return emojiPicker
    }
  }

  /// Opens the `kind` picker for the trigger at `start`, filtered by what
  /// lies between the trigger and the caret. False (and nothing shown)
  /// when nothing matches.
  @discardableResult
  private func showPicker(_ kind: PickerKind, at start: Int, trigger: String) -> Bool {
    closePicker()
    let ns = string as NSString
    let caret = selectedRange().location
    let state = OpenPicker(kind: kind, start: start, trigger: trigger, end: caret, textLength: ns.length)
    guard caret >= state.queryStart, caret <= ns.length else { return false }
    let view = picker(for: kind)
    guard view.filter(ns.substring(with: NSRange(location: state.queryStart, length: caret - state.queryStart))) else { return false }
    openPicker = state
    if view.superview == nil { addSubview(view, positioned: .above, relativeTo: nil) }
    positionPicker()
    view.isHidden = false
    return true
  }

  func closePicker() {
    guard let kind = openPicker?.kind else { return }
    openPicker = nil
    picker(for: kind).isHidden = true
  }

  /// Whether `query` (what follows the trigger) keeps the picker open.
  private static func queryKeepsPickerOpen(_ query: String, kind: PickerKind) -> Bool {
    switch kind {
    case .slash: return query.rangeOfCharacter(from: .newlines) == nil
    case .emoji: return ListEditing.isEmojiQuery(query)
    }
  }

  /// Set while Backspace edits the query, so its transient selection
  /// does not close the picker.
  private var pickerEditing = false

  /// Keeps the picker in step with the text: filters on what follows the
  /// trigger, closes when the caret leaves it or nothing matches.
  private func syncPicker(caretMoved: Bool = false) {
    guard let open = openPicker, !pickerEditing else { return }
    let ns = string as NSString
    let caret = selectedRange().location
    // The query is everything typed after the trigger; a caret that moves
    // anywhere else (even back inside the query) closes the picker, so a
    // pick never leaves part of the query behind.
    // An edit moves the caret before didChangeText runs; only a move
    // with the text unchanged counts as leaving.
    let moved = caretMoved && caret != open.end && ns.length == open.textLength
    let triggerRange = NSRange(location: open.start, length: open.queryStart - open.start)
    guard selectedRange().length == 0, open.queryStart <= ns.length, ns.substring(with: triggerRange) == open.trigger,
      caret >= open.queryStart, !moved
    else {
      closePicker()
      return
    }
    let query = ns.substring(with: NSRange(location: open.queryStart, length: caret - open.queryStart))
    guard Self.queryKeepsPickerOpen(query, kind: open.kind), picker(for: open.kind).filter(query) else {
      closePicker()
      return
    }
    openPicker?.end = caret
    openPicker?.textLength = ns.length
    positionPicker()
  }

  /// The picker hangs under the caret's line, at the caret, so it follows
  /// a query that grows or wraps.
  private func positionPicker() {
    guard let open = openPicker, let layoutManager, let textContainer else { return }
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
    picker(for: open.kind).place(below: anchor, within: visible, container: textContainer)
  }

  private func pickSlashEntry(_ entry: SlashMenu.Entry) {
    finishPick { edit(for: entry.format) }
  }

  private func pickEmoji(_ item: InlinePicker.Item) {
    guard let emoji = item.glyph else { return }
    finishPick { insertion(of: emoji) }
  }

  /// `text` typed at the caret, as an edit.
  private func insertion(of text: String) -> ListEditing.Edit {
    let caret = selectedRange().location
    return ListEditing.Edit(range: NSRange(location: caret, length: 0), replacement: text, cursor: caret + (text as NSString).length)
  }

  /// Takes the trigger and query out, puts the caret where the trigger
  /// was, and applies `makeEdit` (worked out on the text without them).
  private func finishPick(_ makeEdit: () -> ListEditing.Edit?) {
    guard let open = openPicker, let storage = textStorage else { return }
    let start = open.start
    let caret = selectedRange().location
    closePicker()
    let typed = NSRange(location: start, length: max(0, caret - start))
    guard NSMaxRange(typed) <= storage.length else { return }
    // The trigger began its own typing group (insertText breaks
    // coalescing just before it), so undoing takes the trigger and query
    // back out and leaves the text as it was before them: usually one
    // group, a few when the query was edited (a deletion coalesces apart
    // from typing). The edit then goes on as the only step above that:
    // one ⌘Z after a pick lands before the trigger, ⇧⌘Z brings the pick back.
    let withoutQuery = (string as NSString).replacingCharacters(in: typed, with: "")
    if let undoManager, undoManager.canUndo {
      // The length check is what stops the loop (each group only ever
      // shortens the text towards the target); the count is a last guard.
      var steps = 0
      while string != withoutQuery, undoManager.canUndo, steps < 1000,
        (string as NSString).length > (withoutQuery as NSString).length
      {
        undoManager.undo()
        steps += 1
      }
      if string == withoutQuery {
        setSelectedRange(NSRange(location: start, length: 0))
        apply(makeEdit())
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
      setSelectedRange(NSRange(location: start, length: 0))
      didChangeText()
    }
    apply(makeEdit())
    undoManager?.endUndoGrouping()
  }

  /// Keys the open picker takes before the text view sees them.
  private func pickerHandles(_ event: NSEvent) -> Bool {
    guard let open = openPicker else { return false }
    let view = picker(for: open.kind)
    switch event.keyCode {
    case 125: view.move(by: 1)
    case 126: view.move(by: -1)
    case 36, 48: view.pick()  // return, tab
    case 53:  // escape
      if open.kind != .slash { dismissedTrigger = open.start }
      closePicker()
    default: return false
    }
    return true
  }

  /// After a keystroke with no picker open: opens the one whose trigger
  /// the caret has just completed (":" and two letters).
  private func openPickerForTypedTrigger() {
    let caret = selectedRange().location
    if let colon = ListEditing.emojiTrigger(in: string, cursor: caret), colon != dismissedTrigger {
      showPicker(.emoji, at: colon, trigger: ":")
    }
  }

  // MARK: Overscroll

  /// Share of the visible height a long note scrolls past its last line,
  /// and the band at the bottom the caret is lifted out of, so the line
  /// being typed sits above the window's bottom edge.
  static let overscrollShare: CGFloat = 0.4

  /// Height the text shows in: the clip view less the header and footer
  /// insets of the scroll view.
  private var visibleTextHeight: CGFloat {
    guard let scroll = enclosingScrollView else { return 0 }
    let insets = scroll.contentInsets
    return max(0, scroll.contentView.bounds.height - insets.top - insets.bottom)
  }

  override func setFrameSize(_ newSize: NSSize) {
    var size = newSize
    if isVerticallyResizable, let layoutManager, let textContainer {
      let content = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
      size.height = max(size.height, content + visibleTextHeight * Self.overscrollShare)
    }
    super.setFrameSize(size)
  }

  override func scrollRangeToVisible(_ range: NSRange) {
    super.scrollRangeToVisible(range)
    // Only a caret is lifted: lifting a selection's last line could push
    // its start off the top.
    if range.length == 0 { liftOutOfBottomBand(range) }
  }

  private func liftOutOfBottomBand(_ range: NSRange) {
    guard let scroll = enclosingScrollView, let layoutManager else { return }
    let length = (string as NSString).length
    let index = min(NSMaxRange(range), length)
    var line: NSRect
    if index == length, !layoutManager.extraLineFragmentRect.isEmpty {
      line = layoutManager.extraLineFragmentRect
    } else if length > 0 {
      let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
      line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    } else {
      return
    }
    line.origin.y += textContainerOrigin.y
    let clip = scroll.contentView
    let limit = clip.bounds.maxY - scroll.contentInsets.bottom - visibleTextHeight * Self.overscrollShare
    guard line.maxY > limit else { return }
    var target = clip.bounds
    target.origin.y += line.maxY - limit
    clip.scroll(to: clip.constrainBoundsRect(target).origin)
    scroll.reflectScrolledClipView(clip)
  }

  override func didChangeText() {
    super.didChangeText()
    syncPicker()
    // Quote bars and code cards reach outside the lines that changed.
    needsDisplay = true
  }

  // MARK: Typing rules

  override func insertNewline(_ sender: Any?) {
    let pending = pendingDateKeyword()
    newlineRules(sender)
    scheduleDateConversion(pending)
  }

  private func newlineRules(_ sender: Any?) {
    let selection = selectedRange()
    if selection.length == 0, !hasMarkedText() {
      let text = string
      let edit = ListEditing.codeFence(in: text, cursor: selection.location)
        ?? ListEditing.toggleNewline(in: text, cursor: selection.location, collapsed: isCollapsedToggle(at: selection.location))
        ?? ListEditing.quoteNewline(in: text, cursor: selection.location)
        ?? ListEditing.newline(in: text, cursor: selection.location)
        ?? ListEditing.childNewline(in: text, cursor: selection.location)
      if apply(edit) { return }
    }
    super.insertNewline(sender)
  }

  override func insertTab(_ sender: Any?) {
    let pending = pendingDateKeyword()
    if !indentListItem(by: 1) { super.insertTab(sender) }
    scheduleDateConversion(pending)
  }

  // MARK: Date keywords
  //
  // "@today", "@tomorrow" and "@yesterday" become the ISO date when a
  // terminator is typed after them (Dates.afterTerminator). The terminator
  // goes in first, by its own rules (a list continues, an item nests), and
  // the date follows on the next pass of the run loop: the undo manager
  // groups a key's edits by event, so only then is the date an undo step
  // of its own, and ⌘Z right after gives back the keyword. Paste never
  // converts.

  /// Set while pasted or dropped text goes in.
  private var pasting = false
  /// Bumped whenever the text is set wholesale (a note loads or reloads
  /// from disk), so a queued date conversion never lands in another text.
  private var textGeneration = 0

  override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    pasting = true
    defer { pasting = false }
    return super.readSelection(from: pboard, type: type)
  }

  /// Before Enter or Tab: the keyword ending at the caret (its range and
  /// date), with the text as it was, for `convertDateKeyword` after.
  private func pendingDateKeyword() -> (edit: ListEditing.Edit, text: String)? {
    let selection = selectedRange()
    guard selection.length == 0, !hasMarkedText(), !pasting,
      let edit = Dates.keyword(endingAt: selection.location, in: string)
    else { return nil }
    return (edit, string)
  }

  /// Turns the keyword into its date on the next pass of the run loop.
  private func scheduleDateConversion(_ pending: (edit: ListEditing.Edit, text: String)?) {
    guard let pending else { return }
    let generation = textGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self, self.textGeneration == generation else { return }
      self.convertDateKeyword(pending)
    }
  }

  /// Turns the keyword `pending` found in its text into the date where it
  /// sits now, after the terminator's own edit (and any typing since). It
  /// is found by comparing the texts: the keyword must lie wholly before
  /// or wholly after what changed, and still read the same; otherwise
  /// nothing happens.
  private func convertDateKeyword(_ pending: (edit: ListEditing.Edit, text: String)) {
    guard !hasMarkedText() else { return }
    let (edit, old) = pending
    let before = old as NSString
    let after = string as NSString
    let shortest = min(before.length, after.length)
    var prefix = 0
    while prefix < shortest, before.character(at: prefix) == after.character(at: prefix) { prefix += 1 }
    var suffix = 0
    while suffix < shortest - prefix,
      before.character(at: before.length - 1 - suffix) == after.character(at: after.length - 1 - suffix)
    {
      suffix += 1
    }
    var range = edit.range
    if NSMaxRange(range) <= prefix {
      // Before the change: where it was.
    } else if range.location >= before.length - suffix {
      range.location += after.length - before.length
    } else {
      return
    }
    guard NSMaxRange(range) <= after.length, after.substring(with: range) == before.substring(with: edit.range) else { return }
    let selection = selectedRange()
    let delta = (edit.replacement as NSString).length - range.length
    let caret = selection.location >= NSMaxRange(range) ? selection.location + delta : selection.location
    apply(ListEditing.Edit(range: range, replacement: edit.replacement, cursor: caret))
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
    // Backspace inside a picker's query: the text view selects the
    // character first, which would read as the caret leaving the query.
    if let open = openPicker, selection.length == 0, selection.location > open.queryStart {
      pickerEditing = true
      super.deleteBackward(sender)
      pickerEditing = false
      syncPicker()
      return
    }
    if selection.length == 0, !hasMarkedText() {
      if deleteEmptyCodeBlock(at: selection.location) { return }
      if let block = codeBlock(containing: selection.location), selection.location == block.body.location {
        return  // keep the opening fence; the block is one component
      }
      if apply(ListEditing.dividerBackspace(in: string, cursor: selection.location)) { return }
      if apply(ListEditing.backspace(in: string, cursor: selection.location)) { return }
      // Block markers come off one at a time, innermost first.
      if apply(ListEditing.peelMarker(in: string, cursor: selection.location)) { return }
      if apply(backwardJoin(at: selection.location)) { return }
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
      setSelectedRange(deletionRange(for: selection))
    }
    super.deleteBackward(sender)
  }

  /// The space goes in first as ordinary typing, then "[] " or "``` " is
  /// rewritten as a separate undo step, so ⌘Z gives back the literal text.
  /// Typographic pairs ("->", "--", "...") become one symbol the same way.
  /// `apply` edits the text storage directly, so this never re-enters.
  override func insertText(_ string: Any, replacementRange: NSRange) {
    // Typing over a selection: the selection takes whole marker pairs with it.
    if replacementRange.location == NSNotFound, selectedRange().length > 0, !hasMarkedText() {
      setSelectedRange(deletionRange(for: selectedRange()))
    }
    let typed = (string as? String) ?? (string as? NSAttributedString)?.string
    let typing = !hasMarkedText() && replacementRange.location == NSNotFound
    // A "/" at a line start or after a space opens the block menu. It is
    // decided before the insert, and starts a fresh undo group, so a pick
    // can take the whole "/query" back out with one undo.
    var opensMenu = false
    if typed == "/", !slashMenuIsOpen, typing {
      let pre = selectedRange()
      let ns = self.string as NSString
      let lineStart = ns.lineRange(for: NSRange(location: pre.location, length: 0)).location
      let previous = pre.location > lineStart ? ns.character(at: pre.location - 1) : 0x20
      opensMenu = (previous == 0x20 || previous == 0x09) && !ListEditing.insideFence(self.string, cursor: pre.location)
      if opensMenu { breakUndoCoalescing() }
    }
    // A character that belongs to a hidden marker (a divider's dashes)
    // never starts a typographic pair. Decided before the insert, while
    // the styling still matches the text.
    let caretBefore = selectedRange().location
    let markerBefore = typed.map(ListEditing.typographyTriggers.contains) == true
      && (1...2).contains { caretBefore - $0 >= 0 && hiddenRun(at: caretBefore - $0) != nil }
    // A ":" that could start an emoji name also starts its own undo
    // group, for the same reason: the picker opens a few letters later.
    if typed == ":", typing {
      dismissedTrigger = nil
      if ListEditing.emojiColonCanStart(in: self.string, at: selectedRange().location) { breakUndoCoalescing() }
    }
    super.insertText(string, replacementRange: replacementRange)
    if opensMenu {
      showPicker(.slash, at: selectedRange().location - 1, trigger: "/")
      return
    }
    // Programmatic replacements (the task box toggle) pass a non-empty range.
    guard replacementRange.location == NSNotFound || replacementRange.length == 0, !hasMarkedText() else { return }
    let selection = selectedRange()
    guard selection.length == 0 else { return }
    // ":clap:" becomes 👏 as its own undo step, so ⌘Z gives back the name.
    if typed == ":", apply(ListEditing.emojiShortcode(in: self.string, cursor: selection.location, lookup: Emoji.lookup)) {
      return
    }
    if openPicker == nil, typed != nil { openPickerForTypedTrigger() }
    // "@today" and friends: the date follows on the next pass (Date keywords).
    // A date terminator never completes a typographic pair after a keyword.
    // Neither happens inside an open picker's query.
    if !pasting, !pickerIsOpen, let single = typed, (single as NSString).length == 1,
      let edit = Dates.afterTerminator(in: self.string, cursor: selection.location)
    {
      scheduleDateConversion((edit, self.string))
      return
    }
    // "->", "--", "...", and the rest become one symbol as their own undo
    // step. Typing only: a paste never comes through here a character at a time.
    if let typed, ListEditing.typographyTriggers.contains(typed) {
      guard !markerBefore, !pickerIsOpen, var edit = ListEditing.typography(in: self.string, cursor: selection.location)
      else { return }
      var typedEnd = selection.location
      var typedText = (self.string as NSString).substring(with: edit.range)
      if let composite = rewindTypography(for: edit, typedEnd: typedEnd) {
        (edit, typedEnd, typedText) = composite
      }
      if let undoManager, undoManager.groupingLevel == 1 {
        // This event's group may hold the typed key (or the keys put back
        // by the rewind); close it so ⌘Z takes back the symbol alone.
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
      }
      // Undo alone would select the restored pair, and the next key would
      // type over it: the group also puts the caret back after it.
      // Registered first, so it runs last on undo.
      breakUndoCoalescing()
      undoManager?.beginUndoGrouping()
      let caretAfterUndo = typedEnd
      undoManager?.registerUndo(withTarget: self) { $0.setSelectedRange(NSRange(location: caretAfterUndo, length: 0)) }
      apply(edit)
      undoManager?.endUndoGrouping()
      lastTypography = (edit.range.location, edit.replacement, typedText)
      return
    }
    guard typed == " " else { return }
    apply(ListEditing.afterSpace(in: self.string, cursor: selection.location))
  }

  /// The last typographic symbol made, where, and what was typed for it.
  private var lastTypography: (location: Int, symbol: String, typed: String)?

  /// A symbol finishing the next one (`<-` made ←, then `>` makes ↔):
  /// takes the earlier symbol and the keys since back off the undo stack,
  /// puts back what was typed as one step, and returns the composite edit
  /// over the typed text, so one ⌘Z after it restores exactly what was
  /// typed (`<->`). Nil, with the history untouched, when the earlier
  /// symbol was not just made here (pasted, or edited since).
  private func rewindTypography(for edit: ListEditing.Edit, typedEnd: Int)
    -> (edit: ListEditing.Edit, typedEnd: Int, typed: String)?
  {
    guard let prior = lastTypography, let undoManager, let storage = textStorage else { return nil }
    let ns = string as NSString
    let start = edit.range.location
    guard prior.location == start, edit.range.length >= 2, NSMaxRange(edit.range) == typedEnd,
      ns.substring(with: NSRange(location: start, length: 1)) == prior.symbol
    else { return nil }
    let since = ns.substring(with: NSRange(location: start + 1, length: typedEnd - start - 1))
    let expected = ns.replacingCharacters(in: NSRange(location: start, length: typedEnd - start), with: prior.typed)
    // The keys since the symbol (a typing group or two), then the symbol
    // itself; a few more steps for empty event groups along the way.
    var steps = 0
    while string != expected, undoManager.canUndo, steps < 6 {
      undoManager.undo()
      steps += 1
    }
    guard string == expected else {
      while steps > 0, undoManager.canRedo {
        undoManager.redo()
        steps -= 1
      }
      return nil
    }
    let insertAt = start + (prior.typed as NSString).length
    let insertion = NSRange(location: insertAt, length: 0)
    breakUndoCoalescing()
    undoManager.beginUndoGrouping()
    if shouldChangeText(in: insertion, replacementString: since) {
      storage.replaceCharacters(in: insertion, with: since)
      setSelectedRange(NSRange(location: insertAt + (since as NSString).length, length: 0))
      didChangeText()
    }
    undoManager.endUndoGrouping()
    let typed = prior.typed + since
    let length = (typed as NSString).length
    let composite = ListEditing.Edit(range: NSRange(location: start, length: length), replacement: edit.replacement, cursor: start + 1)
    return (composite, start + length, typed)
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
    if selection.length > 0, !hasMarkedText() { setSelectedRange(deletionRange(for: selection)) }
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
    // Select before didChangeText so the restyle it triggers keeps this
    // caret. The rule placed it; the caret rules (which read the styling,
    // stale until the restyle) must not move it.
    suppressCaretRules = true
    setSelectedRange(selection)
    suppressCaretRules = false
    didChangeText()
    breakUndoCoalescing()
    if selectedRange() != selection {
      suppressCaretRules = true
      setSelectedRange(selection)
      suppressCaretRules = false
    }
    scrollRangeToVisible(selection)
    return true
  }
}
