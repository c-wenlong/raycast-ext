// ~/.raycast/focus/config.json: written by Focus Settings (TypeScript), read
// by the helper on every request. Decoding is per key and forgiving: a
// missing or mistyped key falls back to its default, unknown keys are
// ignored, and the helper never rewrites a file that exists.

import Foundation

struct FocusConfig: Equatable {
  var startableCalendars: [String] = []
  var logCalendarId: String? = nil
  var logCalendarName: String? = nil
  var calendarProfiles: [String: String] = [:]
  /// Blocking profiles by name (see ProfileSpec). Always has "default": the
  /// built-in one unless config.json defines its own.
  var profiles: [String: ProfileSpec] = ["default": .builtInDefault]
  /// What was wrong with `profiles` in the file, for the log (empty when fine).
  var profileProblems: [String] = []
  var browsers: [String] = ["com.google.Chrome", "company.thebrowser.dia"]
  var snoozeSeconds: Int = 180
  var raycastDeeplink: Bool = false

  init() {}

  init(json: JSONValue) {
    let fields = json.objectValue ?? [:]
    if let items = fields["startableCalendars"]?.arrayValue {
      startableCalendars = items.compactMap(\.stringValue).filter { !$0.isEmpty }
    }
    if let id = fields["logCalendarId"]?.stringValue, !id.isEmpty { logCalendarId = id }
    if let name = fields["logCalendarName"]?.stringValue, !name.isEmpty { logCalendarName = name }
    if let map = fields["calendarProfiles"]?.objectValue {
      calendarProfiles = map.compactMapValues { value in
        guard let name = value.stringValue, !name.isEmpty else { return nil }
        return name
      }
    }
    if let value = fields["profiles"] {
      if let map = value.objectValue {
        for (name, entry) in map.sorted(by: { $0.key < $1.key }) {
          let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { continue }
          switch ProfileSpec.parse(entry) {
          case .success(let spec):
            profiles[trimmed] = spec
            profileProblems += spec.problems.map { "profile \"\(trimmed)\": \($0)" }
          case .failure(let problem): profileProblems.append("profile \"\(trimmed)\": \(problem.message)")
          }
        }
      } else {
        profileProblems.append("profiles is not an object; using the built-in default profile")
      }
    }
    if let items = fields["browsers"]?.arrayValue { browsers = items.compactMap(\.stringValue) }
    if let seconds = fields["snoozeSeconds"]?.intValue, seconds > 0 { snoozeSeconds = seconds }
    if let flag = fields["raycastDeeplink"]?.boolValue { raycastDeeplink = flag }
  }

  var json: JSONValue {
    .object([
      "startableCalendars": .array(startableCalendars.map(JSONValue.string)),
      "logCalendarId": .optional(logCalendarId),
      "logCalendarName": .optional(logCalendarName),
      "calendarProfiles": .object(calendarProfiles.mapValues(JSONValue.string)),
      "profiles": .object(profiles.mapValues(\.json)),
      "browsers": .array(browsers.map(JSONValue.string)),
      "snoozeSeconds": .int(snoozeSeconds),
      "raycastDeeplink": .bool(raycastDeeplink),
    ])
  }

  /// The blocking profile a session on this calendar starts with.
  func profile(for calendarId: String) -> String {
    calendarProfiles[calendarId] ?? "default"
  }
}

/// One entry of `profiles` in config.json:
///
///     "deep": { "mode": "allowlist", "categories": [], "apps": ["com.microsoft.VSCode"], "hosts": ["github.com"] }
///
/// `mode` is "blocklist" (the listed apps and hosts are blocked) or
/// "allowlist" (everything else is). `categories` names built-in categories
/// (Categories.swift) whose apps and hosts are added to the lists. Every key
/// is optional: a missing mode is blocklist, missing lists are empty. Hosts
/// are normalized (scheme, "www.", port and path dropped); unknown keys are
/// ignored here and kept in the file. A list of another type (a string, say)
/// makes the entry malformed.
struct ProfileSpec: Equatable {
  var mode: String = "blocklist"
  var categories: [String] = []
  var apps: [String] = []
  var hosts: [String] = []
  /// Wrong but recoverable details (an unknown mode or category), for the log.
  var problems: [String] = []

  static let modes = ["blocklist", "allowlist"]

  /// The profile used when config.json has no "default": every built-in category, blocklist.
  static let builtInDefault = ProfileSpec(mode: "blocklist", categories: Categories.all.map(\.id))

  static func parse(_ value: JSONValue) -> Result<ProfileSpec, FocusError> {
    guard let fields = value.objectValue else { return .failure(FocusError("is not an object")) }
    var spec = ProfileSpec()
    if let mode = fields["mode"], !mode.isNull {
      if let text = mode.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(), modes.contains(text) {
        spec.mode = text
      } else {
        spec.problems.append("mode \(mode.serialized()) is not \"blocklist\" or \"allowlist\"; using blocklist")
      }
    }
    // A list given as anything but an array makes the whole entry malformed,
    // so a mistyped "default" keeps the built-in one instead of blocking nothing.
    for key in ["categories", "apps", "hosts"] {
      if let list = fields[key], !list.isNull, list.arrayValue == nil {
        return .failure(FocusError("\(key) is not a list"))
      }
    }
    func strings(_ key: String) -> [String] {
      (fields[key]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    for name in strings("categories") {
      let id = name.lowercased()
      if Categories.byId[id] == nil {
        spec.problems.append("unknown category \"\(name)\"")
      } else if !spec.categories.contains(id) {
        spec.categories.append(id)
      }
    }
    spec.apps = strings("apps")
    spec.hosts = strings("hosts").compactMap(Matching.normalizeHost)
    return .success(spec)
  }

  var json: JSONValue {
    .object([
      "mode": .string(mode), "categories": .array(categories.map(JSONValue.string)),
      "apps": .array(apps.map(JSONValue.string)), "hosts": .array(hosts.map(JSONValue.string)),
    ])
  }
}

/// Loads the config file, creating it with defaults when missing. A file that
/// does not parse (half-written, hand-edited) is left alone and the last good
/// config is used instead, so a save in progress never resets the settings.
final class ConfigFile {
  let path: String
  private var lastGood: FocusConfig?
  private var lastProblem: String?
  private let log: (String) -> Void

  init(path: String, log: @escaping (String) -> Void = { _ in }) {
    self.path = path
    self.log = log
  }

  func load() -> FocusConfig {
    let files = FileManager.default
    guard files.fileExists(atPath: path) else {
      let defaults = FocusConfig()
      do {
        try Data((defaults.json.serialized(pretty: true) + "\n").utf8)
          .write(to: URL(fileURLWithPath: path), options: .atomic)
      } catch {
        report("could not write default config to \(path): \(error.localizedDescription)")
      }
      lastGood = defaults
      return defaults
    }
    guard let data = files.contents(atPath: path),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      value.objectValue != nil
    else {
      report("\(path) is not a JSON object; using the last good config")
      return lastGood ?? FocusConfig()
    }
    lastProblem = nil
    let config = FocusConfig(json: value)
    lastGood = config
    return config
  }

  /// Logs a problem once rather than on every request.
  private func report(_ problem: String) {
    guard problem != lastProblem else { return }
    lastProblem = problem
    log(problem)
  }
}
