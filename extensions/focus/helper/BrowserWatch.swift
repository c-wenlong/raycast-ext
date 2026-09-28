import AppKit
import Foundation

// MARK: - Browser tab watcher
//
// Every two seconds while started, asks each watched browser (Chrome, Dia:
// bundle ids from config) for the URL of the active tab of its front window
// over AppleScript. A blocked host sends that tab to the block page with the
// original URL as `redirect`, and the attempt is recorded once.
//
// AppleScript runs in `/usr/bin/osascript` child processes, not NSAppleScript:
// NSAppleScript must only be used from the main thread, and an Apple event to
// a hung browser can wait up to two minutes; a child process keeps both the
// daemon's main thread (menu bar, end sheet) and this queue safe, and is
// killed after a few seconds. The bundle id is validated and written into
// the script (the compiler needs a literal target to load the browser's
// terms); URLs travel as arguments, never spliced into source.
//
// Automation permission is checked first with
// AEDeterminePermissionToAutomateTarget (no prompt). Never asked: one prompt
// per browser is requested on a thread of its own, so waiting for Kai's
// answer never holds up polling or the other browser's prompt (TCC makes even
// the no-prompt check wait while a prompt for the same browser is up, so that
// browser is skipped meanwhile). Denied (-1743) and other failures are logged
// once per browser until that browser works again; polling carries on.

/// The outcome of one osascript run.
struct ScriptResult: Equatable {
  var status: Int32
  var output: String
  var error: String

  /// The AppleScript error number at the end of stderr ("... (-1743)"), if any.
  var errorNumber: Int? {
    guard let open = error.range(of: "(", options: .backwards),
      let close = error.range(of: ")", options: .backwards), open.upperBound <= close.lowerBound
    else { return nil }
    return Int(error[open.upperBound..<close.lowerBound])
  }
}

final class BrowserWatch {
  typealias Runner = (_ source: String, _ arguments: [String]) -> ScriptResult
  /// OSStatus of AEDeterminePermissionToAutomateTarget for a bundle id; `ask` may show the prompt and blocks until answered.
  typealias PermissionCheck = (_ bundleID: String, _ ask: Bool) -> Int32
  /// The block page URL for (host, redirect, token), nil while the server is down.
  typealias PageBuilder = (_ host: String, _ redirect: String, _ token: String) -> URL?

  static let interval: TimeInterval = 2
  /// After sending a tab to the block page, the same URL read again this soon
  /// is the navigation still settling: it is sent again but not recorded again.
  static let settle: TimeInterval = 4
  static let scriptTimeout: TimeInterval = 6

  static let granted: Int32 = 0  // noErr
  static let denied: Int32 = -1743  // errAEEventNotPermitted
  static let notAsked: Int32 = -1744  // errAEEventWouldRequireUserConsent
  static let notRunning: Int32 = -600  // procNotFound

  let queue = DispatchQueue(label: "focus.browser-watch")
  private let log: (String) -> Void
  private let runner: Runner
  private let permission: PermissionCheck
  private let isRunning: (String) -> Bool
  private let clock: () -> Date
  private let page: PageBuilder
  private let isOwnPage: (String) -> Bool
  private let interval: TimeInterval

  // Everything below is touched only on `queue`.
  private weak var policy: BlockPolicy?
  private var timer: DispatchSourceTimer?
  private var lastRedirect: [String: (url: String, at: Date)] = [:]
  private var reported: [String: String] = [:]
  private var asking: Set<String> = []
  private var deferred: [String: Date] = [:]

  init(
    log: @escaping (String) -> Void,
    page: @escaping PageBuilder,
    isOwnPage: @escaping (String) -> Bool,
    runner: @escaping Runner = { BrowserWatch.osascript($0, $1) },
    permission: @escaping PermissionCheck = BrowserWatch.automationPermission,
    isRunning: @escaping (String) -> Bool = BrowserWatch.appIsRunning,
    clock: @escaping () -> Date = Date.init,
    interval: TimeInterval = BrowserWatch.interval
  ) {
    self.log = log
    self.interval = interval
    self.page = page
    self.isOwnPage = isOwnPage
    self.runner = runner
    self.permission = permission
    self.isRunning = isRunning
    self.clock = clock
  }

  // MARK: Lifecycle

  /// Starts (or keeps) polling every two seconds, the first pass at once.
  func start(policy: BlockPolicy) {
    queue.async {
      self.policy = policy
      guard self.timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: self.interval, leeway: .milliseconds(200))
      timer.setEventHandler { [weak self] in self?.pass() }
      timer.resume()
      self.timer = timer
    }
  }

  func stop() {
    queue.async {
      self.timer?.cancel()
      self.timer = nil
      self.policy = nil
      self.lastRedirect = [:]
    }
  }

  /// One pass right away (when blocking turns on). Nothing while stopped.
  func pollNow() {
    queue.async { self.pass() }
  }

  /// One pass on the caller's thread, waiting for it (tests).
  func passAndWait() {
    queue.sync { pass() }
  }

  var isStarted: Bool { queue.sync { timer != nil } }

  // MARK: One pass

  private func pass() {
    guard let policy, timer != nil else { return }
    let token = policy.token
    guard !token.isEmpty else { return }  // no session: nothing can be blocked
    var seen = Set<String>()
    for bundle in policy.browsers where seen.insert(bundle).inserted {
      poll(bundle, policy: policy, token: token)
    }
  }

  private func poll(_ bundle: String, policy: BlockPolicy, token: String) {
    guard Self.isBundleID(bundle) else {
      report(bundle, "\"\(bundle)\" is not a bundle id; not watched")
      return
    }
    guard isRunning(bundle) else { return }
    // While the prompt is up, even the no-prompt check waits for Kai's answer; leave this browser alone.
    guard !asking.contains(bundle) else { return }
    if let until = deferred[bundle] { if clock() < until { return } else { deferred[bundle] = nil } }
    switch permission(bundle, false) {
    case Self.granted:
      break
    case Self.notAsked:
      requestPermission(bundle)
      return
    case Self.denied:
      report(bundle, "\(bundle): Automation permission denied; allow focus-daemon to control it in System Settings > Privacy & Security > Automation")
      return
    case Self.notRunning:
      return
    case let status:
      report(bundle, "\(bundle): Automation permission check returned \(status); trying anyway")
    }

    let read = runner(Self.readScript(bundle), [])
    guard read.status == 0 else {
      failed(bundle, read)
      return
    }
    let url = read.output.trimmingCharacters(in: .whitespacesAndNewlines)
    clearReport(bundle)
    guard !url.isEmpty, !isOwnPage(url), let host = Self.host(of: url), !Self.neverBlocked(host) else { return }
    guard policy.isBlocked(host: host) else { return }
    guard let target = page(host, url, token) else { return }

    let sent = runner(Self.redirectScript(bundle), [url, target.absoluteString])
    guard sent.status == 0 else {
      failed(bundle, sent)
      return
    }
    // "moved": the tab changed between the read and the write; the next pass looks again.
    guard sent.output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { return }
    if let last = lastRedirect[bundle], last.url == url, clock().timeIntervalSince(last.at) < Self.settle { return }
    lastRedirect[bundle] = (url, clock())
    policy.recordBlocked(host: host)
    log("blocked \(host) in \(bundle)")
  }

  /// Shows the Automation prompt for `bundle` once, on a thread of its own
  /// (the call blocks until Kai answers; one browser's prompt never waits on another's).
  private func requestPermission(_ bundle: String) {
    asking.insert(bundle)
    log("\(bundle): asking for Automation permission to read its tabs")
    DispatchQueue.global(qos: .utility).async {
      let status = self.permission(bundle, true)
      self.queue.async {
        self.asking.remove(bundle)
        if status == Self.granted {
          self.log("\(bundle): Automation permission granted")
          self.pass()
        } else if status == Self.denied {
          self.report(bundle, "\(bundle): Automation permission denied; allow focus-daemon to control it in System Settings > Privacy & Security > Automation")
        } else {
          self.deferred[bundle] = self.clock().addingTimeInterval(Self.promptRetry)
          self.report(bundle, "\(bundle): Automation prompt returned \(status); trying again in \(Int(Self.promptRetry)) s")
        }
      }
    }
  }

  private func failed(_ bundle: String, _ result: ScriptResult) {
    let number = result.errorNumber
    if number == -600 || number == -1728 { return }  // quit meanwhile, or no window: nothing to report
    if number == -1743 {
      report(bundle, "\(bundle): Automation permission denied; allow focus-daemon to control it in System Settings > Privacy & Security > Automation")
      return
    }
    let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
    report(bundle, "\(bundle): AppleScript failed (\(number.map(String.init) ?? "exit \(result.status)")): \(detail.prefix(200))")
  }

  /// Logs `message` unless it is what was last logged for `bundle`.
  private func report(_ bundle: String, _ message: String) {
    guard reported[bundle] != message else { return }
    reported[bundle] = message
    log(message)
  }

  private func clearReport(_ bundle: String) {
    if reported.removeValue(forKey: bundle) != nil { log("\(bundle): reading tabs again") }
  }

  // MARK: Pure helpers

  /// The lowercased host of an http(s) URL, without port, brackets or a
  /// trailing dot; nil for any other scheme or no host.
  static func host(of text: String) -> String? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      var host = url.host?.lowercased()
    else { return nil }
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    while host.hasSuffix(".") { host.removeLast() }
    return host.isEmpty ? nil : host
  }

  /// Loopback names are never blocked (the block page itself lives there).
  static func neverBlocked(_ host: String) -> Bool {
    host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
  }

  /// Letters, digits, dots and hyphens: safe to write into a script literal.
  static func isBundleID(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 255
      && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
  }

  /// Prints the active tab's URL of the front window, or "" with no window.
  static func readScript(_ bundle: String) -> String {
    """
    on run argv
      if application id "\(bundle)" is not running then return ""
      with timeout of 3 seconds
        tell application id "\(bundle)"
          if (count of windows) is 0 then return ""
          return URL of active tab of front window
        end tell
      end timeout
    end run
    """
  }

  /// Sends the active tab to `item 2 of argv` if it still shows `item 1`;
  /// prints "ok", "moved" (the tab changed meanwhile) or "gone".
  static func redirectScript(_ bundle: String) -> String {
    """
    on run argv
      set expected to item 1 of argv
      set target to item 2 of argv
      if application id "\(bundle)" is not running then return "gone"
      with timeout of 3 seconds
        tell application id "\(bundle)"
          if (count of windows) is 0 then return "gone"
          set theTab to active tab of front window
          if (URL of theTab) is not expected then return "moved"
          set URL of theTab to target
        end tell
      end timeout
      return "ok"
    end run
    """
  }

  // MARK: System

  static func appIsRunning(_ bundle: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
  }

  /// Automation permission as osascript sees it. The in-process check,
  /// `AEDeterminePermissionToAutomateTarget`, never returns inside the daemon
  /// (verified 2026-09-28: the watcher thread sat in it for good, with or
  /// without a prompt), so the verdict comes from a probe script instead:
  /// exit 0 is granted, -1743 is denied, anything else is passed through.
  /// Without `ask` the cached verdict is returned, or `notAsked` when this
  /// browser has not been probed yet, so the caller runs the probe (which may
  /// block on the prompt) on a thread of its own. A grant is cached for good;
  /// a denial is re-probed after `denialRetry` so a later grant in System
  /// Settings is picked up without a restart.
  static let denialRetry: TimeInterval = 60
  private static let probeLock = NSLock()
  private static var probed: [String: (verdict: Int32, at: Date)] = [:]

  static func automationPermission(_ bundle: String, ask: Bool) -> Int32 {
    probeLock.lock()
    let cached = probed[bundle]
    probeLock.unlock()
    if let cached {
      if cached.verdict == granted { return granted }
      if Date().timeIntervalSince(cached.at) < denialRetry { return cached.verdict }
    }
    guard ask else { return notAsked }
    let verdict = probeVerdict(osascript(probeScript(bundle), [], timeout: nil))
    if verdict == granted || verdict == denied {
      probeLock.lock()
      probed[bundle] = (verdict, Date())
      probeLock.unlock()
    }
    return verdict
  }

  /// The probe is the real tab read: `get name` needs no consent and would
  /// report "granted" before the prompt, and while a prompt is pending every
  /// other Apple Event to that browser times out (-1712).
  static func probeScript(_ bundle: String) -> String {
    readScript(bundle).replacingOccurrences(of: "with timeout of 3 seconds", with: "with timeout of \(Int(promptWait)) seconds")
  }
  /// How long one probe waits for the Automation prompt to be answered.
  static let promptWait: TimeInterval = 900
  /// How long to leave a browser alone after a probe came back undecided.
  static let promptRetry: TimeInterval = 30

  /// Maps a probe run to the permission constants above. Consent was given
  /// when the script ran at all, so "no window" (-1719, -1728) counts as
  /// granted; a timeout (-1712) is the prompt still pending and is not cached.
  static func probeVerdict(_ result: ScriptResult) -> Int32 {
    if result.status == 0 { return granted }
    guard let number = result.errorNumber else { return notRunning }
    if number == -1719 || number == -1728 { return granted }
    return Int32(clamping: number)
  }

  /// Runs `source` with `arguments` in /usr/bin/osascript, killed after `scriptTimeout`.
  static func osascript(_ source: String, _ arguments: [String], timeout: TimeInterval? = scriptTimeout) -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source] + arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return ScriptResult(status: -1, output: "", error: "could not run osascript: \(error)")
    }
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog) }
    // stderr is read on another thread so neither pipe can fill up and stall the child.
    var errorData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      errorData = err.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    let outputData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    watchdog.cancel()
    return ScriptResult(
      status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
      error: String(decoding: errorData, as: UTF8.self))
  }
}
