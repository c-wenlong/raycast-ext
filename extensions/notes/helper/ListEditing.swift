// List editing rules for the notes window, kept free of AppKit so they
// can be tested from the command line (test/list-editing/main.swift).
//
// Every function takes the whole text plus a cursor offset (UTF-16) and
// returns the replacement for one range plus the new selection, so the
// text view can apply it as one undoable change.

import Foundation

enum ListEditing {
  struct Edit: Equatable {
    let range: NSRange
    let replacement: String
    let cursor: Int
    /// Characters to select after the cursor (0 = just a caret).
    var selectionLength = 0
  }

  enum Marker: Equatable {
    case bullet(String)
    case task(bullet: String, done: Bool)
    case ordered(Int)

    /// Text of the marker without indent, with its trailing space.
    var text: String {
      switch self {
      case .bullet(let char): return "\(char) "
      case .task(let char, let done): return "\(char) [\(done ? "x" : " ")] "
      case .ordered(let number): return "\(number). "
      }
    }

    /// How far a child item is indented under this one.
    var childIndent: Int {
      switch self {
      case .bullet, .task: return 2
      case .ordered(let number): return "\(number). ".count
      }
    }

    /// The marker a new sibling gets when Enter is pressed on this item.
    var next: Marker {
      switch self {
      case .bullet(let char): return .bullet(char)
      case .task(let char, _): return .task(bullet: char, done: false)
      case .ordered(let number): return .ordered(number + 1)
      }
    }
  }

  struct Item: Equatable {
    let indent: String
    let marker: Marker
    let content: String

    var line: String { indent + marker.text + content }
  }

  private static let itemPattern = try! NSRegularExpression(
    pattern: #"^([ \t]*)(?:([-*+])(?:[ \t]+\[([ xX])\])?|(\d+)\.)(?:[ \t]+(.*))?$"#)

  static func parse(line: String) -> Item? {
    let ns = line as NSString
    guard let match = itemPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
    else { return nil }
    let indent = ns.substring(with: match.range(at: 1))
    let content = match.range(at: 5).location == NSNotFound ? "" : ns.substring(with: match.range(at: 5))
    let marker: Marker
    if match.range(at: 4).location != NSNotFound {
      marker = .ordered(Int(ns.substring(with: match.range(at: 4))) ?? 1)
    } else {
      let bullet = ns.substring(with: match.range(at: 2))
      if match.range(at: 3).location != NSNotFound {
        marker = .task(bullet: bullet, done: ns.substring(with: match.range(at: 3)).lowercased() == "x")
      } else {
        marker = .bullet(bullet)
      }
    }
    return Item(indent: indent, marker: marker, content: content)
  }

  // MARK: Line and block helpers

  private struct Line {
    let range: NSRange  // without the newline
    let text: String
  }

  private static func lines(of text: String) -> [Line] {
    let ns = text as NSString
    var result: [Line] = []
    var location = 0
    while true {
      var lineEnd = 0
      var contentsEnd = 0
      ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let range = NSRange(location: location, length: contentsEnd - location)
      result.append(Line(range: range, text: ns.substring(with: range)))
      if lineEnd == contentsEnd { break }  // last line, no line break after it
      location = lineEnd
      if location == ns.length {
        // text ends with a line break: one more, empty line
        result.append(Line(range: NSRange(location: location, length: 0), text: ""))
        break
      }
    }
    return result
  }

  /// The line holding `cursor`; a cursor at the end of a line belongs to it.
  private static func lineIndex(of cursor: Int, in lines: [Line]) -> Int? {
    lines.firstIndex { cursor >= $0.range.location && cursor <= NSMaxRange($0.range) }
  }

  /// The break the text already uses ("\r\n" in a CRLF file), for new lines.
  static func lineBreak(in text: String) -> String {
    let ns = text as NSString
    let found = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n"))
    guard found.location != NSNotFound, ns.character(at: found.location) == 0x0D else { return "\n" }
    let crlf = found.location + 1 < ns.length && ns.character(at: found.location + 1) == 0x0A
    return crlf ? "\r\n" : "\r"
  }

  private static func leadingWhitespace(_ line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.count
  }

  /// The line break at the end of `text`, or "" when it has none.
  private static func trailingBreak(_ text: String) -> String {
    ["\r\n", "\n", "\r"].first { (text as NSString).hasSuffix($0) } ?? ""
  }

  /// Indexes of the contiguous run of non-blank lines around `index`.
  private static func block(around index: Int, in lines: [Line]) -> ClosedRange<Int> {
    var start = index
    while start > 0, !lines[start - 1].text.trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
    var end = index
    while end + 1 < lines.count, !lines[end + 1].text.trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
    return start...end
  }

  /// Renumbers ordered items so siblings count up from 1 and a child list
  /// restarts. A non-list line or a marker type change ends a run.
  static func renumber(_ lines: [String]) -> [String] {
    var counters: [Int: Int] = [:]
    return lines.map { line in
      guard let item = parse(line: line) else {
        counters.removeAll()
        return line
      }
      let depth = item.indent.count
      counters = counters.filter { $0.key <= depth }
      switch item.marker {
      case .ordered:
        let number = (counters[depth] ?? 0) + 1
        counters[depth] = number
        return Item(indent: item.indent, marker: .ordered(number), content: item.content).line
      default:
        counters[depth] = nil
        return line
      }
    }
  }

  /// Rewrites the block around `lineIndex` with `newLines`, renumbered, and
  /// maps `cursorLine`/`cursorColumn` (inside newLines) to a text offset.
  /// Renumbers only the runs of consecutive list lines that touch the
  /// edited line (or its neighbours, for a line that just stopped being an
  /// item), so numbers elsewhere in the block are left alone.
  static func renumberAround(_ lines: [String], line: Int) -> [String] {
    var result = lines
    var index = 0
    while index < lines.count {
      guard parse(line: lines[index]) != nil else {
        index += 1
        continue
      }
      var end = index
      while end + 1 < lines.count, parse(line: lines[end + 1]) != nil { end += 1 }
      if index <= line + 1, end >= line - 1 {
        result.replaceSubrange(index...end, with: renumber(Array(lines[index...end])))
      }
      index = end + 1
    }
    return result
  }

  private static func apply(
    block: ClosedRange<Int>, in lines: [Line], newLines: [String], cursorLine: Int, cursorColumn: Int, eol: String
  ) -> Edit {
    let renumbered = renumberAround(newLines, line: cursorLine)
    let start = lines[block.lowerBound].range.location
    let end = NSMaxRange(lines[block.upperBound].range)
    var cursor = start
    for (index, line) in renumbered.enumerated() {
      if index == cursorLine {
        cursor += min(cursorColumn, (line as NSString).length)
        break
      }
      cursor += (line as NSString).length + (eol as NSString).length
    }
    return Edit(range: NSRange(location: start, length: end - start), replacement: renumbered.joined(separator: eol), cursor: cursor)
  }

  // MARK: Public operations

  private static let quoteLine = try! NSRegularExpression(pattern: #"^(>>?)(?!>)(?:[ \t]|$)(.*)$"#)

  /// Enter on a quote (">") or callout (">>") line: the block continues
  /// on the next line, or ends when the line is empty. Nil when the
  /// cursor is not in one.
  static func quoteNewline(in text: String, cursor: Int) -> Edit? {
    guard !insideFence(text, cursor: cursor) else { return nil }
    let ns = text as NSString
    var lineStart = 0
    var contentsEnd = 0
    ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
    let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
    guard let match = quoteLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
    let content = (line as NSString).substring(with: match.range(at: 2))
    if content.trimmingCharacters(in: .whitespaces).isEmpty {
      return Edit(range: NSRange(location: lineStart, length: contentsEnd - lineStart), replacement: "", cursor: lineStart)
    }
    let inserted = lineBreak(in: text) + (line as NSString).substring(with: match.range(at: 1)) + " "
    return Edit(range: NSRange(location: cursor, length: 0), replacement: inserted, cursor: cursor + (inserted as NSString).length)
  }

  /// Removes the current line's block prefix (heading, quote, list
  /// marker), turning it into plain text. Nil when there is none.
  static func clearLinePrefix(in text: String, cursor: Int) -> Edit? {
    let ns = text as NSString
    var lineStart = 0
    var contentsEnd = 0
    ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
    let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
    guard let match = anyPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
    let prefix = match.range(at: 2)
    let column = cursor - lineStart
    let newColumn = column <= NSMaxRange(prefix) ? prefix.location : column - prefix.length
    return Edit(range: NSRange(location: lineStart + prefix.location, length: prefix.length), replacement: "", cursor: lineStart + newColumn)
  }

  /// Enter on a list item: continues the list, or ends it when the item
  /// is empty. Nil when the cursor is not on a list item.
  static func newline(in text: String, cursor: Int) -> Edit? {
    guard !insideFence(text, cursor: cursor) else { return nil }
    let all = lines(of: text)
    guard let index = lineIndex(of: cursor, in: all), let item = parse(line: all[index].text) else { return nil }

    let eol = lineBreak(in: text)
    let blockRange = block(around: index, in: all)
    var newLines = all[blockRange].map(\.text)
    let local = index - blockRange.lowerBound

    if item.content.trimmingCharacters(in: .whitespaces).isEmpty {
      // Empty item: leave the list (outdent one level first if nested).
      if item.indent.isEmpty {
        newLines[local] = ""
        return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: 0, eol: eol)
      }
      let parentIndent = String(item.indent.dropLast(min(item.indent.count, parentIndentWidth(before: index, in: all, childIndent: item.indent.count))))
      let outdented = Item(indent: parentIndent, marker: item.marker, content: "")
      newLines[local] = outdented.line
      return apply(
        block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: (outdented.line as NSString).length, eol: eol)
    }

    let column = cursor - all[index].range.location
    let ns = all[index].text as NSString
    let head = ns.substring(to: min(column, ns.length))
    let tail = ns.substring(from: min(column, ns.length))
    let prefixLength = (item.indent + item.marker.text).count
    let (before, after) = column <= prefixLength ? (all[index].text, "") : (head, tail)
    let sibling = Item(indent: item.indent, marker: item.marker.next, content: after.trimmingCharacters(in: .whitespaces))
    newLines[local] = before.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    newLines.insert(sibling.line, at: local + 1)
    let cursorColumn = (sibling.indent + sibling.marker.text).count
    return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local + 1, cursorColumn: cursorColumn, eol: eol)
  }

  /// Tab (+1) or Shift-Tab (-1) on a list item, carrying its nested
  /// lines along. Tab nests under the previous sibling (joining its child
  /// list when it has one). Nil when not on an item or it cannot move.
  static func indent(in text: String, cursor: Int, by delta: Int) -> Edit? {
    guard !insideFence(text, cursor: cursor) else { return nil }
    let all = lines(of: text)
    guard let index = lineIndex(of: cursor, in: all), let item = parse(line: all[index].text) else { return nil }

    let blockRange = block(around: index, in: all)
    var newLines = all[blockRange].map(\.text)
    let local = index - blockRange.lowerBound
    let column = cursor - all[index].range.location
    let depth = item.indent.count

    let newDepth: Int
    if delta > 0 {
      var sibling: Item? = nil
      var childDepth: Int? = nil  // shallowest item between the sibling and here
      var i = index - 1
      while i >= blockRange.lowerBound {
        if let above = parse(line: all[i].text) {
          let aboveDepth = above.indent.count
          if aboveDepth == depth { sibling = above; break }
          if aboveDepth < depth { break }  // already the first child of that item
          childDepth = min(childDepth ?? aboveDepth, aboveDepth)
        }
        i -= 1
      }
      guard let sibling else { return nil }
      newDepth = childDepth ?? depth + sibling.marker.childIndent
    } else {
      guard depth > 0 else { return nil }
      newDepth = depth - min(depth, parentIndentWidth(before: index, in: all, childIndent: depth))
    }

    let shift = newDepth - depth
    func moved(_ line: String) -> String {
      shift > 0 ? String(repeating: " ", count: shift) + line : String(line.dropFirst(min(-shift, leadingWhitespace(line))))
    }
    newLines[local] = moved(newLines[local])
    var next = local + 1
    while next < newLines.count {
      let line = newLines[next]
      guard (parse(line: line)?.indent.count ?? leadingWhitespace(line)) > depth else { break }
      newLines[next] = moved(line)
      next += 1
    }
    return apply(
      block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: max(column + shift, newDepth),
      eol: lineBreak(in: text))
  }

  /// Width to remove when outdenting: the parent's child indent when a
  /// parent item is found above, else 2.
  private static func parentIndentWidth(before index: Int, in lines: [Line], childIndent: Int) -> Int {
    var i = index - 1
    while i >= 0 {
      let text = lines[i].text
      if text.trimmingCharacters(in: .whitespaces).isEmpty { break }
      if let item = parse(line: text), item.indent.count < childIndent {
        return childIndent - item.indent.count
      }
      i -= 1
    }
    return min(childIndent, 2)
  }

  // MARK: Code fences

  private static let fenceLine = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(\S*)[ \t]*$"#)

  /// True when `cursor` sits inside an open ``` or ~~~ block, where list
  /// rules must stay out of the way.
  /// True when `cursor` sits inside a fenced block: past the start of
  /// its opening fence line, up to the start of its closing fence line.
  /// An opening fence that is never closed is literal text, as Markdown
  /// draws it.
  static func insideFence(_ text: String, cursor: Int) -> Bool {
    var inside = false
    scanFences(text) { openStart, closeStart in
      if cursor > openStart, cursor <= closeStart { inside = true }
      // Nothing that closes at or after the cursor's block can change
      // the answer: the scan stops at the first block ending past it.
      return closeStart < cursor
    }
    return inside
  }

  /// True when a fence opened in `text` is never closed.
  static func hasUnclosedFence(_ text: String) -> Bool {
    var unclosed = false
    scanFences(text, unclosed: { unclosed = true }) { _, _ in true }
    return unclosed
  }

  /// Walks the fence lines, reporting each closed block's opening and
  /// closing line starts (the closure returns whether to keep going),
  /// and (once, at the end) an opening fence left unclosed.
  private static func scanFences(_ text: String, unclosed: () -> Void = {}, block: (Int, Int) -> Bool) {
    let ns = text as NSString
    var open: (marker: String, start: Int)? = nil
    var location = 0
    while location < ns.length {
      var lineEnd = 0
      var contentsEnd = 0
      ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let line = ns.substring(with: NSRange(location: location, length: contentsEnd - location))
      if let match = fenceLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
        let marker = (line as NSString).substring(with: match.range(at: 1))
        if let current = open {
          if marker.first == current.marker.first, marker.count >= current.marker.count, match.range(at: 2).length == 0 {
            open = nil
            if !block(current.start, location) { return }
          }
        } else {
          open = (marker, location)
        }
      }
      if lineEnd == location { break }
      location = lineEnd
    }
    if open != nil { unclosed() }
  }

  /// Enter or space right after ``` or ~~~ (optionally with a language)
  /// on its own line opens a code block: the closing fence is added and
  /// the cursor lands on the empty line between.
  static func codeFence(in text: String, cursor: Int) -> Edit? {
    let ns = text as NSString
    var lineStart = 0
    var contentsEnd = 0
    ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
    guard cursor == contentsEnd, !insideFence(text, cursor: lineStart) else { return nil }
    let line = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
    guard let match = fenceLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    else { return nil }
    // When a later fence already closes this one, it opens an existing block.
    guard hasUnclosedFence(text) else { return nil }
    let marker = (line as NSString).substring(with: match.range(at: 1))
    let trimmed = line.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
    let eol = lineBreak(in: text)
    let replacement = trimmed + eol + eol + marker
    return Edit(
      range: NSRange(location: lineStart, length: cursor - lineStart), replacement: replacement,
      cursor: lineStart + (trimmed as NSString).length + (eol as NSString).length)
  }

  /// The rules a typed space sets off ("[] " becomes a task, "``` " opens
  /// a code block), checked after the space is in the text so the first
  /// undo steps back to exactly what was typed. The edit covers the space.
  static func afterSpace(in text: String, cursor: Int) -> Edit? {
    let ns = text as NSString
    guard cursor > 0, cursor <= ns.length, ns.character(at: cursor - 1) == 0x20 else { return nil }
    let before = ns.replacingCharacters(in: NSRange(location: cursor - 1, length: 1), with: "")
    guard let edit = taskShortcut(in: before, cursor: cursor - 1) ?? codeFence(in: before, cursor: cursor - 1)
    else { return nil }
    // Both rules end their range at the cursor, which is where the space sits.
    let range = NSRange(location: edit.range.location, length: edit.range.length + 1)
    guard ns.substring(with: range) != edit.replacement else { return nil }
    return Edit(range: range, replacement: edit.replacement, cursor: edit.cursor, selectionLength: edit.selectionLength)
  }

  // MARK: Task shortcut and backspace

  /// Typing a space right after "[]", "[ ]" or "[x]" at the start of a
  /// line turns it into a task item. Returns the edit for the line, or nil.
  private static let boxPattern = try! NSRegularExpression(pattern: #"^([ \t]*)(?:([-*+])[ \t]+)?\[( ?|[xX])\]$"#)

  static func taskShortcut(in text: String, cursor: Int) -> Edit? {
    let ns = text as NSString
    var lineStart = 0
    var contentsEnd = 0
    ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
    guard cursor == contentsEnd, !insideFence(text, cursor: lineStart) else { return nil }
    let line = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
    guard let match = boxPattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    else { return nil }
    let indent = (line as NSString).substring(with: match.range(at: 1))
    let bullet = match.range(at: 2).location == NSNotFound ? "-" : (line as NSString).substring(with: match.range(at: 2))
    let done = (line as NSString).substring(with: match.range(at: 3)).lowercased() == "x"
    let replacement = Item(indent: indent, marker: .task(bullet: bullet, done: done), content: "").line
    return Edit(range: NSRange(location: lineStart, length: cursor - lineStart), replacement: replacement, cursor: lineStart + (replacement as NSString).length)
  }

  /// Backspace with the caret right after a list marker removes the
  /// marker (nested items step out one level first).
  static func backspace(in text: String, cursor: Int) -> Edit? {
    // Every marker ends in a space or tab; skip the line scan otherwise.
    let ns = text as NSString
    guard cursor > 0, cursor <= ns.length, [0x20, 0x09].contains(ns.character(at: cursor - 1)) else { return nil }
    let all = lines(of: text)
    guard let index = lineIndex(of: cursor, in: all),
      let item = parse(line: all[index].text),
      cursor - all[index].range.location == (item.indent + item.marker.text).count,
      !insideFence(text, cursor: all[index].range.location)
    else { return nil }

    let blockRange = block(around: index, in: all)
    var newLines = all[blockRange].map(\.text)
    let local = index - blockRange.lowerBound
    let eol = lineBreak(in: text)
    if item.indent.isEmpty {
      newLines[local] = item.content
      return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: 0, eol: eol)
    }
    let width = parentIndentWidth(before: index, in: all, childIndent: item.indent.count)
    let outdented = Item(indent: String(item.indent.dropLast(min(item.indent.count, width))), marker: item.marker, content: item.content)
    newLines[local] = outdented.line
    return apply(
      block: blockRange, in: all, newLines: newLines, cursorLine: local,
      cursorColumn: (outdented.indent + outdented.marker.text).count, eol: eol)
  }

  // MARK: Formatting shortcuts

  /// Inline pair patterns, shared with the styler (Markdown.bold, .italic,
  /// .strike, .code) so the formatting keys see exactly the pairs that are
  /// drawn styled.
  static let boldPattern = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
  // Groups 1/2 for `*`, 3/4 for `_`. Each marker is a lone character (so
  // a bold marker is never half an italic one) and only refuses its own
  // character next to it, so `_b_` nests inside `**...**` and `**b**`
  // inside `*...*`.
  static let italicPattern = try! NSRegularExpression(pattern: #"(?<![\*\w])(\*)(?!\*)(?=\S)(.+?)(?<=\S)(?<!\*)\1(?![\*\w])|(?<![_\w])(_)(?!_)(?=\S)(.+?)(?<=\S)(?<!_)\3(?![_\w])"#)
  static let strikePattern = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)\1"#)
  static let codePattern = try! NSRegularExpression(pattern: #"(`)([^`\n]+)\1"#)

  /// The styled `marker` pair (markers included) that holds the selection:
  /// a caret between its outer edges, or a selection that starts and ends
  /// anywhere from the opening marker to the closing one. Markers are
  /// hidden on screen, so all of those show as the caret or selection
  /// sitting in the styled text. The whole pattern runs (not just the
  /// marker's alternative) so a pair swallowed by another one, like `_y_`
  /// in `*x _y_ z*`, is not taken for a styled pair. Pairs never span
  /// lines, and fenced code is not styled.
  private static func wrapSpan(in text: String, around selection: NSRange, marker: String) -> NSRange? {
    wrapSpans(in: text, on: selection, marker: marker).first { span in
      selection.length == 0
        ? span.location < selection.location && selection.location < NSMaxRange(span)
        : span.location <= selection.location && NSMaxRange(selection) <= NSMaxRange(span)
    }
  }

  /// Every styled pair of `marker` on the line of `selection`, in order.
  private static func wrapSpans(in text: String, on selection: NSRange, marker: String) -> [NSRange] {
    let pattern: NSRegularExpression
    switch marker {
    case "**": pattern = boldPattern
    case "_": pattern = italicPattern
    case "~~": pattern = strikePattern
    case "`": pattern = codePattern
    default: return []
    }
    guard !insideFence(text, cursor: selection.location) else { return [] }
    let ns = text as NSString
    let width = (marker as NSString).length
    return pattern.matches(in: text, range: ns.lineRange(for: selection)).map(\.range).filter { span in
      ns.substring(with: NSRange(location: span.location, length: width)) == marker
    }
  }

  /// Wraps the selection in `marker` (⌘B, ⌘I, ⇧⌘S, ⌘E), or unwraps it
  /// when the caret or selection is inside a pair of that marker (or is
  /// the pair). An empty selection elsewhere gets an empty pair with the
  /// caret inside.
  static func toggleWrap(in text: String, selection: NSRange, marker: String) -> Edit {
    let ns = text as NSString
    let selected = ns.substring(with: selection)
    let width = (marker as NSString).length
    if selected.rangeOfCharacter(from: .newlines) != nil {
      return toggleWrapLines(in: text, selection: selection, marker: marker)
    }
    if let span = wrapSpan(in: text, around: selection, marker: marker) {
      let inner = ns.substring(with: NSRange(location: span.location + width, length: span.length - width * 2))
      // Each position moves left by the marker characters before it, so
      // the caret or selection stays on the same visible text.
      func shifted(_ position: Int) -> Int {
        position - min(max(position - span.location, 0), width) - min(max(position - (NSMaxRange(span) - width), 0), width)
      }
      let start = shifted(selection.location)
      return Edit(range: span, replacement: inner, cursor: start, selectionLength: shifted(NSMaxRange(selection)) - start)
    }
    let before = selection.location >= width ? ns.substring(with: NSRange(location: selection.location - width, length: width)) : ""
    let afterStart = selection.location + selection.length
    let after = afterStart + width <= ns.length ? ns.substring(with: NSRange(location: afterStart, length: width)) : ""
    let spans = wrapSpans(in: text, on: selection, marker: marker)
    // A caret right against a pair's outer edge: typing there is already
    // plain, so there is nothing to toggle, and an empty pair added here
    // would only show as stray marker characters. A caret between two
    // pairs is the merge case handled below instead.
    if selection.length == 0, !(before == marker && after == marker),
      spans.contains(where: { $0.location == selection.location || NSMaxRange($0) == selection.location })
    {
      return Edit(range: selection, replacement: "", cursor: selection.location)
    }
    // A one-line selection reaching into one or more pairs but not held
    // by one is mixed: it all becomes one styled run (the pairs it touches
    // are folded in, whole), as the format keys do elsewhere. Pairs never
    // span lines, so a selection across lines is left to wrap as a whole;
    // pairs inside fenced code are text, not style.
    let oneLine = ns.substring(with: selection).rangeOfCharacter(from: .newlines) == nil
    let touched = oneLine
      ? spans.filter { $0.location < NSMaxRange(selection) && NSMaxRange($0) > selection.location && !insideFence(text, cursor: $0.location) }
      : []
    if !touched.isEmpty {
      var range = selection
      for span in touched { range = NSUnionRange(range, span) }
      var inner = ns.substring(with: range)
      for span in touched.reversed() {
        let local = NSRange(location: span.location - range.location, length: span.length)
        let content = (inner as NSString).substring(with: NSRange(location: local.location + width, length: local.length - width * 2))
        inner = (inner as NSString).replacingCharacters(in: local, with: content)
      }
      return Edit(range: range, replacement: marker + inner + marker, cursor: range.location + width, selectionLength: (inner as NSString).length)
    }
    if selected.hasPrefix(marker), selected.hasSuffix(marker), (selected as NSString).length >= width * 2 {
      let inner = (selected as NSString).substring(with: NSRange(location: width, length: (selected as NSString).length - width * 2))
      return Edit(range: selection, replacement: inner, cursor: selection.location, selectionLength: (inner as NSString).length)
    }
    if before == marker, after == marker {
      return Edit(range: NSRange(location: selection.location - width, length: selection.length + width * 2), replacement: selected, cursor: selection.location - width, selectionLength: selection.length)
    }
    return Edit(range: selection, replacement: marker + selected + marker, cursor: selection.location + width, selectionLength: selection.length)
  }

  /// A selection across lines, line by line (pairs never span lines):
  /// when every line's part is already styled, each is unwrapped;
  /// otherwise each unstyled part is wrapped (folding in the pairs it
  /// touches) and the styled ones are left as they are, so the whole
  /// selection ends up styled. Blank parts and fenced code are skipped.
  private static func toggleWrapLines(in text: String, selection: NSRange, marker: String) -> Edit {
    let ns = text as NSString
    var segments: [NSRange] = []
    var location = selection.location
    while location < NSMaxRange(selection) {
      var lineEnd = 0
      var contentsEnd = 0
      ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let segment = NSRange(location: location, length: min(contentsEnd, NSMaxRange(selection)) - location)
      var lineStart = 0
      ns.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: location, length: 0))
      let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
      let isFenceLine = fenceLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
      if segment.length > 0, !ns.substring(with: segment).trimmingCharacters(in: .whitespaces).isEmpty,
        !isFenceLine, !insideFence(text, cursor: segment.location)
      {
        segments.append(segment)
      }
      if lineEnd == location { break }
      location = lineEnd
    }
    guard !segments.isEmpty else {
      return Edit(range: selection, replacement: ns.substring(with: selection), cursor: selection.location, selectionLength: selection.length)
    }
    let allStyled = segments.allSatisfy { wrapSpan(in: text, around: $0, marker: marker) != nil }
    var edits: [Edit] = []
    for segment in segments {
      let styled = wrapSpan(in: text, around: segment, marker: marker) != nil
      if allStyled || !styled { edits.append(toggleWrap(in: text, selection: segment, marker: marker)) }
    }
    guard let first = edits.first, let last = edits.last else {
      return Edit(range: selection, replacement: ns.substring(with: selection), cursor: selection.location, selectionLength: selection.length)
    }
    let whole = NSRange(location: min(first.range.location, selection.location), length: max(NSMaxRange(last.range), NSMaxRange(selection)) - min(first.range.location, selection.location))
    var composed = ""
    var cursor = whole.location
    for edit in edits {
      composed += ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)) + edit.replacement
      cursor = NSMaxRange(edit.range)
    }
    composed += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(whole) - cursor))
    return Edit(range: whole, replacement: composed, cursor: whole.location, selectionLength: (composed as NSString).length)
  }

  /// `[selection](url)` for ⌘L and for pasting a URL over a selection.
  /// With no url the caret lands between the parentheses, or between the
  /// brackets when nothing was selected.
  static func link(in text: String, selection: NSRange, url: String?) -> Edit {
    let selected = (text as NSString).substring(with: selection)
    // Parentheses and spaces would end the target early, so encode them.
    let target = (url ?? "")
      .replacingOccurrences(of: "(", with: "%28")
      .replacingOccurrences(of: ")", with: "%29")
      .replacingOccurrences(of: " ", with: "%20")
    let replacement = "[\(selected)](\(target))"
    let cursor: Int
    if url != nil {
      cursor = selection.location + (replacement as NSString).length
    } else if selection.length == 0 {
      cursor = selection.location + 1
    } else {
      cursor = selection.location + (selected as NSString).length + 3
    }
    return Edit(range: selection, replacement: replacement, cursor: cursor)
  }

  enum LinePrefix: Equatable {
    case heading(Int), quote, callout, bullet, ordered, task

    var text: String {
      switch self {
      case .heading(let level): return String(repeating: "#", count: level) + " "
      case .quote: return "> "
      case .callout: return ">> "
      case .bullet: return "- "
      case .ordered: return "1. "
      case .task: return "- [ ] "
      }
    }
  }

  private static let anyPrefix = try! NSRegularExpression(
    pattern: #"^([ \t]*)(#{1,6} |>> |> |[-*+] \[[ xX]\] |[-*+] |\d+\. )"#)

  /// Sets or clears a block prefix on the current line (⌥⌘1/2/3, ⇧⌘B,
  /// ⇧⌘7/8/9). Choosing the prefix the line already has removes it.
  static func setLinePrefix(in text: String, cursor: Int, prefix: LinePrefix) -> Edit {
    let ns = text as NSString
    var lineStart = 0
    var contentsEnd = 0
    ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
    let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
    let lineNS = line as NSString
    var indent = ""
    var rest = line
    var existing = ""
    if let match = anyPrefix.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) {
      indent = lineNS.substring(with: match.range(at: 1))
      existing = lineNS.substring(with: match.range(at: 2))
      rest = lineNS.substring(from: match.range.location + match.range.length)
    }
    let same: Bool
    switch prefix {
    case .ordered: same = existing.range(of: #"^\d+\. $"#, options: .regularExpression) != nil
    case .bullet: same = existing.range(of: #"^[-*+] $"#, options: .regularExpression) != nil
    case .task: same = existing.range(of: #"^[-*+] \[[ xX]\] $"#, options: .regularExpression) != nil
    default: same = existing == prefix.text
    }
    let replacement = same ? indent + rest : indent + prefix.text + rest
    let column = cursor - lineStart
    let oldPrefix = (indent + existing as NSString).length
    let newPrefix = same ? (indent as NSString).length : (indent + prefix.text as NSString).length
    let newColumn = column <= oldPrefix ? newPrefix : column - oldPrefix + newPrefix
    return Edit(range: NSRange(location: lineStart, length: contentsEnd - lineStart), replacement: replacement, cursor: lineStart + newColumn)
  }

  /// Wraps the selected lines (or the current line) in a code fence, or
  /// removes the fences when the selection sits inside a fenced block.
  static func toggleCodeBlock(in text: String, selection: NSRange) -> Edit {
    let ns = text as NSString
    if let fence = enclosingFence(in: ns, at: selection.location),
      NSMaxRange(selection) <= (fence.close.map(NSMaxRange) ?? ns.length) {
      let innerStart = NSMaxRange(fence.open)
      var inner = ns.substring(with: NSRange(location: innerStart, length: (fence.close?.location ?? ns.length) - innerStart))
      var closingBreak = ""
      if let close = fence.close {
        // The inner text's last break goes; the closing fence line's break stays.
        inner = String((inner as NSString).substring(to: (inner as NSString).length - (trailingBreak(inner) as NSString).length))
        closingBreak = trailingBreak(ns.substring(with: close))
      }
      let end = fence.close.map(NSMaxRange) ?? ns.length
      let length = (inner as NSString).length
      let range = NSRange(location: fence.open.location, length: end - fence.open.location)
      guard selection.length == 0 else {
        return Edit(range: range, replacement: inner + closingBreak, cursor: range.location, selectionLength: length)
      }
      let caret = min(max(selection.location - fence.open.length, range.location), range.location + length)
      return Edit(range: range, replacement: inner + closingBreak, cursor: caret)
    }
    let eol = lineBreak(in: text)
    let lineRange = ns.lineRange(for: selection)
    let lines = ns.substring(with: lineRange)
    let trailing = trailingBreak(lines)
    let body = (lines as NSString).substring(to: (lines as NSString).length - (trailing as NSString).length)
    let replacement = "```" + eol + body + eol + "```" + trailing
    return Edit(
      range: lineRange, replacement: replacement, cursor: lineRange.location + 3 + (eol as NSString).length,
      selectionLength: (body as NSString).length)
  }

  /// Line ranges (breaks included) of the fences around `location`, when
  /// it sits in a fenced block or on one of its fence lines. `close` is
  /// nil for a block left open to the end of the text.
  private static func enclosingFence(in ns: NSString, at location: Int) -> (open: NSRange, close: NSRange?)? {
    var open: (range: NSRange, marker: String)? = nil
    var start = 0
    while start < ns.length {
      var lineEnd = 0
      var contentsEnd = 0
      ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
      let line = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
      if let match = fenceLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
        let marker = (line as NSString).substring(with: match.range(at: 1))
        let lineRange = NSRange(location: start, length: lineEnd - start)
        if let current = open {
          if marker.first == current.marker.first, marker.count >= current.marker.count, match.range(at: 2).length == 0 {
            if location >= current.range.location, location <= contentsEnd { return (current.range, lineRange) }
            open = nil
          }
        } else {
          if location < start { return nil }
          open = (lineRange, marker)
        }
      }
      start = lineEnd
    }
    if let current = open, location >= current.range.location { return (current.range, nil) }
    return nil
  }
}
