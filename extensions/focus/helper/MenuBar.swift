import AppKit
import Foundation

// MARK: - Menu bar countdown
//
// An NSStatusItem that is hidden while idle. During a session it shows the
// time left in a darker rounded box and the goal beside it, like the Raycast
// Focus pill: "[ 44:40 ] Deep Work". A paused session reads "[ ⏸ 44:40 ]".
// Its menu holds the session's calendar and planned end, then Pause or
// Resume, Extend ▸ and Stop; every action goes to the presenter delegate.
// Shown only when config.json has `countdownDisplay: "menuBar"` (UIPresenter
// decides); "Move to Floating Panel" and "Move to Notch" switch away.

final class MenuBar: NSObject {
  weak var delegate: SessionPresenterDelegate?
  let statusItem: NSStatusItem
  let menu = NSMenu()
  /// The session on show, nil while idle.
  private(set) var view: SessionView?
  /// What the box shows: "25:00", "⏸ 25:00" or "1:02:05".
  private(set) var timeText = ""
  /// The goal as shown beside the box, truncated.
  private(set) var goalText = ""
  /// Both, as one line: what the tests and VoiceOver read.
  var titleText: String { goalText.isEmpty ? timeText : "\(timeText) \(goalText)" }

  let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
  let extendItem = NSMenuItem(title: "Extend", action: nil, keyEquivalent: "")
  let stopItem = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
  let moveItem = NSMenuItem(title: "Move to Floating Panel", action: nil, keyEquivalent: "")
  let moveToNotchItem = NSMenuItem(title: "Move to Notch", action: nil, keyEquivalent: "")
  /// "Move to Floating Panel" was chosen.
  var onMoveToPanel: (() -> Void)?
  /// "Move to Notch" was chosen.
  var onMoveToNotch: (() -> Void)?
  private var extendOptions: [Int] = []

  /// `statusBar` is the system bar in the daemon; the tests pass a private
  /// NSStatusBar() so nothing appears in the real menu bar.
  init(statusBar: NSStatusBar = .system) {
    statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    statusItem.autosaveName = "focus-daemon.timer"
    statusItem.isVisible = false
    statusItem.button?.imagePosition = .imageOnly

    infoItem.isEnabled = false
    pauseItem.target = self
    pauseItem.action = #selector(pauseOrResume)
    extendItem.submenu = NSMenu(title: "Extend")
    extendItem.image = Self.symbol("plus.circle")
    stopItem.target = self
    stopItem.action = #selector(stop)
    stopItem.image = Self.symbol("stop.circle")
    moveItem.target = self
    moveItem.action = #selector(moveToPanel)
    moveItem.image = Self.symbol("macwindow")
    moveToNotchItem.target = self
    moveToNotchItem.action = #selector(moveToNotch)
    moveToNotchItem.image = Self.symbol("macbook")
    menu.autoenablesItems = false
    for item in [infoItem, .separator(), pauseItem, extendItem, stopItem, .separator(), moveItem, moveToNotchItem] {
      menu.addItem(item)
    }
    statusItem.menu = menu
  }

  private static func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
  }

  // MARK: Text

  /// "mm:ss" under an hour, "h:mm:ss" from an hour up; never negative.
  static func clock(_ seconds: Int) -> String { CountdownModel.clock(seconds) }

  static let goalLimit = 24

  /// The goal on one line, cut to `goalLimit` characters with an ellipsis.
  static func shortGoal(_ goal: String) -> String {
    let line = goal.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard line.count > goalLimit else { return line }
    return line.prefix(goalLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// "5 min" for whole minutes, "90 s" otherwise.
  static func extendTitle(_ seconds: Int) -> String {
    seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
  }

  static func timeOfDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  /// The disabled first line of the menu: "Work · until 15:00".
  static func infoText(_ view: SessionView) -> String {
    let end = "until \(timeOfDay(view.plannedEnd))"
    let calendar = view.calendarTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return calendar.isEmpty ? end.prefix(1).uppercased() + end.dropFirst() : "\(calendar) · \(end)"
  }

  // MARK: Update

  func update(_ view: SessionView?) {
    self.view = view
    guard let view else {
      timeText = ""
      goalText = ""
      statusItem.isVisible = false
      return
    }
    let paused = view.state == "paused"
    let clock = Self.clock(view.state == "ending" ? 0 : view.remainingSeconds)
    timeText = paused ? "⏸ \(clock)" : clock
    goalText = Self.shortGoal(view.goal)
    statusItem.isVisible = true

    if let button = statusItem.button {
      button.image = Self.itemImage(clock: clock, paused: paused, goal: goalText, appearance: button.effectiveAppearance)
      button.setAccessibilityLabel("Focus: \(paused ? "paused, " : "")\(clock) left, \(view.goal)")
      button.toolTip = view.goal
    }
    updateMenu(view)
  }

  private func updateMenu(_ view: SessionView) {
    infoItem.title = Self.infoText(view)
    let ending = view.state == "ending"
    let paused = view.state == "paused"
    pauseItem.isHidden = ending
    pauseItem.title = paused ? "Resume" : "Pause"
    pauseItem.image = Self.symbol(paused ? "play.circle" : "pause.circle")
    stopItem.isHidden = ending
    extendItem.isHidden = view.extendOptions.isEmpty
    if view.extendOptions != extendOptions {
      extendOptions = view.extendOptions
      let submenu = extendItem.submenu ?? NSMenu(title: "Extend")
      submenu.removeAllItems()
      for seconds in view.extendOptions {
        let item = NSMenuItem(title: Self.extendTitle(seconds), action: #selector(extend(_:)), keyEquivalent: "")
        item.target = self
        item.tag = seconds
        submenu.addItem(item)
      }
      extendItem.submenu = submenu
    }
  }

  // MARK: Actions

  @objc private func pauseOrResume() {
    guard let view, view.state != "ending" else { return }
    if view.state == "paused" { delegate?.presenterResume() } else { delegate?.presenterPause() }
  }

  @objc private func extend(_ sender: NSMenuItem) {
    guard view != nil, sender.tag > 0 else { return }
    delegate?.presenterExtend(seconds: sender.tag)
  }

  @objc private func stop() {
    guard let view, view.state != "ending" else { return }
    delegate?.presenterStop()
  }

  @objc private func moveToPanel() { onMoveToPanel?() }
  @objc private func moveToNotch() { onMoveToNotch?() }

  // MARK: Drawing

  static let boxFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static let goalFont = NSFont.menuBarFont(ofSize: 0)
  static let height: CGFloat = 18
  static let boxPadding: CGFloat = 6
  static let goalGap: CGFloat = 6

  /// The whole item as one image: the rounded box with the time, then the
  /// goal. Drawn for the menu bar's current appearance (on macOS 26 the bar
  /// is light or dark by wallpaper; the image is rebuilt on every tick, so a
  /// change shows within a second). One image rather than image plus button
  /// title so the box and the goal share a baseline.
  static func itemImage(clock: String, paused: Bool, goal: String, appearance: NSAppearance) -> NSImage {
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let fill = dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)
    let ink = dark ? NSColor.white.withAlphaComponent(0.62) : NSColor.black.withAlphaComponent(0.58)
    let label = dark ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.85)
    let time = NSAttributedString(string: clock, attributes: [.font: boxFont, .foregroundColor: ink])
    let goalText = NSAttributedString(string: goal, attributes: [.font: goalFont, .foregroundColor: label])
    let timeWidth = ceil(time.size().width)
    let goalWidth = goal.isEmpty ? 0 : ceil(goalText.size().width)
    let pause: NSImage? = paused
      ? NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")?
        .withSymbolConfiguration(
          NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink])))
      : nil
    let pauseWidth = pause.map { ceil($0.size.width) + 4 } ?? 0
    let boxWidth = timeWidth + pauseWidth + boxPadding * 2
    let size = NSSize(width: boxWidth + (goal.isEmpty ? 0 : goalGap + goalWidth), height: height)

    /// Puts the middle of the capitals (and digits) on the image's middle.
    func origin(_ font: NSFont, x: CGFloat) -> NSPoint {
      NSPoint(x: x, y: (height / 2 - font.capHeight / 2 + font.descender).rounded())
    }

    let image = NSImage(size: size, flipped: false) { _ in
      fill.setFill()
      NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: boxWidth, height: height), xRadius: 5, yRadius: 5).fill()
      var x = boxPadding
      if let pause {
        let y = (height - pause.size.height) / 2
        pause.draw(in: NSRect(x: x, y: y, width: pause.size.width, height: pause.size.height))
        x += pauseWidth
      }
      time.draw(at: origin(boxFont, x: x))
      if !goal.isEmpty { goalText.draw(at: origin(goalFont, x: boxWidth + goalGap)) }
      return true
    }
    image.isTemplate = false
    return image
  }
}
