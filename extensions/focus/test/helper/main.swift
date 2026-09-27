// Command-line tests for the focus-daemon logic: rules, log text, recovery,
// config, protocol, sqlite and the command handlers over a fake calendar.
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

  func findEvent(marker: String, in calendarId: String, span: DateInterval) throws -> String? {
    searches.append(span)
    if failSearch { throw Boom() }
    return saved.first {
      $0.calendarId == calendarId && $0.draft.end >= span.start && $0.draft.start <= span.end
        && LogText.notes($0.draft.notes, containMarker: marker)
    }?.id
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
  LogEventDraft(title: "Goal", start: at(14, 0), end: at(14, 30), notes: "x\n\n" + LogText.marker(id))
}

do {
  let store = FakeCalendar()
  let created = Recovery.resolve(WaitingSession(sessionId: 1, logCalendarId: "log", draft: draft(1)), store: store)
  check("creates when no marked event exists", created == .created("log-1"), "\(created)")
  check("searches before creating", store.searches.count == 1)
  check(
    "search spans a day either side",
    store.searches.first == DateInterval(start: at(14, 0).addingTimeInterval(-86_400), end: at(14, 30).addingTimeInterval(86_400)))

  let again = Recovery.resolve(WaitingSession(sessionId: 1, logCalendarId: "log", draft: draft(1)), store: store)
  check("adopts the event saved before", again == .adopted("log-1"), "\(again)")
  check("adopting does not create a duplicate", store.creates == 1 && store.saved.count == 1)

  let other = Recovery.resolve(WaitingSession(sessionId: 2, logCalendarId: "log", draft: draft(2)), store: store)
  check("another session's marker is not adopted", other == .created("log-2"), "\(other)")
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
  check("schema version is 1", db.userVersion == 1, "\(String(describing: db.userVersion))")

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
  check("reopening keeps the schema version", reopened.userVersion == 1)
  check("the database file exists", FileManager.default.fileExists(atPath: path))
}

// MARK: - Commands over a fake calendar

final class Clock {
  var now: Date
  init(_ now: Date) { self.now = now }
}

func makeCore(config: String? = nil, clock: Clock) -> (FocusCore, FakeCalendar, Database, String) {
  let dir = tempDir()
  if let config { try! config.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8) }
  let fake = FakeCalendar()
  let db = try! Database(path: dir + "/focus.db")
  let core = FocusCore(config: ConfigFile(path: dir + "/config.json"), db: db, calendar: fake, clock: { clock.now })
  return (core, fake, db, dir)
}

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
  check("ping", ping["ok"] == true && ping["version"] == "0.1.0" && ping["pid"]?.intValue != nil && ping["calendarAccess"] == "fullAccess", ping.serialized())

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

  let twice = send(core, "start", ["eventId": "E1"])
  check(
    "start refuses while a session runs", twice["ok"] == false
      && twice["error"]?.stringValue?.contains("already running: \"Write report\"") == true
      && twice["session"]?["id"] == session?["id"], twice.serialized())
  let adhocWhileRunning = send(core, "startAdhoc", ["goal": "x", "durationSeconds": 600, "calendarId": "work"])
  check("startAdhoc refuses while a session runs", adhocWhileRunning["ok"] == false)
  check("status returns the running session", send(core, "status")["session"] == session)

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

extension JSONValue {
  subscript(index: Int) -> JSONValue? {
    guard case .array(let items) = self, items.indices.contains(index) else { return nil }
    return items[index]
  }
}

print("\(count - failures)/\(count) passed")
if failures == 0 { print("all passed") }
exit(failures == 0 ? 0 : 1)
