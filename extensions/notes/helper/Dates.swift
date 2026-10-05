import Foundation

// MARK: - Dates
//
// Two pure rules, tested in test/list-editing:
//
// 1. `@today`, `@tomorrow` and `@yesterday` (any case) become the ISO date
//    in the local time zone ("2026-10-05") when a terminator is typed
//    after them: whitespace (Space, Enter, Tab) or closing punctuation. The
//    "@" must start a word: at the line start or after whitespace, with
//    only opening punctuation ("(", "[", "\"", "*"...) between. That keeps
//    out email addresses ("kai@today.com"), handles inside other words and
//    URLs. Inline code, fenced code and link addresses are never touched.
//
// 2. A date chip marks every standalone ISO date in prose. Standalone
//    means the date is a whole token: before it only the line start or
//    whitespace, then any opening punctuation; after it any closing
//    punctuation, then whitespace, the line end or a link's "](". So "2026-10-05.md",
//    "x-2026-10-05", "2026-10-05T09:00" and "/2026-10-05/" get no chip.
//    A date followed by a time ("2026-10-05 1008", "2026-10-05 9:30") is a
//    timestamp, like a generated filename ("2026-10-05 1008 - x.md"), and
//    gets no chip either. The date must exist (no "2026-02-30"). Code
//    (fenced and inline), link addresses and bare URLs are skipped.

enum Dates {
  /// The clock the keyword rule reads; tests replace it.
  static var now: () -> Date = { Date() }
  /// Gregorian in the local time zone, whatever calendar the Mac uses, so
  /// the date is always ISO. Tests replace it to pin the time zone.
  static var calendar: () -> Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
  }

  static let keywords: [String: Int] = ["today": 0, "tomorrow": 1, "yesterday": -1]

  /// Characters allowed between the word start and an "@" or a date.
  static let openers = Set("([{\"'“‘*_~".utf16)
  /// Characters allowed after a date before the token ends.
  static let closers = Set(".,;:!?)]}\"'”’*_~…".utf16)
  /// Characters that end an "@keyword" when typed: whitespace and the
  /// closers, less "_" (it continues handles like "@today_show") and the
  /// apostrophes ("@today's" stays a word).
  static let terminators = closers.subtracting("_'’".utf16).union(" \t\n\r".utf16)

  static func isWhitespace(_ unit: unichar) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0 || unit == 0x2028 || unit == 0x2029
  }

  /// "YYYY-MM-DD" for `date` in `calendar`'s time zone.
  static func iso(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// The ISO date `keyword` (without the "@", any case) stands for.
  static func date(forKeyword keyword: String, now: Date, calendar: Calendar) -> String? {
    guard let offset = keywords[keyword.lowercased()],
      let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))
    else { return nil }
    return iso(day, calendar: calendar)
  }

  /// True when the token starting at `index` starts a word: only opening
  /// punctuation lies between it and the line start or whitespace.
  private static func startsWord(_ ns: NSString, at index: Int) -> Bool {
    var i = index
    while i > 0, openers.contains(ns.character(at: i - 1)) { i -= 1 }
    return i == 0 || isWhitespace(ns.character(at: i - 1))
  }

  /// True when `range` sits in a link's address (`](...)`) or an inline
  /// code span on its line, closed or still being typed.
  private static func inCodeOrLinkTarget(_ ns: NSString, _ range: NSRange) -> Bool {
    let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
    let before = ns.substring(with: NSRange(location: line.location, length: range.location - line.location))
    // An odd number of backticks before it on the line: an open code span.
    if before.utf16.filter({ $0 == 0x60 }).count % 2 == 1 { return true }
    // After a "](" with no ")" since: a link address.
    if let open = before.range(of: "](", options: .backwards) {
      if !before[open.upperBound...].contains(")") { return true }
    }
    return false
  }

  /// The "@keyword" that ends exactly at `end`, as an edit replacing it
  /// with its date (cursor at the end of the date), or nil.
  static func keyword(endingAt end: Int, in text: String, now: Date = Dates.now(), calendar: Calendar = Dates.calendar()) -> ListEditing.Edit? {
    let ns = text as NSString
    guard end > 0, end <= ns.length else { return nil }
    var at = end
    // Back over ASCII letters, at most as many as the longest keyword.
    while at > 0, end - at < 9, case let unit = ns.character(at: at - 1) | 0x20, unit >= 0x61, unit <= 0x7A {
      at -= 1
    }
    guard at > 0, ns.character(at: at - 1) == 0x40 else { return nil }  // "@"
    let start = at - 1
    let word = ns.substring(with: NSRange(location: at, length: end - at))
    guard let date = date(forKeyword: word, now: now, calendar: calendar), startsWord(ns, at: start) else { return nil }
    let range = NSRange(location: start, length: end - start)
    guard !inCodeOrLinkTarget(ns, range), !ListEditing.insideFence(text, cursor: start) else { return nil }
    return ListEditing.Edit(range: range, replacement: date, cursor: start + (date as NSString).length)
  }

  /// After a terminator was typed (it ends just before `cursor`): the edit
  /// turning the "@keyword" before it into its date, keeping the
  /// terminator, the cursor after it. Nil when there is none.
  static func afterTerminator(in text: String, cursor: Int, now: Date = Dates.now(), calendar: Calendar = Dates.calendar()) -> ListEditing.Edit? {
    let ns = text as NSString
    guard cursor > 1, cursor <= ns.length, terminators.contains(ns.character(at: cursor - 1)),
      let edit = keyword(endingAt: cursor - 1, in: text, now: now, calendar: calendar)
    else { return nil }
    let delta = (edit.replacement as NSString).length - edit.range.length
    return ListEditing.Edit(range: edit.range, replacement: edit.replacement, cursor: cursor + delta)
  }

  // MARK: Chips

  private static let isoDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
  /// A time right after a date's space: "1008" (as in generated
  /// filenames) or "9:30".
  private static let timeAfter = try! NSRegularExpression(pattern: #" (?:\d{4}|\d{1,2}:\d{2})(?!\d)"#)
  // Mirrors Markdown.link's address and Markdown.bareURL.
  private static let linkTarget = try! NSRegularExpression(pattern: #"\]\([^)\s]+\)"#)
  private static let bareURL = try! NSRegularExpression(pattern: #"https?://[^\s<>\)\]]+"#)

  static func isValid(year: Int, month: Int, day: Int) -> Bool {
    guard (1...12).contains(month), day >= 1 else { return false }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    return day <= days
  }

  /// Every standalone ISO date in `text` outside `excluded` (the caller's
  /// fenced code blocks), inline code, link addresses and bare URLs.
  static func chipRanges(in text: String, excluding excluded: [NSRange] = []) -> [NSRange] {
    let ns = text as NSString
    let all = NSRange(location: 0, length: ns.length)
    let matches = isoDate.matches(in: text, range: all)
    guard !matches.isEmpty else { return [] }
    var skip = excluded
    skip += ListEditing.codePattern.matches(in: text, range: all).map(\.range)
    skip += linkTarget.matches(in: text, range: all).map(\.range)
    skip += bareURL.matches(in: text, range: all).map(\.range)
    var ranges: [NSRange] = []
    for match in matches {
      let range = match.range
      guard startsWord(ns, at: range.location) else { continue }
      var end = NSMaxRange(range)
      while end < ns.length, closers.contains(ns.character(at: end)) { end += 1 }
      // A link's text ends at "](", where its (hidden) address starts.
      let linkText = end < ns.length && ns.character(at: end) == 0x28 && ns.character(at: end - 1) == 0x5D
      guard end == ns.length || isWhitespace(ns.character(at: end)) || linkText else { continue }
      if timeAfter.firstMatch(in: text, options: .anchored, range: NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))) != nil {
        continue
      }
      let number = { (group: Int) in Int(ns.substring(with: match.range(at: group))) ?? 0 }
      guard isValid(year: number(1), month: number(2), day: number(3)) else { continue }
      guard !skip.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
      ranges.append(range)
    }
    return ranges
  }
}
