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

  static var baseFont: NSFont { NSFont.systemFont(ofSize: 15 * zoom) }
  static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13.5 * zoom, weight: .regular) }
  /// Width of one monospace glyph at the current zoom.
  static var monoAdvance: CGFloat { ("-" as NSString).size(withAttributes: [.font: monoFont]).width }
  static var headingFonts: [NSFont] {
    [
      NSFont.systemFont(ofSize: 24 * zoom, weight: .bold),
      NSFont.systemFont(ofSize: 20 * zoom, weight: .bold),
      NSFont.systemFont(ofSize: 17 * zoom, weight: .semibold),
    ]
  }
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
  static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+\.)[ \t]+(?!\[[ xX]\])"#, options: .anchorsMatchLines)
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

  static func apply(to storage: NSTextStorage) {
    let text = storage.string
    let all = fullRange(text)
    let dim = NSColor.tertiaryLabelColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    paragraph.paragraphSpacing = 4

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
      codeBody.lineSpacing = 3
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

    for match in heading.matches(in: text, range: all) where !inCode(match.range) {
      let level = min(match.range(at: 1).length, 3) - 1
      storage.addAttribute(.font, value: headingFonts[level], range: match.range)
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
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
      let bulletRange = NSRange(location: match.range(at: 2).location, length: box.location - match.range(at: 2).location)
      if (text as NSString).substring(with: bulletRange).contains("\t") {
        // A tab jumps to the next tab stop, which a kern cannot cancel;
        // leave that rare form visible but dim.
        storage.addAttribute(.foregroundColor, value: dim, range: bulletRange)
      } else {
        storage.addAttributes(
          [.foregroundColor: NSColor.clear, .font: monoFont, .kern: -monoAdvance], range: bulletRange)
      }
      let body = match.range(at: 4)
      if done, body.location != NSNotFound, body.length > 0 {
        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: body)
      }
    }
    for match in bullet.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttribute(.foregroundColor, value: accent, range: match.range(at: 2))
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
    for match in bold.matches(in: text, range: all) where !inCode(match.range) {
      let current = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont ?? baseFont
      storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask), range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range.location + match.range.length - match.range(at: 1).length, length: match.range(at: 1).length))
    }
    for match in italic.matches(in: text, range: all) where !inCode(match.range) {
      let current = storage.attribute(.font, at: match.range(at: 2).location, effectiveRange: nil) as? NSFont ?? baseFont
      storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask), range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range.location + match.range.length - 1, length: 1))
    }
    for match in strike.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range.location + match.range.length - 2, length: 2))
    }
    for match in code.matches(in: text, range: all) where !inCode(match.range) {
      storage.addAttributes(
        [.font: monoFont, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)], range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 1))
      storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: match.range.location + match.range.length - 1, length: 1))
    }
    for match in link.matches(in: text, range: all) where !inCode(match.range) {
      let target = (text as NSString).substring(with: match.range(at: 4))
      for index in [1, 3, 5] {
        storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: index))
      }
      storage.addAttributes([.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 4))
      if let url = URL(string: target) {
        storage.addAttribute(.link, value: url, range: match.range(at: 2))
      }
    }
    for match in bareURL.matches(in: text, range: all) where !inCode(match.range) {
      let target = (text as NSString).substring(with: match.range)
      guard let url = URL(string: target) else { continue }
      storage.addAttributes(
        [.link: url, .foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
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
