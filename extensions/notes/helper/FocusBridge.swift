import Foundation

// MARK: - The Focus notch bridge client
//
// Notes talks to focus-daemon over its unix socket (`focus.sock` in
// FOCUS_DIR, default ~/.raycast/focus) with the bridge protocol of
// focus/helper/NotchBridge.swift: `notchBridge` status/claim/renew/release
// keeps a 3-second lease that suppresses only Focus's own island, and
// `notchAction` carries Pause/Resume/Complete/Extend through the daemon's
// ordinary rules. Every request is asynchronous on a worker queue with a
// bounded connect/read/write timeout, one in flight; replies come back on
// the main queue and stale generations (after a mode change, a release or
// a quit) are dropped. A dead socket means a Notes-only notch, never a
// fake countdown; a malformed or refused bridge reply means an
// incompatible daemon, which Notes sidesteps by falling back to floating.

/// A JSON object as the daemon speaks it: object fields, strings, whole
/// numbers, booleans and explicit nulls; just enough to build requests and
/// read replies. Pure Foundation.
enum BridgeValue: Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([BridgeValue])
  case object([String: BridgeValue])

  subscript(key: String) -> BridgeValue? {
    if case .object(let fields) = self { return fields[key] }
    return nil
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var intValue: Int? {
    switch self {
    case .int(let value): return value
    case .double(let value) where value.rounded() == value && abs(value) < 1e15: return Int(value)
    default: return nil
    }
  }

  var arrayValue: [BridgeValue]? {
    if case .array(let items) = self { return items }
    return nil
  }

  var objectValue: [String: BridgeValue]? {
    if case .object(let fields) = self { return fields }
    return nil
  }

  var isNull: Bool { self == .null }

  /// One line on the wire.
  func serialized() -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: foundation, options: [.withoutEscapingSlashes]),
      let text = String(data: data, encoding: .utf8)
    else { return "null" }
    return text
  }

  private var foundation: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .string(let value): return value
    case .array(let items): return items.map { $0.foundation }
    case .object(let fields): return fields.mapValues { $0.foundation }
    }
  }

  static func parse(_ text: String) throws -> BridgeValue {
    let data = Data(text.utf8)
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      throw NSError(domain: "notes-focus-bridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "not JSON"])
    }
    return from(object)
  }

  private static func from(_ object: Any) -> BridgeValue {
    switch object {
    case is NSNull: return .null
    case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): return .bool(value.boolValue)
    case let value as Int: return .int(value)
    case let value as Double: return .double(value)
    case let value as String: return .string(value)
    case let items as [Any]: return .array(items.map(from))
    case let fields as [String: Any]: return .object(fields.mapValues(from))
    default: return .null
    }
  }
}

extension BridgeValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByArrayLiteral, ExpressibleByNilLiteral, ExpressibleByDictionaryLiteral
{
  init(stringLiteral value: String) { self = .string(value) }
  init(integerLiteral value: Int) { self = .int(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
  init(nilLiteral: ()) { self = .null }
  init(arrayLiteral elements: BridgeValue...) { self = .array(elements) }
  init(dictionaryLiteral elements: (String, BridgeValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}


/// A live Focus session as the bridge reports it (mirrors SessionView).
struct FocusSession: Equatable {
  var id: Int
  var goal: String
  var state: String            // "running" or "paused"
  var startedAt: Date
  var plannedEnd: Date
  var remainingSeconds: Int    // at `receivedAt`
  var pausedSeconds: Int
  var calendarTitle: String
  var extendOptions: [Int]
  var pauseStopsClock: Bool
  var receivedAt: Date

  /// The countdown as of `now`: a running session ticks between bridge
  /// replies; a paused one holds what it had. Never negative, never fake.
  func remaining(at now: Date) -> Int {
    guard state == "running" else { return remainingSeconds }
    return max(0, remainingSeconds - Int(now.timeIntervalSince(receivedAt).rounded(.down)))
  }

  /// "mm:ss" (or h:mm:ss past an hour), like Focus's own strip.
  func clock(at now: Date) -> String {
    let seconds = remaining(at: now)
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  init?(json: BridgeValue, at receivedAt: Date) {
    guard json.objectValue != nil, !json.isNull else { return nil }
    guard let id = json["id"]?.intValue, let goal = json["goal"]?.stringValue,
      let state = json["state"]?.stringValue, state == "running" || state == "paused",
      let startedAt = json["startedAt"]?.stringValue.flatMap(FocusBridgeClient.isoDate),
      let plannedEnd = json["plannedEnd"]?.stringValue.flatMap(FocusBridgeClient.isoDate),
      let remaining = json["remainingSeconds"]?.intValue
    else { return nil }
    self.id = id
    self.goal = goal
    self.state = state
    self.startedAt = startedAt
    self.plannedEnd = plannedEnd
    remainingSeconds = remaining
    pausedSeconds = json["pausedSeconds"]?.intValue ?? 0
    calendarTitle = json["calendarTitle"]?.stringValue ?? ""
    extendOptions = json["extendOptions"]?.arrayValue?.compactMap { $0.intValue } ?? [300, 600, 900, 1500]
    pauseStopsClock = json["pauseStopsClock"]?.boolValue ?? false
    self.receivedAt = receivedAt
  }
}

/// What the bridge last told us about the daemon's side of the notch.
struct FocusBridgeStatus: Equatable {
  /// The socket answered and spoke the protocol.
  var present = false
  /// It understood `notchBridge` v1 (an old daemon answers "unknown command").
  var compatible = false
  /// `countdownDisplay` on the daemon's side: "panel", "menuBar" or "notch".
  var display = ""
  /// Our lease is live: Focus's island is suppressed for us.
  var claimed = false
  var session: FocusSession?
}

final class FocusBridgeClient {
  /// The current lease's identity; a fresh UUID every launch.
  private(set) var owner = UUID().uuidString
  let socketPath: String
  /// Replies and state changes arrive here, on the main queue.
  var onStatus: (FocusBridgeStatus) -> Void = { _ in }
  /// An action the daemon refused (or that never landed); `message` is
  /// what the UI surfaces once.
  var onActionProblem: (String) -> Void = { _ in }
  /// The wall clock and reply dispatch; tests drive them by hand.
  var now: () -> Date = Date.init
  var toMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
  /// Set false in tests to skip the worker and inject `receive` results.
  var performsIO = true

  /// Bumped on every mode change/release/quit so late replies from a
  /// previous attachment are dropped.
  private(set) var generation = 0
  private var inflight = false
  private var releaseQueued = false
  private(set) var claimed = false
  private(set) var last = FocusBridgeStatus()

  static let timeout: TimeInterval = 0.5
  static let maxPayload = 64 * 1024
  static let version = 1
  /// The daemon's ISO.local strings carry no fraction; accept both forms.
  static let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
  static let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static func isoDate(_ text: String) -> Date? {
    iso.date(from: text) ?? isoFractional.date(from: text)
  }

  /// `focusDir` defaults to ~/.raycast/focus; FOCUS_DIR overrides it (tests).
  init(focusDir: String? = nil) {
    let dir =
      focusDir
      ?? NSString(string: ProcessInfo.processInfo.environment["FOCUS_DIR"] ?? "~/.raycast/focus")
        .expandingTildeInPath
    socketPath = dir + "/focus.sock"
  }

  /// The 1 Hz driver: `active` is true only while Notes is pinned to the
  /// notch with a healthy UI, which is exactly when renewing is allowed.
  /// One request is ever in flight; a busy second simply waits for the next.
  func tick(active: Bool) {
    if !active { release(); return }
    send(.object(["cmd": "notchBridge", "version": .int(Self.version), "op": .string(claimed ? "renew" : "claim"), "owner": .string(owner)]), kind: .lease)
  }

  /// A status probe that never claims: used while sharing is off but the
  /// daemon's compatibility is being watched for a return to the notch.
  func probe() {
    send(.object(["cmd": "notchBridge", "version": .int(Self.version), "op": .string("status")]), kind: .probe)
  }

  /// Pause, resume, stop (Complete) or extend against the live session.
  func action(_ action: String, session: FocusSession, seconds: Int? = nil) {
    var fields: [String: BridgeValue] = [
      "cmd": "notchAction", "version": .int(Self.version), "owner": .string(owner),
      "sessionId": .int(session.id), "action": .string(action),
    ]
    if let seconds { fields["seconds"] = .int(seconds) }
    send(.object(fields), kind: .action)
  }

  /// Ends the lease, in order behind any request already in flight. The
  /// reply does not matter; the generation bump keeps late renews out.
  func release() {
    claimed = false
    last.claimed = false
    generation += 1
    releaseQueued = true
    if !inflight { flushRelease() }
  }

  private func flushRelease() {
    guard releaseQueued, !inflight else { return }
    releaseQueued = false
    send(.object(["cmd": "notchBridge", "version": .int(Self.version), "op": .string("release"), "owner": .string(owner)]), kind: .release)
  }

  // MARK: Plumbing

  enum Kind { case probe, lease, action, `release` }

  private enum Outgoing {
    static func error(_ message: String) -> Error { NSError(domain: "notes-focus-bridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  }

  private func send(_ body: BridgeValue, kind: Kind) {
    guard performsIO else { return }
    guard !inflight else { return }  // one in flight; the next tick retries
    // A pending release belongs to the old attachment. Finish it before
    // any probe or new claim can reuse this owner's identity.
    if releaseQueued, kind != .release {
      flushRelease()
      return
    }
    guard socketPath.utf8CString.count <= 104 else {
      receive(.failure(Outgoing.error("socket path too long")), kind: kind, expected: generation)
      return
    }
    inflight = true
    let expected = generation
    let path = socketPath
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Self.roundTrip(path: path, body: body)
      self?.toMain { self?.receive(result, kind: kind, expected: expected) }
    }
  }

  /// Applies a worker's outcome on the main queue; a stale generation is
  /// dropped before it can touch anything. `kind` is exposed so tests can
  /// inject results without the socket.
  func receive(_ result: Result<BridgeValue, Error>, kind: Kind, expected: Int? = nil) {
    inflight = false
    // Even a stale reply finishes the outstanding request: it must drain
    // the release queued behind it before a new attachment can claim.
    defer { flushRelease() }
    guard expected == nil || expected == generation else { return }
    var status = last
    switch result {
    case .failure(let error):
      // The socket is gone or unwell: the daemon may still exist and may
      // have restarted without our lease, so the UI steps aside until a
      // probe proves the shared notch safe again.
      claimed = false
      status.present = false
      status.claimed = false
      status.session = nil
      if kind == .action { onActionProblem(error.localizedDescription) }
    case .success(let reply):
      if reply["ok"] == .bool(false), let message = reply["error"]?.stringValue {
        let knownRefusal = message == "no live claim for this owner"
          || message == "the notch is claimed by another host"
          || message == "countdown display is not the notch"
          || (message.hasPrefix("session ") && message.hasSuffix(" is not the current session"))
        let versionMatches = reply["bridgeVersion"] == nil || reply["bridgeVersion"]?.intValue == Self.version
        let protocolMissing = message.hasPrefix("unknown command") || message == "unsupported bridge version"
        if versionMatches && !protocolMissing && (last.compatible || knownRefusal) {
          // A valid refusal is a working protocol, not an old daemon.
          // Drop uncertain ownership and refresh the snapshot on the next tick.
          claimed = false
          status.present = true
          status.compatible = true
          status.claimed = false
          status.session = nil
          if kind == .action { onActionProblem(message) }
          apply(status)
          return
        }
      }
      guard reply["ok"] == .bool(true), reply["bridgeVersion"]?.intValue == Self.version else {
        // It answered but does not speak the bridge (an old daemon:
        // "unknown command"), or the answer makes no sense.
        claimed = false
        status.present = true
        status.compatible = false
        status.claimed = false
        status.session = nil
        if kind == .action, let message = reply["error"]?.stringValue { onActionProblem(message) }
        apply(status)
        return
      }
      status.present = true
      status.compatible = true
      status.display = reply["display"]?.stringValue ?? ""
      status.session = reply["session"].flatMap { FocusSession(json: $0, at: now()) }
      if kind == .release {
        claimed = false
        status.claimed = false
      } else {
        // The wire's claimed flag means *some* host owns the notch. Only
        // an accepted owner-validated lease/action proves that host is us.
        let hosted = reply["claimed"] == .bool(true)
        claimed = hosted && (kind == .lease || kind == .action || claimed)
        status.claimed = claimed
      }
    }
    apply(status)
  }

  private func apply(_ status: FocusBridgeStatus) {
    let changed = status != last
    last = status
    if changed { onStatus(status) }
  }

  /// One newline-delimited request over the unix socket, bounded: the
  /// path fits sun_path, sends handle partial writes, the read stops at
  /// the newline or maxPayload, and every syscall has a timeout. Returns
  /// the reply parsed as JSON.
  static func roundTrip(path: String, body: BridgeValue) -> Result<BridgeValue, Error> {
    guard path.utf8CString.count <= 104 else { return .failure(Outgoing.error("socket path too long")) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failure(Outgoing.error("socket failed")) }
    defer { close(fd) }
    var tv = timeval(tv_sec: 0, tv_usec: Int32(timeout * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutablePointer(to: &address.sun_path) { field in
      field.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
        for (offset, byte) in bytes.prefix(103).enumerated() { destination[offset] = byte }
      }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { return .failure(Outgoing.error("no daemon listening")) }
    var line = body.serialized() + "\n"
    let sent = line.withUTF8 { buffer -> Bool in
      var offset = 0
      while offset < buffer.count {
        let wrote = buffer.baseAddress.map { Darwin.send(fd, $0 + offset, buffer.count - offset, 0) } ?? -1
        guard wrote > 0 else { return false }
        offset += wrote
      }
      return true
    }
    guard sent else { return .failure(Outgoing.error("could not write to the daemon")) }
    var reply = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while !reply.contains(0x0A), reply.count < maxPayload {
      let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
      guard count > 0 else { break }
      reply.append(contentsOf: chunk[0..<count])
    }
    guard let newline = reply.firstIndex(of: 0x0A) else {
      return .failure(Outgoing.error("the daemon did not reply"))
    }
    let text = String(decoding: reply[..<newline], as: UTF8.self)
    guard let parsed = try? BridgeValue.parse(text) else {
      return .failure(Outgoing.error("the daemon's reply was not JSON"))
    }
    return .success(parsed)
  }
}
