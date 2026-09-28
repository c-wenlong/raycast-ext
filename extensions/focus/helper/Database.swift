// ~/.raycast/focus/focus.db through the sqlite3 C API. Only the helper opens
// it. Times are ISO 8601 UTC text (see Dates.swift). The schema is PLAN.md's
// "Database" section; `pragma user_version` holds the schema version (2 adds
// `extended_end`, the planned end with extensions).
//
// An open row (ended_at null) whose end_reason is set is at the end sheet:
// "timer" when its planned end passed, "manual" after a stop. Extending clears
// it again; finishing overwrites it with the final reason.

import Foundation
import SQLite3

struct DatabaseError: Error, LocalizedError {
  var message: String
  var errorDescription: String? { message }
}

struct SessionRow: Equatable {
  var id: Int64
  var sourceEventId: String?
  var calendarId: String
  var goal: String
  var profile: String
  var plannedStart: Date?
  var plannedEnd: Date?
  /// planned_end plus extensions; nil until the first extension.
  var extendedEnd: Date? = nil
  var startedAt: Date
  var endedAt: Date?
  var endReason: String?
  var extendedSeconds: Int
  var rating: Int?
  var note: String?
  var logCalendarId: String?
  var logCalendarName: String?
  var logEventId: String?
  var lastHeartbeat: Date

  /// The end the timer runs to: the extended end, else the planned end.
  var deadline: Date? { extendedEnd ?? plannedEnd }
}

struct NewSession: Equatable {
  var sourceEventId: String?
  var calendarId: String
  var goal: String
  var profile: String
  var plannedStart: Date?
  var plannedEnd: Date?
  var startedAt: Date
}

struct SessionClose: Equatable {
  var endedAt: Date
  var endReason: String
  var rating: Int?
  var note: String?
  var logCalendarId: String?
  var logCalendarName: String?
}

private enum SQLValue {
  case null
  case int(Int64)
  case text(String)

  init(_ text: String?) { self = text.map(SQLValue.text) ?? .null }
  init(_ date: Date?) { self = date.map { .text(ISO.utc($0)) } ?? .null }
  init(_ number: Int?) { self = number.map { .int(Int64($0)) } ?? .null }
}

/// SQLITE_TRANSIENT: sqlite copies bound text before the call returns.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct Row {
  let statement: OpaquePointer

  func text(_ column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
      let pointer = sqlite3_column_text(statement, column)
    else { return nil }
    return String(cString: pointer)
  }

  func int(_ column: Int32) -> Int64? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, column)
  }

  func date(_ column: Int32) -> Date? { text(column).flatMap(ISO.parse) }
}

final class Database {
  static let schemaVersion = 2

  private var handle: OpaquePointer?

  init(path: String) throws {
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
      == SQLITE_OK
    else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
      sqlite3_close_v2(handle)
      throw DatabaseError(message: "could not open \(path): \(message)")
    }
    sqlite3_busy_timeout(handle, 5_000)
    try exec("pragma journal_mode = wal")
    try exec("pragma foreign_keys = on")
    try migrate()
  }

  deinit { sqlite3_close_v2(handle) }

  // MARK: Schema

  private func migrate() throws {
    let version = try scalarInt("pragma user_version") ?? 0
    if version > Database.schemaVersion {
      throw DatabaseError(message: "focus.db has schema \(version), newer than this helper (\(Database.schemaVersion))")
    }
    if version < 1 {
      try transaction {
        try exec(
          """
          create table if not exists sessions (
            id integer primary key,
            source_event_id text,
            calendar_id text not null,
            goal text not null,
            profile text not null,
            planned_start text, planned_end text,
            started_at text not null,
            ended_at text,
            end_reason text,
            extended_seconds integer not null default 0,
            rating integer,
            note text,
            log_calendar_id text,
            log_calendar_name text,
            log_event_id text,
            last_heartbeat text not null
          );
          create table if not exists pauses (
            id integer primary key, session_id integer not null references sessions(id),
            paused_at text not null, resumed_at text
          );
          create table if not exists blocked_attempts (
            id integer primary key, session_id integer not null references sessions(id),
            at text not null, kind text not null,
            target text not null,
            outcome text not null
          );
          pragma user_version = 1;
          """)
      }
    }
    if version < 2 {
      try transaction {
        try exec(
          """
          alter table sessions add column extended_end text;
          pragma user_version = 2;
          """)
      }
    }
  }

  var journalMode: String? { try? scalarText("pragma journal_mode") }
  var userVersion: Int? { (try? scalarInt("pragma user_version")).flatMap { $0 } }

  // MARK: Sessions

  private static let sessionColumns = """
    id, source_event_id, calendar_id, goal, profile, planned_start, planned_end, started_at,
    ended_at, end_reason, extended_seconds, rating, note, log_calendar_id, log_calendar_name,
    log_event_id, last_heartbeat, extended_end
    """

  private static func session(_ row: Row) -> SessionRow {
    SessionRow(
      id: row.int(0) ?? 0,
      sourceEventId: row.text(1),
      calendarId: row.text(2) ?? "",
      goal: row.text(3) ?? "",
      profile: row.text(4) ?? "default",
      plannedStart: row.date(5),
      plannedEnd: row.date(6),
      extendedEnd: row.date(17),
      startedAt: row.date(7) ?? Date(timeIntervalSince1970: 0),
      endedAt: row.date(8),
      endReason: row.text(9),
      extendedSeconds: Int(row.int(10) ?? 0),
      rating: row.int(11).map(Int.init),
      note: row.text(12),
      logCalendarId: row.text(13),
      logCalendarName: row.text(14),
      logEventId: row.text(15),
      lastHeartbeat: row.date(16) ?? Date(timeIntervalSince1970: 0))
  }

  @discardableResult
  func insertSession(_ new: NewSession) throws -> Int64 {
    try run(
      """
      insert into sessions (source_event_id, calendar_id, goal, profile, planned_start, planned_end,
        started_at, last_heartbeat)
      values (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        SQLValue(new.sourceEventId), .text(new.calendarId), .text(new.goal), .text(new.profile),
        SQLValue(new.plannedStart), SQLValue(new.plannedEnd), SQLValue(new.startedAt), SQLValue(new.startedAt),
      ])
    return sqlite3_last_insert_rowid(handle)
  }

  func session(id: Int64) throws -> SessionRow? {
    try rows("select \(Database.sessionColumns) from sessions where id = ?", [.int(id)], Database.session).first
  }

  /// The session that has not ended (there is at most one).
  func openSession() throws -> SessionRow? {
    try rows(
      "select \(Database.sessionColumns) from sessions where ended_at is null order by id desc limit 1", [],
      Database.session
    ).first
  }

  /// Closes an open session and any open pause in one transaction. False if
  /// the session had already ended. A pause never ends before it began.
  func finish(_ id: Int64, _ close: SessionClose) throws -> Bool {
    try transaction {
      let changed = try run(
        """
        update sessions set ended_at = ?, end_reason = ?, rating = ?, note = ?, log_calendar_id = ?,
          log_calendar_name = ?, last_heartbeat = ?
        where id = ? and ended_at is null
        """,
        [
          SQLValue(close.endedAt), .text(close.endReason), SQLValue(close.rating), SQLValue(close.note),
          SQLValue(close.logCalendarId), SQLValue(close.logCalendarName), SQLValue(close.endedAt), .int(id),
        ])
      guard changed == 1 else { return false }
      try run(
        "update pauses set resumed_at = max(paused_at, ?) where session_id = ? and resumed_at is null",
        [SQLValue(close.endedAt), .int(id)])
      return true
    }
  }

  /// Stores the written log event. Only fills an empty slot, so a stale
  /// retry can never overwrite an id already recorded.
  @discardableResult
  func setLogEventId(_ id: Int64, _ eventId: String) throws -> Bool {
    try run(
      "update sessions set log_event_id = ? where id = ? and log_event_id is null", [.text(eventId), .int(id)]) == 1
  }

  /// Finished sessions still owed a log event. Abandoned ones never get one.
  func waitingSessions() throws -> [SessionRow] {
    try rows(
      """
      select \(Database.sessionColumns) from sessions
      where ended_at is not null and log_event_id is null and coalesce(end_reason, '') <> 'abandoned'
      order by id
      """, [], Database.session)
  }

  /// The manual move (PLAN.md "Log event" step 4). Returns the rows moved.
  func moveWaiting(toCalendar calendarId: String, name: String?) throws -> Int {
    try run(
      """
      update sessions set log_calendar_id = ?, log_calendar_name = ?
      where ended_at is not null and log_event_id is null and coalesce(end_reason, '') <> 'abandoned'
      """, [.text(calendarId), SQLValue(name)])
  }

  /// Stores the extension total and the end it gives (open rows only).
  func setExtension(_ id: Int64, seconds: Int, end: Date) throws {
    try run(
      "update sessions set extended_seconds = ?, extended_end = ? where id = ? and ended_at is null",
      [.int(Int64(seconds)), SQLValue(end), .int(id)])
  }

  /// Marks an open row as at the end sheet ("timer" or "manual"), or clears
  /// the mark with nil after an extension.
  func setEnding(_ id: Int64, reason: String?) throws {
    try run("update sessions set end_reason = ? where id = ? and ended_at is null", [SQLValue(reason), .int(id)])
  }

  func heartbeat(_ id: Int64, at date: Date) throws {
    try run("update sessions set last_heartbeat = ? where id = ? and ended_at is null", [SQLValue(date), .int(id)])
  }

  // MARK: Pauses and blocked attempts

  func addPause(_ sessionId: Int64, start: Date, end: Date?) throws {
    try run(
      "insert into pauses (session_id, paused_at, resumed_at) values (?, ?, ?)",
      [.int(sessionId), SQLValue(start), SQLValue(end)])
  }

  /// Ends the session's open pause, never before it began.
  func closePause(_ sessionId: Int64, at date: Date) throws {
    try run(
      "update pauses set resumed_at = max(paused_at, ?) where session_id = ? and resumed_at is null",
      [SQLValue(date), .int(sessionId)])
  }

  func pauses(_ sessionId: Int64) throws -> [PauseSpan] {
    try rows("select paused_at, resumed_at from pauses where session_id = ? order by id", [.int(sessionId)]) {
      PauseSpan(start: $0.date(0) ?? Date(timeIntervalSince1970: 0), end: $0.date(1))
    }
  }

  func addAttempt(_ sessionId: Int64, _ attempt: BlockedAttempt) throws {
    try run(
      "insert into blocked_attempts (session_id, at, kind, target, outcome) values (?, ?, ?, ?, ?)",
      [.int(sessionId), SQLValue(attempt.at), .text(attempt.kind), .text(attempt.target), .text(attempt.outcome)])
  }

  func attempts(_ sessionId: Int64) throws -> [BlockedAttempt] {
    try rows(
      "select at, kind, target, outcome from blocked_attempts where session_id = ? order by id", [.int(sessionId)]
    ) {
      BlockedAttempt(
        at: $0.date(0) ?? Date(timeIntervalSince1970: 0), kind: $0.text(1) ?? "", target: $0.text(2) ?? "",
        outcome: $0.text(3) ?? "")
    }
  }

  // MARK: Stats reads

  /// Finished (and abandoned) sessions that may overlap [start, end): started
  /// before `end` and ended at or after `start`, oldest first.
  func finishedSessions(overlapping start: Date, _ end: Date) throws -> [SessionRow] {
    try rows(
      """
      select \(Database.sessionColumns) from sessions
      where ended_at is not null and started_at < ? and ended_at >= ?
      order by started_at, id
      """, [SQLValue(end), SQLValue(start)], Database.session)
  }

  /// The newest finished (and abandoned) sessions, newest end first.
  func recentSessions(limit: Int) throws -> [SessionRow] {
    try rows(
      """
      select \(Database.sessionColumns) from sessions
      where ended_at is not null order by ended_at desc, id desc limit ?
      """, [.int(Int64(limit))], Database.session)
  }

  /// A session's blocked_attempts rows, and how many of them are snoozes.
  func attemptCounts(_ sessionId: Int64) throws -> (all: Int, snoozed: Int) {
    try rows(
      "select count(*), coalesce(sum(outcome = 'snoozed'), 0) from blocked_attempts where session_id = ?",
      [.int(sessionId)]
    ) { (Int($0.int(0) ?? 0), Int($0.int(1) ?? 0)) }.first ?? (0, 0)
  }

  // MARK: Plumbing

  private func failure(_ context: String) -> DatabaseError {
    DatabaseError(message: "\(context): \(String(cString: sqlite3_errmsg(handle)))")
  }

  func exec(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? "unknown error"
      sqlite3_free(message)
      throw DatabaseError(message: "sqlite: \(text)")
    }
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("begin immediate")
    do {
      let result = try body()
      try exec("commit")
      return result
    } catch {
      try? exec("rollback")
      throw error
    }
  }

  private func withStatement<T>(_ sql: String, _ values: [SQLValue], _ body: (OpaquePointer) throws -> T) throws -> T {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw failure("prepare")
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .null: sqlite3_bind_null(statement, index)
      case .int(let number): sqlite3_bind_int64(statement, index, number)
      case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
      }
    }
    return try body(statement)
  }

  /// Runs a statement to completion and returns the rows it changed.
  @discardableResult
  private func run(_ sql: String, _ values: [SQLValue]) throws -> Int {
    try withStatement(sql, values) { statement in
      let code = sqlite3_step(statement)
      guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure("step") }
      return Int(sqlite3_changes(handle))
    }
  }

  private func rows<T>(_ sql: String, _ values: [SQLValue], _ map: (Row) -> T) throws -> [T] {
    try withStatement(sql, values) { statement in
      var result: [T] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else { throw failure("step") }
        result.append(map(Row(statement: statement)))
      }
      return result
    }
  }

  private func scalarInt(_ sql: String) throws -> Int? {
    try rows(sql, []) { $0.int(0).map(Int.init) }.first ?? nil
  }

  private func scalarText(_ sql: String) throws -> String? {
    try rows(sql, []) { $0.text(0) }.first ?? nil
  }
}
