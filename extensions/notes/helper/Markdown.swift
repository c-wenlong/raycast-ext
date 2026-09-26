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
  /// Selection and inline backgrounds hug the text, as in Raycast Notes:
  /// each line's rect spans only its glyphs, at the height of its font
  /// (not the whole line with its spacing), and a selected line break is
  /// a thin bar rather than a fill to the right edge.
  override func fillBackgroundRectArray(
    _ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor
  ) {
    guard let origin = firstTextView?.textContainerOrigin else {
      super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
      return
    }
    let rects = hugRects(forCharacterRange: charRange).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    guard !rects.isEmpty else { return }
    rects.withUnsafeBufferPointer {
      super.fillBackgroundRectArray($0.baseAddress!, count: rects.count, forCharacterRange: charRange, color: color)
    }
  }

  /// One rect per line fragment of `charRange`, in container coordinates:
  /// from the hanging indent (or the first selected glyph, if later) to
  /// the last selected glyph, as tall as the tallest font on that line's
  /// selected part. A fragment holding only the line break gets a 2pt bar.
  func hugRects(forCharacterRange charRange: NSRange) -> [NSRect] {
    guard let storage = textStorage, let container = textContainers.first, charRange.length > 0 else { return [] }
    let ns = storage.string as NSString
    let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
    var rects: [NSRect] = []
    var index = glyphs.location
    while index < NSMaxRange(glyphs) {
      var fragmentGlyphs = NSRange()
      let fragment = lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentGlyphs)
      let onLine = NSIntersectionRange(fragmentGlyphs, glyphs)
      guard onLine.length > 0 else { break }
      let chars = characterRange(forGlyphRange: onLine, actualGlyphRange: nil)
      var ascent = CGFloat(0)
      var descent = CGFloat(0)
      storage.enumerateAttribute(.font, in: chars) { value, _, _ in
        let font = value as? NSFont ?? Markdown.baseFont
        ascent = max(ascent, font.ascender)
        descent = min(descent, font.descender)
      }
      let baseline = fragment.minY + location(forGlyphAt: onLine.location).y
      var visible = onLine
      if NSMaxRange(chars) <= ns.length, ns.character(at: NSMaxRange(chars) - 1) == 0x0A { visible.length -= 1 }
      // A list line's marker is not highlighted: the fill starts where the
      // text does (the hanging indent), as in Raycast Notes.
      let style = storage.attribute(.paragraphStyle, at: chars.location, effectiveRange: nil) as? NSParagraphStyle
      let textLeft = fragment.minX + container.lineFragmentPadding + (style?.headIndent ?? 0)
      let top = baseline - ascent
      let height = ascent - descent
      if visible.length > 0 {
        let bounds = boundingRect(forGlyphRange: visible, in: container)
        let left = max(bounds.minX, textLeft)
        rects.append(NSRect(x: left, y: top, width: max(0, bounds.maxX - left), height: height))
      } else {
        let x = max(fragment.minX + location(forGlyphAt: onLine.location).x, textLeft)
        rects.append(NSRect(x: x, y: top, width: 2, height: height))
      }
      index = NSMaxRange(fragmentGlyphs)
    }
    return rects
  }

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

  /// Draws the bar down the left of every quote crossing `rect` (text view
  /// coordinates), one bar per run of quote lines, and "Empty quote" on a
  /// quote line with no text. NoteTextView calls it from drawBackground.
  func drawQuoteBars(in rect: NSRect, origin: NSPoint) {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
    let band = NSRect(x: 0, y: rect.minY - origin.y, width: container.size.width, height: rect.height)
    let glyphs = glyphRange(forBoundingRect: band, in: container)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return }
    let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    guard chars.location != NSNotFound, chars.length > 0, NSMaxRange(chars) <= storage.length else { return }
    let whole = NSRange(location: 0, length: storage.length)
    var drawn = Set<Int>()
    storage.enumerateAttribute(Markdown.quoteBar, in: chars) { value, range, _ in
      guard value != nil else { return }
      var run = range
      _ = storage.attribute(Markdown.quoteBar, at: range.location, longestEffectiveRange: &run, in: whole)
      guard drawn.insert(run.location).inserted else { return }
      let runGlyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
      guard runGlyphs.length > 0 else { return }
      // From just above the first line's ascenders to just below the last
      // line's descenders, so a one-line and a many-line quote line up
      // with their text the same way.
      let firstGlyph = runGlyphs.location
      let lastGlyph = NSMaxRange(runGlyphs) - 1
      let first = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
      let last = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
      let font = Markdown.baseFont
      // Within the line's own height, so it never touches the next line.
      let pad = 1 * Markdown.zoom
      let top = first.minY + location(forGlyphAt: firstGlyph).y - font.ascender - pad
      let bottom = last.minY + location(forGlyphAt: lastGlyph).y - font.descender + pad
      let bar = NSRect(
        x: origin.x + first.minX + container.lineFragmentPadding + Markdown.zoom,
        y: origin.y + top, width: Markdown.quoteBarWidth, height: max(0, bottom - top))
      NSGraphicsContext.saveGraphicsState()
      NSColor.labelColor.withAlphaComponent(0.85).setFill()
      NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
      NSGraphicsContext.restoreGraphicsState()
    }
    storage.enumerateAttribute(Markdown.quotePlaceholder, in: chars) { value, range, _ in
      guard value != nil else { return }
      let glyph = glyphIndexForCharacter(at: range.location)
      guard glyph < numberOfGlyphs else { return }
      let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let baseline = origin.y + fragment.minY + location(forGlyphAt: glyph).y
      let font = Markdown.baseFont
      let point = NSPoint(
        x: origin.x + fragment.minX + container.lineFragmentPadding + Markdown.quoteIndent,
        y: baseline - font.ascender)
      ("Empty quote" as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
    }
  }

  /// Draws the outlined box around every callout crossing `rect` (text
  /// view coordinates), one box per run of callout lines, and "Empty
  /// callout" on a callout line with no text. NoteTextView calls it from
  /// drawBackground.
  func drawCalloutBoxes(in rect: NSRect, origin: NSPoint) {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
    let band = NSRect(x: 0, y: rect.minY - origin.y, width: container.size.width, height: rect.height)
    let glyphs = glyphRange(forBoundingRect: band, in: container)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return }
    let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    guard chars.location != NSNotFound, chars.length > 0, NSMaxRange(chars) <= storage.length else { return }
    let whole = NSRange(location: 0, length: storage.length)
    let font = Markdown.baseFont
    var drawn = Set<Int>()
    storage.enumerateAttribute(Markdown.calloutBox, in: chars) { value, range, _ in
      guard value != nil else { return }
      var run = range
      _ = storage.attribute(Markdown.calloutBox, at: range.location, longestEffectiveRange: &run, in: whole)
      guard drawn.insert(run.location).inserted else { return }
      let runGlyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
      guard runGlyphs.length > 0 else { return }
      let firstGlyph = runGlyphs.location
      let lastGlyph = NSMaxRange(runGlyphs) - 1
      let first = lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
      let last = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
      // Padded out from the text's ascenders and descenders, full width.
      let top = first.minY + location(forGlyphAt: firstGlyph).y - font.ascender - Markdown.calloutPad
      let bottom = last.minY + location(forGlyphAt: lastGlyph).y - font.descender + Markdown.calloutPad
      let box = NSRect(
        x: origin.x + container.lineFragmentPadding, y: origin.y + top,
        width: container.size.width - container.lineFragmentPadding * 2, height: max(0, bottom - top))
      NSGraphicsContext.saveGraphicsState()
      let path = NSBezierPath(
        roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: Markdown.calloutRadius, yRadius: Markdown.calloutRadius)
      Markdown.calloutBorder.setStroke()
      path.lineWidth = 1
      path.stroke()
      NSGraphicsContext.restoreGraphicsState()
    }
    storage.enumerateAttribute(Markdown.calloutPlaceholder, in: chars) { value, range, _ in
      guard value != nil else { return }
      let glyph = glyphIndexForCharacter(at: range.location)
      guard glyph < numberOfGlyphs else { return }
      let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let baseline = origin.y + fragment.minY + location(forGlyphAt: glyph).y
      let point = NSPoint(
        x: origin.x + fragment.minX + container.lineFragmentPadding + Markdown.calloutPad,
        y: baseline - font.ascender)
      ("Empty callout" as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
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
    let side = Markdown.taskBoxSide
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
  /// Selected text: a wash of the accent, as in Raycast Notes.
  static var selection: NSColor { accent.withAlphaComponent(0.42) }
  /// Marks a task's "[ ]" / "[x]" characters; the value is `true` when done.
  static let taskBox = NSAttributedString.Key("taskBox")
  /// Marks the (clear) "-", "*" or "+" of a bullet item, which
  /// TaskBoxLayoutManager draws as a round dot.
  static let bulletDot = NSAttributedString.Key("bulletDot")
  static var bulletDotDiameter: CGFloat { 4.5 * zoom }
  /// Side of a task box: 14pt at 15pt text, as in Raycast Notes.
  static var taskBoxSide: CGFloat { (baseFont.pointSize * 14 / 15).rounded() }

  /// The note's background, as in Raycast Notes: near-black in dark mode.
  static let canvas = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(white: 26 / 255, alpha: 1) : NSColor(white: 0.985, alpha: 1)
  }

  static var baseFont: NSFont { NSFont.systemFont(ofSize: 15 * zoom) }
  static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13.5 * zoom, weight: .regular) }
  /// Width of one monospace glyph at the current zoom.
  static var monoAdvance: CGFloat { ("-" as NSString).size(withAttributes: [.font: monoFont]).width }
  static var headingFonts: [NSFont] {
    [
      NSFont.systemFont(ofSize: 24 * zoom, weight: .bold),
      NSFont.systemFont(ofSize: 20 * zoom, weight: .bold),
      NSFont.systemFont(ofSize: 17 * zoom, weight: .bold),
      NSFont.systemFont(ofSize: 15 * zoom, weight: .semibold),
    ]
  }
  /// Space above H1 to H4 before zoom.
  static let headingSpaceBefore: [CGFloat] = [18, 14, 10, 8]
  /// A quote's text sits this far in; the bar is drawn in the gap.
  static var quoteIndent: CGFloat { 16 * zoom }
  static var quoteBarWidth: CGFloat { 3 * zoom }
  /// Space above and below a quote (more than the paragraph gap).
  static var quoteGap: CGFloat { 12 * zoom }
  /// Marks every character of a quote line (bar drawn by the layout
  /// manager); `quotePlaceholder` marks a quote line with no text.
  static let quoteBar = NSAttributedString.Key("quoteBar")
  static let quotePlaceholder = NSAttributedString.Key("quotePlaceholder")
  /// Marks every character of a callout line (box drawn by the layout
  /// manager); `calloutPlaceholder` marks one with no text.
  static let calloutBox = NSAttributedString.Key("calloutBox")
  static let calloutPlaceholder = NSAttributedString.Key("calloutPlaceholder")
  /// Space between a callout's text and its box, on every side, and the
  /// air kept above and below the box.
  static var calloutPad: CGFloat { 14 * zoom }
  static var calloutGap: CGFloat { 10 * zoom }
  static let calloutRadius: CGFloat = 10
  static let calloutBorder = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)
  }
  /// Line height as a multiple of the font's own, for prose and for code,
  /// and the gap between paragraphs: together a 28pt pitch at 15pt text,
  /// matching Raycast Notes.
  static let bodyLineHeight: CGFloat = 1.15
  static let codeLineHeight: CGFloat = 1.15
  static var paragraphGap: CGFloat { 7.5 * zoom }
  /// Width of one list level: the marker column, and the indent of each
  /// nested level. The marker (dot, number) sits `listMarkerLead` in from
  /// the column's left edge; a task box sits flush.
  static var listColumn: CGFloat { 22 * zoom }
  static var listMarkerLead: CGFloat { 2.5 * zoom }
  static let listLine = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*+]|\d+\.)[ \t]+"#)
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

  static let heading = try! NSRegularExpression(pattern: #"^(#{1,4})[ \t]+(.*)$"#, options: .anchorsMatchLines)
  static let task = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+(\[[ xX]\])(?:[ \t]+(.*))?$"#, options: .anchorsMatchLines)
  // Possessive `[ \t]++` so "-  [ ] x" cannot backtrack to one space and
  // pass as a bullet as well as a task.
  static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+\.)[ \t]++(?!\[[ xX]\])"#, options: .anchorsMatchLines)
  static let quote = try! NSRegularExpression(pattern: #"^(>)(?!>)[ \t]?(.*)$"#, options: .anchorsMatchLines)
  /// A callout: ">> " lines, drawn in an outlined box (a nested quote to
  /// other markdown viewers).
  static let callout = try! NSRegularExpression(pattern: #"^(>>)[ \t]?(.*)$"#, options: .anchorsMatchLines)
  static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(?:(`{3,})|(~{3,}))[^\n]*\n[\s\S]*?(?:^ {0,3}(?:\1`*|\2~*)[ \t]*$|\z)"#, options: .anchorsMatchLines)
  static let rule = try! NSRegularExpression(pattern: #"^(?:-{3,}|_{3,}|\*{3,})[ \t]*$"#, options: .anchorsMatchLines)
  static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
  // Groups 1/2 for `*`, 3/4 for `_`. Each marker is a lone character (so
  // a bold marker is never half an italic one) and only refuses its own
  // character next to it, so `_b_` nests inside `**...**` and `**b**`
  // inside `*...*`.
  static let italic = try! NSRegularExpression(pattern: #"(?<![\*\w])(\*)(?!\*)(?=\S)(.+?)(?<=\S)(?<!\*)\1(?![\*\w])|(?<![_\w])(_)(?!_)(?=\S)(.+?)(?<=\S)(?<!_)\3(?![_\w])"#)
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

  /// Nesting level of every list line, keyed by line start: a list line
  /// indented past the previous one is a level deeper, one indented back
  /// returns to the level of the ancestor it lines up with. A line that is
  /// neither a list item nor blank ends the list.
  static func listLevels(in text: String) -> [Int: Int] {
    let ns = text as NSString
    var levels: [Int: Int] = [:]
    var open: [Int] = []  // indent widths of the enclosing items
    var index = 0
    while index < ns.length {
      let line = ns.lineRange(for: NSRange(location: index, length: 0))
      index = NSMaxRange(line)
      let content = ns.substring(with: line)
      let contentRange = NSRange(location: 0, length: (content as NSString).length)
      if let match = listLine.firstMatch(in: content, range: contentRange) {
        let indent = (content as NSString).substring(with: match.range(at: 1))
          .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        while let last = open.last, last >= indent { open.removeLast() }
        levels[line.location] = open.count
        open.append(indent)
      } else if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        open.removeAll()
      }
    }
    return levels
  }

  static func apply(to storage: NSTextStorage) {
    let text = storage.string
    let all = fullRange(text)
    let dim = NSColor.tertiaryLabelColor
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineHeightMultiple = bodyLineHeight
    paragraph.paragraphSpacing = paragraphGap

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
    // List lines are laid out on a grid of `listColumn`s, as in Raycast
    // Notes: the leading whitespace collapses to one column per nesting
    // level, the marker starts `lead` in from there, and the whitespace
    // after the marker stretches so the text starts at the next column.
    // Wrapped lines line up with the text. Tabs keep their tab stops (a
    // kern cannot cancel one), so such a line keeps the plain layout.
    let levels = listLevels(in: text)
    let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width
    func layoutList(line: NSRange, indent: NSRange, lead: CGFloat, markerWidth: CGFloat, gap: NSRange, textStart: Int) {
      let prefix = NSRange(location: line.location, length: textStart - line.location)
      guard !ns.substring(with: prefix).contains("\t") else { return }
      let level = CGFloat(levels[line.location] ?? 0)
      for offset in 0..<indent.length {
        let space = NSRange(location: indent.location + offset, length: 1)
        storage.addAttribute(.kern, value: (offset == 0 ? level * listColumn : 0) - spaceWidth, range: space)
      }
      if gap.length > 0 {
        let gapWidth = storage.attributedSubstring(from: gap).size().width
        let stretch = max(0, listColumn - lead - markerWidth - gapWidth)
        storage.addAttribute(.kern, value: stretch, range: NSRange(location: gap.location, length: 1))
      }
      let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
      style.firstLineHeadIndent = lead
      style.headIndent = lead + storage.attributedSubstring(from: prefix).size().width
      storage.addAttribute(.paragraphStyle, value: style, range: ns.lineRange(for: line))
    }

    for match in heading.matches(in: text, range: all) where !inCode(match.range) {
      let level = min(match.range(at: 1).length, 4) - 1
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
      // sits where the line starts, as in Raycast Notes. The three box
      // characters are squeezed to the drawn box's width.
      collapse(NSRange(location: match.range(at: 2).location, length: box.location - match.range(at: 2).location))
      storage.addAttribute(.kern, value: taskBoxSide / 3 - monoAdvance, range: box)
      let body = match.range(at: 4)
      if done, body.location != NSNotFound, body.length > 0 {
        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: body)
      }
      let textStart = body.location != NSNotFound ? body.location : NSMaxRange(match.range)
      layoutList(
        line: match.range, indent: match.range(at: 1), lead: 0, markerWidth: taskBoxSide,
        gap: NSRange(location: NSMaxRange(box), length: textStart - NSMaxRange(box)), textStart: textStart)
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
      layoutList(
        line: match.range, indent: match.range(at: 1), lead: listMarkerLead,
        markerWidth: storage.attributedSubstring(from: marker).size().width,
        gap: NSRange(location: NSMaxRange(marker), length: NSMaxRange(match.range) - NSMaxRange(marker)),
        textStart: NSMaxRange(match.range))
    }
    // A quote's ">" (and a callout's ">>") is hidden; the layout manager
    // draws a bar down the left of a quote and a box around a callout,
    // spanning consecutive lines, and a hint on an empty one. The text
    // is indented past the bar or into the box.
    func styleBlock(
      _ matches: [NSTextCheckingResult], mark: NSAttributedString.Key, placeholder: NSAttributedString.Key,
      indent: CGFloat, tail: CGFloat, gap: CGFloat
    ) {
      let lineStarts = Set(matches.map { ns.lineRange(for: $0.range).location })
      for match in matches {
        let body = match.range(at: 2)
        // The marker keeps the body font (each character kerned away by
        // its own width) so an empty line is as tall as one with text and
        // the bar or box lines up the same way on both. A tab cannot be
        // kerned away (it jumps to a tab stop), so such a marker stays, dimmed.
        let markerRange = NSRange(location: match.range(at: 1).location, length: body.location - match.range(at: 1).location)
        if ns.substring(with: markerRange).contains("\t") {
          storage.addAttribute(.foregroundColor, value: dim, range: markerRange)
        } else {
          for offset in 0..<markerRange.length {
            let character = NSRange(location: markerRange.location + offset, length: 1)
            let width = (ns.substring(with: character) as NSString).size(withAttributes: [.font: baseFont]).width
            storage.addAttributes(
              [.foregroundColor: NSColor.clear, .kern: -width, hiddenRun: HiddenRole.line.rawValue], range: character)
          }
        }
        // Lines within the block sit close; the block as a whole keeps
        // `gap` above and below.
        let line = ns.lineRange(for: match.range)
        let previousInBlock = line.location > 0
          && lineStarts.contains(ns.lineRange(for: NSRange(location: line.location - 1, length: 0)).location)
        let nextInBlock = NSMaxRange(line) < ns.length && lineStarts.contains(NSMaxRange(line))
        let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.tailIndent = -tail
        style.paragraphSpacingBefore = previousInBlock ? 0 : gap
        style.paragraphSpacing = nextInBlock ? 2 * zoom : gap
        storage.addAttributes([.paragraphStyle: style, mark: true], range: line)
        if ns.substring(with: body).trimmingCharacters(in: .whitespaces).isEmpty {
          storage.addAttribute(placeholder, value: true, range: line)
        }
      }
    }
    styleBlock(
      quote.matches(in: text, range: all).filter { !inCode($0.range) },
      mark: quoteBar, placeholder: quotePlaceholder, indent: quoteIndent, tail: 0, gap: quoteGap)
    styleBlock(
      callout.matches(in: text, range: all).filter { !inCode($0.range) },
      mark: calloutBox, placeholder: calloutPlaceholder, indent: calloutPad, tail: calloutPad,
      gap: calloutPad + calloutGap)
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
      // A whole line of **** or ____ is a horizontal rule, not a pair;
      // an empty code or strike pair on its own line is still a pair.
      let matched = ns.substring(with: match.range)
      let line = ns.lineRange(for: match.range)
      if (matched.hasPrefix("*") || matched.hasPrefix("_")),
        ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) == matched
      { continue }
      let half = match.range.length / 2
      marker(NSRange(location: match.range.location, length: half), .open)
      marker(NSRange(location: match.range.location + half, length: half), .close)
    }
    // Adds a trait to every font run inside `range` (so bold inside italic
    // keeps its italic), leaving already hidden markers untouched.
    func addTrait(_ trait: NSFontTraitMask, in range: NSRange) {
      storage.enumerateAttribute(.font, in: range) { value, run, _ in
        guard storage.attribute(hiddenRun, at: run.location, effectiveRange: nil) == nil else { return }
        let current = value as? NSFont ?? baseFont
        storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: trait), range: run)
      }
    }
    for match in bold.matches(in: text, range: all) where !inCode(match.range) {
      addTrait(.boldFontMask, in: match.range(at: 2))
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
      let group = match.range(at: 1).location != NSNotFound ? 1 : 3
      addTrait(.italicFontMask, in: match.range(at: group + 1))
      marker(match.range(at: group), .open)
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
