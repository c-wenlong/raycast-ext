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
  override init() {
    super.init()
    // Its own delegate: collapsed toggle children get no glyphs or height.
    delegate = self
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    delegate = self
  }

  /// True when character `index` is a collapsed toggle's child.
  func isFolded(_ index: Int) -> Bool {
    guard let storage = textStorage, index >= 0, index < storage.length else { return false }
    return storage.attribute(Markdown.folded, at: index, effectiveRange: nil) != nil
  }

  /// `run` less the folded lines at its start and end; nil when all of it
  /// is folded.
  private func visiblePart(of run: NSRange) -> NSRange? {
    guard let storage = textStorage else { return nil }
    let ns = storage.string as NSString
    var start = run.location
    var end = NSMaxRange(run)
    while start < end, isFolded(start) { start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) }
    while end > start, isFolded(end - 1) { end = ns.lineRange(for: NSRange(location: end - 1, length: 0)).location }
    return end > start ? NSRange(location: start, length: end - start) : nil
  }

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
      // A collapsed toggle's children take no room and show nothing.
      if fragment.height == 0 {
        index = NSMaxRange(fragmentGlyphs)
        continue
      }
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
      guard let done = value as? Bool, !isFolded(range.location) else { return }
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
      guard value != nil, !isFolded(range.location) else { return }
      drawBulletDot(characters: range, origin: origin)
    }
    storage.enumerateAttribute(Markdown.toggleChevron, in: chars) { value, range, _ in
      guard let collapsed = value as? Bool, !isFolded(range.location) else { return }
      drawChevron(markerAt: range.location, collapsed: collapsed, origin: origin)
    }
  }

  /// The gutter column left of the title of the toggle whose ">" is at
  /// `index`, as tall as the title's first line, in container coordinates.
  func chevronRect(forMarkerAt index: Int) -> NSRect? {
    guard let storage = textStorage, let container = textContainers.first, index < storage.length else { return nil }
    let glyph = glyphIndexForCharacter(at: index)
    guard glyph < numberOfGlyphs else { return nil }
    let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    guard fragment.height > 0 else { return nil }
    let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    let textLeft = fragment.minX + container.lineFragmentPadding + (style?.firstLineHeadIndent ?? 0)
    return NSRect(x: textLeft - Markdown.listColumn, y: fragment.minY, width: Markdown.listColumn, height: fragment.height)
  }

  /// The ">" of the toggle whose chevron is under `point` (text view
  /// coordinates), for a click to collapse or expand it.
  func toggleMarker(at point: NSPoint, origin: NSPoint) -> Int? {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return nil }
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    let glyph = glyphIndex(for: local, in: container)
    guard glyph < numberOfGlyphs else { return nil }
    let ns = storage.string as NSString
    let line = ns.lineRange(for: NSRange(location: characterIndexForGlyph(at: glyph), length: 0))
    var found: Int?
    storage.enumerateAttribute(Markdown.toggleChevron, in: line) { value, range, stop in
      if value != nil {
        found = range.location
        stop.pointee = true
      }
    }
    guard let marker = found, let column = chevronRect(forMarkerAt: marker), column.contains(local) else { return nil }
    return marker
  }

  /// A chevron in the accent colour where a bullet's dot would sit:
  /// pointing right when collapsed, down when open, centred on the
  /// title's capitals so it follows a heading's size.
  private func drawChevron(markerAt index: Int, collapsed: Bool, origin: NSPoint) {
    guard let storage = textStorage, let column = chevronRect(forMarkerAt: index) else { return }
    let glyph = glyphIndexForCharacter(at: index)
    let baseline = column.minY + location(forGlyphAt: glyph).y
    let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? Markdown.baseFont
    let zoom = Markdown.zoom
    let center = NSPoint(x: origin.x + column.minX + 7 * zoom, y: origin.y + baseline - font.capHeight / 2)
    let arm = 3.5 * zoom
    let path = NSBezierPath()
    if collapsed {
      path.move(to: NSPoint(x: center.x - arm / 2, y: center.y - arm))
      path.line(to: NSPoint(x: center.x + arm / 2, y: center.y))
      path.line(to: NSPoint(x: center.x - arm / 2, y: center.y + arm))
    } else {
      path.move(to: NSPoint(x: center.x - arm, y: center.y - arm / 2))
      path.line(to: NSPoint(x: center.x, y: center.y + arm / 2))
      path.line(to: NSPoint(x: center.x + arm, y: center.y - arm / 2))
    }
    path.lineWidth = 1.6 * zoom
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    Markdown.accent.setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }

  /// Draws a grey hint on every line marked with `key` inside `chars`,
  /// where its text would start: one per line, since neighbouring empty
  /// lines share one attribute run.
  private func drawPlaceholders(
    _ key: NSAttributedString.Key, in chars: NSRange, origin: NSPoint, label: (Any) -> (String, NSFont)
  ) {
    guard let storage = textStorage, let container = textContainers.first else { return }
    let ns = storage.string as NSString
    storage.enumerateAttribute(key, in: chars) { value, range, _ in
      guard let value else { return }
      let (text, font) = label(value)
      var start = range.location
      while start < NSMaxRange(range) {
        let line = ns.lineRange(for: NSRange(location: start, length: 0))
        start = max(NSMaxRange(line), start + 1)
        let glyph = glyphIndexForCharacter(at: line.location)
        guard !isFolded(line.location), glyph < numberOfGlyphs else { continue }
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = origin.y + fragment.minY + location(forGlyphAt: glyph).y
        let style = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle
        let point = NSPoint(
          x: origin.x + fragment.minX + container.lineFragmentPadding + (style?.firstLineHeadIndent ?? 0),
          y: baseline - font.ascender)
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
      }
    }
  }

  /// Draws the bar down the left of every quote crossing `rect` (text view
  /// coordinates), one bar per run of quote lines, and "Empty quote" on a
  /// quote line with no text. NoteTextView calls it from drawBackground.
  func drawQuoteBars(in rect: NSRect, origin: NSPoint) {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
    let reach = 2 * Markdown.zoom  // the bar's padding past its text
    let band = NSRect(x: 0, y: rect.minY - origin.y - reach, width: container.size.width, height: rect.height + reach * 2)
    let glyphs = glyphRange(forBoundingRect: band, in: container)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return }
    let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    guard chars.location != NSNotFound, chars.length > 0, NSMaxRange(chars) <= storage.length else { return }
    let whole = NSRange(location: 0, length: storage.length)
    var drawn = Set<Int>()
    storage.enumerateAttribute(Markdown.quoteBar, in: chars) { value, range, _ in
      guard value != nil else { return }
      var fullRun = range
      _ = storage.attribute(Markdown.quoteBar, at: range.location, longestEffectiveRange: &fullRun, in: whole)
      guard drawn.insert(fullRun.location).inserted, let run = visiblePart(of: fullRun) else { return }
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
    drawPlaceholders(Markdown.quotePlaceholder, in: chars, origin: origin) { _ in ("Empty quote", Markdown.baseFont) }
    drawPlaceholders(Markdown.togglePlaceholder, in: chars, origin: origin) { value in
      let level = value as? Int ?? 0
      return ("Toggle", level > 0 ? Markdown.headingFonts[level - 1] : Markdown.baseFont)
    }
  }

  /// Draws the outlined box around every callout crossing `rect` (text
  /// view coordinates), one box per run of callout lines, and "Empty
  /// callout" on a callout line with no text. NoteTextView calls it from
  /// drawBackground.
  func drawCalloutBoxes(in rect: NSRect, origin: NSPoint) {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
    // The box reaches `calloutPad` past its text, so look that far past
    // the redraw area for callout glyphs.
    let reach = Markdown.calloutPad + 1
    let band = NSRect(x: 0, y: rect.minY - origin.y - reach, width: container.size.width, height: rect.height + reach * 2)
    let glyphs = glyphRange(forBoundingRect: band, in: container)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return }
    let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    guard chars.location != NSNotFound, chars.length > 0, NSMaxRange(chars) <= storage.length else { return }
    let whole = NSRange(location: 0, length: storage.length)
    let font = Markdown.baseFont
    var drawn = Set<Int>()
    storage.enumerateAttribute(Markdown.calloutBox, in: chars) { value, range, _ in
      guard value != nil else { return }
      var fullRun = range
      _ = storage.attribute(Markdown.calloutBox, at: range.location, longestEffectiveRange: &fullRun, in: whole)
      guard drawn.insert(fullRun.location).inserted, let run = visiblePart(of: fullRun) else { return }
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
    drawPlaceholders(Markdown.calloutPlaceholder, in: chars, origin: origin) { _ in ("Empty callout", font) }
  }

  /// Draws a hairline across the text column on every divider line
  /// crossing `rect` (text view coordinates), centred on where its text
  /// would sit. NoteTextView calls it from drawBackground.
  func drawDividers(in rect: NSRect, origin: NSPoint) {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
    let band = NSRect(x: 0, y: rect.minY - origin.y - 2, width: container.size.width, height: rect.height + 4)
    let glyphs = glyphRange(forBoundingRect: band, in: container)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return }
    let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    guard chars.location != NSNotFound, chars.length > 0, NSMaxRange(chars) <= storage.length else { return }
    let ns = storage.string as NSString
    let scale = firstTextView?.window?.backingScaleFactor ?? 2
    let font = Markdown.baseFont
    var drawn = Set<Int>()
    storage.enumerateAttribute(Markdown.divider, in: chars) { value, range, _ in
      guard value != nil else { return }
      let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
      guard drawn.insert(lineStart).inserted, !isFolded(lineStart) else { return }
      let glyph = glyphIndexForCharacter(at: lineStart)
      let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let baseline = fragment.minY + location(forGlyphAt: glyph).y
      // Mid-height of body text on this line, snapped to a device pixel.
      let mid = ((origin.y + baseline - (font.ascender + font.descender) / 2) * scale).rounded(.down) / scale
      let hairline = NSRect(
        x: origin.x + container.lineFragmentPadding, y: mid,
        width: container.size.width - container.lineFragmentPadding * 2, height: 1 / scale)
      NSGraphicsContext.saveGraphicsState()
      Markdown.dividerColor.setFill()
      hairline.fill()
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  /// Draws a rounded accent-tinted chip behind every date (tagged
  /// `Markdown.dateChip`) crossing `rect` (text view coordinates), one per
  /// line fragment if a date wraps. NoteTextView calls it from
  /// drawBackground, so the selection and the text draw over it.
  func drawDateChips(in rect: NSRect, origin: NSPoint) {
    guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
    let pad = Markdown.dateChipPad
    let band = NSRect(x: 0, y: rect.minY - origin.y - pad, width: container.size.width, height: rect.height + pad * 2)
    let glyphs = glyphRange(forBoundingRect: band, in: container)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return }
    let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    guard chars.location != NSNotFound, chars.length > 0, NSMaxRange(chars) <= storage.length else { return }
    storage.enumerateAttribute(Markdown.dateChip, in: chars) { value, range, _ in
      guard value != nil, !isFolded(range.location) else { return }
      for chip in chipRects(forCharacterRange: range) {
        NSGraphicsContext.saveGraphicsState()
        Markdown.dateChipColor.setFill()
        let radius = Markdown.dateChipRadius
        NSBezierPath(roundedRect: chip.offsetBy(dx: origin.x, dy: origin.y), xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
      }
    }
  }

  /// The chip behind the date spanning `characters`, in container
  /// coordinates: one rect per line fragment, from the first glyph to the
  /// last, padded by `dateChipPad` on the sides, and from a little above the
  /// digits (cap height) to a little below the baseline.
  func chipRects(forCharacterRange characters: NSRange) -> [NSRect] {
    guard let storage = textStorage, characters.length > 0,
      NSMaxRange(characters) <= storage.length
    else { return [] }
    let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
    guard glyphs.location != NSNotFound, glyphs.length > 0 else { return [] }
    var rects: [NSRect] = []
    var index = glyphs.location
    while index < NSMaxRange(glyphs) {
      var fragmentGlyphs = NSRange()
      let fragment = lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentGlyphs)
      let onLine = NSIntersectionRange(fragmentGlyphs, glyphs)
      guard onLine.length > 0 else { break }
      index = NSMaxRange(fragmentGlyphs)
      guard fragment.height > 0 else { continue }
      // From the first glyph's origin to the last glyph's own advance:
      // the kern Markdown.apply puts after the date (room for the pad) is
      // left out.
      let lastGlyph = NSMaxRange(onLine) - 1
      let lastChar = characterIndexForGlyph(at: lastGlyph)
      let font = storage.attribute(.font, at: lastChar, effectiveRange: nil) as? NSFont ?? Markdown.baseFont
      let left = fragment.minX + location(forGlyphAt: onLine.location).x
      let right = fragment.minX + location(forGlyphAt: lastGlyph).x + font.advancement(forCGGlyph: cgGlyph(at: lastGlyph)).width
      let baseline = fragment.minY + location(forGlyphAt: onLine.location).y
      let scale = font.pointSize / 15
      let top = baseline - font.capHeight - 4 * scale
      let bottom = baseline + 3.5 * scale
      let pad = Markdown.dateChipPad
      rects.append(NSRect(x: left - pad, y: top, width: right - left + pad * 2, height: bottom - top))
    }
    return rects
  }

  /// Draws the code cards behind `rect` (text view coordinates), spanning
  /// the text column like a callout box. NoteTextView calls it
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
      guard let id = value as? Int, drawn.insert(id).inserted, !isFolded(id) else { return }
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
  /// top of the opening line fragment, sides are the text column's edges
  /// (the container less its line fragment padding), bottom is the closing line's fixed
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
    let edge = container.lineFragmentPadding
    return NSRect(
      x: edge, y: first.minY,
      width: container.size.width - edge * 2, height: max(0, bottom - first.minY))
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

extension TaskBoxLayoutManager: NSLayoutManagerDelegate {
  // Collapsed toggle children (`Markdown.folded`) stay in the text but
  // get null glyphs (no advance, nothing drawn) and zero-height line
  // fragments, so they take no room; their line breaks still end lines.

  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
    font aFont: NSFont, forGlyphRange glyphRange: NSRange
  ) -> Int {
    guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
    let first = charIndexes[0]
    let last = charIndexes[glyphRange.length - 1]
    guard first >= 0, last < storage.length, last >= first else { return 0 }
    var any = false
    storage.enumerateAttribute(
      Markdown.folded, in: NSRange(location: first, length: last - first + 1), options: .longestEffectiveRangeNotRequired
    ) { value, _, stop in
      if value != nil {
        any = true
        stop.pointee = true
      }
    }
    guard any else { return 0 }
    var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
    for index in 0..<glyphRange.length
    where !properties[index].contains(.controlCharacter)
      && storage.attribute(Markdown.folded, at: charIndexes[index], effectiveRange: nil) != nil
    {
      properties[index] = .null
    }
    layoutManager.setGlyphs(glyphs, properties: properties, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
    return glyphRange.length
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    // A folded tab takes no room either; line breaks still break.
    if action.contains(.horizontalTab), isFolded(charIndex) { return .zeroAdvancement }
    return action
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
    lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
    in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
  ) -> Bool {
    guard glyphRange.length > 0, isFolded(characterIndexForGlyph(at: glyphRange.location)) else { return false }
    lineFragmentRect.pointee.size.height = 0
    lineFragmentUsedRect.pointee.size.height = 0
    baselineOffset.pointee = 0
    return true
  }
}

enum Markdown {
  /// Multiplier applied to every font size (⌘+ / ⌘- zoom).
  static var zoom: CGFloat = 1.0

  /// The note's typeface (⌘K, remembered); code stays monospaced.
  static var font: NoteFont = .sans

  static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  /// The one highlight colour: list markers, numbers, task boxes, links.
  /// The Raycast red over the dark canvas; a deeper red over the light
  /// one, so links and numbers keep 4.5:1 contrast as text.
  static let accent = NSColor(name: nil) { appearance in
    isDark(appearance)
      ? NSColor(srgbRed: 0.91, green: 0.36, blue: 0.33, alpha: 1)
      : NSColor(srgbRed: 0.80, green: 0.24, blue: 0.21, alpha: 1)
  }
  /// Selected text: a wash of the accent, as in Raycast Notes; lighter
  /// over the light canvas so dark text stays crisp on it.
  static let selection = NSColor(name: nil) { appearance in
    isDark(appearance)
      ? NSColor(srgbRed: 0.91, green: 0.36, blue: 0.33, alpha: 0.42)
      : NSColor(srgbRed: 0.91, green: 0.36, blue: 0.33, alpha: 0.3)
  }
  /// Marks a task's "[ ]" / "[x]" characters; the value is `true` when done.
  static let taskBox = NSAttributedString.Key("taskBox")
  /// Marks the (clear) "-", "*" or "+" of a bullet item, which
  /// TaskBoxLayoutManager draws as a round dot.
  static let bulletDot = NSAttributedString.Key("bulletDot")
  static var bulletDotDiameter: CGFloat { 4.5 * zoom }
  /// Side of a task box: 14pt at 15pt text, as in Raycast Notes.
  static var taskBoxSide: CGFloat { (baseFont.pointSize * 14 / 15).rounded() }

  /// The note's background, as in Raycast Notes: near-black (#1A1A1A) in
  /// dark mode, near-white in light mode.
  static let canvas = NSColor(name: nil) { appearance in
    isDark(appearance) ? NSColor(white: 26 / 255, alpha: 1) : NSColor(white: 0.985, alpha: 1)
  }

  static var baseFont: NSFont { font.font(ofSize: 15 * zoom) }
  static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13.5 * zoom, weight: .regular) }
  /// Width of one monospace glyph at the current zoom.
  static var monoAdvance: CGFloat { ("-" as NSString).size(withAttributes: [.font: monoFont]).width }
  static var headingFonts: [NSFont] {
    [
      font.font(ofSize: 24 * zoom, weight: .bold),
      font.font(ofSize: 20 * zoom, weight: .bold),
      font.font(ofSize: 17 * zoom, weight: .bold),
      font.font(ofSize: 15 * zoom, weight: .semibold),
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
  /// Marks a divider line (`---`, `***`, `___`); the layout manager draws
  /// a hairline across the text column, the characters are hidden.
  static let divider = NSAttributedString.Key("divider")
  static let dividerColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.18)
  }
  /// On a toggle's (hidden) ">": the layout manager draws a disclosure
  /// chevron in the gutter left of the title; the value is `true` when
  /// the toggle is collapsed.
  static let toggleChevron = NSAttributedString.Key("toggleChevron")
  /// Marks a collapsed toggle's ">". It is the one attribute `apply`
  /// keeps (it moves with the text as the note is edited); it is never
  /// saved, and lives only while the window shows the note.
  static let toggleCollapsed = NSAttributedString.Key("toggleCollapsed")
  /// Marks a toggle line with an empty title ("Toggle" is drawn there);
  /// the value is the heading level (0 for body text).
  static let togglePlaceholder = NSAttributedString.Key("togglePlaceholder")
  /// Marks the children of a collapsed toggle: no glyphs, no height, and
  /// the caret never rests there (TaskBoxLayoutManager, NoteTextView).
  static let folded = NSAttributedString.Key("folded")
  /// Space between a boxed block's text and its box (callouts and code
  /// blocks), on every side. Boxes span the text column edge to edge, so
  /// every block lines up with the text around it.
  static var blockPad: CGFloat { 14 * zoom }
  static var calloutPad: CGFloat { blockPad }
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
  /// the column's left edge; a task box sits flush. Mono's wider glyphs
  /// get a wider column, so "1. " still fits in one.
  static var listColumn: CGFloat { (font == .mono ? 26 : 22) * zoom }
  static var listMarkerLead: CGFloat { 2.5 * zoom }
  static let listLine = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*+]|\d+\.)[ \t]+"#)
  static let taskScheme = "notes-task"

  /// Marks a standalone ISO date ("2026-10-05", see Dates.chipRanges);
  /// TaskBoxLayoutManager draws a chip behind it. The text is unchanged.
  static let dateChip = NSAttributedString.Key("dateChip")
  static var dateChipPad: CGFloat { 4 * zoom }
  static var dateChipRadius: CGFloat { 5 * zoom }
  /// A faint wash of the accent, lighter than the selection.
  static let dateChipColor = NSColor(name: nil) { appearance in
    NSColor(srgbRed: 0.91, green: 0.36, blue: 0.33, alpha: isDark(appearance) ? 0.2 : 0.14)
  }

  /// Marks every character of a fenced code block, opening fence line
  /// through closing fence line; the value is the block's start offset
  /// (an Int), so neighbouring blocks stay distinct.
  static let codeBlock = NSAttributedString.Key("codeBlock")
  /// Height of the (hidden) opening fence line: the card's header strip,
  /// which the overlay controls sit in.
  static var codeHeaderHeight: CGFloat { (34 * max(zoom, 1)).rounded() }
  /// Height of the (hidden) closing fence line: the card's bottom padding.
  static var codeFooterHeight: CGFloat { (18 * zoom).rounded() }
  static let codeCardRadius: CGFloat = 10
  /// A shade lighter than the editor in dark mode, darker in light mode.
  static let codeCardColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.045)
  }

  /// Behind an inline code span: the code card's wash, a touch stronger
  /// since a span is small.
  static let codeSpanColor = NSColor(name: nil) { appearance in
    isDark(appearance) ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.07)
  }

  static let task = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+(\[[ xX]\])(?:[ \t]+(.*))?$"#, options: .anchorsMatchLines)
  // Possessive `[ \t]++` so "-  [ ] x" cannot backtrack to one space and
  // pass as a bullet as well as a task.
  static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+\.)[ \t]++(?!\[[ xX]\])"#, options: .anchorsMatchLines)
  // A block needs its closing fence: an opening fence typed on its own
  // stays literal text (the Enter and Space rules add the closing fence)
  // rather than swallowing the rest of the note.
  static let fence = ListEditing.fencePattern
  static let rule = ListEditing.rulePattern
  // Shared with the formatting keys (ListEditing.toggleWrap).
  static let bold = ListEditing.boldPattern
  static let italic = ListEditing.italicPattern
  static let strike = ListEditing.strikePattern
  static let code = ListEditing.codePattern
  static let link = NoteNames.linkPattern
  static let bareURL = try! NSRegularExpression(pattern: ListEditing.bareURLPattern + "+")

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

  /// Marks source syntax that acts as one editing unit: collapsed inline
  /// delimiters and targets, or a block/list prefix including its spacing.
  /// Drawn list markers retain width. The caret never rests inside a run.
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

    // Collapsed toggles survive the reset below: the attribute rides on
    // the toggle's ">" as the text is edited. Only a toggle's own ">"
    // counts; the attribute anywhere else (inherited by inserted text) is
    // dropped by the reset.
    let toggleLayout = ListEditing.toggleLayout(in: text)
    var collapsedLines = Set<Int>()
    for toggle in toggleLayout.toggles {
      let title = (text as NSString).substring(with: toggle.title)
      guard let unit = ListEditing.blockPrefix(of: title).unit(.toggle) else { continue }
      if storage.attribute(toggleCollapsed, at: toggle.title.location + unit.range.location, effectiveRange: nil) != nil {
        collapsedLines.insert(toggle.title.location)
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
      // The code sits `blockPad` in from the card's edges, like a callout.
      codeBody.firstLineHeadIndent = blockPad
      codeBody.headIndent = blockPad
      codeBody.tailIndent = -blockPad
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
    // Where each marked line's text starts (after its list or block
    // markers), keyed by line start, for the date chips' spacing.
    var textStarts: [Int: Int] = [:]
    let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width
    func layoutList(line: NSRange, indent: NSRange, lead: CGFloat, markerWidth: CGFloat, gap: NSRange, textStart: Int) {
      let prefix = NSRange(location: line.location, length: textStart - line.location)
      // The drawn marker and its layout spacing are one editing unit,
      // even when their glyphs retain width (checkboxes, numbers, tabs).
      storage.addAttribute(hiddenRun, value: HiddenRole.line.rawValue, range: prefix)
      guard !ns.substring(with: prefix).contains("\t") else { return }
      // Inside a toggle the list starts one column in per enclosing toggle.
      let level = CGFloat((levels[line.location] ?? 0) + (toggleLayout.depth[line.location] ?? 0))
      for offset in 0..<indent.length {
        let space = NSRange(location: indent.location + offset, length: 1)
        storage.addAttribute(.kern, value: (offset == 0 ? level * listColumn : 0) - spaceWidth, range: space)
      }
      if gap.length > 0 {
        let gapWidth = storage.attributedSubstring(from: gap).size().width
        // The gap stretches to the column; a wide space (Mono's) may also
        // shrink to 4pt so the text still reaches it.
        let shrink = min(0, 4 * zoom - gapWidth)
        let stretch = max(shrink, listColumn - lead - markerWidth - gapWidth)
        storage.addAttribute(.kern, value: stretch, range: NSRange(location: gap.location, length: 1))
      }
      let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
      style.firstLineHeadIndent = lead
      style.headIndent = lead + storage.attributedSubstring(from: prefix).size().width
      storage.addAttribute(.paragraphStyle, value: style, range: ns.lineRange(for: line))
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
      textStarts[match.range.location] = textStart
      layoutList(
        line: match.range, indent: match.range(at: 1), lead: 0, markerWidth: taskBoxSide,
        gap: NSRange(location: NSMaxRange(box), length: textStart - NSMaxRange(box)), textStart: textStart)
    }
    for match in bullet.matches(in: text, range: all) where !inCode(match.range) {
      textStarts[match.range.location] = NSMaxRange(match.range)
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
    // Block markers ("| " quote, "> " toggle, "#" heading, "!> " callout)
    // and the indent of a toggle's children are hidden: each character
    // keeps its font and is kerned away by its own width, so an empty line
    // is as tall as one with text. A tab cannot be kerned away (it jumps
    // to a tab stop), so it stays, dimmed. The layout manager draws a bar
    // down a quote, a box around a callout and a chevron left of a
    // toggle, and a hint on an empty one. The text is indented past the
    // bar, into the box, past the chevron, and one column per enclosing
    // toggle.
    struct BlockLine {
      let line: NSRange  // with its line break
      let prefix: ListEditing.BlockPrefix
      let depth: Int
    }
    var blockLines: [BlockLine] = []
    var location = 0
    while location < ns.length {
      let line = ns.lineRange(for: NSRange(location: location, length: 0))
      location = NSMaxRange(line)
      guard !inCode(line) else { continue }
      var contentsEnd = 0
      ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
      let content = ns.substring(with: NSRange(location: line.location, length: contentsEnd - line.location))
      // List lines lay themselves out (layoutList, which knows the depth).
      if listLine.firstMatch(in: content, range: fullRange(content)) != nil { continue }
      let prefix = ListEditing.blockPrefix(of: content)
      let depth = toggleLayout.depth[line.location] ?? 0
      guard prefix.hasMarkers || (depth > 0 && prefix.indent > 0) else { continue }
      blockLines.append(BlockLine(line: line, prefix: prefix, depth: depth))
    }
    let quoteStarts = Set(blockLines.filter { $0.prefix.quote }.map(\.line.location))
    let calloutStarts = Set(blockLines.filter { $0.prefix.callout }.map(\.line.location))
    let toggleStarts = Set(toggleLayout.toggles.map(\.title.location))
    for block in blockLines {
      let line = block.line
      let prefix = block.prefix
      var contentEnd = 0
      ns.getLineStart(nil, end: nil, contentsEnd: &contentEnd, for: line)
      let content = NSRange(location: line.location + prefix.contentStart, length: max(0, contentEnd - line.location - prefix.contentStart))
      textStarts[line.location] = content.location
      let font = prefix.headingLevel > 0 ? headingFonts[prefix.headingLevel - 1] : baseFont
      if prefix.headingLevel > 0, content.length > 0 { storage.addAttribute(.font, value: font, range: content) }
      for offset in 0..<prefix.contentStart {
        let character = NSRange(location: line.location + offset, length: 1)
        let glyph = ns.substring(with: character)
        if glyph == "\t" {
          storage.addAttribute(.foregroundColor, value: dim, range: character)
        } else {
          let width = (glyph as NSString).size(withAttributes: [.font: font]).width
          storage.addAttributes(
            [.font: font, .foregroundColor: NSColor.clear, .kern: -width, hiddenRun: HiddenRole.line.rawValue], range: character)
        }
      }
      var lead = CGFloat(block.depth) * listColumn
      let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
      if prefix.headingLevel > 0 {
        style.lineHeightMultiple = 1.1
        style.paragraphSpacingBefore = headingSpaceBefore[prefix.headingLevel - 1] * zoom
        style.paragraphSpacing = 6 * zoom
      }
      // Lines within a quote or callout sit close; the block as a whole
      // keeps its gap above and below.
      func blockSpacing(_ starts: Set<Int>, gap: CGFloat) {
        let previousInBlock = line.location > 0
          && starts.contains(ns.lineRange(for: NSRange(location: line.location - 1, length: 0)).location)
        let nextInBlock = NSMaxRange(line) < ns.length && starts.contains(NSMaxRange(line))
        style.paragraphSpacingBefore = previousInBlock ? 0 : gap
        style.paragraphSpacing = nextInBlock ? 2 * zoom : gap
      }
      if prefix.quote {
        lead += quoteIndent
        blockSpacing(quoteStarts, gap: quoteGap)
        storage.addAttribute(quoteBar, value: true, range: line)
      }
      if prefix.callout {
        lead += calloutPad
        style.tailIndent = -calloutPad
        blockSpacing(calloutStarts, gap: calloutPad + calloutGap)
        storage.addAttribute(calloutBox, value: true, range: line)
      }
      if let toggle = prefix.unit(.toggle), toggleStarts.contains(line.location) {
        lead += listColumn
        let marker = NSRange(location: line.location + toggle.range.location, length: 1)
        let collapsed = collapsedLines.contains(line.location)
        storage.addAttribute(toggleChevron, value: collapsed, range: marker)
        if collapsed { storage.addAttribute(toggleCollapsed, value: true, range: marker) }
      }
      style.firstLineHeadIndent = lead
      style.headIndent = lead
      storage.addAttribute(.paragraphStyle, value: style, range: line)
      if ns.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty {
        if prefix.toggle {
          storage.addAttribute(togglePlaceholder, value: prefix.headingLevel, range: line)
        } else if prefix.quote {
          storage.addAttribute(quotePlaceholder, value: true, range: line)
        } else if prefix.callout {
          storage.addAttribute(calloutPlaceholder, value: true, range: line)
        }
      }
    }
    // A collapsed toggle's children take no room (TaskBoxLayoutManager).
    for toggle in toggleLayout.toggles where collapsedLines.contains(toggle.title.location) && toggle.children.length > 0 {
      storage.addAttribute(folded, value: true, range: toggle.children)
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
      // Two backticks stay visible: they are usually the start of a
      // fence being typed, and code styling wants text between them.
      if matched.hasPrefix("`") { continue }
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
        [.font: monoFont, .backgroundColor: codeSpanColor], range: match.range(at: 2))
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
    // A divider line: its characters collapse (last, over any pair the
    // inline patterns found in `******`) and the layout manager draws a
    // hairline across the text column.
    for match in rule.matches(in: text, range: all) where !inCode(match.range) {
      let line = ns.substring(with: match.range)
      let marks = NSRange(location: match.range.location, length: (line.trimmingCharacters(in: .whitespaces) as NSString).length)
      storage.removeAttribute(.strikethroughStyle, range: marks)
      storage.addAttributes([.foregroundColor: NSColor.clear, .font: monoFont, .kern: -monoAdvance, hiddenRun: HiddenRole.line.rawValue], range: marks)
      // Trailing whitespace belongs to the same divider, not extra
      // invisible caret stops after the painted hairline.
      storage.addAttribute(hiddenRun, value: HiddenRole.line.rawValue, range: match.range)
      storage.addAttribute(divider, value: true, range: match.range)
    }
    // Room for each chip's padding, so it never covers its neighbours: a
    // kern after the date, and one before it unless the date starts the
    // line's text (there the chip reaches into the margin or marker gap,
    // and the text keeps its column).
    func widen(_ index: Int) {
      let kern = (storage.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
      storage.addAttribute(.kern, value: CGFloat(kern) + dateChipPad, range: NSRange(location: index, length: 1))
    }
    for range in Dates.chipRanges(in: text, excluding: codeRanges) {
      storage.addAttribute(dateChip, value: true, range: range)
      widen(NSMaxRange(range) - 1)
      let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
      if range.location > (textStarts[lineStart] ?? lineStart) { widen(range.location - 1) }
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
