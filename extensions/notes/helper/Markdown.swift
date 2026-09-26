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
final class TaskBoxLayoutManager: NSLayoutManager {
  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    guard let storage = textStorage, glyphsToShow.location != NSNotFound, glyphsToShow.length > 0 else { return }
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
        let lastText = ns.substring(with: lastLine).trimmingCharacters(in: .whitespacesAndNewlines)
        closingLine = lastText.range(of: #"^(`{3,}|~{3,})$"#, options: .regularExpression) != nil ? lastLine : nil
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

    storage.beginEditing()
    storage.setAttributes(
      [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: all)

    var codeRanges: [NSRange] = []
    for match in fence.matches(in: text, range: all) {
      storage.addAttributes([.font: monoFont, .foregroundColor: NSColor.secondaryLabelColor], range: match.range)
      codeRanges.append(match.range)
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
  }
}
