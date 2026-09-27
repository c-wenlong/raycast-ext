// The blocking engine (PLAN.md "Blocking"): decides what is blocked for the
// open session and drives the two sides that enforce it, the app side
// (AppWorkspace: AppBlocker.swift hides apps and shows the block window) and
// the site side (SiteBlocker: the tab watcher and the loopback block page).
//
// FocusCore calls `sessionChanged` from every publish, on its work queue.
// Blocking is on while the session is running or at the end sheet
// ("ending"), off while paused or idle. Turning on mints a token when the
// session is new, resolves the profile, checks the frontmost app and starts
// and polls the site side; turning off stops the site side and closes the
// block window. Snoozes last `snoozeSeconds` per target (a bundle id or a
// host), survive a pause, and end with the session.
//
// Thread safety: all state sits behind `lock`, and nothing is called out
// (workspace, site blocker, recorder, log) while it is held, so a callee may
// call straight back into the engine from any thread. Config is read only
// inside `sessionChanged`, `status` and `snooze(target:)`, which run on
// Core's queue, the only place ConfigFile is used.

import Foundation

/// An app as the engine sees it.
struct RunningApp: Equatable {
  var pid: Int32
  var bundleId: String?
  var name: String
}

/// The app side, implemented by AppBlocker (AppKit) and faked in tests.
/// Calls may come from any thread; the implementation hops to main.
protocol AppWorkspace: AnyObject {
  /// Looks at the frontmost app and hands it to `BlockEngine.appCameForward`.
  func checkFrontmost()
  /// Hides the app and shows the block window for it.
  func block(_ app: RunningApp, snoozeSeconds: Int)
  /// The app was snoozed: close the block window if it shows this app and
  /// unhide it; `activate` also brings it forward (the window's button).
  func unblock(bundleId: String, activate: Bool)
  /// Blocking turned off: close the block window (hidden apps stay hidden).
  func closeBlockWindow()
}

final class BlockEngine: BlockPolicy {
  /// How often, at most, a running session re-reads config for profile edits.
  static let configRefresh: TimeInterval = 5

  private let lock = NSLock()
  private let loadConfig: () -> FocusConfig
  private let log: (String) -> Void
  private let clock: () -> Date
  private let selfPid: Int32
  /// Runs `body` after `seconds` (snooze expiry); tests record it instead.
  var schedule: (TimeInterval, @escaping () -> Void) -> Void = { seconds, body in
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: body)
  }

  // Wiring, set once at launch (main.swift) or by tests.
  private var storedWorkspace: AppWorkspace?
  private var storedSiteBlocker: SiteBlocker?
  private var storedRecorder: ((Int, BlockedAttempt) -> Void)?

  // State for the open session.
  private var view: SessionView?
  private var profileName: String?
  private var resolved: ResolvedProfile?
  private var rules: BlockRules?
  private var on = false
  private var currentToken = ""
  /// Lowercased bundle id → the id as given and the end of its snooze.
  private var snoozedApps: [String: (target: String, until: Date)] = [:]
  /// Normalized host → end of its snooze (covers its subdomains too).
  private var snoozedHosts: [String: Date] = [:]
  /// Bundle ids blocked this session, so `snooze {target}` can tell an app from a host.
  private var blockedApps: Set<String> = []
  private var currentSnoozeSeconds = FocusConfig().snoozeSeconds
  private var currentBrowsers = FocusConfig().browsers
  private var configLoadedAt: Date?
  private var reportedProblems: [String] = []
  private var reportedFallback: String?

  init(
    loadConfig: @escaping () -> FocusConfig, log: @escaping (String) -> Void = { _ in },
    clock: @escaping () -> Date = Date.init, selfPid: Int32 = ProcessInfo.processInfo.processIdentifier
  ) {
    self.loadConfig = loadConfig
    self.log = log
    self.clock = clock
    self.selfPid = selfPid
  }

  /// The daemon's engine: config from `config.json`, re-read on Core's queue.
  convenience init(config: ConfigFile, log: @escaping (String) -> Void, clock: @escaping () -> Date = Date.init) {
    self.init(loadConfig: { config.load() }, log: log, clock: clock)
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  // MARK: Wiring

  /// The app side. Set while blocking is on, it checks the frontmost app at once.
  var workspace: AppWorkspace? {
    get { locked { storedWorkspace } }
    set {
      let isOn = locked { () -> Bool in
        storedWorkspace = newValue
        return on
      }
      if isOn { newValue?.checkFrontmost() }
    }
  }

  /// The site side (the site PR's `makeSiteBlocker`). Set while blocking is
  /// on, it is started and polled at once.
  var siteBlocker: SiteBlocker? {
    get { locked { storedSiteBlocker } }
    set {
      let isOn = locked { () -> Bool in
        storedSiteBlocker = newValue
        return on
      }
      if isOn {
        newValue?.start(policy: self)
        newValue?.pollNow()
      }
    }
  }

  /// Where attempts go: Core stores them in `blocked_attempts` on its queue.
  var recorder: ((Int, BlockedAttempt) -> Void)? {
    get { locked { storedRecorder } }
    set { locked { storedRecorder = newValue } }
  }

  var isOn: Bool { locked { on } }

  // MARK: Session changes (Core's queue)

  private enum Effect {
    case checkFrontmost, startSites, pollSites, stopSites, closeWindow
  }

  /// Called by Core on every publish with the view it shows (nil when idle)
  /// and the session's profile name.
  func sessionChanged(_ view: SessionView?, profileName: String) {
    let now = clock()
    let wantsOn = view.map { $0.state == "running" || $0.state == "ending" } ?? false
    let needsConfig = locked { () -> Bool in
      guard view != nil else { return false }
      let switched = view?.id != self.view?.id
      guard let loaded = configLoadedAt else { return true }
      return switched || wantsOn != on || profileName != self.profileName
        || now.timeIntervalSince(loaded) >= BlockEngine.configRefresh || now < loaded
    }
    let config = needsConfig ? loadConfig() : nil

    var effects: [Effect] = []
    var messages: [String] = []
    lock.lock()
    let switched = view?.id != self.view?.id
    if switched {
      snoozedApps = [:]
      snoozedHosts = [:]
      blockedApps = []
      reportedFallback = nil
      currentToken = view == nil ? "" : BlockEngine.newToken()
      if view == nil {
        resolved = nil
        rules = nil
      }
    }
    self.view = view
    self.profileName = view == nil ? nil : profileName
    var rulesChanged = false
    if let config, view != nil {
      configLoadedAt = now
      currentSnoozeSeconds = config.snoozeSeconds
      currentBrowsers = config.browsers
      if config.profileProblems != reportedProblems {
        reportedProblems = config.profileProblems
        messages += config.profileProblems.map { "config: \($0)" }
      }
      let next = config.resolveProfile(named: profileName)
      if let from = next.fallbackFrom, from != reportedFallback {
        messages.append("blocking: no profile named \"\(from)\"; using \"default\"")
      }
      reportedFallback = next.fallbackFrom
      let nextRules = BlockRules(profile: next.profile, browsers: config.browsers)
      rulesChanged = rules != nil && nextRules != rules
      resolved = next
      rules = nextRules
    }
    let wasOn = on
    if wantsOn && (!wasOn || switched) {
      on = true
      effects = [.checkFrontmost, .startSites, .pollSites]
      if let profile = rules?.profile {
        messages.append(
          "blocking on for session \(view?.id ?? 0): profile \"\(profile.name)\" (\(profile.mode), \(profile.apps.count) apps, \(profile.hosts.count) hosts)")
      }
    } else if wantsOn && rulesChanged {
      effects = [.checkFrontmost, .pollSites]
      messages.append("blocking: profile \"\(rules?.profile.name ?? "")\" changed in config; applied")
    } else if !wantsOn && wasOn {
      on = false
      effects = [.stopSites, .closeWindow]
      messages.append(view == nil ? "blocking off: session over" : "blocking off: session \(view?.state ?? "")")
    }
    pruneSnoozes(now)
    lock.unlock()

    messages.forEach(log)
    perform(effects)
  }

  private func perform(_ effects: [Effect]) {
    guard !effects.isEmpty else { return }
    let (workspace, sites) = locked { (storedWorkspace, storedSiteBlocker) }
    for effect in effects {
      switch effect {
      case .checkFrontmost: workspace?.checkFrontmost()
      case .startSites: sites?.start(policy: self)
      case .pollSites: sites?.pollNow()
      case .stopSites: sites?.stop()
      case .closeWindow: workspace?.closeBlockWindow()
      }
    }
  }

  // MARK: Apps (main thread, from AppBlocker)

  /// An app came forward (or is frontmost when blocking turned on). Blocks
  /// it when the profile says so and it is not snoozed: hides it, shows the
  /// block window and records the attempt. Returns true when it blocked.
  @discardableResult
  func appCameForward(_ app: RunningApp) -> Bool {
    let now = clock()
    let decision = locked { () -> (session: Int, bundleId: String, seconds: Int)? in
      guard on, let rules, let view, app.pid != selfPid, let bundleId = app.bundleId,
        rules.isAppBlocked(bundleId), !isSnoozed(app: bundleId, now)
      else { return nil }
      blockedApps.insert(bundleId.lowercased())
      return (view.id, bundleId, currentSnoozeSeconds)
    }
    guard let decision else { return false }
    workspace?.block(app, snoozeSeconds: decision.seconds)
    record(decision.session, kind: "app", target: decision.bundleId, outcome: "blocked")
    log("blocked app \(decision.bundleId) (\(app.name))")
    return true
  }

  /// True while this app would be blocked if it came forward now.
  func blocksApp(_ bundleId: String?) -> Bool {
    let now = clock()
    return locked {
      guard on, let rules, let bundleId, rules.isAppBlocked(bundleId) else { return false }
      return !isSnoozed(app: bundleId, now)
    }
  }

  /// Snooze from the block window's button: the app may come forward for
  /// `snoozeSeconds`. Returns the snooze's end, or nil when blocking is off.
  @discardableResult
  func snoozeApp(bundleId: String, activate: Bool) -> Date? {
    guard let until = grant(kind: "app", target: bundleId) else { return nil }
    workspace?.unblock(bundleId: bundleId, activate: activate)
    return until
  }

  // MARK: Snoozes

  private func isSnoozed(app bundleId: String, _ now: Date) -> Bool {
    (snoozedApps[bundleId.lowercased()]).map { $0.until > now } ?? false
  }

  private func isSnoozed(host: String, _ now: Date) -> Bool {
    snoozedHosts.contains { $0.value > now && Matching.host(host, matches: $0.key) }
  }

  private func pruneSnoozes(_ now: Date) {
    snoozedApps = snoozedApps.filter { $0.value.until > now }
    snoozedHosts = snoozedHosts.filter { $0.value > now }
  }

  /// Stores a snooze for the running session, records it, and schedules a
  /// re-check for when it ends. Nil when blocking is off.
  private func grant(kind: String, target: String) -> Date? {
    let now = clock()
    let granted = locked { () -> (session: Int, until: Date, seconds: Int)? in
      guard on, let view else { return nil }
      let until = now.addingTimeInterval(TimeInterval(currentSnoozeSeconds))
      if kind == "app" {
        snoozedApps[target.lowercased()] = (target, until)
      } else {
        snoozedHosts[target] = until
      }
      return (view.id, until, currentSnoozeSeconds)
    }
    guard let granted else { return nil }
    record(granted.session, kind: kind, target: target, outcome: "snoozed")
    log("snoozed \(kind) \(target) for \(granted.seconds) s")
    let session = granted.session
    schedule(TimeInterval(granted.seconds) + 0.5) { [weak self] in self?.snoozeEnded(session: session) }
    return granted.until
  }

  /// A snooze ran out: the normal rule applies again to whatever is in front.
  private func snoozeEnded(session: Int) {
    let stillOn = locked { () -> Bool in
      pruneSnoozes(clock())
      return on && view?.id == session
    }
    guard stillOn else { return }
    perform([.checkFrontmost, .pollSites])
  }

  /// First labels that make a dotted name read as a bundle id
  /// ("com.apple.Music") rather than a host.
  static let bundlePrefixes: Set<String> = ["com", "net", "org", "io", "app", "dev", "co", "ru", "de", "desktop", "us"]

  /// `snooze {target, kind?}` from the socket (local and trusted, so no
  /// token). `kind` is "app" or "site"; without it a target is an app when
  /// the session blocked it or the profile lists it as an app, or when it
  /// reads as a bundle id (three or more labels starting "com.", "net.",
  /// ...), and a host otherwise.
  func snooze(target raw: String, kind rawKind: String?) throws -> (kind: String, target: String, until: Date) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw FocusError("target is required") }
    if let rawKind, rawKind != "app", rawKind != "site" { throw FocusError("kind must be \"app\" or \"site\"") }
    let kind =
      rawKind
      ?? locked { () -> String in
        let lower = trimmed.lowercased()
        if blockedApps.contains(lower) || (rules?.apps.contains(lower) ?? false) { return "app" }
        let labels = lower.split(separator: ".")
        if labels.count >= 3, let first = labels.first, BlockEngine.bundlePrefixes.contains(String(first)) {
          return "app"
        }
        return "site"
      }
    var target = trimmed
    if kind == "site" {
      guard let host = Matching.normalizeHost(trimmed) else { throw FocusError("\(trimmed) is not a host") }
      target = host
    }
    let until: Date?
    if kind == "app" {
      until = snoozeApp(bundleId: target, activate: false)
    } else {
      until = grant(kind: "site", target: target)
      if until != nil { siteBlocker?.pollNow() }
    }
    guard let until else { throw FocusError("blocking is off: no session is running") }
    return (kind, target, until)
  }

  // MARK: BlockPolicy (any thread)

  var sessionView: SessionView? { locked { on ? view : nil } }
  var token: String { locked { currentToken } }
  var snoozeSeconds: Int { locked { currentSnoozeSeconds } }
  var browsers: [String] { locked { currentBrowsers } }

  func isBlocked(host: String) -> Bool {
    let now = clock()
    return locked {
      guard on, let rules, rules.isHostBlocked(host), let normalized = Matching.normalizeHost(host) else {
        return false
      }
      return !isSnoozed(host: normalized, now)
    }
  }

  func snooze(host: String, token offered: String) -> Bool {
    let accepted = locked { on && !currentToken.isEmpty && BlockEngine.same(offered, currentToken) }
    guard accepted else {
      log("snooze refused for \(host): wrong token or no running session")
      return false
    }
    guard let normalized = Matching.normalizeHost(host), !Matching.isLoopback(normalized) else {
      log("snooze refused: \"\(host)\" is not a host")
      return false
    }
    return grant(kind: "site", target: normalized) != nil
  }

  func recordBlocked(host: String) {
    guard let normalized = Matching.normalizeHost(host) else { return }
    guard let session = locked({ on ? view?.id : nil }) else { return }
    record(session, kind: "site", target: normalized, outcome: "blocked")
    log("blocked site \(normalized)")
  }

  private func record(_ session: Int, kind: String, target: String, outcome: String) {
    recorder?(session, BlockedAttempt(at: ISO.wholeSeconds(clock()), kind: kind, target: target, outcome: outcome))
  }

  // MARK: Status (the `blocking` command)

  /// `{active, profile, mode, blockedApps, blockedHosts, allowedApps,
  /// allowedHosts, snoozed, snoozeSeconds, profileFallbackFrom}`. Profile and
  /// mode are null only when no session is open; a paused session reports
  /// its profile with `active: false`.
  func statusFields() -> [String: JSONValue] {
    let now = clock()
    return locked {
      pruneSnoozes(now)
      let profile = view == nil ? nil : resolved?.profile
      let allowlist = profile?.mode == "allowlist"
      let apps = JSONValue.array((profile?.apps ?? []).sorted().map(JSONValue.string))
      let hosts = JSONValue.array((profile?.hosts ?? []).sorted().map(JSONValue.string))
      let snoozes =
        snoozedApps.values.map { (kind: "app", target: $0.target, until: $0.until) }
        + snoozedHosts.map { (kind: "site", target: $0.key, until: $0.value) }
      return [
        "active": .bool(on),
        "profile": .optional(profile?.name),
        "profileFallbackFrom": .optional(view == nil ? nil : resolved?.fallbackFrom),
        "mode": .optional(profile?.mode),
        "blockedApps": allowlist ? [] : apps,
        "blockedHosts": allowlist ? [] : hosts,
        "allowedApps": allowlist ? apps : [],
        "allowedHosts": allowlist ? hosts : [],
        "snoozeSeconds": .int(currentSnoozeSeconds),
        "snoozed": .array(
          snoozes.sorted { ($0.until, $0.target) < ($1.until, $1.target) }.map {
            ["kind": .string($0.kind), "target": .string($0.target), "until": .string(ISO.local($0.until))]
          }),
      ]
    }
  }

  // MARK: Tokens

  /// 32 random bytes as 64 hex characters (SystemRandomNumberGenerator is
  /// the system CSPRNG on Darwin).
  static func newToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
  }

  /// Compares without stopping at the first difference.
  static func same(_ a: String, _ b: String) -> Bool {
    let left = Array(a.utf8)
    let right = Array(b.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
  }
}
