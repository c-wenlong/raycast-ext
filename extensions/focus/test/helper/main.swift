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
      "snoozeSeconds", "raycastDeeplink", "countdownDisplay", "panelPosition",
    ], "\(written.keys.sorted())")
  check("created config has explicit nulls", written["logCalendarId"] == .null && written["logCalendarName"] == .null)
  check(
    "created config spells out the default profile",
    written["profiles"]?["default"]?["mode"] == "blocklist"
      && written["profiles"]?["default"]?["categories"] == ["social", "messaging", "gaming", "entertainment", "news", "shopping"],
    written["profiles"]?.serialized() ?? "")
  check("the written default reads back the same", FocusConfig(json: .object(written)) == FocusConfig())

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
  check("profiles are read", loaded.profiles["deep"]?.categories == ["social"] && loaded.profiles["deep"]?.mode == "blocklist")
  check("the built-in default stays when config has none", loaded.profiles["default"] == .builtInDefault)
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
  check("schema version is 3", db.userVersion == 3, "\(String(describing: db.userVersion))")

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
  check("reopening keeps the schema version", reopened.userVersion == 3)
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
    try! db.exec("alter table sessions drop column extended_end; alter table sessions drop column log_skipped; pragma user_version = 1;")
    try! db.insertSession(
      NewSession(sourceEventId: nil, calendarId: "work", goal: "Old", profile: "default", plannedStart: at(9, 0), plannedEnd: at(9, 30), startedAt: at(9, 0)))
  }
  let db = try! Database(path: path)
  check("a version 1 database migrates to 3", db.userVersion == 3)
  check("migration adds log_skipped as false", (try! db.session(id: 1))?.logSkipped == false)
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
  check("ping", ping["ok"] == true && ping["version"] == "0.3.0" && ping["pid"]?.intValue != nil && ping["calendarAccess"] == "fullAccess", ping.serialized())

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

  // A session filed under no calendar ("none") is never written to a calendar.
  do {
    let createsBefore = fake.creates
    clock.now = at(15, 0)
    let noCal = send(core, "startAdhoc", ["goal": "Scratch", "durationSeconds": 600, "calendarId": .string(Rules.noCalendar)])
    check("no-calendar ad-hoc session starts", noCal["ok"] == true && noCal["session"]?["calendarId"] == "none", noCal.serialized())
    let noCalId = Int64(noCal["session"]?["id"]?.intValue ?? 0)
    check("no-calendar session shows a title for the UI", (core.presenter as? NullPresenter)?.views.last??.calendarTitle == "No calendar")
    clock.now = at(15, 10)
    let done = send(core, "finish", ["rating": 3])
    check("no-calendar finish skips the log event", done["ok"] == true && done["logSkipped"] == true && done["logPending"] == false && done["logEventId"] == .null, done.serialized())
    check("no-calendar finish created nothing", fake.creates == createsBefore)
    check("no-calendar session is not waiting", send(core, "pending")["waiting"] == [])
    let skipped = try! db.session(id: noCalId)
    check("no-calendar row is marked skipped", skipped?.logSkipped == true && skipped?.logCalendarId == nil, "\(String(describing: skipped))")
    let recent = send(core, "stats")["recent"]?.arrayValue?.first
    check("stats report the skip", recent?["logSkipped"] == true && recent?["logPending"] == false, recent?.serialized() ?? "nil")
  }

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

// MARK: - Blocking: matching

do {
  let normalized: [(String, String?)] = [
    ("YouTube.com", "youtube.com"), ("https://www.youtube.com/watch?v=1", "youtube.com"),
    ("m.youtube.com:443", "m.youtube.com"), ("http://user:pw@Host.com:80/x#y", "host.com"), ("[::1]:8080", "[::1]"),
    ("::1", "[::1]"), ("example.com.", "example.com"), ("www.example.com", "example.com"),
    ("wwwexample.com", "wwwexample.com"), ("  ", nil), ("https://", nil), ("127.0.0.1:5000", "127.0.0.1"),
  ]
  for (raw, expected) in normalized {
    check("normalize \(raw)", Matching.normalizeHost(raw) == expected, "\(String(describing: Matching.normalizeHost(raw)))")
  }
  check("a subdomain matches its suffix", Matching.host("m.youtube.com", matches: "youtube.com"))
  check("the suffix matches itself", Matching.host("youtube.com", matches: "youtube.com"))
  check("suffixes match on label boundaries only", !Matching.host("notyoutube.com", matches: "youtube.com"))
  check("a lookalike parent does not match", !Matching.host("youtube.com.evil.net", matches: "youtube.com"))
  check("a parent does not match a longer suffix", !Matching.host("youtube.com", matches: "m.youtube.com"))

  let block = BlockRules(
    profile: BlockProfile(name: "default", mode: "blocklist", apps: ["com.apple.Music", "com.raycast.macos"], hosts: ["youtube.com", "WWW.X.com"]),
    browsers: ["com.google.Chrome"])
  check("blocklist: a listed host", block.isHostBlocked("youtube.com"))
  check("blocklist: its subdomain", block.isHostBlocked("m.youtube.com"))
  check("blocklist: case, www and port", block.isHostBlocked("WWW.YOUTUBE.COM:443"))
  check("blocklist: a full URL", block.isHostBlocked("https://youtube.com/watch"))
  check("blocklist: a listed host is normalized too", block.isHostBlocked("x.com"))
  check("blocklist: a lookalike is not blocked", !block.isHostBlocked("notyoutube.com"))
  check("blocklist: other hosts pass", !block.isHostBlocked("github.com"))
  check("blocklist: a listed app, any case", block.isAppBlocked("com.apple.music") && block.isAppBlocked("com.apple.Music"))
  check("blocklist: other apps pass", !block.isAppBlocked("com.apple.Safari") && !block.isAppBlocked(nil) && !block.isAppBlocked(""))
  check("blocklist: the browsers are not blocked unless listed", !block.isAppBlocked("com.google.Chrome"))
  check("always allowed beats a listing", !block.isAppBlocked("com.raycast.macos"))

  let allow = BlockRules(
    profile: BlockProfile(name: "deep", mode: "allowlist", apps: ["com.microsoft.VSCode"], hosts: ["github.com"]),
    browsers: ["com.google.Chrome", "company.thebrowser.dia"])
  check("allowlist: a listed app passes", !allow.isAppBlocked("com.microsoft.VSCode"))
  check("allowlist: an unlisted app is blocked", allow.isAppBlocked("com.apple.Safari") && allow.isAppBlocked("com.apple.Music"))
  check("allowlist: the watched browsers pass as apps", !allow.isAppBlocked("com.google.Chrome") && !allow.isAppBlocked("company.thebrowser.dia"))
  for id in [
    "com.raycast.macos", "com.apple.finder", "com.apple.systempreferences", "com.apple.loginwindow", "com.apple.Spotlight",
    "com.apple.controlcenter", "com.apple.notificationcenterui", "com.c-wenlong.focus-daemon", "com.apple.SecurityAgent",
  ] {
    check("allowlist: \(id) is always allowed", !allow.isAppBlocked(id))
  }
  check("allowlist: an app without a bundle id passes", !allow.isAppBlocked(nil))
  check("allowlist: a listed host and its subdomains pass", !allow.isHostBlocked("github.com") && !allow.isHostBlocked("gist.github.com"))
  check("allowlist: everything else is blocked", allow.isHostBlocked("youtube.com") && allow.isHostBlocked("example.org"))
  check("allowlist: a lookalike is blocked", allow.isHostBlocked("notgithub.com"))
  for host in ["localhost", "127.0.0.1", "[::1]", "127.0.0.1:52811", "http://localhost:3000/x", "::1"] {
    check("\(host) is never blocked", !allow.isHostBlocked(host) && !block.isHostBlocked(host))
  }
  check("snooze label 180 s", Matching.snoozeLabel(seconds: 180) == "Snooze for 3 minutes")
  check("snooze label 60 s", Matching.snoozeLabel(seconds: 60) == "Snooze for 1 minute")
  check("snooze label 45 s", Matching.snoozeLabel(seconds: 45) == "Snooze for 45 seconds")
  check("snooze label 1 s", Matching.snoozeLabel(seconds: 1) == "Snooze for 1 second")
  check("snooze label 150 s", Matching.snoozeLabel(seconds: 150) == "Snooze for 2 minutes 30 seconds", Matching.snoozeLabel(seconds: 150))
}

// MARK: - Blocking: categories and profiles

do {
  check("six categories in PLAN's order", Categories.all.map(\.id) == ["social", "messaging", "gaming", "entertainment", "news", "shopping"])
  for category in Categories.all {
    check("\(category.id) hosts are normalized", category.hosts.allSatisfy { Matching.normalizeHost($0) == $0 }, "\(category.hosts)")
    check("\(category.id) has something to block", !(category.apps.isEmpty && category.hosts.isEmpty))
  }
  let builtIn = ProfileSpec.builtInDefault.blockProfile(named: "default")
  check("the built-in default is a blocklist of every category", builtIn.mode == "blocklist" && ProfileSpec.builtInDefault.categories.count == 6)
  for host in ["instagram.com", "x.com", "reddit.com", "youtube.com", "netflix.com", "news.ycombinator.com", "amazon.sg", "chess.com", "linkedin.com"] {
    check("the default blocks \(host)", builtIn.hosts.contains(host))
  }
  for app in ["net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.valvesoftware.steam", "com.apple.TV"] {
    check("the default blocks \(app)", builtIn.apps.contains(app))
  }
  let union = ProfileSpec(mode: "blocklist", categories: ["social", "news"], apps: ["com.example.App"], hosts: ["example.com"])
    .blockProfile(named: "mix")
  check(
    "a profile is the union of its categories and its own lists",
    union.hosts == Set(Categories.social.hosts + Categories.news.hosts + ["example.com"])
      && union.apps == Set(Categories.news.apps + ["com.example.App"]) && union.name == "mix", "\(union)")

  let text = """
    {"profiles": {
      "default": {"mode": "blocklist", "categories": ["social", "Gaming", "bogus"], "apps": ["com.apple.Calculator", 4, ""], "hosts": ["https://www.Example.com/path", "  "]},
      "deep": {"mode": "allowlist", "apps": ["com.microsoft.VSCode"], "hosts": ["github.com"], "future": true},
      "odd": {"mode": "strict"},
      "broken": 5,
      "  ": {}
    }, "calendarProfiles": {"work": "deep", "home": "nope"}}
    """
  let config = FocusConfig(json: try! JSONValue.parse(text))
  let own = config.profiles["default"]
  check("config's own default replaces the built-in one", own?.categories == ["social", "gaming"] && own?.apps == ["com.apple.Calculator"], "\(String(describing: own))")
  check("profile hosts are normalized", own?.hosts == ["example.com"], "\(String(describing: own?.hosts))")
  check("an allowlist profile reads", config.profiles["deep"] == ProfileSpec(mode: "allowlist", apps: ["com.microsoft.VSCode"], hosts: ["github.com"]))
  check("an unknown mode falls back to blocklist", config.profiles["odd"]?.mode == "blocklist")
  check("a malformed profile is dropped", config.profiles["broken"] == nil && config.profiles.count == 3, "\(config.profiles.keys.sorted())")
  check(
    "profile problems are reported", config.profileProblems.contains { $0.contains("unknown category \"bogus\"") }
      && config.profileProblems.contains { $0.contains("\"broken\": is not an object") }
      && config.profileProblems.contains { $0.contains("\"odd\"") }, "\(config.profileProblems)")
  let deep = config.resolveProfile(named: config.profile(for: "work"))
  check("a calendar's profile resolves", deep.profile.name == "deep" && deep.profile.mode == "allowlist" && deep.fallbackFrom == nil)
  let unknown = config.resolveProfile(named: config.profile(for: "home"))
  check("an unknown profile name falls back to default", unknown.profile.name == "default" && unknown.fallbackFrom == "nope")
  check("the fallback is config's own default", unknown.profile.apps.contains("com.apple.Calculator") && unknown.profile.hosts.contains("example.com"))
  let plain = FocusConfig().resolveProfile(named: "default")
  check("no profiles in config: the built-in default", plain.profile == builtIn && plain.fallbackFrom == nil)
  let notObject = FocusConfig(json: ["profiles": ["default"]])
  check("profiles that is not an object: the built-in default", notObject.profiles == ["default": .builtInDefault] && notObject.profileProblems.count == 1)
  let badDefault = FocusConfig(json: try! JSONValue.parse(#"{"profiles": {"default": "all"}}"#))
  check("a malformed default keeps the built-in one", badDefault.profiles["default"] == .builtInDefault)
  check("an empty profiles object keeps the built-in default", FocusConfig(json: ["profiles": [:]]).profiles == FocusConfig().profiles)
  let mistyped = FocusConfig(json: try! JSONValue.parse(#"{"profiles": {"default": {"categories": "social"}, "work": {"apps": "com.apple.Music"}}}"#))
  check("a default with a mistyped list keeps the built-in one", mistyped.profiles["default"] == .builtInDefault)
  check("another profile with a mistyped list is dropped", mistyped.profiles["work"] == nil)
  check("mistyped lists are reported", mistyped.profileProblems.contains { $0.contains("\"default\": categories is not a list") } && mistyped.profileProblems.contains { $0.contains("\"work\": apps is not a list") }, "\(mistyped.profileProblems)")
}

// MARK: - Blocking: the engine

final class FakeWorkspace: AppWorkspace {
  weak var engine: BlockEngine?
  var front: RunningApp?
  var calls: [String] = []
  func checkFrontmost() {
    calls.append("check")
    if let front { engine?.appCameForward(front) }
  }
  func block(_ app: RunningApp, snoozeSeconds: Int) { calls.append("block \(app.bundleId ?? "?") \(snoozeSeconds)") }
  func unblock(bundleId: String, activate: Bool) { calls.append("unblock \(bundleId)\(activate ? " activate" : "")") }
  func closeBlockWindow() { calls.append("close") }
}

final class FakeSites: SiteBlocker {
  var calls: [String] = []
  weak var policy: BlockPolicy?
  func start(policy: BlockPolicy) {
    calls.append("start")
    self.policy = policy
  }
  func stop() { calls.append("stop") }
  func pollNow() { calls.append("poll") }
}

func blockView(_ id: Int, _ state: String) -> SessionView {
  SessionView(
    id: id, goal: "Goal \(id)", state: state, startedAt: at(10, 0), plannedEnd: at(11, 0), remainingSeconds: 60,
    pausedSeconds: 0, calendarTitle: "Work", extendOptions: [])
}

do {
  let clock = Clock(at(10, 0))
  var configJSON = #"{"snoozeSeconds": 120, "browsers": ["com.google.Chrome"], "profiles": {"default": {"categories": ["entertainment"], "apps": ["com.apple.Music"], "hosts": ["example.com"]}, "deep": {"mode": "allowlist", "apps": ["com.microsoft.VSCode"], "hosts": ["github.com"]}}}"#
  var loads = 0
  var logs: [String] = []
  var recorded: [(Int, BlockedAttempt)] = []
  var scheduled: [(TimeInterval, () -> Void)] = []
  let engine = BlockEngine(
    loadConfig: {
      loads += 1
      return FocusConfig(json: try! JSONValue.parse(configJSON))
    }, log: { logs.append($0) }, clock: { clock.now }, selfPid: 999)
  engine.schedule = { scheduled.append(($0, $1)) }
  engine.recorder = { recorded.append(($0, $1)) }
  let workspace = FakeWorkspace()
  workspace.engine = engine
  let sites = FakeSites()
  engine.workspace = workspace
  engine.siteBlocker = sites
  let music = RunningApp(pid: 42, bundleId: "com.apple.Music", name: "Music")

  check("idle: off", !engine.isOn && engine.token == "" && engine.sessionView == nil && !engine.isBlocked(host: "youtube.com"))
  check("idle: wiring does nothing", workspace.calls.isEmpty && sites.calls.isEmpty)
  engine.sessionChanged(nil, profileName: "default")
  check("idle: no config read, no effects", loads == 0 && sites.calls.isEmpty)
  check("idle: snooze refused", !engine.snooze(host: "youtube.com", token: ""))
  check("idle: an app is never blocked", !engine.appCameForward(music))

  workspace.front = music
  engine.sessionChanged(blockView(1, "running"), profileName: "default")
  check("running: blocking on", engine.isOn && engine.sessionView == blockView(1, "running"))
  check("running: frontmost checked, sites started then polled", workspace.calls.prefix(1) == ["check"] && sites.calls == ["start", "poll"], "\(workspace.calls) \(sites.calls)")
  check("running: the site side gets the engine as policy", sites.policy === engine)
  check("running: the frontmost blocked app is blocked", workspace.calls.contains("block com.apple.Music 120"), "\(workspace.calls)")
  check("running: the attempt is recorded", recorded.count == 1 && recorded[0].0 == 1 && recorded[0].1 == BlockedAttempt(at: at(10, 0), kind: "app", target: "com.apple.Music", outcome: "blocked"))
  let token = engine.token
  check("running: a 32-byte hex token", token.count == 64 && token.allSatisfy { $0.isHexDigit }, token)
  check("running: config settings reach the policy", engine.snoozeSeconds == 120 && engine.browsers == ["com.google.Chrome"])
  check("running: profile hosts and categories", engine.isBlocked(host: "m.youtube.com") && engine.isBlocked(host: "example.com") && !engine.isBlocked(host: "github.com"))
  check("running: never loopback", !engine.isBlocked(host: "127.0.0.1"))
  check("running: an allowed app passes", !engine.appCameForward(RunningApp(pid: 43, bundleId: "com.apple.Safari", name: "Safari")))
  check("running: the daemon's own pid passes", !engine.appCameForward(RunningApp(pid: 999, bundleId: "com.apple.Music", name: "Music")))
  check("running: an app without a bundle id passes", !engine.appCameForward(RunningApp(pid: 44, bundleId: nil, name: "Tool")))
  let loadsBefore = loads
  clock.now = at(10, 0, 1)
  engine.sessionChanged(blockView(1, "running"), profileName: "default")
  check("a tick does not re-read config or repeat effects", loads == loadsBefore && sites.calls == ["start", "poll"])

  engine.recordBlocked(host: "https://www.YouTube.com/watch")
  check("recordBlocked stores the normalized host", recorded.last?.1 == BlockedAttempt(at: at(10, 0, 1), kind: "site", target: "youtube.com", outcome: "blocked"))

  clock.now = at(10, 1)
  engine.sessionChanged(blockView(1, "paused"), profileName: "default")
  check("paused: blocking off", !engine.isOn && sites.calls.suffix(1) == ["stop"] && workspace.calls.last == "close")
  check("paused: nothing is blocked", !engine.isBlocked(host: "youtube.com") && !engine.appCameForward(music) && engine.sessionView == nil)
  check("paused: the token is kept", engine.token == token)
  check("paused: snooze refused", !engine.snooze(host: "youtube.com", token: token))
  check("paused: nothing recorded", recorded.count == 2)

  clock.now = at(10, 2)
  workspace.front = nil
  engine.sessionChanged(blockView(1, "running"), profileName: "default")
  check("resumed: on again, same token", engine.isOn && engine.token == token && sites.calls.suffix(2) == ["start", "poll"])
  check("resumed: frontmost checked again", workspace.calls.last == "check")
  let effects = sites.calls.count
  engine.sessionChanged(blockView(1, "ending"), profileName: "default")
  check("ending: still on, no new effects", engine.isOn && sites.calls.count == effects && engine.isBlocked(host: "youtube.com"))
  check("ending: the block page sees the ending session", engine.sessionView?.state == "ending")

  check("a wrong token is refused", !engine.snooze(host: "youtube.com", token: String(repeating: "0", count: 64)))
  check("a missing token is refused", !engine.snooze(host: "youtube.com", token: ""))
  check("a refusal is logged", logs.contains { $0.contains("snooze refused for youtube.com") })
  check("a refusal records nothing", recorded.count == 2)
  check("the right token snoozes", engine.snooze(host: "www.youtube.com", token: token))
  check("the snooze is recorded", recorded.last?.1 == BlockedAttempt(at: at(10, 2), kind: "site", target: "youtube.com", outcome: "snoozed"))
  check("the snoozed host and its subdomains pass", !engine.isBlocked(host: "youtube.com") && !engine.isBlocked(host: "m.youtube.com"))
  check("other hosts stay blocked", engine.isBlocked(host: "netflix.com"))
  check("the snooze schedules a re-check", scheduled.count == 1 && scheduled[0].0 == 120.5)
  clock.now = at(10, 3, 59)
  check("still snoozed just before the end", !engine.isBlocked(host: "youtube.com"))
  clock.now = at(10, 4)
  check("blocked again when the snooze ends", engine.isBlocked(host: "youtube.com"))
  let checks = workspace.calls.count
  scheduled[0].1()
  check("the re-check looks at the frontmost app and the tabs", workspace.calls.count == checks + 1 && sites.calls.last == "poll")

  check("snoozeApp from the window", engine.snoozeApp(bundleId: "com.apple.Music", activate: true) == at(10, 6))
  check("snoozeApp unhides and activates", workspace.calls.last == "unblock com.apple.Music activate")
  check("a snoozed app passes", !engine.appCameForward(music) && !engine.blocksApp("com.apple.Music"))
  check("snoozeApp is recorded", recorded.last?.1 == BlockedAttempt(at: at(10, 4), kind: "app", target: "com.apple.Music", outcome: "snoozed"))

  let status = engine.statusFields()
  check("status: active, profile and mode", status["sessionId"] == 1 && status["active"] == true && status["profile"] == "default" && status["mode"] == "blocklist" && status["profileFallbackFrom"] == .null)
  check("status: blocked lists", status["blockedApps"] == ["com.apple.Music", "com.apple.TV"] && status["blockedHosts"]?.arrayValue?.contains("youtube.com") == true && status["allowedApps"] == [])
  check(
    "status: live snoozes only", status["snoozed"] == [["kind": "app", "target": "com.apple.Music", "until": .string(ISO.local(at(10, 6)))]],
    status["snoozed"]?.serialized() ?? "")

  // The socket's snooze: no token, app or host guessed.
  let listed = try? engine.snooze(target: "com.apple.TV", kind: nil)
  check("socket snooze: a listed bundle id is an app", listed?.kind == "app" && listed?.until == at(10, 6))
  let host = try? engine.snooze(target: "https://Netflix.com/browse", kind: nil)
  check("socket snooze: anything else is a normalized host", host?.kind == "site" && host?.target == "netflix.com" && !engine.isBlocked(host: "www.netflix.com"))
  check("socket snooze: a host snooze polls the tabs", sites.calls.last == "poll")
  let bundle = try? engine.snooze(target: "com.example.Unlisted", kind: nil)
  check("socket snooze: a reverse-DNS name is an app", bundle?.kind == "app")
  let blockedHost = try? engine.snooze(target: "app.example.com", kind: nil)
  check("socket snooze: a host the profile blocks is a site even if it reads like a bundle id", blockedHost?.kind == "site" && !engine.isBlocked(host: "app.example.com"))
  check("socket snooze: kind wins", (try? engine.snooze(target: "com.example.io", kind: "site"))?.kind == "site")
  check("socket snooze: a bad kind", (try? engine.snooze(target: "x.com", kind: "tab")) == nil)
  check("socket snooze: a blank target", (try? engine.snooze(target: " ", kind: nil)) == nil)

  // Profile edits reach a running session within configRefresh.
  engine.sessionChanged(blockView(1, "ending"), profileName: "default")
  configJSON = configJSON.replacingOccurrences(of: #""hosts": ["example.com"]"#, with: #""hosts": ["example.com", "github.com"]"#)
  clock.now = at(10, 4, 2)
  engine.sessionChanged(blockView(1, "ending"), profileName: "default")
  check("an edit is not read before the refresh interval", !engine.isBlocked(host: "github.com"))
  clock.now = at(10, 4, 6)
  let polls = sites.calls.count
  engine.sessionChanged(blockView(1, "ending"), profileName: "default")
  check("an edit is applied after it", engine.isBlocked(host: "github.com") && sites.calls.count == polls + 1 && sites.calls.last == "poll")
  check("the edit is logged", logs.contains { $0.contains("changed in config") })

  // Finish: off, snoozes and token gone.
  engine.sessionChanged(nil, profileName: "default")
  check("finished: off", !engine.isOn && engine.token == "" && engine.sessionView == nil && sites.calls.last == "stop" && workspace.calls.last == "close")
  check("finished: status is null", engine.statusFields()["profile"] == .null && engine.statusFields()["snoozed"] == [] && engine.statusFields()["active"] == false)
  check("finished: socket snooze refused", (try? engine.snooze(target: "x.com", kind: nil)) == nil)
  let stale = scheduled.count
  scheduled.last?.1()
  check("a snooze ending after the session does nothing", workspace.calls.last == "close" && scheduled.count == stale)

  // The next session: a new token, no snoozes carried over.
  clock.now = at(11, 0)
  workspace.front = RunningApp(pid: 50, bundleId: "com.apple.Safari", name: "Safari")
  engine.sessionChanged(blockView(2, "running"), profileName: "deep")
  check("a new session gets a new token", engine.token.count == 64 && engine.token != token)
  check("the last session's token cannot snooze this one", !engine.snooze(host: "snoozed.org", token: token))
  check("the new token can", engine.snooze(host: "snoozed.org", token: engine.token))
  check("allowlist: the frontmost unlisted app is blocked", workspace.calls.contains("block com.apple.Safari 120"), "\(workspace.calls)")
  check("allowlist: listed apps and browsers pass", !engine.appCameForward(RunningApp(pid: 51, bundleId: "com.microsoft.VSCode", name: "Code")) && !engine.appCameForward(RunningApp(pid: 52, bundleId: "com.google.Chrome", name: "Chrome")))
  check("allowlist: Raycast passes", !engine.appCameForward(RunningApp(pid: 53, bundleId: "com.raycast.macos", name: "Raycast")))
  check("allowlist: hosts", !engine.isBlocked(host: "github.com") && engine.isBlocked(host: "example.com") && !engine.isBlocked(host: "localhost"))
  check("allowlist: status lists what is allowed", engine.statusFields()["allowedHosts"] == ["github.com"] && engine.statusFields()["blockedHosts"] == [] && engine.statusFields()["mode"] == "allowlist")
  check("recorded attempts carry the new session id", recorded.last?.0 == 2)

  // A session going straight from one id to another turns the old one's state over.
  engine.sessionChanged(blockView(3, "running"), profileName: "nope")
  check("an unknown profile falls back to default", engine.statusFields()["profile"] == "default" && engine.statusFields()["profileFallbackFrom"] == "nope")
  check("the fallback is logged once", logs.filter { $0.contains("no profile named \"nope\"") }.count == 1)
  clock.now = at(11, 0, 10)
  engine.sessionChanged(blockView(3, "running"), profileName: "nope")
  check("the fallback is not logged again", logs.filter { $0.contains("no profile named \"nope\"") }.count == 1)

  // Wiring a site blocker while on starts it at once (the lead's one line in main.swift).
  let late = FakeSites()
  engine.siteBlocker = late
  check("a site blocker set while on is started and polled", late.calls == ["start", "poll"])
  let lateWorkspace = FakeWorkspace()
  engine.workspace = lateWorkspace
  check("a workspace set while on checks the frontmost app", lateWorkspace.calls == ["check"])
  check("tokens compare exactly", BlockEngine.same("abc", "abc") && !BlockEngine.same("abc", "abd") && !BlockEngine.same("abc", "abcd"))
}

do {
  // The engine inside the core: session transitions drive it, attempts land in sqlite, and the socket commands.
  let clock = Clock(at(15, 0))
  let h = Harness(config: #"{"logCalendarId": "log", "snoozeSeconds": 45, "profiles": {"default": {"categories": ["social"], "apps": ["com.apple.Calculator"]}}}"#, clock: clock)
  let workspace = FakeWorkspace()
  let sites = FakeSites()
  workspace.engine = h.core.blocker
  h.core.blocker.workspace = workspace
  h.core.blocker.siteBlocker = sites
  h.core.blocker.schedule = { _, _ in }
  check("blocking: idle status", h.send("blocking") == ["ok": true, "sessionId": nil, "active": false, "profile": nil, "profileFallbackFrom": nil, "mode": nil, "blockedApps": [], "blockedHosts": [], "allowedApps": [], "allowedHosts": [], "snoozeSeconds": 180, "snoozed": []], h.send("blocking").serialized())
  check("snooze: refused when idle", h.send("snooze", ["target": "x.com"])["error"] == "blocking is off: no session is running")
  check("snooze: needs a target", h.send("snooze")["error"] == "target is required")

  workspace.front = RunningApp(pid: 77, bundleId: "com.apple.Calculator", name: "Calculator")
  let started = h.send("startAdhoc", ["goal": "Blocked", "durationSeconds": 600, "calendarId": "work"])
  let id = started["session"]?["id"]?.intValue ?? 0
  check("start turns blocking on", h.core.blocker.isOn && sites.calls == ["start", "poll"])
  check("start blocks the frontmost app", workspace.calls.contains("block com.apple.Calculator 45"), "\(workspace.calls)")
  let status = h.send("blocking")
  check(
    "blocking: running status", status["active"] == true && status["profile"] == "default" && status["mode"] == "blocklist"
      && status["blockedApps"] == ["com.apple.Calculator"] && status["blockedHosts"]?.arrayValue?.contains("instagram.com") == true
      && status["snoozeSeconds"] == 45, status.serialized())
  h.core.blocker.recordBlocked(host: "instagram.com")
  clock.now = at(15, 1)
  let snoozed = h.send("snooze", ["target": "com.apple.Calculator"])
  check("snooze over the socket", snoozed["ok"] == true && snoozed["kind"] == "app" && snoozed["until"]?.stringValue.flatMap(ISO.parse) == at(15, 1, 45), snoozed.serialized())
  check("snooze over the socket unhides without activating", workspace.calls.last == "unblock com.apple.Calculator")
  check("blocking lists the snooze", h.send("blocking")["snoozed"]?[0]?["target"] == "com.apple.Calculator")
  h.core.drain()
  let attempts = (try! h.db.attempts(Int64(id))).map { "\($0.kind) \($0.target) \($0.outcome)" }
  check("attempts land in sqlite", attempts == ["app com.apple.Calculator blocked", "site instagram.com blocked", "app com.apple.Calculator snoozed"], "\(attempts)")

  _ = h.send("pause")
  check("pause turns blocking off", !h.core.blocker.isOn && sites.calls.last == "stop" && workspace.calls.last == "close")
  check("blocking while paused: profile kept, inactive", h.send("blocking")["active"] == false && h.send("blocking")["profile"] == "default")
  check("paused: the snooze survives", h.send("blocking")["snoozed"]?.arrayValue?.count == 1)
  _ = h.send("resume")
  check("resume turns it back on", h.core.blocker.isOn && sites.calls.suffix(2) == ["start", "poll"])
  _ = h.send("stop")
  check("the end sheet keeps blocking on", h.core.blocker.isOn && h.core.blocker.sessionView?.state == "ending")
  clock.now = at(15, 3)
  let finished = h.send("finish", ["rating": 3])
  check("finish turns blocking off", !h.core.blocker.isOn && h.core.blocker.token == "" && sites.calls.last == "stop")
  check("the log event counts the attempts", h.fake.saved.last?.draft.notes.contains("Blocked attempts: 3 (com.apple.Calculator 2, instagram.com 1), 1 snoozed") == true, h.fake.saved.last?.draft.notes ?? "")
  check("finish succeeded", finished["ok"] == true)

  // A session recovered at launch turns blocking on in the new core's engine.
  _ = h.send("startAdhoc", ["goal": "Again", "durationSeconds": 600, "calendarId": "work"])
  h.core.tick()
  let second = h.relaunch(at: at(15, 3, 30))
  check("a session recovered at launch is blocked", second.core.blocker.isOn && second.core.blocker.token.count == 64)
  _ = second.send("pause")
  let third = second.relaunch(at: at(15, 3, 40))
  check("a session recovered paused is not", !third.core.blocker.isOn && third.send("blocking")["profile"] == "default")
}

extension JSONValue {
  subscript(index: Int) -> JSONValue? {
    guard case .array(let items) = self, items.indices.contains(index) else { return nil }
    return items[index]
  }
}

// MARK: - Stats: aggregation over fixture rows

func statRow(
  _ id: Int64, _ start: Date, _ end: Date?, calendar: String = "work", event: String? = "E", rating: Int? = nil,
  reason: String? = "manual", pauses: [PauseSpan] = []
) -> StatsRow {
  StatsRow(
    id: id, goal: "Goal \(id)", calendarId: calendar, sourceEventId: event, startedAt: start, endedAt: end,
    endReason: reason, rating: rating, pauses: pauses)
}

do {
  let now = at(15, 0)
  let titles = ["work": "Work", "study": "Study", "personal": "Personal", "log": "Focus Log"]
  let names = CalendarNames(access: true, titles: titles)
  let r1 = statRow(1, at(9, 0), at(10, 0), rating: 4, pauses: [PauseSpan(start: at(9, 20), end: at(9, 30))])
  let r2 = statRow(2, at(23, 30, day: 27), at(0, 30), rating: 2)
  let r3 = statRow(3, at(11, 0), at(11, 10), calendar: "bogus", event: nil, reason: "abandoned")
  let running = statRow(4, at(14, 0), nil)
  let backwards = statRow(5, at(12, 0), at(11, 0), calendar: "log")
  let overPaused = statRow(
    6, at(13, 0), at(13, 10), calendar: "personal",
    pauses: [PauseSpan(start: at(13, 0), end: at(13, 8)), PauseSpan(start: at(13, 2), end: at(13, 10))])
  let r7 = statRow(7, at(10, 0, day: 22), at(10, 30, day: 22), calendar: "study", rating: 5)
  let r8 = statRow(8, at(23, 50, day: 21), at(0, 10, day: 22), calendar: "study")
  let old = statRow(9, at(10, 0, day: 20), at(11, 0, day: 20), rating: 1)
  let openPause = statRow(
    10, at(10, 0, day: 26), at(11, 0, day: 26), calendar: "personal",
    pauses: [PauseSpan(start: at(10, 30, day: 26), end: nil)])
  let rows = [old, r8, r7, openPause, r2, r1, r3, backwards, overPaused, running]

  check("stats: focused subtracts pauses", Stats.focusedSeconds(r1) == 3000)
  check("stats: an open pause runs to the end", Stats.focusedSeconds(openPause) == 1800)
  check("stats: an end before the start clamps to zero", Stats.focusedSeconds(backwards) == 0)
  check("stats: overlapping pauses clamp to zero", Stats.focusedSeconds(overPaused) == 0)
  check("stats: a running session has no focused time", Stats.focusedSeconds(running) == 0)
  check("stats: abandoned counts its span", Stats.focusedSeconds(r3) == 600)
  let summary = LogSummary(
    sessionId: 1, sourceCalendarId: "work", sourceEventId: "E", startedAt: r1.startedAt, endedAt: r1.endedAt!,
    endReason: "manual", pauses: r1.pauses)
  check("stats: focused matches the log event's number", Stats.focusedSeconds(r1) == LogText.focusedSeconds(summary))
  let midnight = Stats.dayIntervals(days: 2, now: now)
  check(
    "stats: a session across midnight splits between the days",
    Stats.focusedSeconds(r2, within: midnight[0]) == 1800 && Stats.focusedSeconds(r2, within: midnight[1]) == 1800)
  check(
    "stats: a pause is split at midnight too",
    Stats.focusedSeconds(
      statRow(11, at(23, 0, day: 27), at(1, 0), pauses: [PauseSpan(start: at(23, 50, day: 27), end: at(0, 20))]),
      within: midnight[1]) == 2400)

  let report = Stats.report(windowRows: rows, recent: rows.reversed(), names: names, days: 7, now: now)
  check("stats: today", report.today == StatsTotals(focusedSeconds: 5400, sessions: 5, averageRating: 3), "\(report.today)")
  check("stats: last 7 days", report.week == StatsTotals(focusedSeconds: 11400, sessions: 8, averageRating: 3.67), "\(report.week)")
  check(
    "stats: days are zero-filled, oldest first, split at local midnight",
    report.days.map(\.date) == ["2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28"]
      && report.days.map(\.focusedSeconds) == [2400, 0, 0, 0, 1800, 1800, 5400], "\(report.days)")
  check("stats: days start at local midnight", report.days.last?.start == at(0, 0) && report.days.first?.start == at(0, 0, day: 22))
  check("stats: days carry the weekday", report.days.last?.weekday == local.component(.weekday, from: at(12, 0)))
  check(
    "stats: per calendar, most focused first, ad hoc bucketed",
    report.perCalendar.map { "\($0.calendarTitle) \($0.focusedSeconds) \($0.sessions)" }
      == ["Work 6600 2", "Study 2400 2", "Personal 1800 2", "Ad hoc 600 1", "Focus Log 0 1"], "\(report.perCalendar)")
  check("stats: the ad hoc bucket has its own id", report.perCalendar.first { $0.calendarTitle == "Ad hoc" }?.calendarId == "adhoc")
  check("stats: running sessions are left out of recent", report.recent.map(\.id) == [6, 5, 3, 1, 2, 10, 7, 8, 9], "\(report.recent.map(\.id))")
  check("stats: recent names calendars", report.recentTitles.first == "Personal" && report.recentTitles.contains("Ad hoc"))
  let many = (1...30).map { statRow(Int64($0), at(9, 0), at(9, 1)) }
  check("stats: recent keeps 20", Stats.report(windowRows: [], recent: many, names: names, days: 7, now: now).recent.count == 20)

  let empty = Stats.report(windowRows: [], recent: [], names: names, days: 3, now: now)
  check("stats: no sessions gives zeros and a null rating", empty.today == StatsTotals(focusedSeconds: 0, sessions: 0, averageRating: nil) && empty.days.map(\.focusedSeconds) == [0, 0, 0] && empty.perCalendar.isEmpty)
  check("stats: only running gives zeros", Stats.report(windowRows: [running], recent: [running], names: names, days: 1, now: now).today.sessions == 0)
  check("stats: a session ending at the window start is not in it", !Stats.belongs(statRow(12, at(23, 0, day: 21), at(0, 0, day: 22)), to: Stats.window(days: 7, now: now)))
  check("stats: a zero-length session in the window counts", Stats.belongs(statRow(13, at(9, 0), at(9, 0)), to: Stats.window(days: 1, now: now)))

  // Names without Calendar access.
  let blind = CalendarNames(access: false, titles: [:])
  var logged = statRow(14, at(9, 0), at(10, 0), calendar: "log")
  logged.logCalendarId = "log"
  logged.logCalendarName = "Focus Log (iCloud)"
  check("stats: without access the log calendar uses its stored name", blind.bucket(for: logged) == ("log", "Focus Log (iCloud)"))
  check("stats: without access another calendar is unknown", blind.bucket(for: r1) == ("work", "Unknown calendar"))
  check("stats: without access an ad hoc id cannot be judged", blind.bucket(for: r3).title == "Unknown calendar")
  check("stats: an ad hoc session with no calendar is ad hoc", blind.bucket(for: statRow(15, at(9, 0), at(9, 1), calendar: "", event: nil)) == ("adhoc", "Ad hoc"))
  check("stats: the none sentinel is ad hoc without access", blind.bucket(for: statRow(17, at(9, 0), at(9, 1), calendar: Rules.noCalendar, event: nil)) == ("adhoc", "Ad hoc"))
  check("stats: the none sentinel is ad hoc with access", names.bucket(for: statRow(18, at(9, 0), at(9, 1), calendar: Rules.noCalendar, event: nil)) == ("adhoc", "Ad hoc"))
  check("stats: with access a vanished event calendar is unknown", names.bucket(for: statRow(16, at(9, 0), at(9, 1), calendar: "gone")) == ("gone", "Unknown calendar"))

  // DST: 1 November 2026 is 25 hours long in New York.
  var york = Calendar(identifier: .gregorian)
  york.timeZone = TimeZone(identifier: "America/New_York")!
  let dstNow = york.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
  let dstDays = Stats.dayIntervals(days: 3, now: dstNow, calendar: york)
  check("stats: a DST day is 25 hours", dstDays.map(\.duration) == [86_400, 90_000, 86_400], "\(dstDays)")
  check("stats: DST days are contiguous", dstDays[0].end == dstDays[1].start && dstDays[1].end == dstDays[2].start)
  let dstStart = york.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0))!
  let dstRow = statRow(17, dstStart, dstStart.addingTimeInterval(90_000))
  check("stats: a session filling the DST day counts 25 hours", Stats.days([dstRow], days: 3, now: dstNow, calendar: york).map(\.focusedSeconds) == [0, 90_000, 0])
  check("stats: dates follow the calendar's zone", Stats.days([], days: 3, now: dstNow, calendar: york).map(\.date) == ["2026-10-31", "2026-11-01", "2026-11-02"])
  var buddhist = Calendar(identifier: .buddhist)
  buddhist.timeZone = york.timeZone
  check("stats: dates are Gregorian on a Buddhist calendar", Stats.days([], days: 2, now: dstNow, calendar: buddhist).map(\.date) == ["2026-11-01", "2026-11-02"])
  var hebrew = Calendar(identifier: .hebrew)
  hebrew.timeZone = york.timeZone
  let hebrewDays = Stats.days([dstRow], days: 3, now: dstNow, calendar: hebrew)
  check("stats: a Hebrew calendar keeps Gregorian dates and local days", hebrewDays.map(\.date) == ["2026-10-31", "2026-11-01", "2026-11-02"] && hebrewDays.map(\.focusedSeconds) == [0, 90_000, 0], "\(hebrewDays)")

  let json = Stats.json(report)
  check("stats: json averages", json["week"]?["averageRating"] == .double(3.67) && json["today"]?["averageRating"] == .double(3))
  check("stats: json null rating", Stats.json(empty)["today"] == ["focusedSeconds": 0, "sessions": 0, "averageRating": nil])
}

// MARK: - Stats: the chart

do {
  func days(_ seconds: [Int]) -> [DayTotal] {
    Stats.days([], days: seconds.count, now: at(12, 0)).enumerated().map { index, day in
      var copy = day
      copy.focusedSeconds = seconds[index]
      return copy
    }
  }
  func rects(_ svg: String) -> Int { svg.components(separatedBy: "<rect").count - 1 }
  let week = Chart.svg(days([2400, 0, 0, 0, 1800, 1800, 5400]))
  check("chart: one rect per day", rects(week) == 7)
  check("chart: no script, no external reference", !week.lowercased().contains("<script") && !week.contains("href") && !week.contains("@import"))
  check("chart: size and canvas", week.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"640\" height=\"264\"") && week.contains("fill=\"#1A1A1A\""))
  // 24 px of canvas above the heading (y 50, was 26) and the plot shifted with it: the baseline sits at top 78 + plot 150.
  check("chart: heading clears the top edge", week.contains("y=\"50\" text-anchor=\"start\" font-size=\"17\"") && !week.contains("y=\"26\""))
  check("chart: plot moved down with the heading", week.contains("d=\"M62 228.5H624\"") && !week.contains("d=\"M62 204.5H624\""))
  check("chart: bars in the accent colour, empty days as stubs", week.components(separatedBy: "fill=\"#E85C54\"").count - 1 == 4 && week.components(separatedBy: "fill=\"#3A3A3A\"").count - 1 == 3)
  check("chart: system fonts only", week.contains("font-family=\"-apple-system, Helvetica, sans-serif\""))
  check("chart: weekday labels and today", week.contains(">Today</text>") && week.contains(">\(local.shortWeekdaySymbols[local.component(.weekday, from: at(0, 0, day: 22)) - 1])</text>"))
  check("chart: minutes labels", week.contains(">1h 30m</text>") && week.contains(">40m</text>") && week.contains(">3 h 10 min in total</text>"), week)
  check("chart: an empty week says so", Chart.svg(days([0, 0, 0])).contains("No focused time yet") && rects(Chart.svg(days([0, 0, 0]))) == 3)
  let fortnight = Chart.svg(days(Array(repeating: 45_000, count: 14)))
  check("chart: no column values past a week (the slots are too narrow)", rects(fortnight) == 14 && !fortnight.contains(">12h 30m</text>") && fortnight.components(separatedBy: "fill=\"#EDEDED\"").count - 1 == 2, fortnight)
  check("chart: a week of long days keeps its values", Chart.svg(days(Array(repeating: 45_000, count: 7))).components(separatedBy: ">12h 30m</text>").count - 1 == 7)
  let quarter = Chart.svg(days(Array(repeating: 600, count: 90)))
  check("chart: 90 days still one rect each", rects(quarter) == 90 && !quarter.contains(">Today<"))
  check("chart: compact labels", Chart.compact(0) == "0m" && Chart.compact(2700) == "45m" && Chart.compact(3600) == "1h" && Chart.compact(5100) == "1h 25m")
  check("chart: scale", Chart.scale(maxMinutes: 0) == (60, 30) && Chart.scale(maxMinutes: 90) == (90, 30) && Chart.scale(maxMinutes: 91) == (120, 30) && Chart.scale(maxMinutes: 45) == (45, 15) && Chart.scale(maxMinutes: 500) == (540, 180))
  check("chart: escapes text", Chart.escape("<a & 'b'>") == "&lt;a &amp; &#39;b&#39;&gt;")
}

// MARK: - Stats: the command end to end

do {
  let clock = Clock(at(9, 0))
  let h = Harness(config: #"{"logCalendarId": "log", "logCalendarName": "Focus Log (iCloud)"}"#, clock: clock)
  // Yesterday: an event-calendar session with a pause and an extension, rated 4.
  clock.now = at(22, 0, day: 27)
  let first = h.send("startAdhoc", ["goal": "Write", "durationSeconds": 1800, "calendarId": "work"])["session"]?["id"]?.intValue ?? 0
  clock.now = at(22, 10, day: 27)
  _ = h.send("pause")
  clock.now = at(22, 15, day: 27)
  _ = h.send("resume")
  _ = h.send("extend", ["seconds": 600])
  clock.now = at(22, 40, day: 27)
  _ = h.send("finish", ["rating": 4, "note": "Draft done"])
  try! h.db.addAttempt(Int64(first), BlockedAttempt(at: at(22, 5, day: 27), kind: "site", target: "x.com", outcome: "blocked"))
  try! h.db.addAttempt(Int64(first), BlockedAttempt(at: at(22, 6, day: 27), kind: "site", target: "x.com", outcome: "snoozed"))
  // Today: ad hoc under a calendar EventKit does not know.
  clock.now = at(9, 0)
  _ = h.send("startAdhoc", ["goal": "Inbox", "durationSeconds": 600, "calendarId": "scratch"])
  clock.now = at(9, 10)
  _ = h.send("finish", ["rating": 2])
  // One waiting for a calendar that is gone.
  try! #"{"logCalendarId": "gone", "logCalendarName": "Old Log (Google)"}"#.write(toFile: h.core.config.path, atomically: true, encoding: .utf8)
  _ = h.send("startAdhoc", ["goal": "Read", "durationSeconds": 300, "calendarId": "work"])
  clock.now = at(9, 15)
  _ = h.send("finish", [:])
  // And one still running, which stats must leave out.
  clock.now = at(10, 0)
  _ = h.send("startAdhoc", ["goal": "Running", "durationSeconds": 3600, "calendarId": "work"])
  clock.now = at(10, 30)

  let reply = h.send("stats")
  check("stats command: ok", reply["ok"] == true, reply.serialized())
  check("stats command: today", reply["today"] == ["focusedSeconds": 900, "sessions": 2, "averageRating": .double(2)], reply["today"]?.serialized() ?? "")
  check("stats command: week", reply["week"] == ["focusedSeconds": 3000, "sessions": 3, "averageRating": .double(3)], reply["week"]?.serialized() ?? "")
  check(
    "stats command: per calendar",
    reply["perCalendar"] == [
      ["calendarId": "work", "calendarTitle": "Work", "focusedSeconds": 2400, "sessions": 2],
      ["calendarId": "adhoc", "calendarTitle": "Ad hoc", "focusedSeconds": 600, "sessions": 1],
    ], reply["perCalendar"]?.serialized() ?? "")
  let dayList = reply["days"]?.arrayValue ?? []
  check("stats command: seven days ending today", dayList.count == 7 && dayList.last?["date"] == "2026-09-28" && dayList.last?["focusedSeconds"] == 900 && dayList[5]["focusedSeconds"] == 2100, reply["days"]?.serialized() ?? "")
  let recent = reply["recent"]?.arrayValue ?? []
  check("stats command: recent newest first, running left out", recent.map { $0["goal"]?.stringValue ?? "" } == ["Read", "Inbox", "Write"], "\(recent)")
  let write = recent.last
  check(
    "stats command: a recent session in full",
    write?["id"]?.intValue == first && write?["calendarTitle"] == "Work" && write?["focusedSeconds"] == 2100
      && write?["rating"] == 4 && write?["note"] == "Draft done" && write?["endReason"] == "timer"
      && write?["blockedAttempts"] == 2 && write?["snoozes"] == 1 && write?["logPending"] == false
      && write?["startedAt"]?.stringValue.flatMap(ISO.parse) == at(22, 0, day: 27)
      && write?["endedAt"]?.stringValue.flatMap(ISO.parse) == at(22, 40, day: 27), write?.serialized() ?? "")
  check("stats command: a waiting session is marked", recent.first?["logPending"] == true && recent.first?["rating"] == .null)
  check(
    "stats command: waiting", reply["waiting"]?.arrayValue?.count == 1 && reply["waiting"]?[0]?["goal"] == "Read"
      && reply["waiting"]?[0]?["logCalendarName"] == "Old Log (Google)" && reply["waiting"]?[0]?["sessionId"]?.intValue != nil,
    reply["waiting"]?.serialized() ?? "")
  let chartPath = reply["chartPath"]?.stringValue ?? ""
  check("stats command: chartPath is absolute, under the focus folder", chartPath.hasPrefix("/") && chartPath == h.dir + "/stats/week.svg", chartPath)
  let svg = (try? String(contentsOfFile: chartPath, encoding: .utf8)) ?? ""
  check("stats command: the chart is written", svg.hasPrefix("<svg") && svg.components(separatedBy: "<rect").count - 1 == 7 && !svg.contains("<script"))
  check("stats command: the running session is untouched", h.send("status")["session"]?["state"] == "running")
  let batchedPauses = try! h.db.pauses(forSessions: [Int64(first), Int64(first), 999])
  check("stats reads: pauses by session in one query", batchedPauses.count == 1 && batchedPauses[Int64(first)] == (try! h.db.pauses(Int64(first))))
  let batchedCounts = try! h.db.attemptCounts(forSessions: Array(1...1200).map(Int64.init))
  check("stats reads: attempt counts over many ids in chunks", batchedCounts.count == 1 && batchedCounts[Int64(first)]?.all == 2 && batchedCounts[Int64(first)]?.snoozed == 1)
  check("stats reads: no ids, no rows", (try! h.db.pauses(forSessions: [])).isEmpty && (try! h.db.attemptCounts(forSessions: [])).isEmpty)

  let month = h.send("stats", ["days": 30])
  check("stats command: days picks the window", month["days"]?.arrayValue?.count == 30 && month["days"]?[0]?["date"] == "2026-08-30")
  check("stats command: rewrites the chart", ((try? String(contentsOfFile: chartPath, encoding: .utf8)) ?? "").components(separatedBy: "<rect").count - 1 == 30)
  check("stats command: one day", h.send("stats", ["days": 1])["week"] == h.send("stats", ["days": 1])["today"])
  check("stats command: days 0 refused", h.send("stats", ["days": 0])["error"] == "days must be 1 to 90")
  check("stats command: days 91 refused", h.send("stats", ["days": 91])["ok"] == false)
  check("stats command: days must be a number", h.send("stats", ["days": "7"])["ok"] == false)

  h.fake.accessState = "denied"
  let blind = h.send("stats")
  check("stats command: works without calendar access", blind["ok"] == true && blind["perCalendar"]?[0]?["calendarTitle"] == "Unknown calendar", blind["perCalendar"]?.serialized() ?? "")

  // A folder that cannot hold the chart: the numbers still come back.
  let blocked = tempDir()
  try! "not a folder".write(toFile: blocked + "/stats", atomically: true, encoding: .utf8)
  let other = Harness(clock: clock, dir: blocked)
  let noChart = other.send("stats")
  check("stats command: a chart that cannot be written gives a null path", noChart["ok"] == true && noChart["chartPath"] == .null && other.logs.contains { $0.contains("could not write the stats chart") }, noChart.serialized())
}

print("\(count - failures)/\(count) passed")
if failures == 0 { print("all passed") }
exit(failures == 0 ? 0 : 1)
