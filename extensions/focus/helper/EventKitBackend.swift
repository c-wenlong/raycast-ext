// CalendarBackend over EventKit. Every method runs on the daemon's serial
// work queue; the permission callback hops back onto it.

import CoreGraphics
import EventKit
import Foundation

final class EventKitBackend: CalendarBackend {
  private var store = EKEventStore()
  private let queue: DispatchQueue
  private let log: (String) -> Void
  private var requesting = false
  private var lastState = EKEventStore.authorizationStatus(for: .event)
  /// Called on the work queue once access is granted (recovery runs then).
  var onAccessGranted: (() -> Void)?

  init(queue: DispatchQueue, log: @escaping (String) -> Void) {
    self.queue = queue
    self.log = log
  }

  var accessState: String {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }

  func requestAccessIfNeeded() {
    guard EKEventStore.authorizationStatus(for: .event) == .notDetermined, !requesting else { return }
    requesting = true
    log("asking for full calendar access")
    store.requestFullAccessToEvents { [weak self] granted, error in
      guard let self else { return }
      self.queue.async {
        self.requesting = false
        if let error { self.log("calendar access request failed: \(error.localizedDescription)") }
        self.log("calendar access is \(self.accessState)")
        self.lastState = EKEventStore.authorizationStatus(for: .event)
        guard granted else { return }
        // A store made before the grant can keep serving an empty cache.
        self.store = EKEventStore()
        self.onAccessGranted?()
      }
    }
  }

  func refreshAccess() -> Bool {
    let state = EKEventStore.authorizationStatus(for: .event)
    defer { lastState = state }
    guard state != lastState, state == .fullAccess, !requesting else { return false }
    log("calendar access is now fullAccess")
    store = EKEventStore()
    return true
  }

  func calendars() -> [CalendarInfo] {
    store.calendars(for: .event).map(info)
  }

  func calendar(id: String) -> CalendarInfo? {
    store.calendar(withIdentifier: id).map(info)
  }

  private func info(_ calendar: EKCalendar) -> CalendarInfo {
    CalendarInfo(
      id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "",
      color: hex(calendar.cgColor), writable: calendar.allowsContentModifications)
  }

  private func hex(_ color: CGColor?) -> String? {
    guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
      let parts = converted.components, parts.count >= 3
    else { return nil }
    let byte = { (value: CGFloat) in Int((min(1, max(0, value)) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(parts[0]), byte(parts[1]), byte(parts[2]))
  }

  func events(from start: Date, to end: Date, calendarIds: [String]?) -> [CalendarEvent] {
    var calendars: [EKCalendar]?
    if let calendarIds {
      calendars = calendarIds.compactMap { store.calendar(withIdentifier: $0) }
      // An empty list would mean "every calendar" to EventKit.
      if calendars?.isEmpty == true { return [] }
    }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    return store.events(matching: predicate).compactMap { event in
      guard let id = event.eventIdentifier, let calendar = event.calendar,
        let startDate = event.startDate, let endDate = event.endDate
      else { return nil }
      return CalendarEvent(
        id: id, title: event.title ?? "", calendarId: calendar.calendarIdentifier, calendarTitle: calendar.title,
        start: startDate, end: endDate, isAllDay: event.isAllDay)
    }
  }

  // MARK: LogCalendarStore

  func writeState(of calendarId: String) -> CalendarWriteState {
    guard let calendar = store.calendar(withIdentifier: calendarId) else { return .missing }
    return calendar.allowsContentModifications ? .writable : .readOnly
  }

  func loggedEvents(in calendarId: String, span: DateInterval) throws -> [LoggedEvent] {
    guard let calendar = store.calendar(withIdentifier: calendarId) else {
      throw FocusError("calendar \(calendarId) disappeared")
    }
    let predicate = store.predicateForEvents(withStart: span.start, end: span.end, calendars: [calendar])
    return store.events(matching: predicate).compactMap { event in
      guard let id = event.eventIdentifier, let start = event.startDate, let end = event.endDate else { return nil }
      return LoggedEvent(id: id, start: start, end: end, notes: event.notes)
    }
  }

  func createEvent(_ draft: LogEventDraft, in calendarId: String) throws -> String {
    guard let calendar = store.calendar(withIdentifier: calendarId) else {
      throw FocusError("calendar \(calendarId) disappeared")
    }
    let event = EKEvent(eventStore: store)
    event.calendar = calendar
    event.title = draft.title
    event.startDate = draft.start
    event.endDate = draft.end
    event.notes = draft.notes
    event.alarms = nil
    try store.save(event, span: .thisEvent, commit: true)
    guard let id = event.eventIdentifier else { throw FocusError("the saved event has no identifier") }
    return id
  }

  func loggedEvent(id: String) -> LoggedEvent? {
    guard let event = store.event(withIdentifier: id), let start = event.startDate, let end = event.endDate else {
      return nil
    }
    return LoggedEvent(id: id, start: start, end: end, notes: event.notes)
  }

  func removeEvent(id: String) throws {
    guard let event = store.event(withIdentifier: id) else { throw FocusError("event \(id) disappeared") }
    try store.remove(event, span: .thisEvent, commit: true)
  }

  // MARK: Debug commands (FOCUS_DEBUG=1 only)

  /// Test fixtures for the live integration check. Anything destructive is
  /// limited to calendars or events whose title starts with "Focus test".
  func debug(_ request: Request) throws -> Reply? {
    let fixturePrefix = "Focus test"
    switch request.cmd {
    case "debugSources":
      return .ok([
        "sources": .array(
          store.sources.map { ["title": .string($0.title), "type": .int($0.sourceType.rawValue)] })
      ])
    case "debugCreateCalendar":
      let title = try request.requiredString("title")
      guard title.hasPrefix(fixturePrefix) else { throw FocusError("title must start with \(fixturePrefix)") }
      let wanted = try request.string("sourceTitle")
      let source =
        wanted.flatMap { name in store.sources.first { $0.title == name } }
        ?? store.sources.first { $0.sourceType == .local }
      guard let source else { throw FocusError("no local calendar source; pass sourceTitle") }
      let calendar = EKCalendar(for: .event, eventStore: store)
      calendar.title = title
      calendar.source = source
      try store.saveCalendar(calendar, commit: true)
      return .ok(["calendarId": .string(calendar.calendarIdentifier), "source": .string(source.title)])
    case "debugDeleteCalendar":
      let id = try request.requiredString("calendarId")
      guard let calendar = store.calendar(withIdentifier: id) else { throw FocusError("no such calendar") }
      guard calendar.title.hasPrefix(fixturePrefix) else { throw FocusError("not a test calendar") }
      try store.removeCalendar(calendar, commit: true)
      return .ok()
    case "debugCreateEvent":
      let id = try request.requiredString("calendarId")
      let title = try request.requiredString("title")
      guard title.hasPrefix(fixturePrefix) else { throw FocusError("title must start with \(fixturePrefix)") }
      guard let start = try request.string("start").flatMap(ISO.parse),
        let end = try request.string("end").flatMap(ISO.parse)
      else { throw FocusError("start and end must be ISO 8601 dates") }
      guard let calendar = store.calendar(withIdentifier: id) else { throw FocusError("no such calendar") }
      let event = EKEvent(eventStore: store)
      event.calendar = calendar
      event.title = title
      event.startDate = start
      event.endDate = end
      try store.save(event, span: .thisEvent, commit: true)
      return .ok(["eventId": .optional(event.eventIdentifier)])
    case "debugEvents":
      let id = try request.requiredString("calendarId")
      guard let calendar = store.calendar(withIdentifier: id) else { throw FocusError("no such calendar") }
      let day = Rules.day(containing: Date())
      let predicate = store.predicateForEvents(
        withStart: day.start.addingTimeInterval(-86_400), end: day.end.addingTimeInterval(86_400),
        calendars: [calendar])
      return .ok([
        "events": .array(
          store.events(matching: predicate).map {
            [
              "id": .optional($0.eventIdentifier), "title": .optional($0.title),
              "start": .string(ISO.local($0.startDate)), "end": .string(ISO.local($0.endDate)),
              "notes": .optional($0.notes), "alarms": .int($0.alarms?.count ?? 0),
            ]
          })
      ])
    case "debugDeleteEvent":
      let id = try request.requiredString("eventId")
      guard let event = store.event(withIdentifier: id) else { throw FocusError("no such event") }
      guard (event.title ?? "").hasPrefix(fixturePrefix) || (event.calendar?.title ?? "").hasPrefix(fixturePrefix)
      else { throw FocusError("not a test event") }
      try store.remove(event, span: .thisEvent, commit: true)
      return .ok()
    default:
      return nil
    }
  }
}
