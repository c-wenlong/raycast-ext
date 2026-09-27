// The description of the log event written at Finish. Pure, so the exact
// text is tested. The last line, "focus-session: <id>", is the marker the
// recovery loop searches for; every other field is squashed onto one line so
// nothing (a note, a calendar title) can forge a second marker line.

import Foundation

struct PauseSpan: Equatable {
  var start: Date
  var end: Date?  // nil while still paused
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

    if summary.pauses.isEmpty {
      lines.append("Pauses: none")
    } else {
      let paused = pausedSeconds(summary.pauses, start: summary.startedAt, end: summary.endedAt)
      lines.append("Pauses: \(summary.pauses.count), \(minutes(paused)) in total")
    }

    lines.append("Blocked attempts: \(attemptsText(summary.attempts))")
    lines.append("Rating: \(summary.rating.map(stars) ?? "none")")
    if let note = summary.note.map(oneLine), !note.isEmpty {
      lines.append("Note: \(note)")
    }

    var ended = summary.endReason == "timer" ? "Ended: when the timer ran out" : "Ended: manually"
    if summary.extendedSeconds > 0 {
      ended += ", after extending \(minutes(summary.extendedSeconds))"
    }
    lines.append(ended)

    lines.append("")
    lines.append(marker(summary.sessionId))
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
