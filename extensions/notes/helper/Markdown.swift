import AppKit
import Foundation

// MARK: - Markdown styling
//
// The text stays raw markdown so files never change shape; only display
// attributes are layered on. Markers are dimmed, headings enlarged, links
// clickable, task boxes clickable (notes-task:// links) and done tasks
// struck through.

/// Draws task boxes over the (invisible) "[ ]" characters. Filled out in
/// Markdown.swift; the text view installs it in PanelController.
final class TaskBoxLayoutManager: NSLayoutManager {}

enum Markdown {
  /// Multiplier applied to every font size (⌘+ / ⌘- zoom).
  static var zoom: CGFloat = 1.0

  static var baseFont: NSFont { NSFont.systemFont(ofSize: 15 * zoom) }
  static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13.5 * zoom, weight: .regular) }
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

  static func apply(to storage: NSTextStorage) {
    let text = storage.string
    let all = fullRange(text)
    let dim = NSColor.tertiaryLabelColor
    let accent = NSColor.controlAccentColor
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
      storage.addAttributes(
        [.foregroundColor: accent, .font: monoFont,
         .link: URL(string: "\(taskScheme)://toggle/\(box.location)")!], range: box)
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 2))
      let body = match.range(at: 4)
      if done, body.location != NSNotFound {
        storage.addAttributes(
          [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
           .foregroundColor: NSColor.secondaryLabelColor], range: body)
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
      storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range(at: 2))
      storage.addAttribute(.foregroundColor, value: dim, range: match.range(at: 4))
      if let url = URL(string: target) {
        storage.addAttribute(.link, value: url, range: match.range(at: 2))
      }
    }
    for match in bareURL.matches(in: text, range: all) where !inCode(match.range) {
      let target = (text as NSString).substring(with: match.range)
      guard let url = URL(string: target) else { continue }
      storage.addAttributes(
        [.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
    }
    storage.endEditing()
  }
}
