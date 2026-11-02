// The description of the log event written at Finish. Pure, so the exact
// text is tested. The last two lines, "focus-session: <id>" (PLAN.md's
// marker) and "focus-started: <UTC start>", identify the session for the
// recovery loop: the id alone repeats if focus.db is recreated, the start
// time tells those sessions apart, and neither changes when the user moves the
// event. Every other field is squashed onto one line so nothing (a note, a
// calendar title) can forge a marker line.

import Foundation

struct PauseSpan: Equatable {
  var start: Date
  var end: Date?  // nil while still paused
  /// "pause" (a real pause), "break" (the task resting between focus
  /// blocks) or "decision" (the wait at the end card of a continued task).
  /// All three count as non-focus time; only "pause" moves an ad-hoc
  /// session's deadline.
  var kind: String = "pause"
}

struct BlockedAttempt: Equatable {
  var at: Date
  var kind: String  // app, site
  var target: String  // bundle id or host
  var outcome: String  // blocked, snoozed
}

struct LogSummary: Equatable {
  var sessionId: Int64
  var sourceCalendarId: String
  var sourceCalendarTitle: String?
  var sourceEventId: String?  // nil for ad hoc
  var startedAt: Date
  var endedAt: Date
  var endReason: String
  var extendedSeconds: Int = 0
  var pauses: [PauseSpan] = []
  var attempts: [BlockedAttempt] = []
  var rating: Int?
  var note: String?
}

enum LogText {
  static func marker(_ sessionId: Int64) -> String { "focus-session: \(sessionId)" }

  static func startedLine(_ startedAt: Date) -> String { "focus-started: \(ISO.utc(startedAt))" }

  /// True when `notes` carry both identity lines of this session.
  static func notes(_ notes: String?, identify sessionId: Int64, startedAt: Date) -> Bool {
    self.notes(notes, containMarker: marker(sessionId)) && self.notes(notes, containMarker: startedLine(startedAt))
  }

  /// ★ for each point, ☆ for the rest: 4 → "★★★★☆".
  static func stars(_ rating: Int) -> String {
    let filled = min(5, max(0, rating))
    return String(repeating: "★", count: filled) + String(repeating: "☆", count: 5 - filled)
  }

  /// Seconds paused inside [start, end]; an open pause runs to `end`.
  static func pausedSeconds(_ pauses: [PauseSpan], start: Date, end: Date) -> Int {
    let total = pauses.reduce(0.0) { sum, pause in
      let from = max(pause.start, start)
      let to = min(pause.end ?? end, end)
      return sum + max(0, to.timeIntervalSince(from))
    }
    return Int(total.rounded())
  }

  /// The focused intervals `start`...`end` has left once every pause-like
  /// span (pause, break, decision) is clipped out: the source of the
  /// "Focus block:" timestamp lines in the event notes.
  static func focusSpans(_ pauses: [PauseSpan], start: Date, end: Date) -> [DateInterval] {
    guard end > start else { return [] }
    let excluded = pauses.compactMap { pause -> DateInterval? in
      let lo = max(start, pause.start)
      let hi = min(end, pause.end ?? end)
      return hi > lo ? DateInterval(start: lo, end: hi) : nil
    }.sorted { $0.start < $1.start }
    var cursor = start
    var focused: [DateInterval] = []
    for span in excluded {
      if span.start > cursor { focused.append(DateInterval(start: cursor, end: span.start)) }
      cursor = max(cursor, span.end)
    }
    if cursor < end { focused.append(DateInterval(start: cursor, end: end)) }
    return focused
  }

  /// Focused time = (end - start) - pauses, never negative.
  static func focusedSeconds(_ summary: LogSummary) -> Int {
    let span = Int(summary.endedAt.timeIntervalSince(summary.startedAt).rounded())
    return max(0, span - pausedSeconds(summary.pauses, start: summary.startedAt, end: summary.endedAt))
  }

  /// "0 min", "47 min", "1 h", "1 h 5 min"; rounded to the nearest minute.
  static func minutes(_ seconds: Int) -> String {
    let total = Int((Double(max(0, seconds)) / 60).rounded())
    let hours = total / 60
    let rest = total % 60
    if hours == 0 { return "\(rest) min" }
    return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
  }

  /// Newlines (and runs of whitespace) become single spaces.
  static func oneLine(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
  }

  static func description(_ summary: LogSummary) -> String {
    var lines: [String] = []
    let calendar = oneLine(summary.sourceCalendarTitle ?? summary.sourceCalendarId)
    if let eventId = summary.sourceEventId {
      lines.append("Source: \(calendar), event \(oneLine(eventId))")
    } else {
      lines.append("Source: ad hoc, filed under \(calendar)")
    }

    let span = Int(summary.endedAt.timeIntervalSince(summary.startedAt).rounded())
    lines.append("Focused: \(minutes(focusedSeconds(summary))) of \(minutes(span))")

    // "pause" rows are real pauses; "break" rows are the task resting
    // between focus blocks and "decision" rows the waits at its end cards.
    // All are clipped once into the total that the Focused line subtracts;
    // the breakdown names each kind separately so a break is never counted
    // twice (also as a pause).
    let realPauses = summary.pauses.filter { $0.kind == "pause" }
    let breaks = summary.pauses.filter { $0.kind == "break" }
    let decisions = summary.pauses.filter { $0.kind == "decision" }
    func seconds(_ spans: [PauseSpan]) -> Int {
      pausedSeconds(spans, start: summary.startedAt, end: summary.endedAt)
    }
    if breaks.isEmpty && decisions.isEmpty {
      if summary.pauses.isEmpty {
        lines.append("Pauses: none")
      } else {
        lines.append("Pauses: \(summary.pauses.count), \(minutes(seconds(summary.pauses))) in total")
      }
    } else {
      if realPauses.isEmpty {
        lines.append("Pauses: none")
      } else {
        lines.append("Pauses: \(realPauses.count), \(minutes(seconds(realPauses))) in total")
      }
      // A continued task's event also names each focus block by its real
      // clock times, between the Focused total and the Breaks breakdown.
      if !breaks.isEmpty {
        for span in focusSpans(summary.pauses, start: summary.startedAt, end: summary.endedAt) {
          lines.append(
            "Focus block: \(ISO.local(span.start)) to \(ISO.local(span.end)) (\(minutes(Int(span.duration.rounded()))))")
        }
        lines.append("Breaks: \(breaks.count), \(minutes(seconds(breaks))) in total")
        for span in breaks {
          let end = span.end ?? summary.endedAt
          let length = Int(end.timeIntervalSince(span.start).rounded())
          lines.append("Break: \(ISO.local(span.start)) to \(ISO.local(end)) (\(minutes(length)))")
        }
      }
      if !decisions.isEmpty {
        lines.append("Waiting between blocks: \(minutes(seconds(decisions)))")
      }
    }

    lines.append("Blocked attempts: \(attemptsText(summary.attempts))")
    lines.append(ratingLine(summary.rating))
    if let line = noteLine(summary.note) { lines.append(line) }

    var ended = summary.endReason == "timer" ? "Ended: when the timer ran out" : "Ended: manually"
    if summary.extendedSeconds > 0 {
      ended += ", after extending \(minutes(summary.extendedSeconds))"
    }
    lines.append(ended)

    lines.append("")
    lines.append(marker(summary.sessionId))
    lines.append(startedLine(summary.startedAt))
    return lines.joined(separator: "\n")
  }

  static func ratingLine(_ rating: Int?) -> String { "Rating: \(rating.map(stars) ?? "none")" }

  /// "Note: <one line>", or nil for no note (the line is left out).
  static func noteLine(_ note: String?) -> String? {
    guard let text = note.map(oneLine), !text.isEmpty else { return nil }
    return "Note: \(text)"
  }

  /// Edit Session: `notes` with only the review changed, in the block Focus
  /// wrote. That block is found by its shape, as `description` writes it:
  /// a "Blocked attempts: " line, then "Rating: " with "none" or five stars,
  /// then optionally one "Note: " line, then an "Ended: " line, all above the
  /// marker lines (the last such run there, the one next to the markers).
  /// Its Rating line is replaced and its Note line replaced, added or
  /// dropped; every other line, including a "Rating:" or "Note:" line the user
  /// added in Calendar, stays as it is. Nil when no such block is left.
  static func replacingReview(in notes: String, rating: Int?, note: String?) -> String? {
    var lines = notes.components(separatedBy: "\n")
    let bare = { (index: Int) -> String in
      let line = lines[index]
      return line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
    let end =
      lines.firstIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("focus-session: ") }
      ?? lines.count
    let generated = Set(["none"] + (1...5).map(stars))
    let isRating = { (index: Int) -> Bool in
      let line = bare(index)
      return line.hasPrefix("Rating: ") && generated.contains(String(line.dropFirst("Rating: ".count)))
    }
    // The review block: attempts, rating, maybe a note, then how it ended.
    let block = { (index: Int) -> (rating: Int, hasNote: Bool)? in
      guard index >= 1, bare(index - 1).hasPrefix("Blocked attempts: "), isRating(index) else { return nil }
      if index + 1 < end, bare(index + 1).hasPrefix("Ended: ") { return (index, false) }
      if index + 2 < end, bare(index + 1).hasPrefix("Note: "), bare(index + 2).hasPrefix("Ended: ") {
        return (index, true)
      }
      return nil
    }
    guard let found = (0..<end).reversed().lazy.compactMap(block).first else { return nil }
    let index = found.rating
    let ending = lines[index].hasSuffix("\r") ? "\r" : ""
    lines[index] = ratingLine(rating) + ending
    switch (found.hasNote, noteLine(note)) {
    case (true, let line?): lines[index + 1] = line + ending
    case (true, nil): lines.remove(at: index + 1)
    case (false, let line?): lines.insert(line + ending, at: index + 1)
    case (false, nil): break
    }
    return lines.joined(separator: "\n")
  }

  /// "none", or "4 (youtube.com 3, x.com 1), 1 snoozed": counts per target,
  /// most frequent first, at most five named.
  static func attemptsText(_ attempts: [BlockedAttempt]) -> String {
    guard !attempts.isEmpty else { return "none" }
    var counts: [String: Int] = [:]
    for attempt in attempts { counts[oneLine(attempt.target), default: 0] += 1 }
    let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    var named = ranked.prefix(5).map { "\($0.key) \($0.value)" }
    if ranked.count > 5 { named.append("\(ranked.count - 5) more") }
    var text = "\(attempts.count) (\(named.joined(separator: ", ")))"
    let snoozed = attempts.filter { $0.outcome == "snoozed" }.count
    if snoozed > 0 { text += ", \(snoozed) snoozed" }
    return text
  }

  /// True when a line of `notes` is exactly the marker. Tolerates CRLF and
  /// <br> line breaks in case a calendar server rewrote the description.
  static func notes(_ notes: String?, containMarker marker: String) -> Bool {
    guard let notes, notes.contains(marker) else { return false }
    let normalized = notes.replacingOccurrences(
      of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
    return normalized.components(separatedBy: .newlines).contains {
      $0.trimmingCharacters(in: .whitespaces) == marker
    }
  }
}
