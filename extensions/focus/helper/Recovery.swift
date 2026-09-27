// Adopt-or-create for log events (PLAN.md "Log event", steps 3 and 4).
// Pure over the LogCalendarStore protocol so the tests drive it with a fake.
//
// For a finished session with no log_event_id:
//   calendar missing            -> keep waiting (it may come back; never re-point)
//   marker found in its span    -> adopt that event (saved before, id never stored)
//   search failed               -> keep waiting (creating now could duplicate)
//   calendar read-only          -> keep waiting
//   otherwise                   -> create the event; a failed save keeps waiting

import Foundation

enum CalendarWriteState: Equatable {
  case writable
  case readOnly
  case missing
}

struct LogEventDraft: Equatable {
  var title: String
  var start: Date
  var end: Date
  var notes: String
}

protocol LogCalendarStore: AnyObject {
  func writeState(of calendarId: String) -> CalendarWriteState
  /// The identifier of an event in `calendarId` overlapping `span` whose notes
  /// carry `marker` on a line of its own, or nil.
  func findEvent(marker: String, in calendarId: String, span: DateInterval) throws -> String?
  /// Saves the event and returns its identifier.
  func createEvent(_ draft: LogEventDraft, in calendarId: String) throws -> String
}

struct WaitingSession: Equatable {
  var sessionId: Int64
  var logCalendarId: String?
  var draft: LogEventDraft
}

enum RecoveryOutcome: Equatable {
  case adopted(String)
  case created(String)
  case waiting(String)  // why, for the log and `pending`
}

struct RecoveryCounts: Equatable {
  var written = 0
  var adopted = 0
  var stillWaiting = 0
}

enum Recovery {
  /// The search looks a day either side of the session, in case the event
  /// was nudged in Calendar.app; the marker keeps the match exact.
  static let searchMargin: TimeInterval = 86_400

  static func searchSpan(for draft: LogEventDraft) -> DateInterval {
    let end = max(draft.end, draft.start)
    return DateInterval(
      start: draft.start.addingTimeInterval(-searchMargin), end: end.addingTimeInterval(searchMargin))
  }

  static func resolve(_ session: WaitingSession, store: LogCalendarStore) -> RecoveryOutcome {
    guard let calendarId = session.logCalendarId else {
      return .waiting("no log calendar was chosen when the session finished")
    }
    let state = store.writeState(of: calendarId)
    if state == .missing { return .waiting("log calendar \(calendarId) is not in Calendar.app") }

    let marker = LogText.marker(session.sessionId)
    do {
      if let found = try store.findEvent(marker: marker, in: calendarId, span: searchSpan(for: session.draft)) {
        return .adopted(found)
      }
    } catch {
      return .waiting("searching the log calendar failed: \(error.localizedDescription)")
    }

    guard state == .writable else { return .waiting("log calendar \(calendarId) is read-only") }
    do {
      return .created(try store.createEvent(session.draft, in: calendarId))
    } catch {
      return .waiting("writing the log event failed: \(error.localizedDescription)")
    }
  }

  static func tally(_ outcomes: [RecoveryOutcome]) -> RecoveryCounts {
    var counts = RecoveryCounts()
    for outcome in outcomes {
      switch outcome {
      case .adopted: counts.adopted += 1
      case .created: counts.written += 1
      case .waiting: counts.stillWaiting += 1
      }
    }
    return counts
  }
}
