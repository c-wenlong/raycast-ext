// List editing rules for the notes window, kept free of AppKit so they
// can be tested from the command line (test/ListEditingTests.swift).
//
// Every function takes the whole text plus a cursor offset (UTF-16) and
// returns the replacement for a range of whole lines plus the new cursor,
// so the text view can apply it as one undoable insertText call.

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
    while location <= ns.length {
      var lineEnd = 0
      var contentsEnd = 0
      ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let range = NSRange(location: location, length: contentsEnd - location)
      result.append(Line(range: range, text: ns.substring(with: range)))
      if lineEnd == location { break }  // last line, no trailing newline
      location = lineEnd
      if location == ns.length {
        // text ends with a newline: one more, empty line
        result.append(Line(range: NSRange(location: location, length: 0), text: ""))
        break
      }
    }
    return result
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
  private static func apply(
    block: ClosedRange<Int>, in lines: [Line], newLines: [String], cursorLine: Int, cursorColumn: Int
  ) -> Edit {
    let renumbered = renumber(newLines)
    let start = lines[block.lowerBound].range.location
    let end = lines[block.upperBound].range.location + lines[block.upperBound].range.length
    var cursor = start
    for (index, line) in renumbered.enumerated() {
      if index == cursorLine {
        cursor += min(cursorColumn, (line as NSString).length)
        break
      }
      cursor += (line as NSString).length + 1
    }
    return Edit(range: NSRange(location: start, length: end - start), replacement: renumbered.joined(separator: "\n"), cursor: cursor)
  }

  // MARK: Public operations

  /// Enter on a list item: continues the list, or ends it when the item
  /// is empty. Nil when the cursor is not on a list item.
  static func newline(in text: String, cursor: Int) -> Edit? {
    guard !insideFence(text, cursor: cursor) else { return nil }
    let all = lines(of: text)
    guard let index = all.firstIndex(where: { NSLocationInRange(cursor, $0.range) || cursor == $0.range.location + $0.range.length }),
      let item = parse(line: all[index].text)
    else { return nil }

    let blockRange = block(around: index, in: all)
    var newLines = all[blockRange].map(\.text)
    let local = index - blockRange.lowerBound

    if item.content.trimmingCharacters(in: .whitespaces).isEmpty {
      // Empty item: leave the list (outdent one level first if nested).
      if item.indent.isEmpty {
        newLines[local] = ""
        return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: 0)
      }
      let parentIndent = String(item.indent.dropLast(min(item.indent.count, parentIndentWidth(before: index, in: all, childIndent: item.indent.count))))
      let outdented = Item(indent: parentIndent, marker: item.marker, content: "")
      newLines[local] = outdented.line
      return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: (outdented.line as NSString).length)
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
    return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local + 1, cursorColumn: cursorColumn)
  }

  /// Tab (+1) or Shift-Tab (-1) on a list item. Nil when not on an item.
  static func indent(in text: String, cursor: Int, by delta: Int) -> Edit? {
    guard !insideFence(text, cursor: cursor) else { return nil }
    let all = lines(of: text)
    guard let index = all.firstIndex(where: { NSLocationInRange(cursor, $0.range) || cursor == $0.range.location + $0.range.length }),
      let item = parse(line: all[index].text)
    else { return nil }

    let blockRange = block(around: index, in: all)
    var newLines = all[blockRange].map(\.text)
    let local = index - blockRange.lowerBound
    let column = cursor - all[index].range.location

    let newIndent: String
    if delta > 0 {
      // Nest under the previous list item; without one there is nothing to nest under.
      guard index > 0, let parent = parse(line: all[index - 1].text) else { return nil }
      let width = parent.indent.count + parent.marker.childIndent
      guard width > item.indent.count else {
        newIndent = item.indent + String(repeating: " ", count: parent.marker.childIndent)
        newLines[local] = Item(indent: newIndent, marker: item.marker, content: item.content).line
        let shift = newIndent.count - item.indent.count
        return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: column + shift)
      }
      newIndent = String(repeating: " ", count: width)
    } else {
      guard !item.indent.isEmpty else { return nil }
      let width = parentIndentWidth(before: index, in: all, childIndent: item.indent.count)
      newIndent = String(item.indent.dropLast(min(item.indent.count, width)))
    }
    newLines[local] = Item(indent: newIndent, marker: item.marker, content: item.content).line
    let shift = newIndent.count - item.indent.count
    return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: max(column + shift, newIndent.count))
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
  static func insideFence(_ text: String, cursor: Int) -> Bool {
    let ns = text as NSString
    var open: String? = nil
    var location = 0
    while location < min(cursor, ns.length) {
      var lineEnd = 0
      var contentsEnd = 0
      ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let line = ns.substring(with: NSRange(location: location, length: contentsEnd - location))
      if let match = fenceLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
        let marker = (line as NSString).substring(with: match.range(at: 1))
        if let current = open {
          if marker.first == current.first, marker.count >= current.count, match.range(at: 2).length == 0 { open = nil }
        } else {
          open = marker
        }
      }
      if lineEnd == location { break }
      location = lineEnd
    }
    return open != nil
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
    let marker = (line as NSString).substring(with: match.range(at: 1))
    let trimmed = line.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
    let replacement = "\(trimmed)\n\n\(marker)"
    return Edit(range: NSRange(location: lineStart, length: cursor - lineStart), replacement: replacement, cursor: lineStart + (trimmed as NSString).length + 1)
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
    let all = lines(of: text)
    guard let index = all.firstIndex(where: { NSLocationInRange(cursor, $0.range) || cursor == $0.range.location + $0.range.length }),
      let item = parse(line: all[index].text),
      cursor - all[index].range.location == (item.indent + item.marker.text).count,
      !insideFence(text, cursor: all[index].range.location)
    else { return nil }

    let blockRange = block(around: index, in: all)
    var newLines = all[blockRange].map(\.text)
    let local = index - blockRange.lowerBound
    if item.indent.isEmpty {
      newLines[local] = item.content
      return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: 0)
    }
    let width = parentIndentWidth(before: index, in: all, childIndent: item.indent.count)
    let outdented = Item(indent: String(item.indent.dropLast(min(item.indent.count, width))), marker: item.marker, content: item.content)
    newLines[local] = outdented.line
    return apply(block: blockRange, in: all, newLines: newLines, cursorLine: local, cursorColumn: (outdented.indent + outdented.marker.text).count)
  }

  // MARK: Formatting shortcuts

  /// Wraps the selection in `marker` (⌘B, ⌘I, ⇧⌘S, ⌘E), or unwraps it
  /// when already wrapped. An empty selection gets an empty pair with the
  /// caret inside.
  static func toggleWrap(in text: String, selection: NSRange, marker: String) -> Edit {
    let ns = text as NSString
    let selected = ns.substring(with: selection)
    let width = (marker as NSString).length
    if selected.hasPrefix(marker), selected.hasSuffix(marker), (selected as NSString).length >= width * 2 {
      let inner = (selected as NSString).substring(with: NSRange(location: width, length: (selected as NSString).length - width * 2))
      return Edit(range: selection, replacement: inner, cursor: selection.location, selectionLength: (inner as NSString).length)
    }
    let before = selection.location >= width ? ns.substring(with: NSRange(location: selection.location - width, length: width)) : ""
    let afterStart = selection.location + selection.length
    let after = afterStart + width <= ns.length ? ns.substring(with: NSRange(location: afterStart, length: width)) : ""
    if before == marker, after == marker {
      return Edit(range: NSRange(location: selection.location - width, length: selection.length + width * 2), replacement: selected, cursor: selection.location - width, selectionLength: selection.length)
    }
    return Edit(range: selection, replacement: marker + selected + marker, cursor: selection.location + width, selectionLength: selection.length)
  }

  /// `[selection](url)` for ⌘L and for pasting a URL over a selection.
  /// With no url the caret lands between the parentheses.
  static func link(in text: String, selection: NSRange, url: String?) -> Edit {
    let selected = (text as NSString).substring(with: selection)
    let target = url ?? ""
    let replacement = "[\(selected)](\(target))"
    let cursor = selection.location + (selected as NSString).length + 3
    return Edit(range: selection, replacement: replacement, cursor: url == nil ? cursor : selection.location + (replacement as NSString).length)
  }

  enum LinePrefix: Equatable {
    case heading(Int), quote, bullet, ordered, task

    var text: String {
      switch self {
      case .heading(let level): return String(repeating: "#", count: level) + " "
      case .quote: return "> "
      case .bullet: return "- "
      case .ordered: return "1. "
      case .task: return "- [ ] "
      }
    }
  }

  private static let anyPrefix = try! NSRegularExpression(
    pattern: #"^([ \t]*)(#{1,6} |> |[-*+] \[[ xX]\] |[-*+] |\d+\. )"#)

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
  /// removes the fence when the selection is exactly a fenced block.
  static func toggleCodeBlock(in text: String, selection: NSRange) -> Edit {
    let ns = text as NSString
    let lineRange = ns.lineRange(for: selection)
    var body = ns.substring(with: lineRange)
    let trailingNewline = body.hasSuffix("\n")
    if trailingNewline { body.removeLast() }
    let lines = body.components(separatedBy: "\n")
    if lines.count >= 2, let first = lines.first, let last = lines.last,
      first.range(of: #"^ {0,3}(`{3,}|~{3,})"#, options: .regularExpression) != nil,
      last.range(of: #"^ {0,3}(`{3,}|~{3,})[ \t]*$"#, options: .regularExpression) != nil {
      let inner = lines.dropFirst().dropLast().joined(separator: "\n")
      let replacement = inner + (trailingNewline ? "\n" : "")
      return Edit(range: lineRange, replacement: replacement, cursor: lineRange.location, selectionLength: (inner as NSString).length)
    }
    let replacement = "```\n" + body + "\n```" + (trailingNewline ? "\n" : "")
    return Edit(range: lineRange, replacement: replacement, cursor: lineRange.location + 4, selectionLength: (body as NSString).length)
  }
}
