// The Focus Stats bar chart: focused time per day as an SVG string. Pure, so
// its markup is tested; FocusCore writes it to <focus dir>/stats/week.svg on
// every `stats` request and Focus Stats shows that file in its Detail pane.
//
// Dark like the rest of the extension: the #1A1A1A canvas of the end sheet,
// columns in the accent colour (BlockPage.accent), text in neutral inks, a
// hairline grid. Columns are at most 24 px wide with a 4 px rounded top and a
// square foot on the baseline (the rounding below the baseline is clipped).
// A day with no focused time still gets its column, a 2 px stub in grey, so
// the chart always has exactly one <rect> per day. System fonts only, no
// script, nothing fetched.

import Foundation

enum Chart {
  static let width = 640.0
  static let height = 240.0
  static let canvas = "#1A1A1A"
  static let accent = "#E85C54"
  static let ink = "#EDEDED"
  static let muted = "#8C8C8C"
  static let grid = "#2E2E2E"
  static let stub = "#3A3A3A"
  static let font = "-apple-system, Helvetica, sans-serif"

  private static let left = 56.0
  /// Where the heading starts: the page margin, left of the tick labels.
  private static let margin = 16.0
  private static let right = 16.0
  private static let top = 44.0
  private static let bottom = 30.0
  private static let maxBar = 24.0
  private static let corner = 4.0

  /// "0m", "45m", "1h", "1h 25m": short enough for an axis tick or a column cap.
  static func compact(_ seconds: Int) -> String {
    let minutes = Int((Double(max(0, seconds)) / 60).rounded())
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(minutes)m" }
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
  }

  /// The axis top and tick step in minutes: the smallest step from a fixed
  /// list that covers `maxMinutes` in at most four steps.
  static func scale(maxMinutes: Double) -> (top: Double, step: Double) {
    let steps: [Double] = [5, 10, 15, 20, 30, 60, 90, 120, 180, 240, 360, 480, 720, 1440]
    guard maxMinutes > 0 else { return (60, 30) }
    let step = steps.first { $0 * 4 >= maxMinutes } ?? steps.last!
    return ((maxMinutes / step).rounded(.up) * step, step)
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private static func number(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
  }

  private static func text(
    _ value: String, x: Double, y: Double, anchor: String = "start", size: Int = 11, color: String = muted,
    weight: String? = nil
  ) -> String {
    let bold = weight.map { " font-weight=\"\($0)\"" } ?? ""
    return
      "<text x=\"\(number(x))\" y=\"\(number(y))\" text-anchor=\"\(anchor)\" font-size=\"\(size)\" fill=\"\(color)\"\(bold)>\(escape(value))</text>"
  }

  /// The label under day `index` of `count`: the weekday for a week or two,
  /// "22/9" on every few days of a longer window (always on the last day).
  private static func label(_ day: DayTotal, index: Int, count: Int, calendar: Calendar) -> String? {
    if count <= 14 {
      let symbols = calendar.shortWeekdaySymbols
      return symbols.indices.contains(day.weekday - 1) ? symbols[day.weekday - 1] : nil
    }
    let every = Int((Double(count) / 8).rounded(.up))
    guard (count - 1 - index) % every == 0 else { return nil }
    let parts = Stats.gregorian(like: calendar).dateComponents([.day, .month], from: day.start)
    return "\(parts.day ?? 0)/\(parts.month ?? 0)"
  }

  /// The chart for `days` (oldest first, the last one today).
  static func svg(_ days: [DayTotal], calendar: Calendar = .current) -> String {
    let count = max(1, days.count)
    let plotWidth = width - left - right
    let plotHeight = height - top - bottom
    let baseline = top + plotHeight
    let slot = plotWidth / Double(count)
    let barWidth = max(1, min(maxBar, slot - 2))
    let radius = min(corner, barWidth / 2)
    let maxSeconds = days.map(\.focusedSeconds).max() ?? 0
    let (axisTop, step) = scale(maxMinutes: Double(maxSeconds) / 60)
    let total = days.reduce(0) { $0 + $1.focusedSeconds }

    var parts: [String] = []
    parts.append(
      "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(width))\" height=\"\(Int(height))\" viewBox=\"0 0 \(Int(width)) \(Int(height))\" font-family=\"\(font)\">"
    )
    parts.append("<path d=\"M0 0H\(Int(width))V\(Int(height))H0Z\" fill=\"\(canvas)\"/>")
    parts.append("<clipPath id=\"plot\"><path d=\"M0 0H\(Int(width))V\(number(baseline))H0Z\"/></clipPath>")
    let heading = days.count == 1 ? "Focused time today" : "Focused time, last \(days.count) days"
    parts.append(text(heading, x: margin, y: 22, size: 13, color: ink, weight: "600"))
    parts.append(text(LogText.minutes(total) + " in total", x: width - right, y: 22, anchor: "end", size: 12))

    // Grid and ticks: a hairline per step, labelled on the left.
    var tick = 0.0
    while tick <= axisTop + 0.001 {
      let y = (baseline - tick / axisTop * plotHeight).rounded() + 0.5
      parts.append(
        "<path d=\"M\(number(left)) \(number(y))H\(number(width - right))\" stroke=\"\(grid)\" stroke-width=\"1\"/>")
      parts.append(text(compact(Int(tick * 60)), x: left - 8, y: y + 4, anchor: "end", size: 10))
      tick += step
    }

    if maxSeconds == 0 {
      // Between the top gridline and the middle one, clear of both.
      parts.append(
        text("No focused time yet", x: left + plotWidth / 2, y: top + plotHeight / 4 + 4, anchor: "middle", size: 12))
    }

    for (index, day) in days.enumerated() {
      let x = left + slot * Double(index) + (slot - barWidth) / 2
      let centre = x + barWidth / 2
      let empty = day.focusedSeconds <= 0
      let barHeight = empty ? 2 : max(2, Double(day.focusedSeconds) / 60 / axisTop * plotHeight)
      let y = baseline - barHeight
      let title = "\(day.date): \(LogText.minutes(day.focusedSeconds))"
      parts.append(
        "<rect x=\"\(number(x))\" y=\"\(number(y))\" width=\"\(number(barWidth))\" height=\"\(number(barHeight + radius))\" rx=\"\(number(radius))\" fill=\"\(empty ? stub : accent)\" clip-path=\"url(#plot)\"><title>\(escape(title))</title></rect>"
      )
      if !empty && days.count <= 14 {
        parts.append(text(compact(day.focusedSeconds), x: centre, y: y - 6, anchor: "middle", size: 10, color: ink))
      }
      let isToday = index == days.count - 1
      if let name = label(day, index: index, count: days.count, calendar: calendar) {
        let shown = isToday && days.count <= 14 ? "Today" : name
        parts.append(
          text(shown, x: centre, y: baseline + 18, anchor: "middle", size: 11, color: isToday ? ink : muted))
      }
    }
    parts.append("</svg>")
    return parts.joined(separator: "\n") + "\n"
  }
}
