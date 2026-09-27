import Foundation

/// A blocking profile resolved from config for one session.
struct BlockProfile: Equatable {
  var name: String
  var mode: String              // "blocklist" or "allowlist"
  var apps: Set<String>         // bundle ids, e.g. "com.apple.Music"
  var hosts: Set<String>        // lowercased host suffixes without scheme, e.g. "youtube.com"
}

/// What the site watcher and the block page need from the blocking engine.
/// Every member is safe to call from any thread.
protocol BlockPolicy: AnyObject {
  /// The current session for the block page; nil when nothing is blocked.
  var sessionView: SessionView? { get }
  /// Random per-session token for the block page and /snooze; "" when idle.
  var token: String { get }
  /// Snooze length in seconds from config.
  var snoozeSeconds: Int { get }
  /// Bundle ids of browsers to watch, from config.
  var browsers: [String] { get }
  /// True when this host must be blocked right now (session running or ending, profile matches, not snoozed).
  func isBlocked(host: String) -> Bool
  /// Grants a snooze when the token matches the running session and logs it; false otherwise.
  func snooze(host: String, token: String) -> Bool
  /// Records one blocked site attempt (outcome "blocked").
  func recordBlocked(host: String)
}

/// What the engine drives on the site side.
protocol SiteBlocker: AnyObject {
  /// Start the page server (if not up) and the tab polling; `policy` answers the questions above.
  func start(policy: BlockPolicy)
  /// Stop polling; the page server may stay up.
  func stop()
  /// Poll every watched browser right now (called whenever blocking turns on).
  func pollNow()
}
