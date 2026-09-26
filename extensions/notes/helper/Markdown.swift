import AppKit
import Foundation

// MARK: - Markdown styling
//
// The text stays raw markdown so files never change shape; only display
// attributes are layered on. Markers are dimmed, headings enlarged, links
// clickable, task boxes drawn as checkboxes and clickable (notes-task://
// links), and done tasks greyed out.

/// Draws a checkbox over each task's "[ ]" / "[x]" characters, which
/// Markdown.apply leaves in place but paints clear and tags with
/// `Markdown.taskBox`. The text view installs it in PanelController.
/// It also measures and paints the rounded card behind each fenced code
/// block (tagged `Markdown.codeBlock`), for NoteTextView to call.
final class TaskBoxLayoutManager: NSLayoutManager {
  /// Draws the task boxes that fall inside `rect` (text view coordinates).
  /// NoteTextView calls it from `draw(_:)` after the text and selection are
  /// drawn, so a selection never reveals the hidden characters under a box.
  func drawTaskBoxes(in rect: NSRect, origin: NSPoint) {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
    let band = NSRect(x: 0, y: rect.minY - origin.y, width: container.size.width, height: rect.height)
    let glyphsToShow = glyphRange(forBoundingRect: band, in: container)
    guard glyphsToShow.location != NSNotFound, glyphsToShow.length > 0 else { return }
    let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    guard chars.location != NSNotFound, chars.length > 0,
      NSMaxRange(chars) <= storage.length
    else { return }
    storage.enumerateAttribute(Markdown.taskBox, in: chars) { value, range, _ in
      guard let done = value as? Bool else { return }
      // A redraw can start or stop mid-box; widen to the whole box so the
      // square is never drawn from a partial glyph span.
      let window = NSIntersectionRange(
        NSRange(location: max(0, range.location - 2), length: range.length + 4),
        NSRange(location: 0, length: storage.length))
      var box = range
      _ = storage.attribute(Markdown.taskBox, at: range.location, longestEffectiveRange: &box, in: window)
      drawTaskBox(characters: box, done: done, origin: origin)
    }
    storage.enumerateAttribute(Markdown.bulletDot, in: chars) { value, range, _ in
      guard value != nil else { return }
      drawBulletDot(characters: range, origin: origin)
    }
  }

  /// Draws the code cards behind `rect` (text view coordinates), reaching
  /// `Markdown.codeCardOutset` into the inset margin. NoteTextView calls it
  /// from `drawBackground(in:)`, which (unlike this class's own background
  /// drawing) is not clipped to the text container, and which runs before
  /// the selection and the text are drawn.
  func drawCodeCards(in rect: NSRect, origin: NSPoint) {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
    // Search the full container width: `rect` may be only the margin.
    let band = NSRect(x: 0, y: rect.minY - origin.y, width: container.size.width, height: rect.height)
    let glyphs = glyphRange(forBoundingRect: band, in: container)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return }
    let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    guard chars.location != NSNotFound, chars.length > 0, NSMaxRange(chars) <= storage.length else { return }
    var drawn = Set<Int>()
    storage.enumerateAttribute(Markdown.codeBlock, in: chars) { value, range, _ in
      guard let id = value as? Int, drawn.insert(id).inserted else { return }
      // The redraw may cover only part of the block; widen to all of it so
      // the card is always the same shape.
      var block = range
      _ = storage.attribute(
        Markdown.codeBlock, at: range.location, longestEffectiveRange: &block,
        in: NSRange(location: 0, length: storage.length))
      guard let card = codeCardRect(forCharacterRange: block) else { return }
      NSGraphicsContext.saveGraphicsState()
      Markdown.codeCardColor.setFill()
      let radius = Markdown.codeCardRadius
      NSBezierPath(roundedRect: card.offsetBy(dx: origin.x, dy: origin.y), xRadius: radius, yRadius: radius).fill()
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  /// The card behind the code block spanning `characters` (opening fence
  /// line through closing fence line), in text container coordinates; add
  /// the text view's `textContainerOrigin` for view coordinates. Top is the
  /// top of the opening line fragment, sides are the container edges pushed
  /// out by `Markdown.codeCardOutset`, bottom is the closing line's fixed
  /// height (or the last line of an unclosed block).
  func codeCardRect(forCharacterRange characters: NSRange) -> NSRect? {
    guard let storage = textStorage, characters.length > 0, NSMaxRange(characters) <= storage.length else { return nil }
    let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
    guard glyphs.location != NSNotFound, glyphs.length > 0,
      let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
    else { return nil }
    let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
    let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)

    let text = storage.string as NSString
    let openingLine = text.lineRange(for: NSRange(location: characters.location, length: 0))
    let lastLine = text.lineRange(for: NSRange(location: NSMaxRange(characters) - 1, length: 0))
    let closed = lastLine.location > openingLine.location
      && Markdown.isClosingFence(text.substring(with: lastLine))

    var bottom: CGFloat
    if closed {
      bottom = last.minY + Markdown.codeFooterHeight
    } else {
      bottom = last.maxY
      // Typing into an unclosed block at the end of the note: keep the empty
      // line the caret sits on inside the card.
      if NSMaxRange(characters) == storage.length, extraLineFragmentTextContainer === container {
        bottom = max(bottom, extraLineFragmentRect.maxY)
      }
    }
    let outset = Markdown.codeCardOutset
    return NSRect(
      x: -outset, y: first.minY,
      width: container.size.width + outset * 2, height: max(0, bottom - first.minY))
  }

  /// A filled accent circle centred on the (clear) list marker, at the
  /// height of the body font's lowercase letters, like a typeset bullet.
  private func drawBulletDot(characters: NSRange, origin: NSPoint) {
    let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
    guard glyphs.location != NSNotFound, glyphs.length > 0,
      let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
    else { return }
    let span = boundingRect(forGlyphRange: glyphs, in: container)
    let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
    let baseline = origin.y + line.minY + location(forGlyphAt: glyphs.location).y
    let font = Markdown.baseFont
    let diameter = Markdown.bulletDotDiameter
    let center = NSPoint(x: origin.x + span.midX, y: baseline - font.xHeight / 2)
    NSGraphicsContext.saveGraphicsState()
    Markdown.accent.setFill()
    NSBezierPath(ovalIn: NSRect(
      x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)).fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawTaskBox(characters: NSRange, done: Bool, origin: NSPoint) {
    let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
    guard glyphs.location != NSNotFound, glyphs.length > 0,
      let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
    else { return }
    let span = boundingRect(forGlyphRange: glyphs, in: container)
    let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
    let baseline = origin.y + line.minY + location(forGlyphAt: glyphs.location).y

    // Sized from the body font (not the line) so paragraph spacing never
    // stretches it, and so ⌘+ / ⌘- zoom scales it with the text.
    let font = Markdown.baseFont
    let side = (defaultLineHeight(for: font) * 0.75).rounded()
    let center = NSPoint(x: origin.x + span.midX, y: baseline - font.capHeight / 2)
    let square = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    Markdown.accent.set()
    let lineWidth: CGFloat = 1.5
    let outline = square.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let radius = side * 0.3
    let stroke = NSBezierPath(roundedRect: outline, xRadius: radius, yRadius: radius)
    stroke.lineWidth = lineWidth
    stroke.stroke()
    if done {
      let fill = square.insetBy(dx: side * 0.24, dy: side * 0.24)
      let inner = radius * 0.5
      NSBezierPath(roundedRect: fill, xRadius: inner, yRadius: inner).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}

enum Markdown {
  /// Multiplier applied to every font size (⌘+ / ⌘- zoom).
  static var zoom: CGFloat = 1.0

  /// The one highlight colour: list markers, numbers, task boxes, links.
  static let accent = NSColor(srgbRed: 0.91, green: 0.36, blue: 0.33, alpha: 1)
  /// Marks a task's "[ ]" / "[x]" characters; the value is `true` when done.
  static let taskBox = NSAttributedString.Key("taskBox")
  /// Marks the (clear) "-", "*" or "+" of a bullet item, which
  /// TaskBoxLayoutManager draws as a round dot.
  static let bulletDot = NSAttributedString.Key("bulletDot")
  static var bulletDotDiameter: CGFloat { 5 * zoom }

  static var baseFont: NSFont { NSFont.systemFont(ofSize: 15 * zoom) }
  static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13.5 * zoom, weight: .regular) }
  /// Width of one monospace glyph at the current zoom.
  static var monoAdvance: CGFloat { ("-" as NSString).size(withAttributes: [.font: monoFont]).width }
  static var headingFonts: [NSFont] {
    [
      NSFont.systemFont(ofSize: 24 * zoom, weight: .bold),
      NSFont.systemFont(ofSize: 20 * zoom, weight: .bold),
      NSFont.systemFont(ofSize: 17 * zoom, weight: .bold),
    ]
  }
  /// Space above H1, H2, H3 before zoom.
  static let headingSpaceBefore: [CGFloat] = [18, 14, 10]
  /// Line height as a multiple of the font's own, for prose and for code.
  static let bodyLineHeight: CGFloat = 1.25
  static let codeLineHeight: CGFloat = 1.15
  /// On-screen width of one space of list indentation, so a nested item
  /// sits under its parent's text rather than a few pixels in.
  static var indentSpaceWidth: CGFloat { 6 * zoom }
  /// Height of a blank line between blocks (not the one the caret is on).
  static var blankLineHeight: CGFloat { (10 * zoom).rounded() }
  static let blankLine = try! NSRegularExpression(pattern: #"^[ \t]*$"#, options: .anchorsMatchLines)
  static let taskScheme = "notes-task"

  /// Marks every character of a fenced code block, opening fence line
  /// through closing fence line; the value is the block's start offset
  /// (an Int), so neighbouring blocks stay distinct.
  static let codeBlock = NSAttributedString.Key("codeBlock")
  /// Height of the (hidden) opening fence line: the card's header strip,
  /// which the overlay controls sit in.
  static var codeHeaderHeight: CGFloat { (34 * max(zoom, 1)).rounded() }
  /// Height of the (hidden) closing fence line: the card's bottom padding.
  static var codeFooterHeight: CGFloat { (18 * zoom).rounded() }
  /// How far the card reaches past the text container on each side.
  static let codeCardOutset: CGFloat = 12
  static let codeCardRadius: CGFloat = 10
  /// A shade lighter than the editor in dark mode, darker in light mode.
  static let codeCardColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.045)
  }

  static let heading = try! NSRegularExpression(pattern: #"^(#{1,3})[ \t]+(.*)$"#, options: .anchorsMatchLines)
  static let task = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+(\[[ xX]\])(?:[ \t]+(.*))?$"#, options: .anchorsMatchLines)
  // Possessive `[ \t]++` so "-  [ ] x" cannot backtrack to one space and
  // pass as a bullet as well as a task.
  static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+\.)[ \t]++(?!\[[ xX]\])"#, options: .anchorsMatchLines)
  static let quote = try! NSRegularExpression(pattern: #"^(>)[ \t]?(.*)$"#, options: .anchorsMatchLines)
  static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(?:(`{3,})|(~{3,}))[^\n]*\n[\s\S]*?(?:^ {0,3}(?:\1`*|\2~*)[ \t]*$|\z)"#, options: .anchorsMatchLines)
  static let rule = try! NSRegularExpression(pattern: #"^(?:-{3,}|_{3,}|\*{3,})[ \t]*$"#, options: .anchorsMatchLines)
  static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
  static let italic = try! NSRegularExpression(pattern: #"(?<![\*\w])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![\*\w])"#)
  static let strike = try! NSRegularExpression(pattern: #"(~~)(?=\S)(.+?)(?<=\S)\1"#)
  static let code = try! NSRegularExpression(pattern: #"(`)([^`\n]+)\1"#)
  static let link = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^)\s]+)(\))"#)
  static let bareURL = try! NSRegularExpression(pattern: #"(?<![\(\w])https?://[^\s<>\)\]]+"#)

  /// One fenced code block: the opening fence line, the language word on
  /// it (may be empty), the body between the fences (may be empty), and
  /// the closing fence line if present. Shared by the highlighter and the
  /// block overlay controls.
  struct CodeBlock {
    let range: NSRange
    let openingLine: NSRange
    let language: String
    let languageRange: NSRange
    let body: NSRange
    let closingLine: NSRange?
  }

  private static let fenceOpen = try! NSRegularExpression(pattern: #"^ {0,3}(?:`{3,}|~{3,})[ \t]*([^\s`]*)"#)

  /// A closing fence may be indented by at most three spaces; four or
  /// more make it code, as the fence pattern itself already assumes.
  static func isClosingFence(_ line: String) -> Bool {
    line.range(of: #"^ {0,3}(`{3,}|~{3,})[ \t]*\r?\n?$"#, options: .regularExpression) != nil
  }

  static func codeBlocks(in text: String) -> [CodeBlock] {
    let ns = text as NSString
    return fence.matches(in: text, range: fullRange(text)).map { match in
      let openingLine = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
      let openingText = ns.substring(with: openingLine)
      let info = fenceOpen.firstMatch(in: openingText, range: NSRange(location: 0, length: (openingText as NSString).length))
      let languageRange = NSRange(location: openingLine.location + (info?.range(at: 1).location ?? 0), length: info?.range(at: 1).length ?? 0)
      let language = ns.substring(with: languageRange)
      let end = NSMaxRange(match.range)
      let closingLine: NSRange?
      if end > NSMaxRange(openingLine) {
        let lastLine = ns.lineRange(for: NSRange(location: end - 1, length: 0))
        closingLine = isClosingFence(ns.substring(with: lastLine)) ? lastLine : nil
      } else {
        closingLine = nil
      }
      let bodyStart = NSMaxRange(openingLine)
      let bodyEnd = closingLine?.location ?? end
      let body = NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))
      return CodeBlock(range: match.range, openingLine: openingLine, language: language, languageRange: languageRange, body: body, closingLine: closingLine)
    }
  }

  /// Marks every run of characters that is collapsed to nothing on screen
  /// (heading and list markers, `**`, `_`, `~~`, backticks, link brackets
  /// and targets). The caret never rests inside such a run.
  static let hiddenRun = NSAttributedString.Key("hiddenRun")

  /// Values of `hiddenRun`: which side of a pair a run is, or a line-start
  /// marker (heading, bullet, task box). Adjacent runs of different roles
  /// stay separate, so the caret can sit between the halves of an empty
  /// pair.
  enum HiddenRole: String { case open, close, line }

  /// An empty pair left by ⌘B / ⌘I / ⇧⌘S / ⌘E before anything is typed
  /// inside it; hidden like a matched pair so the markers never show.
  static let emptyPair = try! NSRegularExpression(pattern: #"(?<!\*)\*\*\*\*(?!\*)|(?<!_)____(?!_)|(?<!~)~~~~(?!~)|(?<!`)``(?!`)"#)

  static func apply(to storage: NSTextStorage) {
    let text = storage.string
    let all = fullRange(text)
    let dim = NSColor.tertiaryLabelColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = bodyLineHeight
    paragraph.paragraphSpacing = 4 * zoom

    var hadCards = false
    if storage.length > 0 {
      storage.enumerateAttribute(codeBlock, in: all, options: .longestEffectiveRangeNotRequired) { value, _, stop in
        if value != nil { hadCards = true; stop.pointee = true }
      }
    }

    storage.beginEditing()
    storage.setAttributes(
      [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: all)

    let blocks = codeBlocks(in: text)
    let codeRanges = blocks.map(\.range)
    if !blocks.isEmpty {
      let mono = monoFont
      let collapse = -monoAdvance
      let codeBody = NSMutableParagraphStyle()
      codeBody.lineHeightMultiple = codeLineHeight
      codeBody.defaultTabInterval = monoAdvance * 4
      codeBody.tabStops = []
      let header = NSMutableParagraphStyle()
      header.minimumLineHeight = codeHeaderHeight
      header.maximumLineHeight = codeHeaderHeight
      let footer = NSMutableParagraphStyle()
      footer.minimumLineHeight = codeFooterHeight
      footer.maximumLineHeight = codeFooterHeight
      footer.paragraphSpacing = 10 * zoom
      // The fence lines stay in the file but collapse on screen: clear
      // colour plus a kern cancelling each monospace glyph's advance (the
      // task bullet trick). The overlay shows the language instead.
      func hide(_ line: NSRange, style: NSParagraphStyle) {
        storage.addAttributes([.font: mono, .paragraphStyle: style], range: line)
        let content = (text as NSString).substring(with: line)
        let visible = (content as NSString).length - (content.hasSuffix("\n") ? 1 : 0)
        guard visible > 0 else { return }
        storage.addAttributes(
          [.foregroundColor: NSColor.clear, .kern: collapse], range: NSRange(location: line.location, length: visible))
      }
      for block in blocks {
        let end = block.closingLine.map(NSMaxRange) ?? max(NSMaxRange(block.range), NSMaxRange(block.body))
        let whole = NSRange(location: block.openingLine.location, length: end - block.openingLine.location)
        storage.addAttributes([.font: mono, codeBlock: block.openingLine.location], range: whole)
        hide(block.openingLine, style: header)
        if let closing = block.closingLine { hide(closing, style: footer) }
        if block.body.length > 0 {
          storage.addAttribute(.paragraphStyle, value: codeBody, range: block.body)
          Highlighter.highlight(storage, body: block.body, language: block.language)
        }
      }
    }
    func inCode(_ range: NSRange) -> Bool {
      codeRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    let ns = text as NSString
    // A blank line separates blocks, so it shows as a gap about the size of
    // a paragraph break rather than a full empty line. The caret's own
    // line keeps its full height, so typing on it never makes it jump.
    let selection = storage.layoutManagers.first?.firstTextView?.selectedRange()
    let caretLine = selection.map { ns.lineRange(for: NSRange(location: min($0.location, ns.length), length: 0)) }
    let blankStyle = NSMutableParagraphStyle()
    blankStyle.minimumLineHeight = blankLineHeight
    blankStyle.maximumLineHeight = blankLineHeight
    for match in blankLine.matches(in: text, range: all) {
      let line = ns.lineRange(for: match.range)
      guard line.length > 0, line != caretLine, !inCode(line) else { continue }
      storage.addAttribute(.paragraphStyle, value: blankStyle, range: line)
    }

    // Markers that stay in the file but take no room on screen: clear
    // colour plus a kern cancelling each monospace glyph's advance, so the
    // text starts where the marker did. A tab jumps to the next tab stop,
    // which a kern cannot cancel; such a run stays visible but dim.
    func collapse(_ range: NSRange) {
      guard range.length > 0 else { return }
      if ns.substring(with: range).contains("\t") {
        storage.addAttribute(.foregroundColor, value: dim, range: range)
      } else {
        storage.addAttributes([.foregroundColor: NSColor.clear, .font: monoFont, .kern: -monoAdvance, hiddenRun: HiddenRole.line.rawValue], range: range)
      }
    }
    // Leading spaces of a list item are widened to `indentSpaceWidth` each
    // (tabs keep their tab stops), so nesting reads at a glance.
    let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width
    func widenIndent(_ range: NSRange) {
      guard range.location != NSNotFound else { return }
      for offset in 0..<range.length where ns.character(at: range.location + offset) == 0x20 {
        storage.addAttribute(.kern, value: indentSpaceWidth - spaceWidth, range: NSRange(location: range.location + offset, length: 1))
      }
    }
    // Wrapped lines of a list item line up with its text, not its marker.
    func hang(line: NSRange, prefixEnd: Int) {
      let prefix = NSRange(location: line.location, length: prefixEnd - line.location)
      guard prefix.length > 0, !ns.substring(with: prefix).contains("\t") else { return }
      let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
      style.headIndent = storage.attributedSubstring(from: prefix).size().width
      storage.addAttribute(.paragraphStyle, value: style, range: ns.lineRange(for: line))
    }

    for match in heading.matches(in: text, range: all) where !inCode(match.range) {
      let level = min(match.range(at: 1).length, 3) - 1
      storage.addAttribute(.font, value: headingFonts[level], range: match.range)
      // "## " is hidden, as in Raycast Notes; the size says the level.
      let marker = match.range(at: 1)
      collapse(NSRange(location: marker.location, length: match.range(at: 2).location - marker.location))
      let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
      style.lineHeightMultiple = 1.1
      style.paragraphSpacingBefore = headingSpaceBefore[level] * zoom
      style.paragraphSpacing = 6 * zoom
      storage.addAttribute(.paragraphStyle, value: style, range: ns.lineRange(for: match.range))
    }
    for match in task.matches(in: text, range: all) where !inCode(match.range) {
      let box = match.range(at: 3)
      let done = (text as NSString).substring(with: box).lowercased() == "[x]"
      // The characters stay (so the file is untouched and clicks still hit
      // the link) but paint clear; TaskBoxLayoutManager draws the box.
      storage.addAttributes(
        [.foregroundColor: NSColor.clear, .font: monoFont, taskBox: done,
         .link: URL(string: "\(taskScheme)://toggle/\(box.location)")!], range: box)
      // The bullet and the space after it stay in the file (a task needs a
      // list marker in markdown) but collapse to nothing on screen: clear
      // colour plus a kern that cancels each glyph's advance, so the box
      // sits where the line starts, as in Raycast Notes.
      collapse(NSRange(location: match.range(at: 2).location, length: box.location - match.range(at: 2).location))
      widenIndent(match.range(at: 1))
      let body = match.range(at: 4)
      if done, body.location != NSNotFound, body.length > 0 {
        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: body)
      }
      hang(line: match.range, prefixEnd: body.location != NSNotFound ? body.location : NSMaxRange(match.range))
    }
    for match in bullet.matches(in: text, range: all) where !inCode(match.range) {
      let marker = match.range(at: 2)
      if marker.length == 1, ns.character(at: marker.location) < 0x30 {
        // "-", "*" or "+": the character stays (clear, one monospace glyph
        // wide) and TaskBoxLayoutManager draws a round dot over it.
        storage.addAttributes([.foregroundColor: NSColor.clear, .font: monoFont, bulletDot: true], range: marker)
      } else {
        storage.addAttribute(.foregroundColor, value: accent, range: marker)
      }
      widenIndent(match.range(at: 1))
      hang(line: match.range, prefixEnd: NSMaxRange(match.range))
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
    // Inline markers are never shown; the styled text is the only thing
    // on screen, and NoteTextView keeps the caret out of the hidden runs.
    let mono = monoFont
    let collapseKern = -monoAdvance
    func marker(_ range: NSRange, _ role: HiddenRole) {
      guard range.location != NSNotFound, range.length > 0 else { return }
      storage.addAttributes([.foregroundColor: NSColor.clear, .font: mono, .kern: collapseKern, hiddenRun: role.rawValue], range: range)
    }
    for match in emptyPair.matches(in: text, range: all) where !inCode(match.range) {
      // A whole line of **** or ____ is a horizontal rule, not a pair.
      let line = ns.lineRange(for: match.range)
      if ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) == ns.substring(with: match.range) { continue }
      let half = match.range.length / 2
      marker(NSRange(location: match.range.location, length: half), .open)
      marker(NSRange(location: match.range.location + half, length: half), .close)
    }
    for match in bold.matches(in: text, range: all) where !inCode(match.range) {
      let current = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont ?? baseFont
      storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask), range: match.range(at: 2))
      marker(match.range(at: 1), .open)
      marker(NSRange(location: match.range.location + match.range.length - match.range(at: 1).length, length: match.range(at: 1).length), .close)
    }
    // "**bold**" also matches the italic pattern as "*" + "*bold*" + "*";
    // an italic marker that is part of a bold marker is not one.
    let boldMarkers = bold.matches(in: text, range: all).flatMap { match -> [NSRange] in
      let width = match.range(at: 1).length
      return [match.range(at: 1), NSRange(location: NSMaxRange(match.range) - width, length: width)]
    }
    func inBoldMarker(_ location: Int) -> Bool { boldMarkers.contains { NSLocationInRange(location, $0) } }
    for match in italic.matches(in: text, range: all) where !inCode(match.range) {
      guard !inBoldMarker(match.range.location), !inBoldMarker(NSMaxRange(match.range) - 1) else { continue }
      let current = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont ?? baseFont
      storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask), range: match.range(at: 2))
      marker(match.range(at: 1), .open)
      marker(NSRange(location: match.range.location + match.range.length - 1, length: 1), .close)
    }
    for match in strike.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 2))
      marker(match.range(at: 1), .open)
      marker(NSRange(location: match.range.location + match.range.length - 2, length: 2), .close)
    }
    for match in code.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttributes(
        [.font: monoFont, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)], range: match.range(at: 2))
      marker(match.range(at: 1), .open)
      marker(NSRange(location: match.range.location + match.range.length - 1, length: 1), .close)
    }
    for match in link.matches(in: text, range: all) where !inCode(match.range) {
      let target = (text as NSString).substring(with: match.range(at: 4))
      marker(match.range(at: 1), .open)
      // "](url)" collapses as one run
      marker(NSRange(location: match.range(at: 3).location, length: NSMaxRange(match.range(at: 5)) - match.range(at: 3).location), .close)
      storage.addAttributes([.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range(at: 2))
      if let url = URL(string: target) {
        storage.addAttribute(.link, value: url, range: match.range(at: 2))
      }
    }
    for match in bareURL.matches(in: text, range: all) where !inCode(match.range) {
      // Trailing sentence punctuation is prose, not part of the address.
      // (GFM autolink rule; only ASCII units are checked, so a trailing
      // emoji's surrogate half is never touched.)
      var range = match.range
      let trailing: Set<unichar> = Set(".,;:!?'\"".utf16)
      while range.length > 0, trailing.contains((text as NSString).character(at: NSMaxRange(range) - 1)) {
        range.length -= 1
      }
      let target = (text as NSString).substring(with: range)
      guard let url = URL(string: target) else { continue }
      storage.addAttributes(
        [.link: url, .foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
    }
    storage.endEditing()

    // Cards reach into the text view's inset margin, which the text view
    // does not repaint when lines move; repaint what is on screen.
    if hadCards || !blocks.isEmpty {
      for layoutManager in storage.layoutManagers {
        for container in layoutManager.textContainers {
          guard let view = container.textView else { continue }
          view.setNeedsDisplay(view.visibleRect)
        }
      }
    }
  }
}
