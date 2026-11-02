// Adopt-or-create for log events (PLAN.md "Log event", steps 3 and 4).
// Pure over the LogCalendarStore protocol so the tests drive it with a fake.
//
// For a finished session with no log_event_id:
//   calendar missing            -> keep waiting (it may come back; never re-point)
//   its event already there     -> adopt it (saved before, id never stored); found
//                                  by the session id and start time in its notes, so
//                                  neither a recreated focus.db reusing an id nor the user
//                                  moving the event in Calendar.app can fool it
//   search failed               -> keep waiting (creating now could duplicate)
//   calendar read-only          -> keep waiting (only movePending gets it written)
//   otherwise                   -> create the event; a failed save keeps waiting
//
// A row with no destination at all (finished before 2026-09-28 with no log
// calendar set) is given one by FocusCore before it gets here.

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

/// An event already in a log calendar, as the recovery search sees it.
struct LoggedEvent: Equatable {
  var id: String
  var start: Date
  var end: Date
  var notes: String?
}

protocol LogCalendarStore: AnyObject {
  func writeState(of calendarId: String) -> CalendarWriteState
  /// Events in `calendarId` overlapping `span`.
  func loggedEvents(in calendarId: String, span: DateInterval) throws -> [LoggedEvent]
  /// Saves the event and returns its identifier.
  func createEvent(_ draft: LogEventDraft, in calendarId: String) throws -> String
}

struct WaitingSession: Equatable {
  var sessionId: Int64
  var logCalendarId: String?
  var draft: LogEventDraft
  /// The destination's stored "<title> (<account>)", for the waiting reason.
  var logCalendarName: String? = nil

  /// How the waiting reasons name the destination.
  var calendarLabel: String {
    if let name = logCalendarName, !name.isEmpty { return name }
    return logCalendarId ?? "?"
  }
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
  /// The search looks a week either side of the session, so an event the user
  /// moved in Calendar.app before its id was stored is still found. The
  /// notes, not the times, decide the match.
  static let searchMargin: TimeInterval = 7 * 86_400

  static func searchSpan(for draft: LogEventDraft) -> DateInterval {
    let end = max(draft.end, draft.start)
    return DateInterval(
      start: draft.start.addingTimeInterval(-searchMargin), end: end.addingTimeInterval(searchMargin))
  }

  /// The event this session already wrote: its notes carry the session id and
  /// the session's start time (`draft.start` is the real start).
  static func match(_ events: [LoggedEvent], sessionId: Int64, draft: LogEventDraft) -> LoggedEvent? {
    events.first { LogText.notes($0.notes, identify: sessionId, startedAt: draft.start) }
  }

  static func resolve(_ session: WaitingSession, store: LogCalendarStore) -> RecoveryOutcome {
    guard let calendarId = session.logCalendarId else {
      return .waiting(Recovery.noDestination)
    }
    let state = store.writeState(of: calendarId)
    if state == .missing { return .waiting(Recovery.missing(session.calendarLabel)) }

    do {
      let events = try store.loggedEvents(in: calendarId, span: searchSpan(for: session.draft))
      if let found = match(events, sessionId: session.sessionId, draft: session.draft) {
        return .adopted(found.id)
      }
    } catch {
      return .waiting("searching the log calendar failed: \(error.localizedDescription)")
    }

    guard state == .writable else { return .waiting(Recovery.readOnly(session.calendarLabel)) }
    do {
      return .created(try store.createEvent(session.draft, in: calendarId))
    } catch {
      return .waiting("writing the log event failed: \(error.localizedDescription)")
    }
  }

  // The waiting reasons `pending` shows as they are.

  /// A row with no destination: no override and no calendar id to log to.
  static let noDestination = "the session has no calendar to log to; move the waiting sessions to a calendar"

  static func missing(_ label: String) -> String { "calendar \(label) is not in Calendar.app" }

  /// A subscribed (or otherwise read-only) calendar never takes the event;
  /// only `movePending` gets such a row written.
  static func readOnly(_ label: String) -> String {
    "calendar \(label) is read-only, so it cannot take the log event; move the waiting sessions to a writable calendar"
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
