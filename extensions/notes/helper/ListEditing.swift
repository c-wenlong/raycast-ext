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

  // Shared with Markdown: editing boundaries must match rendered syntax,
  // including the exclusion of numbered checkbox lines from bullet styling.
  static let taskPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+(\[[ xX]\])(?:[ \t]+(.*))?$"#, options: .anchorsMatchLines)
  // Possessive whitespace prevents backtracking into the task marker.
  static let bulletPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+\.)[ \t]++(?!\[[ xX]\])"#, options: .anchorsMatchLines)

  /// The actual rendered prefix, including indentation and separator spacing.
  static func listMarkerRange(in line: String) -> NSRange? {
    let all = NSRange(location: 0, length: (line as NSString).length)
    if let task = taskPattern.firstMatch(in: line, range: all) {
      let body = task.range(at: 4)
      return NSRange(location: 0, length: body.location == NSNotFound ? NSMaxRange(task.range) : body.location)
    }
    return bulletPattern.firstMatch(in: line, range: all)?.range
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

  // MARK: Block markers
  //
  // A line can start with block markers, after any indent and always in
  // this order: "| " (quote), "> " (toggle), "#" to "#### " (heading).
  // A callout, "!> ", stands alone. Every marker needs the whitespace
  // after it: "|text", ">text" and a bare "#" are plain text. The
  // renderer (Markdown.apply) reads lines with the same parser, so a
  // marker the rules can remove is exactly a marker that is hidden.

  enum MarkerKind: Equatable { case quote, toggle, heading, callout }

  struct MarkerUnit: Equatable {
    let kind: MarkerKind
    /// The symbol(s) and the whitespace after them, in the line (UTF-16).
    let range: NSRange
  }

  struct BlockPrefix: Equatable {
    /// Length of the leading whitespace (UTF-16).
    var indent = 0
    /// The markers in the order they appear.
    var units: [MarkerUnit] = []
    var headingLevel = 0

    var contentStart: Int { units.last.map { NSMaxRange($0.range) } ?? indent }
    var hasMarkers: Bool { !units.isEmpty }
    func unit(_ kind: MarkerKind) -> MarkerUnit? { units.first { $0.kind == kind } }
    var quote: Bool { unit(.quote) != nil }
    var toggle: Bool { unit(.toggle) != nil }
    var callout: Bool { unit(.callout) != nil }
  }

  /// The block markers at the start of `line` (no line break).
  static func blockPrefix(of line: String) -> BlockPrefix {
    let u = Array(line.utf16)
    func at(_ index: Int) -> UInt16? { index < u.count ? u[index] : nil }
    func isBlank(_ c: UInt16?) -> Bool { c == 0x20 || c == 0x09 }
    var prefix = BlockPrefix()
    var i = 0
    while isBlank(at(i)) { i += 1 }
    prefix.indent = i
    if at(i) == 0x21, at(i + 1) == 0x3E, at(i + 2) == 0x20 {  // "!> "
      prefix.units = [MarkerUnit(kind: .callout, range: NSRange(location: i, length: 3))]
      return prefix
    }
    if at(i) == 0x7C, at(i + 1) == 0x20 {  // "| "
      prefix.units.append(MarkerUnit(kind: .quote, range: NSRange(location: i, length: 2)))
      i += 2
    }
    if at(i) == 0x3E, at(i + 1) == 0x20 {  // "> "
      prefix.units.append(MarkerUnit(kind: .toggle, range: NSRange(location: i, length: 2)))
      i += 2
    }
    var hashes = 0
    while at(i + hashes) == 0x23 { hashes += 1 }
    if (1...4).contains(hashes), isBlank(at(i + hashes)) {
      var end = i + hashes
      while isBlank(at(end)) { end += 1 }
      prefix.units.append(MarkerUnit(kind: .heading, range: NSRange(location: i, length: end - i)))
      prefix.headingLevel = hashes
    }
    return prefix
  }

  /// The canonical marker text for a stack: "| ", "> ", "#… " in order.
  static func markerText(quote: Bool, toggle: Bool, heading: Int) -> String {
    (quote ? "| " : "") + (toggle ? "> " : "") + (heading > 0 ? String(repeating: "#", count: heading) + " " : "")
  }

  /// The line holding `cursor`: its start, the end of its contents, and
  /// its text without the line break.
  private static func line(at cursor: Int, in text: String) -> (start: Int, end: Int, text: String) {
    let ns = text as NSString
    var lineStart = 0
    var contentsEnd = 0
    ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(cursor, ns.length), length: 0))
    return (lineStart, contentsEnd, ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart)))
  }

  // MARK: Toggles

  /// A toggle line ("> ") and its children: the lines right after it
  /// indented deeper than it is. A line at the same or a shallower indent
  /// (an empty line included) ends it. A fenced block whose opening fence
  /// is a child is a child to its closing fence.
  struct Toggle: Equatable {
    /// The title line, without its line break.
    let title: NSRange
    /// Indent of the title line, in columns (a tab counts four).
    let indent: Int
    /// From the first child's start to the start of the line after the
    /// last child (or the end of the text); empty when it has none.
    let children: NSRange
    /// Line starts of the children.
    let childLines: [Int]
  }

  private static func columns(_ line: String) -> Int {
    var count = 0
    for c in line {
      if c == " " { count += 1 } else if c == "\t" { count += 4 } else { break }
    }
    return count
  }

  /// Line index ranges of the closed fenced blocks, fence lines included.
  private static func fenceSpans(_ lines: [Line]) -> [ClosedRange<Int>] {
    var spans: [ClosedRange<Int>] = []
    var open: (marker: String, index: Int)? = nil
    for (index, line) in lines.enumerated() {
      guard let match = fenceLine.firstMatch(in: line.text, range: NSRange(location: 0, length: (line.text as NSString).length))
      else { continue }
      let marker = (line.text as NSString).substring(with: match.range(at: 1))
      if let current = open {
        if marker.first == current.marker.first, marker.count >= current.marker.count, match.range(at: 2).length == 0 {
          spans.append(current.index...index)
          open = nil
        }
      } else {
        open = (marker, index)
      }
    }
    return spans
  }

  /// Every toggle in `text`, in order, and how many toggles each child
  /// line sits inside (keyed by line start; lines outside any are absent).
  static func toggleLayout(in text: String) -> (toggles: [Toggle], depth: [Int: Int]) {
    let all = lines(of: text)
    let spans = fenceSpans(all)
    var spanAt: [Int: ClosedRange<Int>] = [:]
    var inFence = Set<Int>()
    for span in spans {
      spanAt[span.lowerBound] = span
      for index in span { inFence.insert(index) }
    }
    var toggles: [Toggle] = []
    var depth: [Int: Int] = [:]
    for index in all.indices where !inFence.contains(index) {
      let text = all[index].text
      guard blockPrefix(of: text).toggle else { continue }
      let indent = columns(text)
      var next = index + 1
      while next < all.count, columns(all[next].text) > indent {
        next = (spanAt[next]?.upperBound ?? next) + 1
      }
      let childIndexes = Array((index + 1)..<max(index + 1, min(next, all.count)))
      var children = NSRange(location: NSMaxRange(all[index].range), length: 0)
      if let first = childIndexes.first, let last = childIndexes.last {
        let start = all[first].range.location
        let end = last + 1 < all.count ? all[last + 1].range.location : NSMaxRange(all[last].range)
        children = NSRange(location: start, length: end - start)
      }
      let starts = childIndexes.map { all[$0].range.location }
      for start in starts { depth[start, default: 0] += 1 }
      toggles.append(Toggle(title: all[index].range, indent: indent, children: children, childLines: starts))
    }
    return (toggles, depth)
  }

  /// True when the line starting at `lineStart` is a toggle's child.
  private static func isToggleChild(_ text: String, lineStart: Int) -> Bool {
    (toggleLayout(in: text).depth[lineStart] ?? 0) > 0
  }

  /// The indent with one level taken off its end: a tab, or up to two spaces.
  private static func outdented(_ indent: String) -> String {
    if indent.hasSuffix("\t") { return String(indent.dropLast()) }
    var result = indent
    var removed = 0
    while removed < 2, result.hasSuffix(" ") { result.removeLast(); removed += 1 }
    return result
  }

  // MARK: Marker stacking

  /// A space typed right after "|", ">" or "#"…"####" at the content start
  /// of a line (the very start, or just past its hidden markers) rewrites
  /// the line's markers in canonical order, consuming what was typed:
  /// headings replace headings, a toggle adds to a heading and the other
  /// way round, a quote can take a heading or a toggle but typing "| "
  /// on a heading or toggle line makes it a plain quote. Called with the
  /// text before the space, `cursor` where the space goes; the edit ends
  /// at the cursor. Nil when nothing needs rewriting.
  static func stackMarkers(in text: String, cursor: Int) -> Edit? {
    let (lineStart, _, line) = line(at: cursor, in: text)
    guard !insideFence(text, cursor: lineStart) else { return nil }
    let u = Array(line.utf16)
    let column = cursor - lineStart
    guard column > 0, column <= u.count else { return nil }
    enum Typed { case quote, toggle, heading(Int) }
    var symbolStart = column - 1
    let typed: Typed
    switch u[column - 1] {
    case 0x7C: typed = .quote
    case 0x3E: typed = .toggle
    case 0x23:
      while symbolStart > 0, u[symbolStart - 1] == 0x23 { symbolStart -= 1 }
      guard column - symbolStart <= 4 else { return nil }
      typed = .heading(column - symbolStart)
    default: return nil
    }
    let lineNS = line as NSString
    let original = lineNS.replacingCharacters(in: NSRange(location: symbolStart, length: column - symbolStart), with: "")
    let prefix = blockPrefix(of: original)
    guard symbolStart == prefix.contentStart, !prefix.callout else { return nil }
    var quote = prefix.quote
    var toggle = prefix.toggle
    var heading = prefix.headingLevel
    switch typed {
    case .heading(let level): heading = level
    case .toggle: toggle = true
    case .quote:
      if !quote {
        quote = true
        toggle = false
        heading = 0
      }
    }
    let replacement = lineNS.substring(to: prefix.indent) + markerText(quote: quote, toggle: toggle, heading: heading)
    return Edit(
      range: NSRange(location: lineStart, length: column), replacement: replacement,
      cursor: lineStart + (replacement as NSString).length)
  }

  /// Backspace at the content start of a line with markers takes off one
  /// marker, the innermost (heading, then toggle, then quote; a callout
  /// on its own), keeping the text. On a toggle's child with no markers
  /// left it takes off one level of indent. Nil otherwise (plain
  /// Backspace: join with the line before).
  static func peelMarker(in text: String, cursor: Int) -> Edit? {
    let (lineStart, _, line) = line(at: cursor, in: text)
    guard !insideFence(text, cursor: lineStart) else { return nil }
    let prefix = blockPrefix(of: line)
    let column = cursor - lineStart
    guard prefix.contentStart > 0, column <= prefix.contentStart else { return nil }
    if let unit = prefix.units.last {
      return Edit(
        range: NSRange(location: lineStart + unit.range.location, length: unit.range.length), replacement: "",
        cursor: lineStart + unit.range.location)
    }
    guard parse(line: line) == nil, isToggleChild(text, lineStart: lineStart) else { return nil }
    let indent = (line as NSString).substring(to: prefix.indent)
    let shorter = outdented(indent)
    return Edit(
      range: NSRange(location: lineStart, length: prefix.indent), replacement: shorter,
      cursor: lineStart + (shorter as NSString).length)
  }

  // MARK: Enter on blocks

  /// Enter on a toggle line. An empty title loses its toggle marker. On
  /// an open toggle the text after the caret moves to a new first child,
  /// one level deeper (a quoted toggle's child stays quoted); on a
  /// collapsed one (`collapsed`) it moves to a new sibling toggle after
  /// the hidden children. A caret at the title's start counts as its end.
  static func toggleNewline(in text: String, cursor: Int, collapsed: Bool) -> Edit? {
    let (lineStart, contentsEnd, line) = line(at: cursor, in: text)
    guard !insideFence(text, cursor: lineStart) else { return nil }
    let prefix = blockPrefix(of: line)
    guard let toggleUnit = prefix.unit(.toggle) else { return nil }
    let lineNS = line as NSString
    let content = lineNS.substring(from: prefix.contentStart)
    if content.trimmingCharacters(in: .whitespaces).isEmpty {
      return Edit(
        range: NSRange(location: lineStart + toggleUnit.range.location, length: toggleUnit.range.length), replacement: "",
        cursor: lineStart + prefix.contentStart - toggleUnit.range.length)
    }
    let eol = lineBreak(in: text)
    let ns = text as NSString
    let split = cursor - lineStart <= prefix.contentStart ? contentsEnd : cursor
    let tail = ns.substring(with: NSRange(location: split, length: contentsEnd - split))
      .replacingOccurrences(of: #"^[ \t]+"#, with: "", options: .regularExpression)
    let indent = lineNS.substring(to: prefix.indent)
    if !collapsed {
      let inserted = eol + indent + "  " + (prefix.quote ? "| " : "")
      return Edit(
        range: NSRange(location: split, length: contentsEnd - split), replacement: inserted + tail,
        cursor: split + (inserted as NSString).length)
    }
    var lastEnd = contentsEnd
    if let children = toggleLayout(in: text).toggles.first(where: { $0.title.location == lineStart })?.children,
      children.length > 0
    {
      // The end of the last child's text, before its line break.
      let childText = ns.substring(with: children)
      lastEnd = NSMaxRange(children) - (trailingBreak(childText) as NSString).length
    }
    let hidden = ns.substring(with: NSRange(location: contentsEnd, length: lastEnd - contentsEnd))
    let inserted = hidden + eol + indent + markerText(quote: prefix.quote, toggle: true, heading: prefix.headingLevel)
    return Edit(
      range: NSRange(location: split, length: lastEnd - split), replacement: inserted + tail,
      cursor: split + (inserted as NSString).length)
  }

  /// Enter on a quote ("| ") or callout ("!> ") line: the block continues
  /// on the next line, or its markers go when the line is empty. Nil when
  /// the cursor is not in one. (Toggle lines go to toggleNewline first.)
  static func quoteNewline(in text: String, cursor: Int) -> Edit? {
    let (lineStart, contentsEnd, line) = line(at: cursor, in: text)
    guard !insideFence(text, cursor: lineStart) else { return nil }
    let prefix = blockPrefix(of: line)
    guard prefix.quote || prefix.callout else { return nil }
    let lineNS = line as NSString
    if lineNS.substring(from: prefix.contentStart).trimmingCharacters(in: .whitespaces).isEmpty {
      return Edit(
        range: NSRange(location: lineStart + prefix.indent, length: contentsEnd - lineStart - prefix.indent),
        replacement: "", cursor: lineStart + prefix.indent)
    }
    let at = max(cursor, lineStart + prefix.contentStart)
    let inserted = lineBreak(in: text) + lineNS.substring(to: prefix.indent) + (prefix.callout ? "!> " : "| ")
    return Edit(range: NSRange(location: at, length: 0), replacement: inserted, cursor: at + (inserted as NSString).length)
  }

  /// Enter on a toggle's child (not a list item, quote or toggle): the
  /// next line is a child at the same indent; an empty child steps out
  /// one level instead. Nil when the line is not a child.
  static func childNewline(in text: String, cursor: Int) -> Edit? {
    let (lineStart, contentsEnd, line) = line(at: cursor, in: text)
    guard !insideFence(text, cursor: lineStart), parse(line: line) == nil else { return nil }
    let prefix = blockPrefix(of: line)
    guard !prefix.quote, !prefix.toggle, !prefix.callout, prefix.indent > 0,
      isToggleChild(text, lineStart: lineStart)
    else { return nil }
    let lineNS = line as NSString
    let indent = lineNS.substring(to: prefix.indent)
    if lineNS.substring(from: prefix.contentStart).trimmingCharacters(in: .whitespaces).isEmpty {
      let shorter = outdented(indent)
      return Edit(
        range: NSRange(location: lineStart, length: contentsEnd - lineStart), replacement: shorter,
        cursor: lineStart + (shorter as NSString).length)
    }
    let at = max(cursor, lineStart + prefix.contentStart)
    let inserted = lineBreak(in: text) + indent
    let tail = (text as NSString).substring(with: NSRange(location: at, length: contentsEnd - at))
    return Edit(
      range: NSRange(location: at, length: contentsEnd - at), replacement: inserted + tail,
      cursor: at + (inserted as NSString).length)
  }

  /// Moves the text of the line starting at `lineStart` onto the end of
  /// an earlier line (`target`, the end of that line's text), dropping
  /// the line break before it. Backspace at the start of the line after
  /// a collapsed toggle, and Delete at the end of its title, join the
  /// title and that line this way rather than editing hidden children.
  /// Only the line's text moves: its indent and markers (block markers or
  /// a list marker) are dropped, so none lands mid-line as raw text.
  static func joinLine(in text: String, lineStart: Int, onto target: Int) -> Edit? {
    let ns = text as NSString
    guard target < lineStart, lineStart <= ns.length else { return nil }
    let whole = line(at: lineStart, in: text).text
    let wholeNS = whole as NSString
    let lineLength = wholeNS.length
    var textStart = blockPrefix(of: whole).contentStart
    if textStart == blockPrefix(of: whole).indent,
      let list = listMarkerRange(in: whole)
    {
      textStart = NSMaxRange(list)
    }
    let moved = wholeNS.substring(from: textStart)
    let between = ns.substring(with: NSRange(location: target, length: lineStart - target))
    let kept = (between as NSString).substring(to: (between as NSString).length - (trailingBreak(between) as NSString).length)
    return Edit(
      range: NSRange(location: target, length: lineStart + lineLength - target),
      replacement: moved + kept, cursor: target)
  }

  // MARK: Deleting a range

  /// The range a deletion of `range` really removes, so that no marker
  /// is left half there or stranded mid-line as raw text: an end inside
  /// a line's markers grows to take that marker whole, and when the
  /// deletion joins two lines the markers left at the start of the second
  /// go too. A range reaching into a collapsed toggle's children
  /// (`folded`) takes all of them.
  static func deletionRange(in text: String, range: NSRange, folded: [NSRange] = []) -> NSRange {
    guard range.length > 0 else { return range }
    let ns = text as NSString
    var start = range.location
    var end = NSMaxRange(range)
    for fold in folded {
      if start >= fold.location, start < NSMaxRange(fold) { start = fold.location }
      if end > fold.location, end < NSMaxRange(fold) { end = NSMaxRange(fold) }
    }
    let depth = toggleLayout(in: text).depth
    // Where a deletion may start or end inside a line's hidden prefix,
    // and where its text begins; nil for a line with nothing hidden.
    func boundaries(at location: Int) -> (lineStart: Int, stops: [Int], contentStart: Int)? {
      let current = line(at: location, in: text)
      let (lineStart, _, line) = current
      // A divider is hidden whole: kept whole or removed whole.
      if isDivider(current, in: text) {
        let length = (line as NSString).length
        return (lineStart, [0, length], length)
      }
      guard !insideFence(text, cursor: lineStart) else { return nil }
      if let prefix = listMarkerRange(in: line) {
        let end = NSMaxRange(prefix)
        return (lineStart, [0, end], end)
      }
      let prefix = blockPrefix(of: line)
      let child = (depth[lineStart] ?? 0) > 0
      guard prefix.hasMarkers || (child && prefix.indent > 0) else { return nil }
      return (lineStart, [0, prefix.indent] + prefix.units.map { NSMaxRange($0.range) }, prefix.contentStart)
    }
    if let b = boundaries(at: start), start - b.lineStart < b.contentStart {
      let column = start - b.lineStart
      start = b.lineStart + (b.stops.filter { $0 <= column }.max() ?? 0)
    }
    if let b = boundaries(at: end), end - b.lineStart < b.contentStart {
      let column = end - b.lineStart
      end = b.lineStart + (b.stops.filter { $0 >= column }.min() ?? b.contentStart)
      let startLine = ns.lineRange(for: NSRange(location: start, length: 0)).location
      if startLine != b.lineStart, start != startLine {
        end = b.lineStart + b.contentStart
      }
    }
    return NSRange(location: start, length: max(0, end - start))
  }

  /// Removes the current line's block prefix (its whole marker stack, or
  /// its list marker), turning it into plain text. Nil when there is none.
  static func clearLinePrefix(in text: String, cursor: Int) -> Edit? {
    let (lineStart, _, line) = line(at: cursor, in: text)
    let prefix = blockPrefix(of: line)
    let removed: NSRange
    if prefix.hasMarkers {
      removed = NSRange(location: prefix.indent, length: prefix.contentStart - prefix.indent)
    } else if let match = listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
      removed = match.range(at: 2)
    } else {
      return nil
    }
    let column = cursor - lineStart
    let newColumn = column <= NSMaxRange(removed) ? removed.location : column - removed.length
    return Edit(range: NSRange(location: lineStart + removed.location, length: removed.length), replacement: "", cursor: lineStart + newColumn)
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
  /// a code block, "> " on a heading stacks the markers), checked after the space is in the text so the first
  /// undo steps back to exactly what was typed. The edit covers the space.
  static func afterSpace(in text: String, cursor: Int) -> Edit? {
    let ns = text as NSString
    guard cursor > 0, cursor <= ns.length, ns.character(at: cursor - 1) == 0x20 else { return nil }
    let before = ns.replacingCharacters(in: NSRange(location: cursor - 1, length: 1), with: "")
    guard
      let edit = taskShortcut(in: before, cursor: cursor - 1) ?? codeFence(in: before, cursor: cursor - 1)
        ?? stackMarkers(in: before, cursor: cursor - 1)
    else { return nil }
    // Both rules end their range at the cursor, which is where the space sits.
    let range = NSRange(location: edit.range.location, length: edit.range.length + 1)
    guard ns.substring(with: range) != edit.replacement else { return nil }
    return Edit(range: range, replacement: edit.replacement, cursor: edit.cursor, selectionLength: edit.selectionLength)
  }

  // MARK: Typography

  /// A bare http(s) address, as the styler links it (Markdown.bareURL):
  /// not right after `(` or a word character, and ending at whitespace,
  /// `<`, `>`, `)` or `]`. The scheme matches in any case.
  static let bareURLPattern = #"(?<![\(\w])(?i:https?)://[^\s<>\)\]]"#

  /// Text before the caret that ends inside a link address: after `](`
  /// with no `)` yet, or in a bare address with the styler's boundary.
  private static let urlBeforeCaret = try! NSRegularExpression(pattern: #"(?:\]\([^)\s]*|"# + bareURLPattern + "*)$")

  /// A line that opens (or closes) a fence, from its start up to the
  /// caret: the pair would be fence text or the info string.
  private static let fencePrefix = try! NSRegularExpression(pattern: #"^ {0,3}(?:`{3,}|~{3,})"#)

  /// The typed characters that can finish a typographic pair.
  static let typographyTriggers: Set<String> = [">", "-", "=", "."]

  /// A typed character that finishes a pair turns it into one symbol:
  /// `->` →, `=>` ⇒, `<-` ←, `--` – (en dash), `>=` ≥, `<=` ≤, `...` ….
  /// Checked after the character is in the text (like `afterSpace`) so the
  /// first undo gives back what was typed. Only the characters right
  /// before the caret count, so a symbol already made can finish the next
  /// one: `-->` gives → (its `--` became –), `<->` ↔, `<=>` ⇔, `<-->` ↔.
  /// `<--` gives ←- and `....` gives …. (nothing further).
  /// `--` with only whitespace and dashes before it on its line stays
  /// literal, so `---` (and `----`) still types a divider. Code stays
  /// literal: inside a fenced block (as the styler draws it), an inline code
  /// span (`inCodeSpan`, closed or still being typed), or on a fence line (``` or ~~~, closed or still being
  /// typed). So do link addresses: after `](` with no `)` yet, or inside
  /// an `http(s)://` address as the styler bounds it.
  static func typography(in text: String, cursor: Int) -> Edit? {
    let ns = text as NSString
    guard cursor >= 2, cursor <= ns.length else { return nil }
    func at(_ index: Int) -> unichar? { index >= 0 ? ns.character(at: index) : nil }
    var length = 2
    let symbol: String
    switch (ns.character(at: cursor - 2), ns.character(at: cursor - 1)) {
    case (0x2D, 0x3E):  // ->, or <--> after its <- became ←
      if at(cursor - 3) == 0x2190 {
        length = 3
        symbol = "\u{2194}"
      } else {
        symbol = "\u{2192}"
      }
    case (0x2013, 0x3E): symbol = "\u{2192}"  // -->, its -- already an en dash
    case (0x2190, 0x3E): symbol = "\u{2194}"  // <->
    case (0x3D, 0x3E): symbol = "\u{21D2}"  // =>
    case (0x2264, 0x3E): symbol = "\u{21D4}"  // <=>
    case (0x3C, 0x2D): symbol = "\u{2190}"  // <-
    case (0x2D, 0x2D): symbol = "\u{2013}"  // --
    case (0x3E, 0x3D): symbol = "\u{2265}"  // >=
    case (0x3C, 0x3D): symbol = "\u{2264}"  // <=
    case (0x2E, 0x2E) where at(cursor - 3) == 0x2E:  // ...
      length = 3
      symbol = "\u{2026}"
    default: return nil
    }
    let start = cursor - length
    let lineStart = ns.lineRange(for: NSRange(location: start, length: 0)).location
    let before = ns.substring(with: NSRange(location: lineStart, length: start - lineStart))
    // Dashes that start a line stay dashes: "---" types a divider.
    if symbol == "\u{2013}", before.drop(while: { $0 == " " || $0 == "\t" }).allSatisfy({ $0 == "-" }) { return nil }
    guard !inCodeSpan(ns, NSRange(location: start, length: length)),
      urlBeforeCaret.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) == nil,
      fencePrefix.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) == nil,
      !inCodeBlock(text, NSRange(location: start, length: length))
    else { return nil }
    return Edit(range: NSRange(location: start, length: length), replacement: symbol, cursor: start + 1)
  }

  /// True when `range` sits in inline code on its line, for the typing
  /// rules (typography, date keywords): inside a span the styler draws
  /// (`codePattern`), inside a backtick run closed by the next run of the
  /// same length (``` ``a->b`` ```), or after a run that nothing closes yet
  /// (a span still being typed). That last case errs towards code: a stray
  /// backtick earlier on the line keeps the rest of it literal, which only
  /// ever leaves typed text alone.
  static func inCodeSpan(_ ns: NSString, _ range: NSRange) -> Bool {
    let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
    let end = NSMaxRange(line)
    var runs: [NSRange] = []
    var index = line.location
    while index < end {
      guard ns.character(at: index) == 0x60 else { index += 1; continue }
      var after = index
      while after < end, ns.character(at: after) == 0x60 { after += 1 }
      runs.append(NSRange(location: index, length: after - index))
      index = after
    }
    guard !runs.isEmpty else { return false }
    var next = 0
    while next < runs.count, runs[next].location < NSMaxRange(range) {
      let open = runs[next]
      guard let close = runs[(next + 1)...].firstIndex(where: { $0.length == open.length }) else {
        if open.location < range.location { return true }
        break
      }
      if NSIntersectionRange(NSRange(location: open.location, length: NSMaxRange(runs[close]) - open.location), range).length > 0 {
        return true
      }
      next = close + 1
    }
    return codePattern.matches(in: ns as String, range: line).contains { NSIntersectionRange($0.range, range).length > 0 }
  }

  // MARK: Dividers

  /// A horizontal rule line, shared with the styler (Markdown.rule), which
  /// draws it as a hairline with the characters hidden.
  static let rulePattern = try! NSRegularExpression(pattern: #"^(?:-{3,}|_{3,}|\*{3,})[ \t]*$"#, options: .anchorsMatchLines)

  /// A fenced code block as the styler draws it (Markdown.fence): an
  /// opening fence line (any info string) through its closing fence. An
  /// opening fence with no closing fence is literal text.
  static let fencePattern = try! NSRegularExpression(
    pattern: #"^ {0,3}(?:(`{3,})|(~{3,}))[^\n]*\n[\s\S]*?^ {0,3}(?:\1`*|\2~*)[ \t]*$"#, options: .anchorsMatchLines)

  /// True when `range` touches a fenced code block, exactly as the styler
  /// decides what is code (its `inCode`).
  static func inCodeBlock(_ text: String, _ range: NSRange) -> Bool {
    fencePattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
      .contains { NSIntersectionRange($0.range, range).length > 0 }
  }

  /// True when `line` (no line break) is a divider: a rule the styler
  /// draws, so not in a code block.
  private static func isDivider(_ line: (start: Int, end: Int, text: String), in text: String) -> Bool {
    let length = (line.text as NSString).length
    return rulePattern.firstMatch(in: line.text, range: NSRange(location: 0, length: length)) != nil
      && !inCodeBlock(text, NSRange(location: line.start, length: length))
  }

  /// Backspace on a divider line takes the divider off, leaving the line
  /// empty; at the start of the line after one, it removes the divider's
  /// whole line. Either way the dashes never show as text.
  static func dividerBackspace(in text: String, cursor: Int) -> Edit? {
    let current = line(at: cursor, in: text)
    if current.end > current.start, isDivider(current, in: text) {
      return Edit(range: NSRange(location: current.start, length: current.end - current.start), replacement: "", cursor: current.start)
    }
    guard cursor == current.start, cursor > 0 else { return nil }
    let previous = line(at: cursor - 1, in: text)
    guard isDivider(previous, in: text) else { return nil }
    return Edit(range: NSRange(location: previous.start, length: cursor - previous.start), replacement: "", cursor: previous.start)
  }

  /// Delete on a divider line takes the divider off, leaving the line
  /// empty. (Delete at the end of the line before one goes through
  /// `deletionRange`, which keeps the divider whole.)
  static func dividerDelete(in text: String, cursor: Int) -> Edit? {
    let current = line(at: cursor, in: text)
    guard current.end > current.start, isDivider(current, in: text) else { return nil }
    return Edit(range: NSRange(location: current.start, length: current.end - current.start), replacement: "", cursor: current.start)
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
      cursor - all[index].range.location == listMarkerRange(in: all[index].text)?.length,
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
      // The selection keeps to the same visible text: each position moves
      // right by the new opening marker and left by the marker
      // characters removed before it.
      func shifted(_ position: Int) -> Int {
        var removed = 0
        for span in touched {
          removed += min(max(position - span.location, 0), width)
          removed += min(max(position - (NSMaxRange(span) - width), 0), width)
        }
        return position + width - removed
      }
      let start = shifted(selection.location)
      return Edit(range: range, replacement: marker + inner + marker, cursor: start, selectionLength: shifted(NSMaxRange(selection)) - start)
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
    // The selection keeps to the visible text it covered: its ends map
    // through the edit on their own line (each line edit already reports
    // where its selected text lands), or shift by what changed before them.
    var composed = ""
    var cursor = whole.location
    var newStart = selection.location
    var newEnd: Int?
    for edit in edits {
      composed += ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor))
      let editStart = whole.location + (composed as NSString).length
      if selection.location >= edit.range.location, selection.location <= NSMaxRange(edit.range) {
        newStart = editStart + (edit.cursor - edit.range.location)
      }
      if NSMaxRange(selection) >= edit.range.location, NSMaxRange(selection) <= NSMaxRange(edit.range) {
        newEnd = editStart + (edit.cursor - edit.range.location) + edit.selectionLength
      }
      composed += edit.replacement
      cursor = NSMaxRange(edit.range)
    }
    composed += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(whole) - cursor))
    let end = newEnd ?? NSMaxRange(selection) + (composed as NSString).length - whole.length
    return Edit(range: whole, replacement: composed, cursor: newStart, selectionLength: max(0, end - newStart))
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
    case heading(Int), quote, toggle, callout, bullet, ordered, task

    var text: String {
      switch self {
      case .heading(let level): return String(repeating: "#", count: level) + " "
      case .quote: return "| "
      case .toggle: return "> "
      case .callout: return "!> "
      case .bullet: return "- "
      case .ordered: return "1. "
      case .task: return "- [ ] "
      }
    }
  }

  private static let listPrefix = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+] \[[ xX]\] |[-*+] |\d+\. )"#)

  /// Sets or clears a block prefix on the current line (⌥⌘1/2/3, ⇧⌘B,
  /// ⇧⌘7/8/9, the slash menu). Choosing the prefix the line already has
  /// removes it. Headings and toggles stack on each other and inside a
  /// quote, as typing them does; a quote replaces a heading or toggle; a
  /// callout or list marker replaces the whole stack.
  static func setLinePrefix(in text: String, cursor: Int, prefix: LinePrefix) -> Edit {
    let (lineStart, contentsEnd, line) = line(at: cursor, in: text)
    let lineNS = line as NSString
    let block = blockPrefix(of: line)
    let indent = lineNS.substring(to: block.indent)
    var existing = ""
    if block.hasMarkers {
      existing = lineNS.substring(with: NSRange(location: block.indent, length: block.contentStart - block.indent))
    } else if let match = listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) {
      existing = lineNS.substring(with: match.range(at: 2))
    }
    let rest = lineNS.substring(from: block.indent + (existing as NSString).length)
    let stack = block.hasMarkers && !block.callout
    let markers: String
    switch prefix {
    case .heading(let level):
      markers = stack
        ? markerText(quote: block.quote, toggle: block.toggle, heading: block.headingLevel == level ? 0 : level)
        : prefix.text
    case .toggle:
      markers = stack ? markerText(quote: block.quote, toggle: !block.toggle, heading: block.headingLevel) : prefix.text
    case .quote:
      markers = block.quote ? markerText(quote: false, toggle: block.toggle, heading: block.headingLevel) : prefix.text
    case .callout:
      markers = block.callout ? "" : prefix.text
    case .ordered:
      markers = existing.range(of: #"^\d+\. $"#, options: .regularExpression) != nil ? "" : prefix.text
    case .bullet:
      markers = existing.range(of: #"^[-*+] $"#, options: .regularExpression) != nil ? "" : prefix.text
    case .task:
      markers = existing.range(of: #"^[-*+] \[[ xX]\] $"#, options: .regularExpression) != nil ? "" : prefix.text
    }
    let replacement = indent + markers + rest
    let column = cursor - lineStart
    let oldPrefix = (indent + existing as NSString).length
    let newPrefix = (indent + markers as NSString).length
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

  // MARK: Inline picker triggers
  //
  // Where the emoji picker may open (":" and two letters), and the
  // ":name:" shortcut. The view asks after each keystroke; these only
  // read the text. A trigger never fires inside a code block or span or
  // inside a link's address.

  /// A character an emoji name can hold: ASCII letters, digits, "_", "+"
  /// and "-" (as in +1, t-rex, 100).
  static func isEmojiNameCharacter(_ c: unichar) -> Bool {
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2B || c == 0x2D
  }

  private static func isASCIILetter(_ c: unichar) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) }

  /// What may follow ":" for the emoji picker to show: name characters,
  /// starting with a letter and holding at least two (":cl", ":thumbs",
  /// ":t-r"), so ":3", ":a1" and ":-)" stay text.
  static func isEmojiQuery(_ query: String) -> Bool {
    let units = Array(query.utf16)
    guard let first = units.first, isASCIILetter(first), units.allSatisfy(isEmojiNameCharacter) else { return false }
    return units.filter(isASCIILetter).count >= 2
  }

  /// True when a ":" at `location` can start an emoji name: at a line
  /// start or after whitespace or punctuation, but not after a letter or
  /// digit (`10:30`, `mailto:`), another ":" (`std::string`), a "/" or a
  /// backslash; and not in a code block, a code span or a link address.
  static func emojiColonCanStart(in text: String, at location: Int) -> Bool {
    let ns = text as NSString
    guard location >= 0, location <= ns.length else { return false }
    if location > 0 {
      let previous = ns.character(at: location - 1)
      if previous != 0x0A, previous != 0x0D {
        if isEmojiNameCharacter(previous) && previous != 0x2B && previous != 0x2D && previous != 0x5F { return false }
        if previous == 0x3A || previous == 0x2F || previous == 0x5C { return false }
        // Any other letter or digit (é, ٣) counts as a word character too.
        if let scalar = Unicode.Scalar(previous), CharacterSet.alphanumerics.contains(scalar) { return false }
      }
    }
    return !insideCodeOrAddress(text, at: location)
  }

  /// True when `range` sits in an inline code span (`inCodeSpan`, closed
  /// or still being typed) or a link's address (`inLinkTarget`): where the
  /// date keywords and the emoji trigger stay as typed.
  static func inCodeSpanOrLinkTarget(_ ns: NSString, _ range: NSRange) -> Bool {
    inCodeSpan(ns, range) || inLinkTarget(ns, range)
  }

  /// True when `range` starts after a "](" on its line with no ")" since:
  /// inside a markdown link's address.
  static func inLinkTarget(_ ns: NSString, _ range: NSRange) -> Bool {
    let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
    let before = ns.substring(with: NSRange(location: line.location, length: range.location - line.location))
    guard let open = before.range(of: "](", options: .backwards) else { return false }
    return !before[open.upperBound...].contains(")")
  }

  /// True inside a fenced block, an inline code span or a link address
  /// (as `inCodeSpanOrLinkTarget` decides, shared with the date keywords),
  /// or a word holding "://" (a bare URL).
  static func insideCodeOrAddress(_ text: String, at location: Int) -> Bool {
    let ns = text as NSString
    guard location >= 0, location <= ns.length else { return false }
    if insideFence(text, cursor: location) { return true }
    // The character at `location`, when there is one, so a closed span
    // around it counts.
    if inCodeSpanOrLinkTarget(ns, NSRange(location: location, length: location < ns.length ? 1 : 0)) { return true }
    let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
    let before = ns.substring(with: NSRange(location: lineStart, length: location - lineStart)) as NSString
    let space = before.rangeOfCharacter(from: .whitespaces, options: .backwards)
    let wordStart = space.location == NSNotFound ? 0 : NSMaxRange(space)
    return before.substring(from: wordStart).contains("://")
  }

  /// The ":" the emoji picker opens at, when the caret has just finished
  /// ":" plus a query (at least two letters) at a place a name can start,
  /// and is not in the middle of a word. Nil otherwise.
  static func emojiTrigger(in text: String, cursor: Int) -> Int? {
    let ns = text as NSString
    guard cursor > 0, cursor <= ns.length else { return nil }
    if cursor < ns.length, isEmojiNameCharacter(ns.character(at: cursor)) { return nil }
    var start = cursor
    while start > 0, isEmojiNameCharacter(ns.character(at: start - 1)) { start -= 1 }
    guard start > 0, ns.character(at: start - 1) == 0x3A else { return nil }
    let colon = start - 1
    guard isEmojiQuery(ns.substring(with: NSRange(location: start, length: cursor - start))),
      emojiColonCanStart(in: text, at: colon)
    else { return nil }
    return colon
  }

  /// Typing the closing ":" of a known ":name:" turns it into the emoji.
  /// `lookup` gives the emoji for a name. The edit covers ":name:".
  static func emojiShortcode(in text: String, cursor: Int, lookup: (String) -> String?) -> Edit? {
    let ns = text as NSString
    guard cursor >= 3, cursor <= ns.length, ns.character(at: cursor - 1) == 0x3A else { return nil }
    var start = cursor - 1
    while start > 0, isEmojiNameCharacter(ns.character(at: start - 1)) { start -= 1 }
    guard start > 0, start < cursor - 1, ns.character(at: start - 1) == 0x3A else { return nil }
    let colon = start - 1
    let name = ns.substring(with: NSRange(location: start, length: cursor - 1 - start))
    guard emojiColonCanStart(in: text, at: colon), let emoji = lookup(name) else { return nil }
    return Edit(
      range: NSRange(location: colon, length: cursor - colon), replacement: emoji,
      cursor: colon + (emoji as NSString).length)
  }

  // MARK: Note link trigger

  /// True when a "[" typed at `location` could begin "[[": not right
  /// after another "[", not in code or a link address.
  static func noteLinkCanStart(in text: String, at location: Int) -> Bool {
    let ns = text as NSString
    guard location >= 0, location <= ns.length else { return false }
    if location > 0, ns.character(at: location - 1) == 0x5B { return false }
    return !insideCodeOrAddress(text, at: location)
  }

  /// The "[[" the note picker opens at: the last one before the caret on
  /// its line, with nothing but the query (no brackets) between it and
  /// the caret. The query may be empty and may hold spaces. Nil inside
  /// code or a link address, or after a third "[".
  static func noteLinkTrigger(in text: String, cursor: Int) -> Int? {
    let ns = text as NSString
    guard cursor >= 2, cursor <= ns.length else { return nil }
    let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
    let before = NSRange(location: lineStart, length: cursor - lineStart)
    let open = ns.range(of: "[[", options: .backwards, range: before)
    guard open.location != NSNotFound else { return nil }
    let queryStart = NSMaxRange(open)
    let query = ns.substring(with: NSRange(location: queryStart, length: cursor - queryStart))
    guard query.utf16.count <= 100, query.rangeOfCharacter(from: CharacterSet(charactersIn: "[]")) == nil,
      noteLinkCanStart(in: text, at: open.location)
    else { return nil }
    return open.location
  }

  /// The markdown link a note pick inserts: `[Title](target)`, with the
  /// target percent-encoded (spaces as %20) so it stays one valid link,
  /// and brackets dropped from the title.
  static func noteLink(title: String, target: String) -> String {
    var label = title.components(separatedBy: .newlines).joined(separator: " ")
      .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
      .trimmingCharacters(in: .whitespaces)
    if label.isEmpty { label = "Untitled" }
    return "[\(label)](\(encodedLinkTarget(target)))"
  }

  /// A file path as a link address: every character outside the URL path
  /// set is percent-encoded, and so are ":" (it would read as a scheme)
  /// and "(" ")" (they end a markdown address early).
  static func encodedLinkTarget(_ path: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: ":()")
    return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
  }
}
