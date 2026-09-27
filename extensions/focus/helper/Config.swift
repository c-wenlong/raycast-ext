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
  /// Shape settled in step 3 (blocking); kept verbatim until then.
  var profiles: JSONValue = .object([:])
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
    if let value = fields["profiles"], value.objectValue != nil { profiles = value }
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
      "profiles": profiles,
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
