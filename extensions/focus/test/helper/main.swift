// Command-line tests for the focus-daemon logic: rules, log text, recovery,
// config, protocol, sqlite, the session state machine, the Raycast deeplink,
// and the command handlers (sessions, timer, UI callbacks, launch recovery)
// over a fake calendar.
// Run with scripts/test-helper.sh (npm run test-helper).

import Foundation

var failures = 0
var count = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
  count += 1
  if condition() {
    print("ok   \(name)")
  } else {
    failures += 1
    print("FAIL \(name) \(detail())")
  }
}

let local = Calendar.current

func at(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 28) -> Date {
  local.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute, second: second))!
}

func event(
  _ id: String, _ title: String, _ start: Date, _ end: Date, calendar: String = "work", allDay: Bool = false
) -> CalendarEvent {
  CalendarEvent(
    id: id, title: title, calendarId: calendar, calendarTitle: calendar.capitalized, start: start, end: end,
    isAllDay: allDay)
}

func tempDir() -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("focus-tests-\(UUID().uuidString)").path
  try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

struct Boom: Error, LocalizedError {
  var errorDescription: String? { "boom" }
}

/// An in-memory calendar: CalendarInfo list, events, and saved log events.
final class FakeCalendar: CalendarBackend {
  var accessState = "fullAccess"
  var requests = 0
  var infos: [CalendarInfo] = [
    CalendarInfo(id: "work", title: "Work", account: "Google", color: "#FF0000", writable: true),
    CalendarInfo(id: "log", title: "Focus Log", account: "iCloud", color: nil, writable: true),
    CalendarInfo(id: "holidays", title: "Holidays", account: "Subscribed", color: nil, writable: false),
  ]
  var eventList: [CalendarEvent] = []
  var saved: [(calendarId: String, id: String, draft: LogEventDraft)] = []
  var failSearch = false
  var failCreate = false
  var searches: [DateInterval] = []
  var creates = 0

  var grantedOutside = false
  func requestAccessIfNeeded() { requests += 1 }
  func refreshAccess() -> Bool {
    defer { grantedOutside = false }
    return grantedOutside
  }
  func calendars() -> [CalendarInfo] { infos }
  func calendar(id: String) -> CalendarInfo? { infos.first { $0.id == id } }

  func events(from start: Date, to end: Date, calendarIds: [String]?) -> [CalendarEvent] {
    eventList.filter { $0.end > start && $0.start < end && (calendarIds?.contains($0.calendarId) ?? true) }
  }

  func writeState(of calendarId: String) -> CalendarWriteState {
    guard let info = calendar(id: calendarId) else { return .missing }
    return info.writable ? .writable : .readOnly
  }

  func loggedEvents(in calendarId: String, span: DateInterval) throws -> [LoggedEvent] {
    searches.append(span)
    if failSearch { throw Boom() }
    return saved.filter { $0.calendarId == calendarId && $0.draft.end >= span.start && $0.draft.start <= span.end }
      .map { LoggedEvent(id: $0.id, start: $0.draft.start, end: $0.draft.end, notes: $0.draft.notes) }
  }

  func createEvent(_ draft: LogEventDraft, in calendarId: String) throws -> String {
    creates += 1
    if failCreate { throw Boom() }
    let id = "log-\(saved.count + 1)"
    saved.append((calendarId, id, draft))
    return id
  }
}

// MARK: - Rules: startable filter, the 60 s edge, all-day, duration

do {
  let now = at(14, 10)
  let day = Rules.day(containing: now)
  check("day starts at local midnight", day.start == at(0, 0))
  check("day ends at the next midnight", day.end == at(0, 0, day: 29))

  let past = event("a", "Standup", at(9, 0), at(9, 30))
  let endsNow = event("b", "Ends now", at(13, 0), now)
  let sixty = event("c", "Sixty left", at(13, 0), now.addingTimeInterval(60))
  let sixtyOne = event("d", "Sixty-one left", at(13, 0), now.addingTimeInterval(61))
  let allDay = event("e", "Offsite", at(0, 0), at(0, 0, day: 29), allDay: true)
  let later = event("f", "Deep work", at(16, 0), at(17, 0))
  let otherCalendar = event("g", "Gym", at(15, 0), at(16, 0), calendar: "personal")

  check("an ended event is refused", Rules.refusal(for: past, now: now)?.contains("already ended") == true)
  check("an event ending right now is refused", !Rules.isStartable(endsNow, now: now))
  check("exactly 60 s left is refused", Rules.refusal(for: sixty, now: now)?.contains("under a minute") == true)
  check("61 s left is startable", Rules.isStartable(sixtyOne, now: now))
  check("all-day events are refused", Rules.refusal(for: allDay, now: now)?.contains("all-day") == true)
  check("a later event is startable", Rules.isStartable(later, now: now))

  let listed = Rules.startable(
    [later, past, allDay, sixty, sixtyOne, otherCalendar, endsNow], calendarIds: ["work"], now: now)
  check("today lists startable events from chosen calendars only", listed.map(\.id) == ["d", "f"], "\(listed.map(\.id))")

  let overlapA = event("x", "Overlap A", at(14, 0), at(15, 0))
  let overlapB = event("y", "Overlap B", at(14, 0), at(14, 45))
  let overlapC = event("z", "Overlap C", at(13, 30), at(16, 0))
  let sorted = Rules.startable([overlapA, overlapB, overlapC], calendarIds: ["work"], now: now)
  check("overlapping events are all listed, by start then end", sorted.map(\.id) == ["z", "y", "x"], "\(sorted.map(\.id))")

  let hour = event("h", "Planning", at(14, 0), at(15, 0))
  check("session runs until the planned end", Rules.sessionEnd(for: hour) == at(15, 0))
  check("starting 14:10 on 14:00-15:00 gives 50 minutes", Rules.sessionSeconds(for: hour, now: now) == 3000)
  check("remaining seconds round down", Rules.remainingSeconds(until: now.addingTimeInterval(90.9), now: now) == 90)
  check("remaining seconds never go negative", Rules.remainingSeconds(until: at(9, 0), now: now) == 0)
}

do {
  let now = at(14, 10)
  let plan = try? Rules.adhocPlan(now: now, durationSeconds: 1500).get()
  check("ad hoc starts now", plan?.start == now)
  check("ad hoc ends now plus the length", plan?.end == now.addingTimeInterval(1500))
  check("ad hoc length rounds down to whole seconds", (try? Rules.adhocPlan(now: now, durationSeconds: 90.7).get())?.duration == 90)
  for bad in [59.0, 86_401, -5, .nan, .infinity] {
    if case .success = Rules.adhocPlan(now: now, durationSeconds: bad) { check("ad hoc rejects \(bad)", false) }
    else { check("ad hoc rejects \(bad)", true) }
  }
  check("ad hoc accepts one minute", (try? Rules.adhocPlan(now: now, durationSeconds: 60).get()) != nil)
  check("ad hoc accepts one day", (try? Rules.adhocPlan(now: now, durationSeconds: 86_400).get()) != nil)
}

do {
  let now = at(10, 30)
  let morning = event("rec", "Hourly", at(9, 0), at(10, 0))
  let current = event("rec", "Hourly", at(10, 0), at(11, 0))
  let next = event("rec", "Hourly", at(11, 0), at(12, 0))
  let occurrences = [next, morning, current]
  let pick = try? Rules.pickOccurrence(occurrences, eventId: "rec", requestedStart: nil, now: now).get()
  check("a recurring event starts its current occurrence", pick?.start == at(10, 0))
  let chosen = try? Rules.pickOccurrence(occurrences, eventId: "rec", requestedStart: at(11, 0), now: now).get()
  check("start picks the occurrence the client named", chosen?.start == at(11, 0))
  if case .failure(let error) = Rules.pickOccurrence(occurrences, eventId: "rec", requestedStart: at(9, 0), now: now) {
    check("a named past occurrence is refused", error.message.contains("already ended"), error.message)
  } else {
    check("a named past occurrence is refused", false)
  }
  if case .failure(let error) = Rules.pickOccurrence(occurrences, eventId: "nope", requestedStart: nil, now: now) {
    check("an unknown id is not on today's calendar", error.message.contains("not on today's calendar"), error.message)
  } else {
    check("an unknown id is not on today's calendar", false)
  }
}

// MARK: - Log text

do {
  check("4 stars", LogText.stars(4) == "★★★★☆", LogText.stars(4))
  check("5 stars", LogText.stars(5) == "★★★★★")
  check("1 star", LogText.stars(1) == "★☆☆☆☆")
  check("stars clamp", LogText.stars(9) == "★★★★★" && LogText.stars(-1) == "☆☆☆☆☆")
  check("minutes", LogText.minutes(0) == "0 min" && LogText.minutes(2820) == "47 min", LogText.minutes(2820))
  check("minutes round to nearest", LogText.minutes(89) == "1 min" && LogText.minutes(91) == "2 min")
  check("hours", LogText.minutes(3600) == "1 h" && LogText.minutes(3900) == "1 h 5 min", LogText.minutes(3900))
  check("marker", LogText.marker(12) == "focus-session: 12")

  let start = at(14, 10)
  let end = at(14, 58)
  let pauses = [PauseSpan(start: at(14, 20), end: at(14, 25))]
  check("paused seconds", LogText.pausedSeconds(pauses, start: start, end: end) == 300)
  let open = [PauseSpan(start: at(14, 50), end: nil)]
  check("an open pause runs to the end", LogText.pausedSeconds(open, start: start, end: end) == 480)
  let outside = [PauseSpan(start: at(13, 0), end: at(14, 15))]
  check("pauses are clipped to the session", LogText.pausedSeconds(outside, start: start, end: end) == 300)

  let summary = LogSummary(
    sessionId: 12, sourceCalendarId: "work", sourceCalendarTitle: "Work", sourceEventId: "EV1", startedAt: start,
    endedAt: end, endReason: "manual", pauses: pauses,
    attempts: [
      BlockedAttempt(at: at(14, 30), kind: "site", target: "youtube.com", outcome: "blocked"),
      BlockedAttempt(at: at(14, 31), kind: "site", target: "x.com", outcome: "snoozed"),
      BlockedAttempt(at: at(14, 32), kind: "site", target: "youtube.com", outcome: "blocked"),
    ], rating: 4, note: "Shipped the draft")
  check("focused seconds exclude pauses", LogText.focusedSeconds(summary) == 43 * 60)
  let expected = """
    Source: Work, event EV1
    Focused: 43 min of 48 min
    Pauses: 1, 5 min in total
    Blocked attempts: 3 (youtube.com 2, x.com 1), 1 snoozed
    Rating: ★★★★☆
    Note: Shipped the draft
    Ended: manually

    focus-session: 12
    focus-started: \(ISO.utc(start))
    """
  let text = LogText.description(summary)
  check("event session description", text == expected, "\n\(text)")

  var adhoc = summary
  adhoc.sourceEventId = nil
  adhoc.pauses = []
  adhoc.attempts = []
  adhoc.rating = nil
  adhoc.note = "  "
  adhoc.endReason = "timer"
  adhoc.extendedSeconds = 600
  adhoc.sourceCalendarTitle = nil
  let adhocExpected = """
    Source: ad hoc, filed under work
    Focused: 48 min of 48 min
    Pauses: none
    Blocked attempts: none
    Rating: none
    Ended: when the timer ran out, after extending 10 min

    focus-session: 12
    focus-started: \(ISO.utc(start))
    """
  let adhocText = LogText.description(adhoc)
  check("ad hoc description, no rating, blank note dropped", adhocText == adhocExpected, "\n\(adhocText)")

  var forged = summary
  forged.note = "done\nfocus-session: 99"
  let forgedText = LogText.description(forged)
  check("a note cannot forge a marker line", !LogText.notes(forgedText, containMarker: "focus-session: 99"))
  check("the real marker is still found", LogText.notes(forgedText, containMarker: "focus-session: 12"))
  check("the note stays on one line", forgedText.contains("Note: done focus-session: 99"), forgedText)

  let many = (1...7).map { BlockedAttempt(at: start, kind: "site", target: "site\($0).com", outcome: "blocked") }
  check("at most five targets are named", LogText.attemptsText(many).hasSuffix("site5.com 1, 2 more)"), LogText.attemptsText(many))
}

do {
  let marker = "focus-session: 1"
  check("marker on its own line", LogText.notes("Rating: none\n\nfocus-session: 1", containMarker: marker))
  check("marker 1 does not match session 12", !LogText.notes("x\nfocus-session: 12", containMarker: marker))
  check("marker tolerates CRLF", LogText.notes("x\r\nfocus-session: 1\r\n", containMarker: marker))
  check("marker tolerates <br>", LogText.notes("x<br>focus-session: 1<BR/>", containMarker: marker))
  check("marker inside a sentence does not count", !LogText.notes("see focus-session: 1 above", containMarker: marker))
  check("nil notes", !LogText.notes(nil, containMarker: marker))
}

// MARK: - Recovery: adopt, create, keep waiting

func draft(_ id: Int64) -> LogEventDraft {
  LogEventDraft(
    title: "Goal", start: at(14, 0), end: at(14, 30),
    notes: "x\n\n" + LogText.marker(id) + "\n" + LogText.startedLine(at(14, 0)))
}

do {
  let store = FakeCalendar()
  let created = Recovery.resolve(WaitingSession(sessionId: 1, logCalendarId: "log", draft: draft(1)), store: store)
  check("creates when no marked event exists", created == .created("log-1"), "\(created)")
  check("searches before creating", store.searches.count == 1)
  check(
    "search spans a week either side",
    store.searches.first == DateInterval(start: at(14, 0).addingTimeInterval(-7 * 86_400), end: at(14, 30).addingTimeInterval(7 * 86_400)))

  let again = Recovery.resolve(WaitingSession(sessionId: 1, logCalendarId: "log", draft: draft(1)), store: store)
  check("adopts the event saved before", again == .adopted("log-1"), "\(again)")
  check("adopting does not create a duplicate", store.creates == 1 && store.saved.count == 1)

  let other = Recovery.resolve(WaitingSession(sessionId: 2, logCalendarId: "log", draft: draft(2)), store: store)
  check("another session's marker is not adopted", other == .created("log-2"), "\(other)")

  // A recreated focus.db reuses id 1 for a later session in the same window.
  var reused = draft(1)
  reused.start = at(14, 5)
  reused.end = at(14, 25)
  reused.notes = "x\n\n" + LogText.marker(1) + "\n" + LogText.startedLine(at(14, 5))
  let collision = Recovery.resolve(WaitingSession(sessionId: 1, logCalendarId: "log", draft: reused), store: store)
  check("a reused id with another start time is not adopted", collision == .created("log-3"), "\(collision)")

  // Kai moved the saved event by hours before its id was stored.
  var seven = draft(7)
  seven.notes = "x\n\n" + LogText.marker(7) + "\n" + LogText.startedLine(at(14, 0))
  let movedEvent = LoggedEvent(id: "m", start: at(17, 0), end: at(17, 30), notes: seven.notes)
  check("a moved event is still adopted", Recovery.match([movedEvent], sessionId: 7, draft: seven)?.id == "m")
  check("the session id must match", Recovery.match([movedEvent], sessionId: 8, draft: seven) == nil)
  check("the start line must match", Recovery.match([LoggedEvent(id: "n", start: at(14, 0), end: at(14, 30), notes: LogText.marker(7))], sessionId: 7, draft: seven) == nil)
}

do {
  let store = FakeCalendar()
  let missing = Recovery.resolve(WaitingSession(sessionId: 3, logCalendarId: "gone", draft: draft(3)), store: store)
  if case .waiting(let reason) = missing {
    check("a missing calendar keeps waiting", reason.contains("not in Calendar.app"), reason)
  } else {
    check("a missing calendar keeps waiting", false, "\(missing)")
  }
  check("a missing calendar is never searched or written", store.searches.isEmpty && store.creates == 0)

  let unchosen = Recovery.resolve(WaitingSession(sessionId: 3, logCalendarId: nil, draft: draft(3)), store: store)
  if case .waiting = unchosen { check("no log calendar keeps waiting", true) } else { check("no log calendar keeps waiting", false) }

  let readOnly = Recovery.resolve(WaitingSession(sessionId: 3, logCalendarId: "holidays", draft: draft(3)), store: store)
  if case .waiting(let reason) = readOnly {
    check("a read-only calendar keeps waiting", reason.contains("read-only") && store.creates == 0, reason)
  } else {
    check("a read-only calendar keeps waiting", false, "\(readOnly)")
  }
  store.saved.append(("holidays", "old-1", draft(4)))
  let adoptReadOnly = Recovery.resolve(WaitingSession(sessionId: 4, logCalendarId: "holidays", draft: draft(4)), store: store)
  check("a read-only calendar still adopts an existing event", adoptReadOnly == .adopted("old-1"), "\(adoptReadOnly)")

  store.failSearch = true
  let searchFailed = Recovery.resolve(WaitingSession(sessionId: 5, logCalendarId: "log", draft: draft(5)), store: store)
  if case .waiting = searchFailed {
    check("a failed search keeps waiting without writing", store.creates == 0)
  } else {
    check("a failed search keeps waiting without writing", false, "\(searchFailed)")
  }
  store.failSearch = false
  store.failCreate = true
  let writeFailed = Recovery.resolve(WaitingSession(sessionId: 5, logCalendarId: "log", draft: draft(5)), store: store)
  if case .waiting(let reason) = writeFailed {
    check("a failed write keeps waiting", reason.contains("boom"), reason)
  } else {
    check("a failed write keeps waiting", false, "\(writeFailed)")
  }
  check(
    "tally counts each outcome",
    Recovery.tally([.created("a"), .adopted("b"), .waiting("c"), .waiting("d")])
      == RecoveryCounts(written: 1, adopted: 1, stillWaiting: 2))
}

// MARK: - Config

do {
  let dir = tempDir()
  let path = dir + "/config.json"
  var logged: [String] = []
  let file = ConfigFile(path: path, log: { logged.append($0) })
  let first = file.load()
  check("missing config gives defaults", first == FocusConfig())
  check(
    "defaults", first.startableCalendars.isEmpty && first.logCalendarId == nil && first.snoozeSeconds == 180
      && first.browsers == ["com.google.Chrome", "company.thebrowser.dia"] && !first.raycastDeeplink)
  let written = (try? JSONValue.parse(String(contentsOfFile: path, encoding: .utf8)))?.objectValue ?? [:]
  check(
    "missing config is created with exactly the schema keys",
    Set(written.keys) == [
      "startableCalendars", "logCalendarId", "logCalendarName", "calendarProfiles", "profiles", "browsers",
      "snoozeSeconds", "raycastDeeplink",
    ], "\(written.keys.sorted())")
  check("created config has explicit nulls", written["logCalendarId"] == .null && written["logCalendarName"] == .null)

  let custom = """
    {"startableCalendars": ["a", 5, "b", ""], "logCalendarId": "log", "logCalendarName": "Log (iCloud)",
     "calendarProfiles": {"a": "deep", "b": 3}, "profiles": {"deep": {"categories": ["social"]}},
     "snoozeSeconds": "soon", "raycastDeeplink": true, "futureKey": {"x": 1}}
    """
  try! custom.write(toFile: path, atomically: true, encoding: .utf8)
  let loaded = file.load()
  check("config reads string arrays, dropping other types", loaded.startableCalendars == ["a", "b"], "\(loaded.startableCalendars)")
  check("config reads the log calendar", loaded.logCalendarId == "log" && loaded.logCalendarName == "Log (iCloud)")
  check("config reads calendar profiles", loaded.calendarProfiles == ["a": "deep"])
  check("profile falls back to default", loaded.profile(for: "a") == "deep" && loaded.profile(for: "b") == "default")
  check("profiles are kept verbatim", loaded.profiles["deep"]?["categories"] == ["social"])
  check("a mistyped key falls back to its default", loaded.snoozeSeconds == 180)
  check("missing keys keep defaults", loaded.browsers == FocusConfig().browsers)
  check("unknown keys are ignored", loaded.raycastDeeplink)

  try! "{\"startableCalendars\": [".write(toFile: path, atomically: true, encoding: .utf8)
  check("a half-written file uses the last good config", file.load() == loaded)
  check("a half-written file is left alone", (try? String(contentsOfFile: path, encoding: .utf8)) == "{\"startableCalendars\": [")
  _ = file.load()
  check("a bad file is logged once", logged.count == 1, "\(logged)")
  try! "[]".write(toFile: path, atomically: true, encoding: .utf8)
  check("a non-object file is rejected", file.load() == loaded)
  check("null clears the log calendar", FocusConfig(json: ["logCalendarId": nil]).logCalendarId == nil)
}

// MARK: - Protocol

do {
  check("request parses", (try? Request(line: #"{"cmd":"ping","x":1}"#))?.cmd == "ping")
  for (line, message) in [
    ("nope", "not valid JSON"), ("[1]", "JSON object"), (#"{"x":1}"#, "\"cmd\""), (#"{"cmd":""}"#, "\"cmd\""),
  ] {
    do {
      _ = try Request(line: line)
      check("bad request \(line)", false)
    } catch let error as FocusError {
      check("bad request \(line)", error.message.contains(message), error.message)
    } catch {
      check("bad request \(line)", false)
    }
  }
  let request = try! Request(line: #"{"cmd":"x","a":4.0,"b":4.5,"c":"s","d":null,"e":"  "}"#)
  check("4.0 is a whole number", (try? request.int("a")) == 4)
  check("4.5 is not a whole number", (try? request.int("b")) == nil)
  check("null reads as absent", (try? request.string("d")) == .some(nil))
  check("a blank required string is missing", (try? request.requiredString("e")) == nil)
  check("a number is not a string", (try? request.string("a")) == nil)
  let json = JSONValue.object(["ok": true, "session": nil, "url": "a/b", "n": 1]).serialized()
  check("null is written, keys sorted, slashes kept", json == #"{"n":1,"ok":true,"session":null,"url":"a/b"}"#, json)
  check("json round trip", (try? JSONValue.parse(json)) == ["n": 1, "ok": true, "session": nil, "url": "a/b"])
  check("booleans stay booleans", (try? JSONValue.parse("[true, 1]")) == [true, 1])
}

// MARK: - SQLite round trip

do {
  let dir = tempDir()
  let path = dir + "/focus.db"
  let db = try! Database(path: path)
  check("database is in WAL mode", db.journalMode == "wal", db.journalMode ?? "nil")
  check("schema version is 2", db.userVersion == 2, "\(String(describing: db.userVersion))")

  let new = NewSession(
    sourceEventId: "EV1", calendarId: "work", goal: "Write", profile: "deep", plannedStart: at(14, 0),
    plannedEnd: at(15, 0), startedAt: at(14, 10))
  let id = try! db.insertSession(new)
  let row = try! db.session(id: id)!
  check(
    "session round trip", row.sourceEventId == "EV1" && row.calendarId == "work" && row.goal == "Write"
      && row.profile == "deep" && row.plannedStart == at(14, 0) && row.plannedEnd == at(15, 0)
      && row.startedAt == at(14, 10) && row.lastHeartbeat == at(14, 10) && row.endedAt == nil
      && row.extendedSeconds == 0 && row.logEventId == nil, "\(row)")
  check("open session is found", (try! db.openSession())?.id == id)

  try! db.heartbeat(id, at: at(14, 40))
  check("heartbeat is stored", (try! db.session(id: id))?.lastHeartbeat == at(14, 40))

  try! db.addPause(id, start: at(14, 20), end: at(14, 25))
  try! db.addPause(id, start: at(14, 50), end: nil)
  try! db.addAttempt(id, BlockedAttempt(at: at(14, 30), kind: "site", target: "x.com", outcome: "snoozed"))
  let closed = try! db.finish(
    id,
    SessionClose(
      endedAt: at(14, 55), endReason: "manual", rating: 4, note: "ok", logCalendarId: "log",
      logCalendarName: "Focus Log (iCloud)"))
  check("finish closes the session", closed)
  check("finish is refused twice", !(try! db.finish(id, SessionClose(endedAt: at(15, 0), endReason: "timer"))))
  let done = try! db.session(id: id)!
  check(
    "finished row", done.endedAt == at(14, 55) && done.endReason == "manual" && done.rating == 4 && done.note == "ok"
      && done.logCalendarId == "log" && done.logCalendarName == "Focus Log (iCloud)", "\(done)")
  check("finish closes the open pause", (try! db.pauses(id)).last?.end == at(14, 55))
  check("blocked attempts round trip", (try! db.attempts(id)) == [BlockedAttempt(at: at(14, 30), kind: "site", target: "x.com", outcome: "snoozed")])
  check("no open session after finish", (try! db.openSession()) == nil)
  check("a finished row without a log event waits", (try! db.waitingSessions()).map(\.id) == [id])

  let abandoned = try! db.insertSession(new)
  _ = try! db.finish(abandoned, SessionClose(endedAt: at(15, 0), endReason: "abandoned"))
  check("abandoned sessions never wait for a log event", (try! db.waitingSessions()).map(\.id) == [id])
  check("move rewrites waiting rows only", (try! db.moveWaiting(toCalendar: "log2", name: "Log 2 (Google)")) == 1)
  check("move rewrites id and name", (try! db.session(id: id))?.logCalendarName == "Log 2 (Google)")
  check("abandoned rows are not moved", (try! db.session(id: abandoned))?.logCalendarId == nil)

  check("log event id is stored once", (try! db.setLogEventId(id, "E1")) && !(try! db.setLogEventId(id, "E2")))
  check("log event id sticks", (try! db.session(id: id))?.logEventId == "E1")
  check("a logged row stops waiting", (try! db.waitingSessions()).isEmpty)

  let reopened = try! Database(path: path)
  check("reopening keeps the data", (try! reopened.session(id: id))?.goal == "Write")
  check("reopening keeps the schema version", reopened.userVersion == 2)
  check("the database file exists", FileManager.default.fileExists(atPath: path))
}

// MARK: - Session state machine

/// The error message of a refused input, or nil when it was accepted.
func refused(_ machine: inout SessionMachine, _ input: SessionInput) -> String? {
  let before = machine
  switch machine.apply(input) {
  case .success: return nil
  case .failure(let error):
    check("a refusal leaves the machine unchanged (\(error.message))", machine == before)
    return error.message
  }
}

func applied(_ machine: inout SessionMachine, _ input: SessionInput) -> SessionTransition? {
  try? machine.apply(input).get()
}

func running(at start: Date = at(14, 0), until end: Date = at(14, 30)) -> SessionMachine {
  var machine = SessionMachine()
  _ = machine.apply(.start(at: start, plannedEnd: end))
  return machine
}

do {
  // Idle: only start and tick are accepted.
  var idle = SessionMachine()
  check("a new machine is idle", idle.state == .idle && !idle.state.isOpen)
  for input: SessionInput in [
    .pause(at: at(14, 0)), .resume(at: at(14, 0)), .extend(seconds: 300, at: at(14, 0)), .stop(at: at(14, 0)),
    .finish(at: at(14, 0), rating: nil, note: nil, reason: nil), .abandon(at: at(14, 0)),
  ] {
    check("idle refuses \(input)", refused(&idle, input) == "no session is running")
  }
  check("idle ticks to nothing", applied(&idle, .tick(at: at(14, 0))) == SessionTransition.none && idle.state == .idle)
  check("start needs an end after the start", refused(&idle, .start(at: at(14, 0), plannedEnd: at(14, 0))) != nil)
  check("idle numbers are zero", idle.remainingSeconds(at: at(14, 0)) == 0 && idle.pausedSeconds(at: at(14, 0)) == 0 && idle.focusedSeconds(at: at(14, 0)) == 0)

  var machine = SessionMachine()
  check("start", applied(&machine, .start(at: at(14, 0), plannedEnd: at(14, 30))) == .started)
  check("start gives running", machine.state == .running && machine.startedAt == at(14, 0) && machine.plannedEnd == at(14, 30) && machine.extendedSeconds == 0)
  check("start twice is refused", refused(&machine, .start(at: at(14, 1), plannedEnd: at(15, 0))) == "a session is already running")
  check("resume while running is refused", refused(&machine, .resume(at: at(14, 1))) == "the session is not paused")
  check("remaining counts down while running", machine.remainingSeconds(at: at(14, 10, 30)) == 1170)
  check("a tick before the deadline changes nothing", applied(&machine, .tick(at: at(14, 29, 59))) == SessionTransition.none && machine.state == .running)

  // Pause and resume.
  check("pause", applied(&machine, .pause(at: at(14, 10))) == .paused && machine.state == .paused && machine.isPaused)
  check("pause opens a pause span", machine.pauses == [PauseSpan(start: at(14, 10), end: nil)])
  check("pause twice is refused", refused(&machine, .pause(at: at(14, 11))) == "the session is already paused")
  check("an open pause counts up to now", machine.pausedSeconds(at: at(14, 12)) == 120)
  check("the deadline keeps counting down while paused", machine.remainingSeconds(at: at(14, 12)) == 18 * 60)
  check("resume", applied(&machine, .resume(at: at(14, 15))) == .resumed && machine.state == .running)
  check("resume closes the pause", machine.pauses == [PauseSpan(start: at(14, 10), end: at(14, 15))])
  check("paused time is kept after resume", machine.pausedSeconds(at: at(14, 20)) == 300)
  check("focused time excludes pauses", machine.focusedSeconds(at: at(14, 20)) == 15 * 60)

  // Extend while running and while paused.
  check("extend while running", applied(&machine, .extend(seconds: 300, at: at(14, 20))) == .extended(seconds: 300, fromEnding: false))
  check("extend moves the planned end", machine.plannedEnd == at(14, 35) && machine.extendedSeconds == 300 && machine.state == .running)
  for bad in [0, 59, -300, 86_401] {
    check("extend refuses \(bad) s", refused(&machine, .extend(seconds: bad, at: at(14, 20)))?.contains("60 to 86400") == true)
  }
  _ = machine.apply(.pause(at: at(14, 21)))
  check("extend while paused", applied(&machine, .extend(seconds: 600, at: at(14, 22))) == .extended(seconds: 600, fromEnding: false))
  check("extend while paused stays paused", machine.state == .paused && machine.plannedEnd == at(14, 45) && machine.extendedSeconds == 900)

  // The planned end passes while paused.
  check("a paused tick before the deadline changes nothing", applied(&machine, .tick(at: at(14, 44))) == SessionTransition.none)
  check("the deadline passing while paused reaches the end sheet", applied(&machine, .tick(at: at(14, 46))) == .reachedDeadline)
  check("paused past the deadline is ending by the timer", machine.state == .ending && machine.endingReason == .timer)
  check("reaching the end sheet closes the pause at the deadline", machine.pauses.last == PauseSpan(start: at(14, 21), end: at(14, 45)))
  check("remaining is zero while ending", machine.remainingSeconds(at: at(14, 46)) == 0)

  // Ending refuses everything but extend and finish.
  check("pause at the end sheet is refused", refused(&machine, .pause(at: at(14, 47)))?.contains("end sheet") == true)
  check("resume at the end sheet is refused", refused(&machine, .resume(at: at(14, 47)))?.contains("end sheet") == true)
  check("stop at the end sheet is refused", refused(&machine, .stop(at: at(14, 47)))?.contains("end sheet") == true)
  check("start at the end sheet is refused", refused(&machine, .start(at: at(14, 47), plannedEnd: at(15, 0))) == "a session is already running")
  check("a tick at the end sheet changes nothing", applied(&machine, .tick(at: at(15, 30))) == SessionTransition.none && machine.state == .ending)

  // Extend from the end sheet after it waited: counts from now.
  check("extend from the end sheet", applied(&machine, .extend(seconds: 300, at: at(14, 50))) == .extended(seconds: 300, fromEnding: true))
  check("extend from the end sheet returns to running", machine.state == .running && machine.endingReason == nil)
  check("an extension after the deadline counts from now", machine.plannedEnd == at(14, 55) && machine.extendedSeconds == 1200)
  check("the same session carries on", machine.startedAt == at(14, 0) && machine.pauses.count == 2)

  // The deadline while running, then finish records the timer.
  check("the deadline while running reaches the end sheet", applied(&machine, .tick(at: at(14, 55))) == .reachedDeadline && machine.endingReason == .timer)
  check("finish from the timer's end sheet", applied(&machine, .finish(at: at(14, 56), rating: 4, note: "ok", reason: nil)) == .finished(.timer))
  check(
    "finish closes the session", machine.state == .finished && !machine.state.isOpen && machine.endedAt == at(14, 56)
      && machine.endReason == .timer && machine.rating == 4 && machine.note == "ok" && machine.endingReason == nil)
  // 56 min elapsed, paused 14:10-14:15 and 14:21-14:45 (29 min).
  check("focused seconds after finish", machine.focusedSeconds(at: at(16, 0)) == 27 * 60 && machine.pausedSeconds(at: at(16, 0)) == 29 * 60)
  for input: SessionInput in [
    .pause(at: at(15, 0)), .resume(at: at(15, 0)), .extend(seconds: 300, at: at(15, 0)), .stop(at: at(15, 0)),
    .finish(at: at(15, 0), rating: nil, note: nil, reason: nil), .abandon(at: at(15, 0)),
  ] {
    check("finished refuses \(input)", refused(&machine, input) == "the session has already ended")
  }
  check("a finished session is not started again", refused(&machine, .start(at: at(15, 0), plannedEnd: at(16, 0))) != nil)
  check("a finished session ignores ticks", applied(&machine, .tick(at: at(16, 0))) == SessionTransition.none)
}

do {
  // Manual stop from running and from paused; extend from a manual stop.
  var machine = running()
  check("stop from running", applied(&machine, .stop(at: at(14, 10))) == .stopped && machine.state == .ending && machine.endingReason == .manual)
  check("extend after a stop before the deadline moves the planned end", applied(&machine, .extend(seconds: 300, at: at(14, 11))) == .extended(seconds: 300, fromEnding: true) && machine.plannedEnd == at(14, 35))
  check("stop again", applied(&machine, .stop(at: at(14, 12))) == .stopped)
  check("finish after a stop is manual", applied(&machine, .finish(at: at(14, 13), rating: nil, note: nil, reason: nil)) == .finished(.manual))
  check("finish without a rating", machine.rating == nil && machine.endedAt == at(14, 13))

  var paused = running()
  _ = paused.apply(.pause(at: at(14, 5)))
  check("stop from paused", applied(&paused, .stop(at: at(14, 9))) == .stopped && paused.state == .ending)
  check("stop from paused closes the pause at the stop", paused.pauses == [PauseSpan(start: at(14, 5), end: at(14, 9))])
  check("extend from a stopped pause returns to running, not paused", applied(&paused, .extend(seconds: 600, at: at(14, 10))) != nil && paused.state == .running)

  // Finish straight from running or paused (the shortcut), and explicit reasons.
  var direct = running()
  check("finish from running is manual", applied(&direct, .finish(at: at(14, 20), rating: 5, note: nil, reason: nil)) == .finished(.manual))
  var directPaused = running()
  _ = directPaused.apply(.pause(at: at(14, 10)))
  check("finish from paused is manual", applied(&directPaused, .finish(at: at(14, 20), rating: nil, note: nil, reason: nil)) == .finished(.manual))
  check("finish from paused closes the pause", directPaused.pauses == [PauseSpan(start: at(14, 10), end: at(14, 20))])
  check("focused time from paused finish", directPaused.focusedSeconds(at: at(15, 0)) == 10 * 60)
  var explicit = running()
  check("an explicit reason wins", applied(&explicit, .finish(at: at(14, 20), rating: nil, note: nil, reason: .timer)) == .finished(.timer))
  var badRating = running()
  check("rating 0 is refused", refused(&badRating, .finish(at: at(14, 20), rating: 0, note: nil, reason: nil)) == "rating must be 1 to 5")
  check("rating 6 is refused", refused(&badRating, .finish(at: at(14, 20), rating: 6, note: nil, reason: nil)) == "rating must be 1 to 5")
  check("finish as abandoned is refused", refused(&badRating, .finish(at: at(14, 20), rating: nil, note: nil, reason: .abandoned)) != nil)
  var early = running()
  check("finish before the start clamps to the start", applied(&early, .finish(at: at(13, 0), rating: nil, note: nil, reason: nil)) != nil && early.endedAt == at(14, 0))

  // The deadline is inclusive: now == planned end reaches it.
  var exact = running()
  check("the deadline is reached at exactly the planned end", applied(&exact, .tick(at: at(14, 30))) == .reachedDeadline)
  // A tick long after (the Mac slept) still reaches it once, closing a pause at the deadline.
  var slept = running()
  _ = slept.apply(.pause(at: at(14, 20)))
  check("a late tick reaches the deadline", applied(&slept, .tick(at: at(18, 0))) == .reachedDeadline && slept.pauses.last?.end == at(14, 30))
  check("an extension after a long wait still gives the full length", applied(&slept, .extend(seconds: 1500, at: at(18, 0))) != nil && slept.plannedEnd == at(18, 25))

  // Abandon (launch recovery) from each open state.
  var abandonRunning = running()
  check("abandon from running", applied(&abandonRunning, .abandon(at: at(14, 12))) == .abandoned)
  check("abandoned ends at the given time", abandonRunning.state == .abandoned && abandonRunning.endedAt == at(14, 12) && abandonRunning.endReason == .abandoned && abandonRunning.rating == nil)
  check("an abandoned session refuses finish", refused(&abandonRunning, .finish(at: at(14, 13), rating: 5, note: nil, reason: nil)) == "the session has already ended")
  var abandonPaused = running()
  _ = abandonPaused.apply(.pause(at: at(14, 20)))
  check("abandon from paused", applied(&abandonPaused, .abandon(at: at(14, 15))) == .abandoned)
  check("a pause begun after the last heartbeat closes at its own start", abandonPaused.pauses == [PauseSpan(start: at(14, 20), end: at(14, 20))])
  var abandonEnding = running()
  _ = abandonEnding.apply(.stop(at: at(14, 5)))
  check("abandon from ending", applied(&abandonEnding, .abandon(at: at(14, 6))) == .abandoned)

  // Pauses never start before the session or end before they began.
  var clamp = running()
  _ = clamp.apply(.pause(at: at(13, 0)))
  _ = clamp.apply(.resume(at: at(12, 0)))
  check("pause times are clamped", clamp.pauses == [PauseSpan(start: at(14, 0), end: at(14, 0))])

  // Restoring from sqlite.
  let restoredRunning = SessionMachine(restoring: at(14, 0), plannedEnd: at(14, 30), extendedSeconds: 0, pauses: [PauseSpan(start: at(14, 5), end: at(14, 6))], endingReason: nil)
  check("restoring with closed pauses is running", restoredRunning.state == .running && restoredRunning.pauses.count == 1)
  let restoredPaused = SessionMachine(restoring: at(14, 0), plannedEnd: at(14, 30), extendedSeconds: 300, pauses: [PauseSpan(start: at(14, 5), end: nil)], endingReason: nil)
  check("restoring with an open pause is paused", restoredPaused.state == .paused && restoredPaused.extendedSeconds == 300)
  var restoredEnding = SessionMachine(restoring: at(14, 0), plannedEnd: at(14, 30), extendedSeconds: 0, pauses: [], endingReason: .timer)
  check("restoring with an ending reason is at the end sheet", restoredEnding.state == .ending && restoredEnding.endingReason == .timer)
  check("a restored end sheet finishes with its reason", applied(&restoredEnding, .finish(at: at(14, 40), rating: nil, note: nil, reason: nil)) == .finished(.timer))
  check("the extend options are 5, 10, 15 and 25 minutes", SessionMachine.extendOptions == [300, 600, 900, 1500])
}

// MARK: - Raycast deeplink

do {
  let url = RaycastDeeplink.start(goal: "Write & review: 50% done #1+2 é/x?y=z", durationSeconds: 1500)
  check(
    "the start deeplink encodes the goal as a query value",
    url.absoluteString == "raycast://focus/start?goal=Write%20%26%20review%3A%2050%25%20done%20%231%2B2%20%C3%A9%2Fx%3Fy%3Dz&duration=1500&mode=block",
    url.absoluteString)
  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
  check("the goal round-trips", items.first { $0.name == "goal" }?.value == "Write & review: 50% done #1+2 é/x?y=z", "\(items)")
  check("duration and mode are separate items", items.map(\.name) == ["goal", "duration", "mode"] && items.last?.value == "block")
  check("a negative duration becomes zero", RaycastDeeplink.start(goal: "x", durationSeconds: -5).absoluteString.contains("duration=0&"))
  check("the complete deeplink", RaycastDeeplink.complete.absoluteString == "raycast://focus/complete")
}

// MARK: - SQLite: schema 2 and the step 2 writes

do {
  let dir = tempDir()
  let path = dir + "/focus.db"
  do {
    let db = try! Database(path: path)
    // Back to a step 1 database: no extended_end, version 1.
    try! db.exec("alter table sessions drop column extended_end; pragma user_version = 1;")
    try! db.insertSession(
      NewSession(sourceEventId: nil, calendarId: "work", goal: "Old", profile: "default", plannedStart: at(9, 0), plannedEnd: at(9, 30), startedAt: at(9, 0)))
  }
  let db = try! Database(path: path)
  check("a version 1 database migrates to 2", db.userVersion == 2)
  let old = try! db.session(id: 1)
  check("migration keeps the rows", old?.goal == "Old" && old?.extendedEnd == nil && old?.deadline == at(9, 30), "\(String(describing: old))")

  try! db.setExtension(1, seconds: 600, end: at(9, 40))
  try! db.setEnding(1, reason: "timer")
  var row = try! db.session(id: 1)!
  check("the extension is stored beside the planned end", row.extendedSeconds == 600 && row.extendedEnd == at(9, 40) && row.plannedEnd == at(9, 30) && row.deadline == at(9, 40))
  check("an open row can carry its ending reason", row.endReason == "timer" && row.endedAt == nil && (try! db.openSession())?.id == 1)
  check("an open row at the end sheet does not wait for a log event", (try! db.waitingSessions()).isEmpty)
  try! db.setEnding(1, reason: nil)
  check("the ending reason clears", (try! db.session(id: 1))?.endReason == nil)

  try! db.addPause(1, start: at(9, 10), end: nil)
  try! db.closePause(1, at: at(9, 5))
  check("a pause never closes before it began", (try! db.pauses(1)) == [PauseSpan(start: at(9, 10), end: at(9, 10))])
  try! db.addPause(1, start: at(9, 20), end: nil)
  _ = try! db.finish(1, SessionClose(endedAt: at(9, 15), endReason: "abandoned"))
  check("finish clamps an open pause too", (try! db.pauses(1)).last == PauseSpan(start: at(9, 20), end: at(9, 20)))
  try! db.setExtension(1, seconds: 900, end: at(10, 0))
  try! db.setEnding(1, reason: "manual")
  row = try! db.session(id: 1)!
  check("a finished row is not changed by open-row writes", row.extendedSeconds == 600 && row.endReason == "abandoned")
}

// MARK: - Commands over a fake calendar

final class Clock {
  var now: Date
  init(_ now: Date) { self.now = now }
}

/// A core on a fake clock and calendar with a recording presenter, no real
/// timer, presenter calls run inline, and deeplinks recorded.
final class Harness {
  let dir: String
  let clock: Clock
  let fake: FakeCalendar
  let db: Database
  let presenter = NullPresenter()
  var opened: [URL] = []
  var logs: [String] = []
  var core: FocusCore!

  init(config: String? = nil, clock: Clock, dir: String? = nil, fake: FakeCalendar = FakeCalendar()) {
    self.dir = dir ?? tempDir()
    self.clock = clock
    self.fake = fake
    if let config { try! config.write(toFile: self.dir + "/config.json", atomically: true, encoding: .utf8) }
    db = try! Database(path: self.dir + "/focus.db")
    core = FocusCore(
      config: ConfigFile(path: self.dir + "/config.json"), db: db, calendar: fake, clock: { clock.now },
      log: { [unowned self] in self.logs.append($0) }, secondTimer: false, presenter: presenter,
      runOnMain: { $0() }, openURL: { [unowned self] in self.opened.append($0) })
  }

  /// A second daemon launch over the same folder (the first one died).
  func relaunch(at date: Date) -> Harness {
    clock.now = date
    return Harness(clock: clock, dir: dir, fake: fake)
  }

  func send(_ cmd: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    var all = fields
    all["cmd"] = .string(cmd)
    return core.handle(line: JSONValue.object(all).serialized()).body
  }

  var lastView: SessionView? { presenter.views.last ?? nil }
}

func makeCore(config: String? = nil, clock: Clock) -> (FocusCore, FakeCalendar, Database, String) {
  let harness = Harness(config: config, clock: clock)
  keepHarnesses.append(harness)
  return (harness.core, harness.fake, harness.db, harness.dir)
}

var keepHarnesses: [Harness] = []

func send(_ core: FocusCore, _ cmd: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
  var all = fields
  all["cmd"] = .string(cmd)
  return core.handle(line: JSONValue.object(all).serialized()).body
}

do {
  let clock = Clock(at(14, 10, 30))
  let config = #"{"startableCalendars": ["work"], "logCalendarId": "log", "logCalendarName": "Focus Log (iCloud)", "calendarProfiles": {"work": "deep"}}"#
  let (core, fake, db, _) = makeCore(config: config, clock: clock)
  fake.eventList = [
    event("E1", "Write report", at(14, 0), at(15, 0)),
    event("E2", "Standup", at(9, 0), at(9, 15)),
    event("E3", "Almost over", at(13, 0), at(14, 11)),
    event("E4", "Gym", at(18, 0), at(19, 0), calendar: "personal"),
    event("E5", "Tomorrow", at(9, 0, day: 29), at(10, 0, day: 29)),
  ]

  let ping = send(core, "ping")
  check("ping", ping["ok"] == true && ping["version"] == "0.2.0" && ping["pid"]?.intValue != nil && ping["calendarAccess"] == "fullAccess", ping.serialized())

  let calendars = send(core, "calendars")["calendars"]?.arrayValue ?? []
  check("calendars lists every calendar with its account", calendars.count == 3 && calendars.contains { $0["title"] == "Work" && $0["account"] == "Google" && $0["color"] == "#FF0000" && $0["writable"] == true })
  check("calendar color can be null", calendars.contains { $0["id"] == "log" && $0["color"] == .null })

  let today = send(core, "today")
  let events = today["events"]?.arrayValue ?? []
  check("today lists only startable events from startable calendars", events.map { $0["id"]?.stringValue ?? "" } == ["E1"], today.serialized())
  check("today reports remaining seconds", events.first?["remainingSeconds"] == 2970, today.serialized())
  check("today dates carry a timezone", events.first?["start"]?.stringValue.flatMap(ISO.parse) == at(14, 0))
  check("today names the calendar", events.first?["calendarTitle"] == "Work" && events.first?["calendarId"] == "work")

  check("status is null when idle", send(core, "status") == ["ok": true, "session": nil])

  let refused = send(core, "start", ["eventId": "E3"])
  check("start refuses under a minute left", refused["ok"] == false && refused["error"]?.stringValue?.contains("under a minute") == true, refused.serialized())
  let ended = send(core, "start", ["eventId": "E2"])
  check("start refuses an ended event", ended["error"]?.stringValue?.contains("already ended") == true, ended.serialized())
  let tomorrow = send(core, "start", ["eventId": "E5"])
  check("start refuses an event that is not today", tomorrow["error"]?.stringValue?.contains("not on today's calendar") == true, tomorrow.serialized())
  check("start needs an eventId", send(core, "start")["error"] == "eventId is required")
  fake.eventList.append(event("E6", "Other calendar", at(14, 0), at(15, 0), calendar: "personal"))
  let excluded = send(core, "start", ["eventId": "E6"])
  check("start refuses an event from a calendar not picked in Settings", excluded["error"]?.stringValue?.contains("startable calendar") == true, excluded.serialized())

  let started = send(core, "start", ["eventId": "E1"])
  let session = started["session"]
  check("start creates a running session", started["ok"] == true && session?["state"] == "running", started.serialized())
  check(
    "start copies the event", session?["goal"] == "Write report" && session?["calendarId"] == "work"
      && session?["sourceEventId"] == "E1" && session?["profile"] == "deep", started.serialized())
  check("start runs until the planned end", session?["plannedEnd"]?.stringValue.flatMap(ISO.parse) == at(15, 0))
  check("start time is now", session?["startedAt"]?.stringValue.flatMap(ISO.parse) == at(14, 10, 30))
  let row = try! db.openSession()!
  check("start stores planned start and heartbeat", row.plannedStart == at(14, 0) && row.lastHeartbeat == at(14, 10, 30))

  check("status returns the running session", send(core, "status")["session"] == session)
  check(
    "a running session reports its live numbers", session?["remainingSeconds"] == 2970 && session?["pausedSeconds"] == 0
      && session?["extendedSeconds"] == 0 && session?["endReason"] == .null, started.serialized())
  let bogus = send(core, "start", ["eventId": "nope"])
  check("a start that fails validation leaves the running session alone", bogus["ok"] == false && send(core, "status")["session"]?["state"] == "running", bogus.serialized())

  // PLAN: starting while a session is open sends that one to the end sheet first.
  let twice = send(core, "start", ["eventId": "E1"])
  check(
    "start refuses while a session runs", twice["ok"] == false
      && twice["error"]?.stringValue?.contains("already running: \"Write report\"") == true
      && twice["error"]?.stringValue?.contains("end sheet") == true
      && twice["session"]?["id"] == session?["id"], twice.serialized())
  check("the running session went to the end sheet", twice["session"]?["state"] == "ending" && twice["session"]?["endReason"] == "manual", twice.serialized())
  let adhocWhileRunning = send(core, "startAdhoc", ["goal": "x", "durationSeconds": 600, "calendarId": "work"])
  check("startAdhoc refuses while a session is at the end sheet", adhocWhileRunning["ok"] == false && adhocWhileRunning["session"]?["state"] == "ending")
  check("status returns the session at the end sheet", send(core, "status")["session"]?["id"] == session?["id"] && send(core, "status")["session"]?["state"] == "ending")

  clock.now = at(14, 40)
  core.tick()
  check("the tick refreshes the heartbeat", (try! db.openSession())?.lastHeartbeat == at(14, 40))

  check("finish rejects rating 6", send(core, "finish", ["rating": 6])["error"] == "rating must be 1 to 5")
  check("finish rejects rating 4.5", send(core, "finish", ["rating": .double(4.5)])["ok"] == false)
  check("finish rejects an unknown reason", send(core, "finish", ["reason": "bored"])["ok"] == false)
  check("a rejected finish leaves the session running", (try! db.openSession()) != nil)

  clock.now = at(14, 58)
  let finished = send(core, "finish", ["rating": 4, "note": "Shipped it\n", "reason": "timer"])
  check("finish succeeds", finished["ok"] == true && finished["logPending"] == false, finished.serialized())
  check("finish returns the log event id", finished["logEventId"] == "log-1", finished.serialized())
  check(
    "finish returns the closed session", finished["session"]?["state"] == "finished"
      && finished["session"]?["rating"] == 4 && finished["session"]?["note"] == "Shipped it"
      && finished["session"]?["endReason"] == "timer" && finished["session"]?["logEventId"] == "log-1",
    finished.serialized())
  let logged = fake.saved.first
  check("log event goes to the log calendar", logged?.calendarId == "log")
  check("log event title is the goal", logged?.draft.title == "Write report")
  check("log event spans the real start and end", logged?.draft.start == at(14, 10, 30) && logged?.draft.end == at(14, 58))
  check("log event description has stars and marker", logged?.draft.notes.contains("Rating: ★★★★☆") == true && logged.map { LogText.notes($0.draft.notes, containMarker: "focus-session: \(row.id)") } == true, logged?.draft.notes ?? "")
  check("log event names the source", logged?.draft.notes.hasPrefix("Source: Work, event E1\nFocused: 48 min of 48 min") == true, logged?.draft.notes ?? "")
  let stored = try! db.session(id: row.id)!
  check("finish stores the log calendar from config", stored.logCalendarId == "log" && stored.logCalendarName == "Focus Log (iCloud)")
  check("status is idle after finish", send(core, "status")["session"] == .null)
  check("finish with nothing running fails", send(core, "finish")["error"] == "no session is running")
  check("nothing is pending", send(core, "pending")["waiting"] == [])

  // The save succeeded but the id was never stored: recovery adopts it.
  try! db.exec("update sessions set log_event_id = null where id = \(row.id)")
  let adopted = send(core, "retryPending")
  check("retryPending adopts the saved event", adopted == ["ok": true, "written": 0, "adopted": 1, "stillWaiting": 0], adopted.serialized())
  check("adoption writes no duplicate", fake.saved.count == 1 && (try! db.session(id: row.id))?.logEventId == "log-1")

  // Ad hoc into a log calendar that has vanished: the row waits.
  try! #"{"startableCalendars": ["work"], "logCalendarId": "gone", "logCalendarName": "Old Log (Google)"}"#
    .write(toFile: core.config.path, atomically: true, encoding: .utf8)
  check("startAdhoc needs a goal", send(core, "startAdhoc", ["durationSeconds": 600, "calendarId": "work"])["error"] == "goal is required")
  check("startAdhoc needs a calendar", send(core, "startAdhoc", ["goal": "x", "durationSeconds": 600])["error"] == "calendarId is required")
  check("startAdhoc needs a length", send(core, "startAdhoc", ["goal": "x", "calendarId": "work"])["error"] == "durationSeconds is required")
  check("startAdhoc rejects 30 s", send(core, "startAdhoc", ["goal": "x", "durationSeconds": 30, "calendarId": "work"])["ok"] == false)
  clock.now = at(16, 0)
  let adhoc = send(core, "startAdhoc", ["goal": "Inbox zero", "durationSeconds": 1500, "calendarId": "personal"])
  check(
    "startAdhoc creates a session", adhoc["ok"] == true && adhoc["session"]?["goal"] == "Inbox zero"
      && adhoc["session"]?["sourceEventId"] == .null && adhoc["session"]?["profile"] == "default"
      && adhoc["session"]?["plannedEnd"]?.stringValue.flatMap(ISO.parse) == at(16, 25), adhoc.serialized())
  let adhocId = adhoc["session"]?["id"]?.intValue ?? 0
  check("startAdhoc stores planned start as now", (try! db.session(id: Int64(adhocId)))?.plannedStart == at(16, 0))
  clock.now = at(16, 25)
  let waiting = send(core, "finish", ["reason": "timer"])
  check("finish into a missing calendar is pending", waiting["ok"] == true && waiting["logPending"] == true && waiting["logEventId"] == .null, waiting.serialized())
  let pending = send(core, "pending")["waiting"]?.arrayValue ?? []
  check(
    "pending names the calendar stored at finish", pending.count == 1 && pending.first?["sessionId"]?.intValue == adhocId
      && pending.first?["goal"] == "Inbox zero" && pending.first?["logCalendarName"] == "Old Log (Google)"
      && pending.first?["endedAt"]?.stringValue.flatMap(ISO.parse) == at(16, 25), pending.description)
  check("pending gives the reason", pending.first?["reason"]?.stringValue?.contains("not in Calendar.app") == true)
  check("retry keeps it waiting", send(core, "retryPending") == ["ok": true, "written": 0, "adopted": 0, "stillWaiting": 1])
  check("waiting never re-points on its own", (try! db.session(id: Int64(adhocId)))?.logCalendarId == "gone")

  check("move needs a known calendar", send(core, "movePending", ["calendarId": "nope"])["ok"] == false)
  check("move refuses a read-only calendar", send(core, "movePending", ["calendarId": "holidays"])["error"]?.stringValue?.contains("read-only") == true)
  let moved = send(core, "movePending", ["calendarId": "log"])
  check("move writes the waiting session", moved == ["ok": true, "moved": 1, "written": 1, "adopted": 0, "stillWaiting": 0], moved.serialized())
  let movedRow = try! db.session(id: Int64(adhocId))!
  check("move rewrites id and name", movedRow.logCalendarId == "log" && movedRow.logCalendarName == "Focus Log (iCloud)" && movedRow.logEventId == "log-2")
  check("the ad hoc log event says so", fake.saved.last?.draft.notes.hasPrefix("Source: ad hoc, filed under personal") == true, fake.saved.last?.draft.notes ?? "")
  check("nothing is pending after the move", send(core, "pending")["waiting"] == [])

  check("unknown commands fail", send(core, "dance")["error"] == "unknown command: dance")
  check("quit replies and asks to exit", core.handle(line: #"{"cmd":"quit"}"#).quit)
  check("bad JSON is an error reply", core.handle(line: "{").body["ok"] == false)
}

do {
  // No calendar access yet: EventKit commands explain, ad hoc still works,
  // and finish keeps the log event waiting until access arrives.
  let clock = Clock(at(10, 0))
  let (core, fake, _, _) = makeCore(config: #"{"logCalendarId": "log"}"#, clock: clock)
  fake.accessState = "notDetermined"
  let today = send(core, "today")
  check("today explains missing access", today["ok"] == false && today["calendarAccess"] == "notDetermined" && today["error"]?.stringValue?.contains("permission prompt") == true, today.serialized())
  check("a request without access asks for it", fake.requests == 1)
  fake.accessState = "denied"
  check("denied access points to System Settings", send(core, "calendars")["error"]?.stringValue?.contains("System Settings") == true)
  check("ad hoc works without calendar access", send(core, "startAdhoc", ["goal": "Read", "durationSeconds": 60, "calendarId": "work"])["ok"] == true)
  clock.now = at(10, 1)
  let finished = send(core, "finish", [:])
  check("finish without access leaves the log pending", finished["ok"] == true && finished["logPending"] == true && fake.creates == 0, finished.serialized())
  check("finish stores the log calendar id even without access", send(core, "pending")["waiting"]?[0]?["logCalendarId"] == "log")
  fake.accessState = "fullAccess"
  fake.grantedOutside = true
  _ = send(core, "ping")
  check("a grant from System Settings runs recovery on the next request", fake.saved.count == 1)
  core.tick()
  check("the tick writes it once access arrives", fake.saved.count == 1 && send(core, "pending")["waiting"] == [])
  _ = send(core, "startAdhoc", ["goal": "Read more", "durationSeconds": 60, "calendarId": "work"])
  clock.now = at(10, 3)
  let named = send(core, "finish", [:])
  check("finish looks up the log calendar name when config has none", named["session"]?["logCalendarName"] == "Focus Log (iCloud)", named.serialized())
}

do {
  // Config with no log calendar at all: the row waits with a null name.
  let clock = Clock(at(10, 0))
  let (core, _, _, dir) = makeCore(clock: clock)
  _ = send(core, "startAdhoc", ["goal": "Read", "durationSeconds": 120, "calendarId": "work", "profile": "light"])
  check("startAdhoc keeps an explicit profile", send(core, "status")["session"]?["profile"] == "light")
  clock.now = at(10, 2)
  let finished = send(core, "finish", ["note": "  "])
  check("finish with no log calendar is pending", finished["logPending"] == true && finished["session"]?["note"] == .null)
  check("pending shows a null calendar name", send(core, "pending")["waiting"]?[0]?["logCalendarName"] == .null)
  check("the first request creates config.json", FileManager.default.fileExists(atPath: dir + "/config.json"))
}

// MARK: - Session commands, the timer and the presenter

func pauseRows(_ db: Database, _ id: Int) -> [PauseSpan] { try! db.pauses(Int64(id)) }

do {
  let clock = Clock(at(10, 0))
  let h = Harness(config: #"{"logCalendarId": "log", "logCalendarName": "Focus Log (iCloud)"}"#, clock: clock)
  check("idle: nothing to tick", !h.core.ticking && h.core.sessionView() == nil)
  check("pause with nothing running", h.send("pause")["error"] == "no session is running")
  check("stop with nothing running", h.send("stop")["error"] == "no session is running")
  check("extend with nothing running", h.send("extend", ["seconds": 300])["error"] == "no session is running")

  let started = h.send("startAdhoc", ["goal": "Draft", "durationSeconds": 600, "calendarId": "work"])
  let id = started["session"]?["id"]?.intValue ?? 0
  check("start begins the 1 Hz tick", h.core.ticking)
  check("start shows the session", h.lastView?.state == "running" && h.lastView?.remainingSeconds == 600 && h.lastView?.goal == "Draft", "\(String(describing: h.lastView))")
  check("the view names the calendar and the extend options", h.lastView?.calendarTitle == "Work" && h.lastView?.extendOptions == [300, 600, 900, 1500] && h.lastView?.id == id)
  check("the view carries the start and the planned end", h.lastView?.startedAt == at(10, 0) && h.lastView?.plannedEnd == at(10, 10))
  check("no deeplink unless configured", h.opened.isEmpty)

  clock.now = at(10, 2)
  let paused = h.send("pause")
  check("pause replies with the paused session", paused["ok"] == true && paused["session"]?["state"] == "paused", paused.serialized())
  check("pause writes an open pause row", pauseRows(h.db, id) == [PauseSpan(start: at(10, 2), end: nil)])
  check("pause twice is refused", h.send("pause")["error"] == "the session is already paused")
  check("the view shows paused", h.lastView?.state == "paused")
  clock.now = at(10, 4)
  let status = h.send("status")["session"]
  check("status counts paused time and the deadline keeps running", status?["pausedSeconds"] == 120 && status?["remainingSeconds"] == 360 && status?["state"] == "paused", status?.serialized() ?? "")
  let views = h.presenter.views.count
  h.core.secondTick()
  check("each second refreshes the view", h.presenter.views.count == views + 1 && h.lastView?.pausedSeconds == 120)

  clock.now = at(10, 5)
  check("resume", h.send("resume")["session"]?["state"] == "running")
  check("resume closes the pause row", pauseRows(h.db, id) == [PauseSpan(start: at(10, 2), end: at(10, 5))])
  check("resume twice is refused", h.send("resume")["error"] == "the session is not paused")

  check("extend needs seconds", h.send("extend")["error"] == "seconds is required")
  check("extend refuses 30 s", h.send("extend", ["seconds": 30])["ok"] == false)
  check("extend refuses a fraction", h.send("extend", ["seconds": .double(90.5)])["ok"] == false)
  clock.now = at(10, 6)
  let extended = h.send("extend", ["seconds": 60])["session"]
  check("extend moves the planned end", extended?["plannedEnd"]?.stringValue.flatMap(ISO.parse) == at(10, 11) && extended?["extendedSeconds"] == 60, extended?.serialized() ?? "")
  var row = try! h.db.session(id: Int64(id))!
  check("extend is stored", row.extendedSeconds == 60 && row.extendedEnd == at(10, 11) && row.plannedEnd == at(10, 10))

  clock.now = at(10, 10, 59)
  h.core.secondTick()
  check("no end sheet before the extended end", h.presenter.endSheets.isEmpty && h.lastView?.remainingSeconds == 1)
  clock.now = at(10, 11)
  h.core.secondTick()
  check("the timer reaching the planned end shows the end sheet", h.presenter.endSheets.count == 1 && h.presenter.endSheets.last?.state == "ending")
  check("the end sheet view has nothing remaining", h.presenter.endSheets.last?.remainingSeconds == 0 && h.presenter.endSheets.last?.pausedSeconds == 180)
  row = try! h.db.session(id: Int64(id))!
  check("the end sheet is persisted on the open row", row.endReason == "timer" && row.endedAt == nil)
  check("the tick keeps running at the end sheet", h.core.ticking)
  h.core.secondTick()
  check("the end sheet is shown once", h.presenter.endSheets.count == 1)
  let ending = h.send("status")["session"]
  check("status says ending, by the timer", ending?["state"] == "ending" && ending?["endReason"] == "timer" && ending?["remainingSeconds"] == 0, ending?.serialized() ?? "")
  check("pause at the end sheet is refused", h.send("pause")["error"]?.stringValue?.contains("end sheet") == true)
  check("stop at the end sheet is refused", h.send("stop")["ok"] == false)

  clock.now = at(10, 12)
  let dismissals = h.presenter.dismissals
  let again = h.send("extend", ["seconds": 300])["session"]
  check("extend from the end sheet returns to running", again?["state"] == "running" && again?["endReason"] == .null && again?["extendedSeconds"] == 360, again?.serialized() ?? "")
  check("extend from the end sheet counts from now", again?["plannedEnd"]?.stringValue.flatMap(ISO.parse) == at(10, 17))
  check("extend from the end sheet dismisses it", h.presenter.dismissals == dismissals + 1)
  row = try! h.db.session(id: Int64(id))!
  check("the same row carries on", row.endReason == nil && row.extendedSeconds == 360 && row.extendedEnd == at(10, 17) && row.endedAt == nil)

  clock.now = at(10, 13)
  let stopped = h.send("stop")["session"]
  check("stop goes to the end sheet", stopped?["state"] == "ending" && stopped?["endReason"] == "manual" && h.presenter.endSheets.count == 2)
  check("stop is persisted", (try! h.db.session(id: Int64(id)))?.endReason == "manual")

  clock.now = at(10, 14)
  let finished = h.send("finish", ["rating": 5, "note": "Good"])
  check("finish from a stop", finished["ok"] == true && finished["session"]?["state"] == "finished" && finished["session"]?["endReason"] == "manual", finished.serialized())
  check("finish reports the totals", finished["session"]?["extendedSeconds"] == 360 && finished["session"]?["pausedSeconds"] == 180 && finished["logPending"] == false)
  check("finish ends the tick and clears the view", !h.core.ticking && h.lastView == nil && h.presenter.views.last! == nil)
  check("finish dismisses the sheet", h.presenter.dismissals == dismissals + 2)
  let notes = h.fake.saved.last?.draft.notes ?? ""
  check("the log event counts pauses and the extension", notes.contains("Focused: 11 min of 14 min") && notes.contains("Pauses: 1, 3 min in total") && notes.contains("Ended: manually, after extending 6 min"), notes)
  check("idle after finish", h.send("status")["session"] == .null && h.send("stop")["error"] == "no session is running")
  h.core.secondTick()
  check("a stray tick after finish does nothing", !h.core.ticking && h.lastView == nil)
}

do {
  // The deadline while paused, noticed by a command before the timer fires,
  // then Finish records "timer".
  let clock = Clock(at(11, 0))
  let h = Harness(config: #"{"logCalendarId": "log"}"#, clock: clock)
  let id = h.send("startAdhoc", ["goal": "Short", "durationSeconds": 60, "calendarId": "work"])["session"]?["id"]?.intValue ?? 0
  clock.now = at(11, 0, 30)
  _ = h.send("pause")
  clock.now = at(11, 1, 5)
  let status = h.send("status")["session"]
  check("a command notices the deadline passed while paused", status?["state"] == "ending" && status?["endReason"] == "timer", status?.serialized() ?? "")
  check("the end sheet shows then too", h.presenter.endSheets.count == 1)
  check("the pause closes at the deadline", pauseRows(h.db, id) == [PauseSpan(start: at(11, 0, 30), end: at(11, 1))])
  clock.now = at(11, 2)
  let finished = h.send("finish", ["rating": 3])
  check("finish at the timer's end sheet records timer", finished["session"]?["endReason"] == "timer", finished.serialized())
  check("its log event says the timer ran out", h.fake.saved.last?.draft.notes.contains("Ended: when the timer ran out") == true)
  check("pause with nothing running after finish", h.send("pause")["error"] == "no session is running")
}

do {
  // The UI drives the same transitions through the delegate.
  let clock = Clock(at(12, 0))
  let h = Harness(config: #"{"logCalendarId": "log"}"#, clock: clock)
  check("the core is the presenter's delegate", h.presenter.delegate === h.core)
  _ = h.send("startAdhoc", ["goal": "From the menu bar", "durationSeconds": 1500, "calendarId": "work"])
  clock.now = at(12, 1)
  h.core.presenterPause()
  h.core.drain()
  check("pause from the UI", h.send("status")["session"]?["state"] == "paused" && h.lastView?.state == "paused")
  h.core.presenterPause()
  h.core.drain()
  check("a refused UI call is logged and refreshes the view", h.logs.contains { $0.contains("pause from the UI refused") } && h.lastView?.state == "paused")
  clock.now = at(12, 3)
  h.core.presenterResume()
  h.core.presenterExtend(seconds: 600)
  h.core.drain()
  check("resume and extend from the UI", h.lastView?.state == "running" && h.lastView?.plannedEnd == at(12, 35))
  h.core.presenterStop()
  h.core.drain()
  check("stop from the UI shows the end sheet", h.presenter.endSheets.count == 1 && h.lastView?.state == "ending")
  h.core.presenterFinish(rating: 9, note: nil)
  h.core.drain()
  check("an invalid rating from the UI keeps the sheet", h.lastView?.state == "ending" && h.logs.contains { $0.contains("rating must be 1 to 5") })
  clock.now = at(12, 4)
  h.core.presenterFinish(rating: 4, note: "  Done\n")
  h.core.drain()
  let last = try! h.db.session(id: 1)!
  check("finish from the UI closes the row", last.endedAt == at(12, 4) && last.rating == 4 && last.note == "Done" && last.endReason == "manual", "\(last)")
  check("finish from the UI writes the log event and idles", h.fake.saved.count == 1 && !h.core.ticking && h.lastView == nil)
  let headless = FocusCore(config: ConfigFile(path: h.dir + "/other.json"), db: h.db, calendar: h.fake, secondTimer: false)
  check("a core without a UI does not record views", !(headless.presenter is NullPresenter))
  let replacement = NullPresenter()
  h.core.presenter = replacement
  check("a new presenter is told the state at once", replacement.views.count == 1 && replacement.views[0] == nil && replacement.delegate === h.core)
}

do {
  // Deeplink on: start and finish open Raycast Focus too.
  let clock = Clock(at(13, 0))
  let h = Harness(config: #"{"raycastDeeplink": true}"#, clock: clock)
  _ = h.send("startAdhoc", ["goal": "Side by side", "durationSeconds": 1500, "calendarId": "work"])
  check("start opens raycast://focus/start", h.opened == [RaycastDeeplink.start(goal: "Side by side", durationSeconds: 1500)], "\(h.opened)")
  clock.now = at(13, 5)
  _ = h.send("finish")
  check("finish opens raycast://focus/complete", h.opened.last == RaycastDeeplink.complete && h.opened.count == 2)
}

do {
  // Launch recovery: a stale heartbeat is abandoned, a fresh one carries on.
  let clock = Clock(at(9, 0))
  let first = Harness(config: #"{"logCalendarId": "log"}"#, clock: clock)
  let id = first.send("startAdhoc", ["goal": "Crashed", "durationSeconds": 3600, "calendarId": "work"])["session"]?["id"]?.intValue ?? 0
  clock.now = at(9, 5)
  first.core.tick()
  clock.now = at(9, 6)
  _ = first.send("pause")
  // The helper dies here; it comes back 91 s after the last heartbeat.
  let second = first.relaunch(at: at(9, 6, 31))
  let row = try! second.db.session(id: Int64(id))!
  check("a stale heartbeat is abandoned at launch", row.endReason == "abandoned" && row.endedAt == at(9, 5) && row.rating == nil, "\(row)")
  check("an abandoned pause begun after the heartbeat closes at its start", pauseRows(second.db, id) == [PauseSpan(start: at(9, 6), end: at(9, 6))])
  check("abandoned: no log event, not pending", second.fake.saved.isEmpty && second.send("pending")["waiting"] == [])
  check("abandoned: the sheet is dismissed and the view cleared", second.presenter.dismissals == 1 && second.presenter.views.last! == nil)
  check("abandoned: idle, no tick", second.send("status")["session"] == .null && !second.core.ticking)
  check("abandoned is logged", second.logs.contains { $0.contains("abandoned") })
  check("retry never writes an abandoned session", second.send("retryPending") == ["ok": true, "written": 0, "adopted": 0, "stillWaiting": 0])
}

do {
  let clock = Clock(at(9, 0))
  let first = Harness(clock: clock)
  let id = first.send("startAdhoc", ["goal": "Restarted", "durationSeconds": 3600, "calendarId": "work"])["session"]?["id"]?.intValue ?? 0
  clock.now = at(9, 1)
  _ = first.send("extend", ["seconds": 600])
  clock.now = at(9, 10)
  _ = first.send("pause")
  first.core.tick()
  // Back exactly 90 s after the last heartbeat: still fresh.
  let second = first.relaunch(at: at(9, 11, 30))
  let status = second.send("status")["session"]
  check("a fresh heartbeat resumes the session paused", status?["id"]?.intValue == id && status?["state"] == "paused", status?.serialized() ?? "")
  check("the resumed session keeps its extension", status?["plannedEnd"]?.stringValue.flatMap(ISO.parse) == at(10, 10) && status?["extendedSeconds"] == 600)
  check("the resumed session keeps its pause", status?["pausedSeconds"] == 90)
  check("the resumed session ticks and is shown", second.core.ticking && second.presenter.views.contains { $0?.state == "paused" })
  check("resuming is logged", second.logs.contains { $0.contains("resumed as paused") })
  clock.now = at(9, 12)
  _ = second.send("resume")
  check("resume after a restart closes the same pause row", pauseRows(second.db, id) == [PauseSpan(start: at(9, 10), end: at(9, 12))])

  // Restarted while at the end sheet: the sheet comes back.
  _ = second.send("stop")
  second.core.tick()
  let third = second.relaunch(at: at(9, 12, 20))
  check("a session at the end sheet comes back at it", third.send("status")["session"]?["state"] == "ending" && third.presenter.endSheets.count == 1)
  let late = NullPresenter()
  third.core.presenter = late
  check("a presenter attached later is shown the sheet too", late.endSheets.count == 1 && late.views.count == 1)
  clock.now = at(9, 13)
  check("finish after the restart keeps the stop's reason", third.send("finish")["session"]?["endReason"] == "manual")
}

do {
  // Restarted after the planned end passed during the downtime.
  let clock = Clock(at(9, 0))
  let first = Harness(clock: clock)
  _ = first.send("startAdhoc", ["goal": "Short", "durationSeconds": 60, "calendarId": "work"])
  clock.now = at(9, 0, 50)
  first.core.tick()
  let second = first.relaunch(at: at(9, 1, 30))
  check("a resumed session whose end passed goes to the end sheet", second.send("status")["session"]?["state"] == "ending" && second.presenter.endSheets.count == 1)

  // Heartbeat boundary: 91 s is stale.
  let boundary = Harness(clock: clock)
  clock.now = at(9, 30)
  _ = boundary.send("startAdhoc", ["goal": "Boundary", "durationSeconds": 3600, "calendarId": "work"])
  let stale = boundary.relaunch(at: at(9, 31, 31))
  check("91 s without a heartbeat is abandoned", stale.send("status")["session"] == .null && (try! stale.db.session(id: 1))?.endReason == "abandoned")
}

extension JSONValue {
  subscript(index: Int) -> JSONValue? {
    guard case .array(let items) = self, items.indices.contains(index) else { return nil }
    return items[index]
  }
}

print("\(count - failures)/\(count) passed")
if failures == 0 { print("all passed") }
exit(failures == 0 ? 0 : 1)
