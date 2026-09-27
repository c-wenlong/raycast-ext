// ISO 8601 in two flavours: UTC ("...Z") in sqlite so text order is time
// order even after a timezone change, local offset ("...+08:00") on the wire.

import Foundation

enum ISO {
  private static func formatter(_ timeZone: TimeZone, fractional: Bool = false) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter
  }

  static func utc(_ date: Date) -> String {
    formatter(TimeZone(identifier: "UTC")!).string(from: date)
  }

  static func local(_ date: Date, timeZone: TimeZone = .current) -> String {
    formatter(timeZone).string(from: date)
  }

  /// Accepts either flavour, with or without fractional seconds.
  static func parse(_ text: String) -> Date? {
    let utc = TimeZone(identifier: "UTC")!
    return formatter(utc).date(from: text) ?? formatter(utc, fractional: true).date(from: text)
  }

  /// Stored times have whole seconds, so "now" is truncated before use and
  /// a value read back from sqlite equals the one written.
  static func wholeSeconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
  }
}
