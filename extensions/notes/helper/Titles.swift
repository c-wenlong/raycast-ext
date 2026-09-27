import Foundation

// MARK: - Note titles
//
// A note is named by its first line, whatever that line is: a heading,
// a list item, a quote or plain text. The markdown is stripped so the
// title reads as text. Mirrors parseTitleFromContentOrFilename in
// src/lib/notes.ts.

enum Titles {
  static let maxLength = 80
  private static let blockPrefix = try! NSRegularExpression(
    pattern: #"^\s*(?:#{1,6}\s+|>+\s*|[-*+]\s+(?:\[[ xX]\]\s*)?|\d+[.)]\s+)*"#)
  private static let link = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
  private static let inlineMarkers = try! NSRegularExpression(pattern: #"(\*\*|__|~~|`|(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w))"#)
  private static let fence = try! NSRegularExpression(pattern: #"^\s*(`{3,}|~{3,})"#)

  /// The first line of `text` that has any words once its markdown is
  /// stripped; nil for an empty note. Fence lines are skipped.
  static func firstLine(of text: String) -> String? {
    for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
      let line = String(rawLine)
      let range = NSRange(location: 0, length: (line as NSString).length)
      if fence.firstMatch(in: line, range: range) != nil { continue }
      var stripped = blockPrefix.stringByReplacingMatches(in: line, range: range, withTemplate: "")
      stripped = link.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "$1")
      stripped = inlineMarkers.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "")
      stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !stripped.isEmpty else { continue }
      return stripped.count > maxLength ? String(stripped.prefix(maxLength)).trimmingCharacters(in: .whitespaces) : stripped
    }
    return nil
  }
}
