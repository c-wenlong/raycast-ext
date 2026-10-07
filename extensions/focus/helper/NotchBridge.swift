// The lease behind the shared notch: while another helper (Notes) holds a
// valid claim and `countdownDisplay` is "notch", Focus's own island steps
// aside and Notes draws the timer and controls instead. The claim is kept
// only in memory and expires a few seconds after the last renew, so a
// crashed or hung host hands the notch back without Focus doing anything.
// Pure Foundation so the test harness can compile it.

import Foundation

/// Bridge protocol version 1. A request is `{cmd:"notchBridge", version:1,
/// op:"status"|"claim"|"renew"|"release", owner:"UUID"}` (owner required for
/// everything but status); replies carry `{ok, bridgeVersion:1, display,
/// claimed, ttlSeconds, session}` where `session` mirrors SessionView or is
/// null. `notchAction` requests are validated against the same claim.
final class NotchBridge {
  static let version = 1
  /// A claim stays valid this long after the last claim/renew.
  static let ttlSeconds: Int = 3

  private let clock: () -> Date
  /// The current claim: its owner and the time it expires.
  private(set) var claim: (owner: String, until: Date)?

  init(clock: @escaping () -> Date = Date.init) {
    self.clock = clock
  }

  /// True while a claim is live and the countdown display is the notch:
  /// the native island is hosted elsewhere.
  func hosted(display: CountdownDisplay) -> Bool {
    display == .notch && claim != nil && claim!.until > clock()
  }

  /// Drops an expired claim (and any claim once the display is not the
  /// notch). Returns true when the claim went away, so callers refresh.
  @discardableResult
  func expireIfNeeded(display: CountdownDisplay) -> Bool {
    guard let claim, display != .notch || claim.until <= clock() else { return false }
    self.claim = nil
    return true
  }

  /// Validates `version:1` and returns it, or throws.
  private func version(_ request: Request) throws {
    guard let version = try request.int("version"), version == NotchBridge.version else {
      throw FocusError("unsupported bridge version")
    }
  }

  /// The actions v1 clients always support; replies advertise these plus
  /// any extras the daemon can do (`pauseFor`, `edit`, `cancel`,
  /// `moveToPanel`, `moveToMenuBar`), so an old or headless daemon still
  /// offers the original controls.
  static let legacyActions = ["pause", "resume", "stop", "extend"]

  /// The fields every bridge reply shares. `actions` lists the `notchAction`
  /// verbs this daemon accepts; missing or malformed, the host keeps the
  /// legacy four.
  func fields(display: CountdownDisplay, session: JSONValue, actions: [String] = NotchBridge.legacyActions) -> [String: JSONValue] {
    expireIfNeeded(display: display)
    return [
      "bridgeVersion": .int(NotchBridge.version),
      "display": .string(display.rawValue),
      "claimed": .bool(hosted(display: display)),
      "ttlSeconds": .int(NotchBridge.ttlSeconds),
      "session": session,
      "actions": .array(actions.map { .string($0) }),
    ]
  }

  /// `notchBridge`: lease bookkeeping, never touches the session itself.
  /// `claimed(owner:)` reports whether the claim moved, so the core can
  /// refresh the UI exactly when hosting changed.
  func handle(
    _ request: Request, display: CountdownDisplay, session: JSONValue,
    actions: [String] = NotchBridge.legacyActions
  ) throws -> Reply {
    try version(request)
    expireIfNeeded(display: display)
    let op = try request.requiredString("op")
    switch op {
    case "status":
      break
    case "claim", "renew", "release":
      let owner = try request.requiredString("owner")
      try apply(op, owner: owner, display: display)
    default:
      throw FocusError("unknown bridge op: \(op)")
    }
    return .ok(fields(display: display, session: session, actions: actions))
  }

  /// claim, renew or release. Only the current owner renews or releases;
  /// a different owner cannot take a live claim. A display that is not the
  /// notch clears any claim instead of holding it.
  private func apply(_ op: String, owner: String, display: CountdownDisplay) throws {
    guard display == .notch else {
      claim = nil
      return
    }
    switch op {
    case "claim":
      if let current = claim, current.until > clock(), current.owner != owner {
        throw FocusError("the notch is claimed by another host")
      }
      claim = (owner, clock().addingTimeInterval(TimeInterval(NotchBridge.ttlSeconds)))
    case "renew":
      guard let current = claim, current.until > clock(), current.owner == owner else {
        throw FocusError("no live claim for this owner")
      }
      claim = (owner, clock().addingTimeInterval(TimeInterval(NotchBridge.ttlSeconds)))
    case "release":
      if let current = claim, current.owner == owner { claim = nil }
    default:
      break
    }
  }

  /// What a validated `notchAction` asks the core to do. `session` is an
  /// ordinary session input; the rest are the additive v1 controls the
  /// core answers itself (timed pause, edit, cancel, display move).
  enum Action: Equatable {
    case session(SessionInput)
    /// "Pause for N seconds": pause now, resume when the timer fires.
    case pauseFor(Int)
    /// Open the Focus Today command (the panel's Edit menu item).
    case edit
    /// End the session now: no rating, no note, no end sheet.
    case cancel
    /// Move the countdown to another display.
    case move(CountdownDisplay)
  }

  /// `notchAction`: a session control from the hosting helper. Returns what
  /// to do, or throws before anything mutates: the lease must be valid, the
  /// display the notch, the session id the current one and the action
  /// supported.
  func action(_ request: Request, display: CountdownDisplay, session: SessionView?, at now: Date) throws
    -> Action
  {
    try version(request)
    guard display == .notch else { throw FocusError("countdown display is not the notch") }
    expireIfNeeded(display: display)
    let owner = try request.requiredString("owner")
    guard let current = claim, current.until > clock(), current.owner == owner else {
      throw FocusError("no live claim for this owner")
    }
    let sessionId = try request.int("sessionId")
    guard let session, sessionId == session.id else {
      throw FocusError("session \(sessionId.map(String.init) ?? "missing") is not the current session")
    }
    switch try request.requiredString("action") {
    case "pause": return .session(.pause(at: now))
    case "resume": return .session(.resume(at: now))
    case "stop": return .session(.stop(at: now))
    case "extend":
      guard let seconds = try request.int("seconds") else { throw FocusError("seconds is required") }
      return .session(.extend(seconds: seconds, at: now))
    case "pauseFor":
      guard let seconds = try request.int("seconds") else { throw FocusError("seconds is required") }
      guard (1...86400).contains(seconds) else { throw FocusError("seconds out of range") }
      return .pauseFor(seconds)
    case "edit": return .edit
    case "cancel": return .cancel
    case "moveToPanel": return .move(.panel)
    case "moveToMenuBar": return .move(.menuBar)
    case let other:
      throw FocusError("unknown bridge action: \(other)")
    }
  }
}
