// Socket protocol types: a small JSON value, the request wrapper and reply
// helpers. One request per connection, newline-delimited JSON both ways.
// Pure Foundation so the test harness can compile it.

import Foundation

/// A JSON value that keeps `null` explicit (Codable structs drop nils).
enum JSONValue: Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  subscript(key: String) -> JSONValue? {
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

  var isNull: Bool { self == .null }

  /// Integers, and doubles with no fractional part (JavaScript sends 4.0 as 4
  /// but a hand-written client might not).
  var intValue: Int? {
    switch self {
    case .int(let value): return value
    case .double(let value) where value.rounded() == value && abs(value) < 1e15: return Int(value)
    default: return nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .int(let value): return Double(value)
    case .double(let value): return value
    default: return nil
    }
  }

  var arrayValue: [JSONValue]? {
    if case .array(let items) = self { return items }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let fields) = self { return fields }
    return nil
  }

  static func parse(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  /// Compact, sorted keys, no escaped slashes: one line on the wire.
  func serialized(pretty: Bool = false) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting =
      pretty
      ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
      : [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}

extension JSONValue: Codable {
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  init(stringLiteral value: String) { self = .string(value) }
  init(integerLiteral value: Int) { self = .int(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
  init(nilLiteral: ()) { self = .null }
  init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }

  /// `.string` or `.null`.
  static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
  static func optional(_ value: Int?) -> JSONValue { value.map(JSONValue.int) ?? .null }
}

/// A failed request: becomes `{"ok": false, "error": message}` plus `extra`.
struct FocusError: Error, Equatable {
  var message: String
  var extra: [String: JSONValue] = [:]

  init(_ message: String, extra: [String: JSONValue] = [:]) {
    self.message = message
    self.extra = extra
  }
}

/// `{"cmd": "...", ...}` with typed field accessors that fail with a message
/// naming the field, so a client bug reads clearly in the reply.
struct Request {
  let cmd: String
  let fields: [String: JSONValue]

  init(line: String) throws {
    let value: JSONValue
    do {
      value = try JSONValue.parse(line)
    } catch {
      throw FocusError("request is not valid JSON")
    }
    guard let fields = value.objectValue else { throw FocusError("request must be a JSON object") }
    guard let cmd = fields["cmd"]?.stringValue, !cmd.isEmpty else {
      throw FocusError("request needs a \"cmd\" string")
    }
    self.cmd = cmd
    self.fields = fields
  }

  init(cmd: String, _ fields: [String: JSONValue] = [:]) {
    self.cmd = cmd
    var all = fields
    all["cmd"] = .string(cmd)
    self.fields = all
  }

  private func present(_ key: String) -> JSONValue? {
    guard let value = fields[key], !value.isNull else { return nil }
    return value
  }

  /// A string field; nil when absent or null. Throws on another type.
  func string(_ key: String) throws -> String? {
    guard let value = present(key) else { return nil }
    guard let text = value.stringValue else { throw FocusError("\(key) must be a string") }
    return text
  }

  /// A string field that must be present and non-blank.
  func requiredString(_ key: String) throws -> String {
    guard let text = try string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { throw FocusError("\(key) is required") }
    return text
  }

  func int(_ key: String) throws -> Int? {
    guard let value = present(key) else { return nil }
    guard let number = value.intValue else { throw FocusError("\(key) must be a whole number") }
    return number
  }

  func double(_ key: String) throws -> Double? {
    guard let value = present(key) else { return nil }
    guard let number = value.doubleValue, number.isFinite else {
      throw FocusError("\(key) must be a number")
    }
    return number
  }
}

/// What the server sends back, plus whether to exit after sending it.
struct Reply {
  var body: JSONValue
  var quit = false

  static func ok(_ fields: [String: JSONValue] = [:]) -> Reply {
    var all = fields
    all["ok"] = true
    return Reply(body: .object(all))
  }

  static func failure(_ error: FocusError) -> Reply {
    var all = error.extra
    all["ok"] = false
    all["error"] = .string(error.message)
    return Reply(body: .object(all))
  }
}
