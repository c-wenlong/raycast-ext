import Foundation

// MARK: - Note titles
//
// A note is named by its first line, whatever that line is: a heading,
// a list item, a quote, toggle or callout, or plain text. The markdown is stripped so the
// title reads as text. Mirrors parseTitleFromContentOrFilename in
// src/lib/notes.ts.

enum Titles {
  static let maxLength = 80
  private static let blockPrefix = try! NSRegularExpression(
    pattern: #"^\s*(?:#{1,6}\s+|!?>\s+|\|\s+|[-*+]\s+(?:\[[ xX]\]\s*)?|\d+[.)]\s+)*"#)
  private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)
  private static let inlineMarkers = try! NSRegularExpression(pattern: #"(\*\*|__|~~|`|(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w))"#)
  private static let fence = try! NSRegularExpression(pattern: #"^\s*(`{3,}|~{3,})"#)

  /// The first line of `text` that has any words once its markdown is
  /// stripped; nil for an empty note. Fence lines are skipped.
  static func firstLine(of text: String) -> String? {
    titleLine(of: text)?.title
  }

  /// The range of the raw line the title comes from (without its line
  /// break), for edits that change the title in place.
  static func titleLineRange(of text: String) -> NSRange? {
    titleLine(of: text)?.range
  }

  private static func titleLine(of text: String) -> (title: String, range: NSRange)? {
    let ns = text as NSString
    var location = 0
    while location < ns.length {
      var lineEnd = 0
      var contentsEnd = 0
      ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let lineRange = NSRange(location: location, length: contentsEnd - location)
      let line = ns.substring(with: lineRange)
      let range = NSRange(location: 0, length: (line as NSString).length)
      if lineEnd == location { break }
      location = lineEnd
      if fence.firstMatch(in: line, range: range) != nil { continue }
      var stripped = blockPrefix.stringByReplacingMatches(in: line, range: range, withTemplate: "")
      stripped = link.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "$1")
      stripped = inlineMarkers.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "")
      stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !stripped.isEmpty else { continue }
      let title = stripped.count > maxLength ? String(stripped.prefix(maxLength)).trimmingCharacters(in: .whitespaces) : stripped
      return (title, lineRange)
    }
    return nil
  }
}
