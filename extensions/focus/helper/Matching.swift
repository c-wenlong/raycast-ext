// Pure matching rules for blocking (PLAN.md "Blocking"): hosts by suffix on
// label boundaries, apps by bundle id, allowlist mode as the inverse with an
// always-allowed set, and the snooze button's label. No AppKit, no state.

import Foundation

enum Matching {
  /// Never hidden, in either mode: Raycast, the Finder, System Settings,
  /// the login window, Spotlight, Control Center, Notification Center, the
  /// helper itself, plus the system prompts that must never disappear under
  /// an allowlist (password dialogs, notification alerts, the Dock and the
  /// system menu extras).
  static let alwaysAllowedApps: Set<String> = [
    "com.raycast.macos",
    "com.apple.finder",
    "com.apple.systempreferences",
    "com.apple.loginwindow",
    "com.apple.spotlight",
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.c-wenlong.focus-daemon",
    "com.apple.securityagent",
    "com.apple.usernotificationcenter",
    "com.apple.coreservices.uiagent",
    "com.apple.dock",
    "com.apple.systemuiserver",
  ]

  /// Hosts that are never blocked: the machine itself (the block page is served from 127.0.0.1).
  static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

  /// A host as matching sees it: lowercased, without scheme, user info, port,
  /// path, trailing dot or a leading "www.". Accepts a bare host or a URL.
  /// Bare IPv6 ("::1") comes back bracketed ("[::1]"). Nil when nothing is left.
  static func normalizeHost(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
    if let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<end]) }
    if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { return nil }
      text = String(text[...close])
    } else if text.filter({ $0 == ":" }).count > 1 {
      text = "[\(text)]"
    } else if let colon = text.firstIndex(of: ":") {
      text = String(text[..<colon])
    }
    while text.hasSuffix(".") { text.removeLast() }
    if text.hasPrefix("www.") { text.removeFirst(4) }
    return text.isEmpty ? nil : text
  }

  /// True when `host` is `suffix` or a subdomain of it: "m.youtube.com"
  /// matches "youtube.com", "notyoutube.com" does not. Both already normalized.
  static func host(_ host: String, matches suffix: String) -> Bool {
    host == suffix || host.hasSuffix("." + suffix)
  }

  static func isLoopback(_ host: String) -> Bool { loopbackHosts.contains(host) }

  /// "Snooze for 3 minutes", "Snooze for 1 minute", "Snooze for 45 seconds",
  /// "Snooze for 2 minutes 30 seconds": from the configured length, never a fixed "3".
  static func snoozeLabel(seconds: Int) -> String {
    let seconds = max(1, seconds)
    func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
    if seconds < 60 { return "Snooze for " + unit(seconds, "second") }
    let minutes = seconds / 60
    let rest = seconds % 60
    return "Snooze for " + unit(minutes, "minute") + (rest == 0 ? "" : " " + unit(rest, "second"))
  }
}

/// A resolved profile turned into the two questions blocking asks: is this
/// app blocked, is this host blocked. Built once per session and profile
/// change; immutable, so any thread may use it.
struct BlockRules: Equatable {
  let profile: BlockProfile
  let allowlist: Bool
  /// Lowercased bundle ids listed by the profile (and its categories).
  let apps: Set<String>
  /// Normalized host suffixes listed by the profile (and its categories).
  let hosts: Set<String>
  /// Lowercased bundle ids of the watched browsers: allowed as apps in
  /// allowlist mode, since their tabs are filtered by host instead.
  let browsers: Set<String>

  init(profile: BlockProfile, browsers: [String]) {
    self.profile = profile
    allowlist = profile.mode == "allowlist"
    apps = Set(profile.apps.map { $0.lowercased() })
    hosts = Set(profile.hosts.compactMap(Matching.normalizeHost))
    self.browsers = Set(browsers.map { $0.lowercased() })
  }

  func isAppBlocked(_ bundleId: String?) -> Bool {
    guard let id = bundleId?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty else { return false }
    if Matching.alwaysAllowedApps.contains(id) { return false }
    if allowlist { return !(apps.contains(id) || browsers.contains(id)) }
    return apps.contains(id)
  }

  func isHostBlocked(_ raw: String) -> Bool {
    guard let host = Matching.normalizeHost(raw), !Matching.isLoopback(host) else { return false }
    let listed = hosts.contains { Matching.host(host, matches: $0) }
    return allowlist ? !listed : listed
  }
}
