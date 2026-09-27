// Which events can be started and how long a session runs. Pure: the
// EventKit layer maps EKEvents into CalendarEvent and asks these rules.

import Foundation

/// One occurrence of a calendar event. `id` is EventKit's eventIdentifier,
/// which every occurrence of a recurring event shares; `start` tells them apart.
struct CalendarEvent: Equatable {
  var id: String
  var title: String
  var calendarId: String
  var calendarTitle: String
  var start: Date
  var end: Date
  var isAllDay: Bool
}

enum Rules {
  /// An event is startable only while more than this much of it is left.
  static let minimumRemaining: TimeInterval = 60
  /// Ad-hoc sessions run between one minute and one day.
  static let adhocSeconds: ClosedRange<Double> = 60...86_400

  /// Local midnight to the next local midnight around `now`.
  static func day(containing now: Date, calendar: Calendar = .current) -> DateInterval {
    let start = calendar.startOfDay(for: now)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return DateInterval(start: start, end: end)
  }

  /// Why this occurrence cannot be started now, or nil if it can.
  static func refusal(for event: CalendarEvent, now: Date) -> String? {
    let name = event.title.isEmpty ? "The event" : "\"\(event.title)\""
    if event.isAllDay { return "\(name) is an all-day event; start an ad-hoc session instead" }
    let left = event.end.timeIntervalSince(now)
    if left <= 0 { return "\(name) has already ended; start an ad-hoc session instead" }
    if left <= minimumRemaining { return "\(name) has under a minute left" }
    return nil
  }

  static func isStartable(_ event: CalendarEvent, now: Date) -> Bool {
    refusal(for: event, now: now) == nil
  }

  /// Focus Today: startable events from the chosen calendars, overlapping ones
  /// included, ordered by start (then end, title, id for a stable list).
  static func startable(_ events: [CalendarEvent], calendarIds: Set<String>, now: Date) -> [CalendarEvent] {
    events
      .filter { calendarIds.contains($0.calendarId) && isStartable($0, now: now) }
      .sorted {
        ($0.start, $0.end, $0.title, $0.id) < ($1.start, $1.end, $1.title, $1.id)
      }
  }

  static func remainingSeconds(until end: Date, now: Date) -> Int {
    max(0, Int(end.timeIntervalSince(now).rounded(.down)))
  }

  /// A session from an event runs until the event's planned end, whenever it
  /// is started: 14:10 on a 14:00 to 15:00 event gives 50 minutes.
  static func sessionEnd(for event: CalendarEvent) -> Date { event.end }

  static func sessionSeconds(for event: CalendarEvent, now: Date) -> Int {
    remainingSeconds(until: sessionEnd(for: event), now: now)
  }

  /// Ad hoc: planned start is now, planned end is now plus the length.
  static func adhocPlan(now: Date, durationSeconds: Double) -> Result<DateInterval, FocusError> {
    guard durationSeconds.isFinite, adhocSeconds.contains(durationSeconds) else {
      return .failure(FocusError("durationSeconds must be between 60 and 86400"))
    }
    return .success(DateInterval(start: now, duration: durationSeconds.rounded(.down)))
  }

  /// Picks the occurrence `start {eventId}` means among today's events. With
  /// `requestedStart` (the `start` value `today` returned) it must match that
  /// occurrence; without, the earliest startable one wins, which for a
  /// recurring event is the current or next occurrence.
  static func pickOccurrence(
    _ events: [CalendarEvent], eventId: String, requestedStart: Date?, now: Date
  ) -> Result<CalendarEvent, FocusError> {
    var matches = events.filter { $0.id == eventId }
    if let requestedStart {
      matches = matches.filter { abs($0.start.timeIntervalSince(requestedStart)) < 1 }
    }
    guard !matches.isEmpty else {
      return .failure(FocusError("event \(eventId) is not on today's calendar"))
    }
    if let pick = matches.filter({ isStartable($0, now: now) }).min(by: { $0.start < $1.start }) {
      return .success(pick)
    }
    let latest = matches.max(by: { $0.end < $1.end })!
    return .failure(FocusError(refusal(for: latest, now: now) ?? "event cannot be started"))
  }
}
