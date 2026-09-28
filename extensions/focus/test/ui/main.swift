// Headless checks of the menu bar countdown, the floating panel, the end
// sheet, the completion sequence and the block window, with a fake delegate
// in place of the session logic, a fake scheduler and sound, and a real
// BlockEngine behind the app blocker. Run with scripts/test-ui.sh.
// Pass a folder to also write sheet.png, card-0s.png, card-2.5s.png,
// card-over-glow.png, menubar-*.png, panel-*.png (panel-fallback.png is the
// pre-macOS 26 backdrop), glow.png and block.png there.
//
// Nothing shows on screen: the status item lives in a private NSStatusBar
// and the sheet is ordered in far off screen without becoming key.

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  " + detail()))
  if !ok { failures += 1 }
}

final class FakeDelegate: SessionPresenterDelegate {
  var calls: [String] = []
  func presenterPause() { calls.append("pause") }
  func presenterResume() { calls.append("resume") }
  func presenterExtend(seconds: Int) { calls.append("extend \(seconds)") }
  func presenterStop() { calls.append("stop") }
  func presenterFinish(rating: Int?, note: String?) {
    calls.append("finish \(rating.map(String.init) ?? "nil") \(note.map { "\"\($0)\"" } ?? "nil")")
  }
}

/// Runs scheduled work when the test moves time on, in time order.
final class FakeScheduler: UIScheduler {
  private(set) var time: TimeInterval = 0
  private var items: [(due: TimeInterval, seq: Int, task: ScheduledTask, body: () -> Void)] = []
  private var seq = 0
  @discardableResult
  func after(_ seconds: TimeInterval, _ body: @escaping () -> Void) -> ScheduledTask {
    let task = ScheduledTask()
    items.append((time + seconds, seq, task, body))
    seq += 1
    return task
  }
  var pending: Int { items.filter { !$0.task.isCancelled }.count }
  func advance(_ seconds: TimeInterval) {
    let end = time + seconds
    while let next = items.filter({ !$0.task.isCancelled && $0.due <= end + 1e-9 })
      .min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) })
    {
      items.removeAll { $0.seq == next.seq }
      time = next.due
      next.body()
    }
    items.removeAll { $0.task.isCancelled }
    time = end
  }
}

final class FakeSound: CompletionSound {
  var plays = 0
  func play() { plays += 1 }
}

var now = Date(timeIntervalSince1970: 1_790_000_000)
let scheduler = FakeScheduler()
let sound = FakeSound()
let laptop = ScreenGeometry(
  frame: NSRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 944))
let external = ScreenGeometry(
  frame: NSRect(x: 1512, y: 0, width: 1920, height: 1080), visibleFrame: NSRect(x: 1512, y: 0, width: 1920, height: 1055))
var screenList = [laptop, external]
let configDir = NSTemporaryDirectory() + "focus-ui-tests-\(getpid())"
try? FileManager.default.removeItem(atPath: configDir)
try! FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
let configPath = configDir + "/config.json"
// The menu bar checks come first, so start on the menu bar display. An
// unknown key checks that the helper's writes keep it.
try! #"{"countdownDisplay": "menuBar", "snoozeSeconds": 300, "futureKey": {"keep": [1, 2]}}"#
  .write(toFile: configPath, atomically: true, encoding: .utf8)
var logged: [String] = []
let ui = UIPresenter(
  statusBar: NSStatusBar(), clock: { now }, settings: ConfigFile(path: configPath), scheduler: scheduler, sound: sound,
  screens: { screenList }, log: { logged.append($0) })
ui.endSheet.headless = true
ui.floating.headless = true
ui.completion.headless = true
var popped: [String] = []
ui.floating.popUpMenu = { menu, _ in popped.append(menu.title) }
var opened: [URL] = []
ui.openURL = { opened.append($0) }
// The end card's hover poll reads this instead of the real mouse.
let away = NSPoint(x: -5000, y: -5000)
var pointer = away
ui.pointerLocation = { pointer }
let fake = FakeDelegate()
ui.delegate = fake
let bar = ui.menuBar
let sheet = ui.endSheet
let panel = sheet.panel

func session(
  id: Int = 7, goal: String = "Deep Work", state: String = "running", remaining: Int = 1500,
  started: TimeInterval = -1500, plannedEnd: TimeInterval? = nil, paused: Int = 0, calendar: String = "Work",
  extend: [Int] = [300, 600, 900, 1500]
) -> SessionView {
  SessionView(
    id: id, goal: goal, state: state, startedAt: now.addingTimeInterval(started),
    plannedEnd: now.addingTimeInterval(plannedEnd ?? TimeInterval(remaining)), remainingSeconds: remaining,
    pausedSeconds: paused, calendarTitle: calendar, extendOptions: extend)
}

func lastCall() -> String { fake.calls.last ?? "(none)" }

// MARK: Menu bar title

check("idle: status item hidden at start", !bar.statusItem.isVisible)
ui.update(session(remaining: 1500))
check("running: status item shown", bar.statusItem.isVisible)
check("menu bar display: the floating panel stays hidden", !ui.floating.isVisible && !ui.floating.panel.isVisible)
check("running: title 25:00 Deep Work", bar.titleText == "25:00 Deep Work", bar.titleText)
let runningWidth = bar.statusItem.button?.image?.size.width ?? 0
check("running: box and goal drawn", runningWidth > 80, "\(runningWidth)")
ui.update(session(remaining: 65))
check("running: 01:05", bar.timeText == "01:05", bar.timeText)
ui.update(session(state: "paused", remaining: 65))
check("paused: ⏸ 01:05", bar.timeText == "⏸ 01:05", bar.timeText)
check("paused: title", bar.titleText == "⏸ 01:05 Deep Work", bar.titleText)
let pausedWidth = bar.statusItem.button?.image?.size.width ?? 0
ui.update(session(remaining: 65))
check("paused item is wider than running", pausedWidth > (bar.statusItem.button?.image?.size.width ?? 0))
check("the digits do not change the width", bar.statusItem.button?.image?.size.width == runningWidth)
ui.update(session(remaining: 3725))
check("over an hour: 1:02:05", bar.timeText == "1:02:05", bar.timeText)
check("exactly an hour: 1:00:00", MenuBar.clock(3600) == "1:00:00", MenuBar.clock(3600))
check("just under an hour: 59:59", MenuBar.clock(3599) == "59:59", MenuBar.clock(3599))
check("never negative", MenuBar.clock(-5) == "00:00", MenuBar.clock(-5))
ui.update(session(state: "ending", remaining: 0))
check("ending: 00:00", bar.timeText == "00:00", bar.timeText)
ui.update(session(goal: "Write the quarterly planning document for the team"))
check("long goal truncated to 24", bar.goalText.count == 24 && bar.goalText.hasSuffix("…"), bar.goalText)
check("long goal keeps its start", bar.goalText.hasPrefix("Write the quarterly"), bar.goalText)
ui.update(session(goal: "Exactly twenty-four char"))
check("24-char goal untouched", bar.goalText == "Exactly twenty-four char", bar.goalText)
ui.update(session(goal: "  two\nlines  "))
check("goal on one line", bar.goalText == "two lines", bar.goalText)

// MARK: Menu

func visibleTitles() -> [String] {
  bar.menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "---" : $0.title }
}
func perform(_ item: NSMenuItem) {
  guard let menu = item.menu else { return }
  menu.performActionForItem(at: menu.index(of: item))
}

let running = session()
ui.update(running)
let info = "Work · until \(MenuBar.timeOfDay(running.plannedEnd))"
let move = ["---", "Move to Floating Panel"]
check("running menu", visibleTitles() == [info, "---", "Pause", "Extend", "Stop"] + move, "\(visibleTitles())")
check("info line disabled", !bar.infoItem.isEnabled)
check(
  "extend submenu from extendOptions",
  bar.extendItem.submenu?.items.map(\.title) == ["5 min", "10 min", "15 min", "25 min"],
  "\(bar.extendItem.submenu?.items.map(\.title) ?? [])")
perform(bar.pauseItem)
check("Pause calls presenterPause", lastCall() == "pause", lastCall())
if let ten = bar.extendItem.submenu?.items[1] { perform(ten) }
check("Extend ▸ 10 min calls presenterExtend(600)", lastCall() == "extend 600", lastCall())
perform(bar.stopItem)
check("Stop calls presenterStop", lastCall() == "stop", lastCall())

ui.update(session(state: "paused"))
check("paused menu", visibleTitles() == [info, "---", "Resume", "Extend", "Stop"] + move, "\(visibleTitles())")
perform(bar.pauseItem)
check("Resume calls presenterResume", lastCall() == "resume", lastCall())

ui.update(session(state: "ending", remaining: 0, plannedEnd: 0))
check("ending menu: extend only", visibleTitles() == ["Work · until \(MenuBar.timeOfDay(now))", "---", "Extend"] + move, "\(visibleTitles())")
let callsBefore = fake.calls.count
perform(bar.stopItem)
perform(bar.pauseItem)
check("ending: hidden Stop and Pause do nothing", fake.calls.count == callsBefore, "\(fake.calls)")

ui.update(session(calendar: "", extend: [300, 90]))
check("no calendar: Until …", bar.infoItem.title == "Until \(MenuBar.timeOfDay(now.addingTimeInterval(1500)))", bar.infoItem.title)
check(
  "extend options rebuilt", bar.extendItem.submenu?.items.map(\.title) == ["5 min", "90 s"],
  "\(bar.extendItem.submenu?.items.map(\.title) ?? [])")
ui.update(session(extend: []))
check("no extend options: Extend hidden", bar.extendItem.isHidden)

ui.update(nil)
check("update(nil) hides the status item", !bar.statusItem.isVisible)
check("update(nil) clears the title", bar.titleText == "", bar.titleText)

// MARK: End sheet text

check("hidden before showEndSheet", !sheet.isVisible)
let timeUp = session(state: "ending", remaining: 0, started: -1560, plannedEnd: 0, paused: 60)
ui.showEndSheet(timeUp)
check("showEndSheet shows the sheet", sheet.isVisible)
check("status item shown with the sheet", bar.statusItem.isVisible)
check("title is the goal", sheet.titleLabel.stringValue == "Deep Work", sheet.titleLabel.stringValue)
check("time's up text", sheet.statusLabel.stringValue == "Time's up · 25 min focused", sheet.statusLabel.stringValue)
check("four extend buttons", sheet.extendButtons.map(\.title) == ["+5 min", "+10 min", "+15 min", "+25 min"], "\(sheet.extendButtons.map(\.title))")
check("sheet floats on every space", panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
check("sheet level above floating windows", panel.level.rawValue > NSWindow.Level.floating.rawValue)
check("sheet level one above the completion glow", panel.level.rawValue == NSWindow.Level.screenSaver.rawValue + 1)
check("sheet does not activate the app", panel.styleMask.contains(.nonactivatingPanel))
check("the card is 360 wide", panel.frame.width == 360, "\(panel.frame)")
check("the card is compact: about 130 tall", panel.frame.height >= 110 && panel.frame.height <= 140, "\(panel.frame)")
check("the card is borderless with the banner's type", panel.styleMask.contains(.borderless) && sheet.titleLabel.font?.pointSize == 14 && sheet.statusLabel.font?.pointSize == 13)
sheet.content.layoutSubtreeIfNeeded()
func inContent(_ view: NSView) -> NSRect { view.convert(view.bounds, to: sheet.content) }
check("stars and the note share a row", abs(inContent(sheet.stars).midY - inContent(sheet.noteField).midY) <= 1 && inContent(sheet.noteField).minX > inContent(sheet.stars).maxX, "\(inContent(sheet.stars)) \(inContent(sheet.noteField))")
check("extend and Finish share the row below", abs(inContent(sheet.extendRow).midY - inContent(sheet.finishButton).midY) <= 1 && inContent(sheet.extendRow).maxY < inContent(sheet.stars).minY && inContent(sheet.finishButton).maxX <= 360 - 11, "\(inContent(sheet.extendRow)) \(inContent(sheet.finishButton))")
check("every extend label fits its button with room", sheet.extendButtons.allSatisfy { $0.frame.width >= $0.titleWidth + 8 }, "\(sheet.extendButtons.map { ($0.frame.width, $0.titleWidth) })")
check("Finish and its keycap fit", sheet.finishButton.frame.width >= sheet.finishButton.intrinsicContentSize.width - 0.5, "\(sheet.finishButton.frame)")
check("content is first responder", panel.firstResponder === sheet.content)

check("stopped early text", EndSheet.statusText(session(state: "ending", remaining: 0, started: -600, plannedEnd: 900), now: now) == "Stopped · 10 min focused")
check("stopped in the final second reads Stopped", EndSheet.headline(session(state: "ending", remaining: 0, plannedEnd: 0.4), now: now) == "Stopped")
check("planned end just passed reads Time's up", EndSheet.headline(session(state: "ending", remaining: 0, plannedEnd: -0.2), now: now) == "Time's up")
check("stopped with time left text", EndSheet.headline(session(state: "ending", remaining: 300), now: now) == "Stopped")
check("duration under a minute", EndSheet.duration(59) == "under a minute")
check("duration hours", EndSheet.duration(3600) == "1 h" && EndSheet.duration(3900) == "1 h 5 min", EndSheet.duration(3900))

// MARK: Stars, by mouse

func mouse(_ type: NSEvent.EventType, star index: Int, dx: CGFloat = 0) -> NSEvent {
  let rect = sheet.stars.starRect(index)
  let point = sheet.stars.convert(NSPoint(x: rect.midX + dx, y: rect.midY), to: nil)
  return NSEvent.mouseEvent(
    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
}
func click(star index: Int, dx: CGFloat = 0) {
  panel.sendEvent(mouse(.leftMouseDown, star: index, dx: dx))
  panel.sendEvent(mouse(.leftMouseUp, star: index, dx: dx))
}

check("no stars at first", sheet.rating == nil && sheet.stars.shown == 0)
click(star: 3)
check("click star 3 rates 3", sheet.rating == 3, "\(String(describing: sheet.rating))")
click(star: 5)
check("click star 5 rates 5", sheet.rating == 5, "\(String(describing: sheet.rating))")
click(star: 1)
check("click star 1 rates 1", sheet.rating == 1, "\(String(describing: sheet.rating))")
click(star: 2, dx: StarRating.side / 2 + 2)  // in the gap, nearer star 2
check("click in a gap goes to the nearer star", sheet.rating == 2, "\(String(describing: sheet.rating))")
panel.sendEvent(mouse(.leftMouseDown, star: 4))
panel.sendEvent(mouse(.leftMouseUp, star: 1))
check("press on 4, release on 1: no change", sheet.rating == 2, "\(String(describing: sheet.rating))")
sheet.stars.mouseMoved(with: mouse(.mouseMoved, star: 5))
check("hover 5 previews five stars", sheet.stars.shown == 5 && sheet.rating == 2, "\(sheet.stars.shown)")
sheet.stars.mouseMoved(with: mouse(.mouseMoved, star: 1))
check("hover 1 previews one star", sheet.stars.shown == 1)
sheet.stars.mouseExited(with: mouse(.mouseMoved, star: 1))
check("leaving shows the rating again", sheet.stars.shown == 2, "\(sheet.stars.shown)")

// MARK: Keys

func key(_ characters: String, _ code: UInt16, flags: NSEvent.ModifierFlags = []) {
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
    windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
    isARepeat: false, keyCode: code)!
  panel.sendEvent(event)
}

key("4", 21)
check("4 inside the grace period is ignored", sheet.rating == 2, "\(String(describing: sheet.rating))")
key("\r", 36)
check("Return inside the grace period is ignored", sheet.isVisible && fake.calls.count == callsBefore, "\(fake.calls)")
now = now.addingTimeInterval(1)
for (digit, code) in [(1, 18), (2, 19), (3, 20), (4, 21), (5, 23)] as [(Int, UInt16)] {
  key("\(digit)", code)
  check("key \(digit) rates \(digit)", sheet.rating == digit, "\(String(describing: sheet.rating))")
}
key("6", 22)
check("6 does nothing", sheet.rating == 5)
key("4", 21, flags: .command)
check("⌘4 does not rate", sheet.rating == 5)
key("\u{1b}", 53)
check("Escape keeps the sheet up", sheet.isVisible)
panel.cancelOperation(nil)
check("cancelOperation keeps the sheet up", sheet.isVisible)
key("4", 21)

// Typing starts the note; Escape in the note returns to the stars.
key("S", 1)
check("typing a letter focuses the note", sheet.noteField.currentEditor() != nil && sheet.noteField.stringValue == "S", sheet.noteField.stringValue)
(sheet.noteField.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
check("Escape in the note keeps the sheet and leaves the note", sheet.isVisible && panel.firstResponder === sheet.content)
check("note kept after leaving it", sheet.noteField.stringValue == "S", sheet.noteField.stringValue)
key("\t", 48)
check("Tab focuses the note", sheet.noteField.currentEditor() != nil)
(sheet.noteField.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

// MARK: Note and Finish

check("note trimmed", EndSheet.cleanNote("  Shipped the draft \n") == "Shipped the draft", EndSheet.cleanNote("  Shipped the draft \n") ?? "nil")
check("blank note is nil", EndSheet.cleanNote(" \n\t ") == nil)
check("note newlines become spaces", EndSheet.cleanNote("a\nb") == "a b")
sheet.noteField.stringValue = "   Shipped the draft   "
key("\r", 36)
check("Return finishes with rating and trimmed note", lastCall() == "finish 4 \"Shipped the draft\"", lastCall())
check("Finish hides the sheet", !sheet.isVisible)
let afterFinish = fake.calls.count
sheet.finishButton.performClick(nil)
check("a second Finish sends nothing", fake.calls.count == afterFinish, "\(fake.calls)")

// Same session back (after an extend): stars and note kept.
ui.showEndSheet(timeUp)
check("same session keeps its rating", sheet.rating == 4, "\(String(describing: sheet.rating))")
check("same session keeps its note", sheet.noteField.stringValue == "   Shipped the draft   ")
now = now.addingTimeInterval(1)

// Return inside the note field finishes too.
key("x", 7)
sheet.noteField.stringValue = "  in the field "
(sheet.noteField.currentEditor() as? NSTextView)?.string = "  in the field "
(sheet.noteField.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
check("Return in the note finishes", lastCall() == "finish 4 \"in the field\"", lastCall())

// A new session: nothing carried over; the button finishes with no rating.
ui.showEndSheet(session(id: 8, goal: "Inbox", state: "ending", remaining: 0, plannedEnd: 0))
check("new session starts with no stars", sheet.rating == nil)
check("new session starts with no note", sheet.noteField.stringValue == "")
check("new title", sheet.titleLabel.stringValue == "Inbox")
sheet.noteField.stringValue = "   "
sheet.finishButton.performClick(nil)
check("Finish button with no stars and blank note", lastCall() == "finish nil nil", lastCall())

// MARK: Extend

ui.showEndSheet(session(id: 9, state: "ending", remaining: 0, plannedEnd: 0))
check("sheet back up", sheet.isVisible)
sheet.extendButtons[1].performClick(nil)
check("+10 min calls presenterExtend(600)", lastCall() == "extend 600", lastCall())
check("Extend hides the sheet", !sheet.isVisible)
ui.showEndSheet(session(id: 9, state: "ending", remaining: 0, plannedEnd: 0))
sheet.extendButtons[3].performClick(nil)
check("+25 min calls presenterExtend(1500)", lastCall() == "extend 1500", lastCall())
let afterExtend = fake.calls.count
sheet.extendButtons[0].performClick(nil)
check("a second answer sends nothing", fake.calls.count == afterExtend)

ui.showEndSheet(session(id: 9, state: "ending", remaining: 0, plannedEnd: 0, extend: [120]))
check("extend buttons follow extendOptions", sheet.extendButtons.map(\.title) == ["+2 min"], "\(sheet.extendButtons.map(\.title))")
ui.update(session(id: 9, state: "running", remaining: 120))
check("back to running (extended from the menu) hides the sheet", !sheet.isVisible)

// MARK: Dismiss

ui.showEndSheet(session(id: 10, state: "ending", remaining: 0, plannedEnd: 0))
ui.update(session(id: 10, state: "ending", remaining: 0, plannedEnd: 0))
check("ticks while ending keep the sheet up", sheet.isVisible)
ui.dismissEndSheet()
check("dismissEndSheet hides the sheet", !sheet.isVisible)
ui.dismissEndSheet()
check("dismissEndSheet twice is harmless", !sheet.isVisible)
ui.showEndSheet(session(id: 11, state: "ending", remaining: 0, plannedEnd: 0))
ui.update(nil)
check("update(nil) hides the sheet", !sheet.isVisible)
check("update(nil) hides the status item", !bar.statusItem.isVisible)
check("no calls from dismissals", fake.calls.count == afterExtend, "\(fake.calls)")

// MARK: Config keys

check("countdownDisplay defaults to the panel", FocusConfig().countdownDisplay == .panel)
check("panelPosition defaults to nil", FocusConfig().panelPosition == nil)
check("countdownDisplay menuBar reads", FocusConfig(json: ["countdownDisplay": "menuBar"]).countdownDisplay == .menuBar)
check("an unknown countdownDisplay is the panel", FocusConfig(json: ["countdownDisplay": "dock"]).countdownDisplay == .panel)
check(
  "panelPosition reads x and y", FocusConfig(json: ["panelPosition": ["x": 100, "y": .double(850.5)]]).panelPosition == PanelPosition(x: 100, y: 850.5))
check("a malformed panelPosition is nil", FocusConfig(json: ["panelPosition": ["x": "1", "y": 2]]).panelPosition == nil)
check("a null panelPosition is nil", FocusConfig(json: ["panelPosition": nil]).panelPosition == nil)
check("both keys in the written defaults", FocusConfig().json["countdownDisplay"] == "panel" && FocusConfig().json["panelPosition"] == .null)
check("a position writes whole points", PanelPosition(x: 10.4, y: 20.6).json == ["x": 10, "y": 21])
let roundTrip = FocusConfig(json: .object(FocusConfig(json: ["countdownDisplay": "menuBar", "panelPosition": ["x": 3, "y": 4]]).json.objectValue!))
check("the keys round-trip", roundTrip.countdownDisplay == .menuBar && roundTrip.panelPosition == PanelPosition(x: 3, y: 4))

func fileFields() -> [String: JSONValue] {
  (try? JSONValue.parse(String(contentsOfFile: configPath, encoding: .utf8)))?.objectValue ?? [:]
}
let scratch = configDir + "/scratch.json"
try! #"{"a": 1, "profiles": {"deep": {"mode": "allowlist"}}}"#.write(toFile: scratch, atomically: true, encoding: .utf8)
try? ConfigFile(path: scratch).update(["countdownDisplay": "menuBar"])
let scratchFields = (try? JSONValue.parse(String(contentsOfFile: scratch, encoding: .utf8)))?.objectValue ?? [:]
check(
  "update sets the key and keeps the others",
  scratchFields["countdownDisplay"] == "menuBar" && scratchFields["a"] == 1
    && scratchFields["profiles"] == ["deep": ["mode": "allowlist"]], "\(scratchFields)")
try! "{ half".write(toFile: scratch, atomically: true, encoding: .utf8)
check("update refuses a file that does not parse", (try? ConfigFile(path: scratch).update(["countdownDisplay": "panel"])) == nil)
check("and leaves it alone", (try? String(contentsOfFile: scratch, encoding: .utf8)) == "{ half")
try? FileManager.default.removeItem(atPath: scratch)
try? ConfigFile(path: scratch).update(["panelPosition": ["x": 1, "y": 2]])
let fresh = ConfigFile(path: scratch).load()
check("update on a missing file starts from the defaults", fresh.panelPosition == PanelPosition(x: 1, y: 2) && fresh.snoozeSeconds == 180)
check("no temp files left", (try? FileManager.default.contentsOfDirectory(atPath: configDir).sorted()) == ["config.json", "scratch.json"])

// MARK: Floating panel

let floating = ui.floating
ui.update(nil)
ui.panelMoveToMenuBar()  // already there: harmless
ui.setDisplay(.panel)
check("Move to Floating Panel writes the display", fileFields()["countdownDisplay"] == "panel", "\(fileFields())")
check("the write keeps other keys", fileFields()["futureKey"] == ["keep": [1, 2]] && fileFields()["snoozeSeconds"] == 300)
check("idle: panel hidden", !floating.isVisible)

// Half way: 25 of 50 minutes left.
ui.update(session(remaining: 1500, started: -1500))
check("panel display: panel shown", floating.isVisible && floating.panel.isVisible)
check("panel display: status item hidden", !bar.statusItem.isVisible)
check("panel title", floating.content?.titleText == "25:00 Deep Work", floating.content?.titleText ?? "nil")
check("half way: chip half green", abs((floating.content?.progress ?? 0) - 0.5) < 0.001, "\(floating.content?.progress ?? -1)")
let chip = floating.pill.chipRect
check("the green part is half the pill, full height", abs(floating.pill.progressRect.width - floating.pill.bounds.width / 2) <= 1 && floating.pill.progressRect.height == floating.pill.bounds.height, "\(floating.pill.progressRect) \(floating.pill.bounds)")
check("the chip is 28 tall (the button height), rounded 8", chip.height == 28 && PanelStyle.chipRadius == 8)
check("the panel is 40 tall, like the controls row", floating.frame.height == 40, "\(floating.frame)")
check("the pill is as wide as the controls row", floating.frame.width == floating.controlsWidth, "\(floating.frame)")
check("panel floats on every space, above the block page", floating.panel.collectionBehavior.contains(.canJoinAllSpaces)
  && floating.panel.collectionBehavior.contains(.fullScreenAuxiliary) && floating.panel.level.rawValue > NSWindow.Level.floating.rawValue
  && floating.panel.level.rawValue < sheet.panel.level.rawValue)
check("panel never activates or takes focus", floating.panel.styleMask.contains(.nonactivatingPanel) && !floating.panel.canBecomeKey
  && !floating.panel.hidesOnDeactivate && !floating.panel.isMovableByWindowBackground)
let defaultFrame = FloatingPanel.defaultFrame(width: floating.frame.width, on: laptop)
check("default place: top right of the main screen, 12 in", defaultFrame == NSRect(x: 1512 - 12 - floating.frame.width, y: 944 - 12 - 40, width: floating.frame.width, height: 40), "\(defaultFrame)")
check("first show uses the default place", floating.frame == defaultFrame, "\(floating.frame)")
check("default place maths", FloatingPanel.defaultFrame(width: 160, on: laptop) == NSRect(x: 1340, y: 892, width: 160, height: 40))
check("anchored to the right edge there", floating.anchoredRight)

// The glass. The window server's glass does not render headless, so these
// check how it is set up and the edges' geometry, and sample what the
// edges draw.
check("the panel window stays clear so the glass shows the desktop", !floating.panel.isOpaque && floating.panel.backgroundColor == .clear)
check("the backdrop is the window's content view", floating.panel.contentView === floating.backdrop)
if #available(macOS 26, *) {
  let glass = floating.backdrop as? NSGlassEffectView
  check("macOS 26: the backdrop is NSGlassEffectView", floating.usesGlass && glass != nil)
  check("the glass has the pill's radius", glass?.cornerRadius == PanelStyle.radius)
  check("clear glass, untinted (the tint is painted: AppKit greys a glass tint in a window that is never key)", glass?.style == .clear && glass?.tintColor == nil)
  check("the chrome is the glass's content view", glass?.contentView === floating.chrome)
} else {
  check("before macOS 26: the HUD blur", !floating.usesGlass && floating.backdrop is NSVisualEffectView)
}
check("the chrome paints the dark green tint", floating.chrome.canvas == (floating.usesGlass ? GlassStyle.tint : GlassStyle.fallbackCanvas))
check("the tint is a translucent dark green", GlassStyle.tint.alphaComponent >= 0.65 && GlassStyle.tint.alphaComponent <= 0.8
  && GlassStyle.tint.greenComponent > GlassStyle.tint.redComponent && GlassStyle.tint.greenComponent < 0.35)
check("the edges sit on top of the pill and the controls", floating.chrome.subviews.last === floating.edges
  && floating.edges.frame == floating.chrome.bounds && floating.edges.radius == PanelStyle.radius)
check("the edges never take the mouse", floating.edges.hitTest(NSPoint(x: 10, y: 10)) == nil)

let pillEdges = GlassEdges(bounds: NSRect(x: 0, y: 0, width: 264, height: 40), radius: 14)
check("rim: 1 pt, half a point in from the edge", pillEdges.rimRect == NSRect(x: 0.5, y: 0.5, width: 263, height: 39) && pillEdges.rimRadius == 13.5)
check("highlight: the top 6 pt", pillEdges.highlightRect == NSRect(x: 0, y: 34, width: 264, height: 6))
check("sheen: the top third", pillEdges.sheenRect == NSRect(x: 0, y: 27, width: 264, height: 13))
check("shade: the bottom 9 pt", pillEdges.shadeRect == NSRect(x: 0, y: 0, width: 264, height: 9))
check("the left light reaches 36 pt in", pillEdges.leftLightRect == NSRect(x: 0, y: 0, width: 36, height: 40))
check("every edge rect lies inside the pill", [pillEdges.rimRect, pillEdges.highlightRect, pillEdges.sheenRect, pillEdges.shadeRect, pillEdges.leftLightRect]
  .allSatisfy { pillEdges.bounds.contains($0) })
let tinyEdges = GlassEdges(bounds: NSRect(x: 0, y: 0, width: 30, height: 8), radius: 4)
check("a short pill keeps the highlight and shade to half its height each", tinyEdges.highlightRect.height == 4 && tinyEdges.shadeRect.height == 4)
check("rim colours: light at the top, dark at the bottom", GlassEdges.rimStops.first?.1 == 0 && GlassEdges.rimStops.last?.1 == 1
  && GlassEdges.rimStops.last?.0 == GlassStyle.rimTop && GlassEdges.rimStops.first?.0 == GlassStyle.rimBottom
  && GlassStyle.rimTop.whiteComponent == 1 && GlassStyle.rimBottom.whiteComponent == 0 && abs(GlassStyle.rimBottom.alphaComponent - 0.25) < 0.001)
check("highlight white 35 %, sheen 8 %", abs(GlassStyle.highlight.alphaComponent - 0.35) < 0.001 && abs(GlassStyle.sheen.alphaComponent - 0.08) < 0.001)
// What the edges draw, over mid grey at 1x: brighter along the top and the
// left, darker along the bottom, untouched in the middle and outside the
// rounded corners.
func edgesSample() -> ((Int, Int) -> CGFloat)? {
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 264, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
  else { return nil }
  rep.size = NSSize(width: 264, height: 40)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor(white: 0.5, alpha: 1).setFill()
  NSRect(x: 0, y: 0, width: 264, height: 40).fill()
  pillEdges.draw()
  NSGraphicsContext.restoreGraphicsState()
  // Rows count from the top in a bitmap.
  return { x, y in rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? -1 }
}
if let grey = edgesSample() {
  let middle = grey(132, 20)
  check("the middle of the pill is untouched", abs(middle - 0.5) < 0.02, "\(middle)")
  check("the top rim is bright", grey(132, 0) > middle + 0.12, "\(grey(132, 0))")
  check("the highlight fades down from the top", grey(132, 2) > grey(132, 4) && grey(132, 4) > grey(132, 7) - 0.001, "\(grey(132, 2)) \(grey(132, 4)) \(grey(132, 7))")
  check("the bottom rim is dark", grey(132, 39) < middle - 0.05, "\(grey(132, 39))")
  check("the left rim is brighter than the right", grey(0, 20) > grey(263, 20) + 0.04, "\(grey(0, 20)) \(grey(263, 20))")
  check("nothing drawn outside the rounded corner", abs(grey(0, 0) - 0.5) < 0.01, "\(grey(0, 0))")
} else {
  check("the edges render", false)
}
let chipBorder = floating.pill.chipBorder
check("the chip's border is 1 pt inside the chip", chipBorder.rect == floating.pill.chipRect.insetBy(dx: 0.5, dy: 0.5) && chipBorder.radius == PanelStyle.chipRadius - 0.5)
check("chip: white 12 % fill, 22 % border", abs(GlassStyle.chipFill.alphaComponent - 0.12) < 0.001 && abs(GlassStyle.chipBorder.alphaComponent - 0.22) < 0.001)
check("the sweep is translucent green glass", GlassStyle.progressTop.alphaComponent < 0.6 && GlassStyle.progressBottom.alphaComponent < 0.6
  && GlassStyle.progressTop.greenComponent > GlassStyle.progressTop.redComponent)
if let edge = floating.pill.progressEdgeRect {
  check("half way: the sweep's lit edge is 1 pt at its right end", edge == NSRect(x: floating.pill.progressRect.maxX - 1, y: 0, width: 1, height: 40), "\(edge)")
} else {
  check("half way: the sweep has a lit edge", false)
}
check("hover buttons: glass pills, white 10 % fill and 20 % border", abs(GlassStyle.buttonFill.alphaComponent - 0.10) < 0.001 && abs(GlassStyle.buttonBorder.alphaComponent - 0.20) < 0.001)

// The pre-macOS 26 backdrop, forced: the HUD blur cut to the pill, the
// tint painted denser, the same fixed size.
let fallback = FloatingPanel(scheduler: scheduler, screens: { screenList }, glass: false)
fallback.headless = true
fallback.show(session(remaining: 1500, started: -1500), saved: nil)
let fallbackEffect = fallback.backdrop as? NSVisualEffectView
check("fallback: the HUD blur", !fallback.usesGlass && fallbackEffect?.material == .hudWindow && fallbackEffect?.state == .active)
check("fallback: cut to the pill's shape", fallbackEffect?.maskImage != nil && fallbackEffect?.maskImage?.capInsets.left == PanelStyle.radius)
check("fallback: the chrome on the blur, painting the denser tint", fallback.chrome.superview === fallback.backdrop && fallback.chrome.canvas == GlassStyle.fallbackCanvas)
check("fallback: the edges on top", fallback.chrome.subviews.last === fallback.edges)
check("fallback: the same fixed size", fallback.frame.height == 40 && fallback.frame.width == fallback.controlsWidth && fallback.frame.width == floating.frame.width, "\(fallback.frame)")
fallback.setHovering(true, animated: false)
check("fallback: hovering keeps the size", fallback.frame.size == NSSize(width: floating.frame.width, height: 40), "\(fallback.frame)")
fallback.setHovering(false, animated: false)
fallback.hide()

// The lava lamp. The layout is pure and seeded: every seed's blobs keep
// their centres inside the pill for the whole drift.
let pillSize = CGSize(width: floating.frame.width, height: 40)
let lavaBounds = CGRect(origin: .zero, size: pillSize).insetBy(dx: LavaStyle.inset, dy: LavaStyle.inset)
var lavaProblems: [String] = []
var paleSeen = false
var deepSeen = false
for seed in UInt64(0)..<300 {
  var rng = SeededGenerator(seed: seed)
  let blobs = LavaLayout.blobs(in: pillSize, using: &rng)
  if blobs.count != LavaStyle.count { lavaProblems.append("seed \(seed): \(blobs.count) blobs") }
  for blob in blobs {
    let color = blob.color.usingColorSpace(.sRGB)!
    if !lavaBounds.contains(blob.from) || !lavaBounds.contains(blob.to) {
      lavaProblems.append("seed \(seed): drift \(blob.from) to \(blob.to) leaves \(lavaBounds)")
    }
    if !LavaStyle.diameter.contains(blob.diameter) { lavaProblems.append("seed \(seed): diameter \(blob.diameter)") }
    if !LavaStyle.alpha.contains(color.alphaComponent) { lavaProblems.append("seed \(seed): alpha \(color.alphaComponent)") }
    if ![blob.periodX, blob.periodY, blob.periodScale].allSatisfy({ LavaStyle.period.contains($0) }) {
      lavaProblems.append("seed \(seed): periods \(blob.periodX) \(blob.periodY) \(blob.periodScale)")
    }
    if !(0..<1).contains(blob.phase) { lavaProblems.append("seed \(seed): phase \(blob.phase)") }
    // Between #3FA36A and #9BE7B0 on every channel.
    let inRange = { (value: CGFloat, low: CGFloat, high: CGFloat) in value >= low / 255 - 0.002 && value <= high / 255 + 0.002 }
    if !(inRange(color.redComponent, 0x3F, 0x9B) && inRange(color.greenComponent, 0xA3, 0xE7) && inRange(color.blueComponent, 0x6A, 0xB0)) {
      lavaProblems.append("seed \(seed): colour \(color)")
    }
    if color.greenComponent > 0.85 { paleSeen = true }
    if color.greenComponent < 0.7 { deepSeen = true }
  }
}
check("lava: 5 blobs, 60 to 120 pt, alpha 25 to 45 %, 12 to 25 s, pale to deep green, centres inside the pill (300 seeds)",
  lavaProblems.isEmpty, lavaProblems.prefix(3).joined(separator: "; "))
check("lava: the colours span pale to deep", paleSeen && deepSeen)
var seedA = SeededGenerator(seed: 42)
var seedB = SeededGenerator(seed: 42)
var seedC = SeededGenerator(seed: 43)
let blobsA = LavaLayout.blobs(in: pillSize, using: &seedA)
check("lava: a seed gives the same blobs", blobsA == LavaLayout.blobs(in: pillSize, using: &seedB))
check("lava: another seed, other blobs", blobsA != LavaLayout.blobs(in: pillSize, using: &seedC))
check("lava: the blobs spread across the pill", (blobsA.map(\.from.x).min() ?? 0) < pillSize.width / 3 && (blobsA.map(\.from.x).max() ?? 0) > pillSize.width * 2 / 3, "\(blobsA.map(\.from))")
var tinyRng = SeededGenerator(seed: 1)
check("lava: no blobs in a pill too small to hold one", LavaLayout.blobs(in: CGSize(width: 6, height: 40), using: &tinyRng).isEmpty)

let lamp = LiveBackgroundView(seed: 7)
lamp.frame = NSRect(origin: .zero, size: pillSize)
check("lamp: one disc per blob, clipped to the pill's rounded shape", lamp.blobLayers.count == LavaStyle.count
  && lamp.layer?.masksToBounds == true && lamp.layer?.cornerRadius == PanelStyle.radius)
check("lamp: never takes the mouse", lamp.hitTest(NSPoint(x: 20, y: 20)) == nil)
var driftProblems: [String] = []
for (disc, blob) in zip(lamp.blobLayers, lamp.blobs) {
  if disc.type != .radial || disc.bounds.width != blob.diameter || disc.bounds.height != blob.diameter {
    driftProblems.append("disc \(disc.bounds) \(disc.type.rawValue)")
  }
  // Soft all the way out: clear at the rim.
  if let last = (disc.colors as? [CGColor])?.last, last.alpha != 0 { driftProblems.append("rim alpha \(last.alpha)") }
  for (key, keyPath, from, to, period) in [
    ("lava.x", "position.x", blob.from.x, blob.to.x, blob.periodX), ("lava.y", "position.y", blob.from.y, blob.to.y, blob.periodY),
  ] {
    guard let animation = disc.animation(forKey: key) as? CABasicAnimation else {
      driftProblems.append("no \(key)")
      continue
    }
    if animation.keyPath != keyPath || animation.fromValue as? CGFloat != from || animation.toValue as? CGFloat != to
      || animation.duration != period || !animation.autoreverses || animation.repeatCount != .infinity
      || animation.timingFunction != CAMediaTimingFunction(name: .easeInEaseOut)
    {
      driftProblems.append("\(key): \(String(describing: animation.fromValue)) to \(String(describing: animation.toValue)) over \(animation.duration)")
    }
  }
  if let scale = disc.animation(forKey: "lava.scale") as? CABasicAnimation {
    if scale.fromValue as? CGFloat != 1 - LavaStyle.breathe || scale.toValue as? CGFloat != 1 + LavaStyle.breathe {
      driftProblems.append("scale \(String(describing: scale.fromValue))")
    }
  } else {
    driftProblems.append("no lava.scale")
  }
}
check("lamp: each disc drifts between its blob's points, eased, looping, and breathes", driftProblems.isEmpty, driftProblems.prefix(3).joined(separator: "; "))
check("lamp: runs until told otherwise", lamp.isRunning && lamp.layer?.speed == 1)
lamp.setRunning(false)
let frozenAt = lamp.layer?.timeOffset ?? -1
check("lamp: stopping freezes the clock", !lamp.isRunning && lamp.layer?.speed == 0 && frozenAt > 0)
lamp.setRunning(false)
check("lamp: stopping twice keeps the frozen time", lamp.layer?.speed == 0 && lamp.layer?.timeOffset == frozenAt)
lamp.setRunning(true)
check("lamp: starting again runs the clock on from there", lamp.isRunning && lamp.layer?.speed == 1 && lamp.layer?.timeOffset == 0
  && abs((lamp.layer?.convertTime(CACurrentMediaTime(), from: nil) ?? 0) - frozenAt) < 1)
lamp.dimmed = true
check("lamp: dimmed for a paused session", lamp.layer?.opacity == LavaStyle.pausedOpacity)
lamp.dimmed = false
check("lamp: full again after", lamp.layer?.opacity == 1)
let stillLamp = LiveBackgroundView(seed: 7)
stillLamp.reduceMotion = { true }
stillLamp.setRunning(false)
stillLamp.frame = NSRect(origin: .zero, size: pillSize)
stillLamp.setRunning(true)
check("lamp: Reduce Motion keeps it still", !stillLamp.isRunning && stillLamp.layer?.speed == 0 && stillLamp.blobLayers.count == LavaStyle.count)
// Switched while it shows: the system's notification applies it at once.
var motionReduced = false
stillLamp.reduceMotion = { motionReduced }
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
check("lamp: Reduce Motion switched off: it drifts at once", stillLamp.isRunning && stillLamp.layer?.speed == 1)
motionReduced = true
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
check("lamp: switched on: it stops at once", !stillLamp.isRunning && stillLamp.layer?.speed == 0)
motionReduced = false
stillLamp.setRunning(false)
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
check("lamp: the setting never starts a lamp the panel stopped", !stillLamp.isRunning)

// In the panel: under everything else, drifting only while it shows a
// running session.
check("panel lamp: over the tint, under the pill, the controls and the edges", floating.chrome.subviews.first === floating.lava
  && floating.lava.frame == floating.chrome.bounds && floating.lava.blobLayers.count == LavaStyle.count)
check("panel lamp: blobs inside the pill", floating.lava.blobs.allSatisfy {
  CGRect(origin: .zero, size: floating.lava.bounds.size).insetBy(dx: LavaStyle.inset, dy: LavaStyle.inset).contains($0.from)
    && CGRect(origin: .zero, size: floating.lava.bounds.size).insetBy(dx: LavaStyle.inset, dy: LavaStyle.inset).contains($0.to)
})
floating.lava.reduceMotion = { false }
ui.update(session(remaining: 1500, started: -1500))
check("panel lamp: drifts while running", floating.lava.isRunning && !floating.lava.dimmed && floating.lava.layer?.speed == 1)
ui.update(session(state: "paused", remaining: 1500, started: -1500))
check("panel lamp: a paused session freezes and dims it", !floating.lava.isRunning && floating.lava.dimmed
  && floating.lava.layer?.speed == 0 && floating.lava.layer?.opacity == LavaStyle.pausedOpacity)
ui.update(session(remaining: 1500, started: -1500))
check("panel lamp: resuming starts it again, full strength", floating.lava.isRunning && !floating.lava.dimmed && floating.lava.layer?.opacity == 1)
floating.hide()
check("panel lamp: hidden, it stops", !floating.isVisible && !floating.lava.isRunning && floating.lava.layer?.speed == 0)
ui.update(session(remaining: 1500, started: -1500))
check("panel lamp: shown again, it runs", floating.isVisible && floating.lava.isRunning)
let fallbackLamp = FloatingPanel(scheduler: scheduler, screens: { screenList }, glass: false)
check("panel lamp: still until the panel first shows", !fallbackLamp.lava.isRunning)

ui.update(session(remaining: 3000, started: 0))
check("at the start: no green", floating.content?.progress == 0 && floating.pill.progressRect.width == 0)
ui.update(session(remaining: 0, started: -3000))
check("at the end: all green", floating.content?.progress == 1)
ui.update(session(remaining: 2100, started: -1500))
check("extended by 10 min: the fill drops to 1500/3600", abs((floating.content?.progress ?? 0) - 1500.0 / 3600) < 0.001, "\(floating.content?.progress ?? -1)")
ui.update(session(state: "paused", remaining: 1500, started: -1500))
check("paused title", floating.content?.titleText == "⏸ 25:00 Deep Work", floating.content?.titleText ?? "nil")
check("paused keeps the fill", abs((floating.content?.progress ?? 0) - 0.5) < 0.001)
let pausedPanelWidth = floating.frame.width
ui.update(session(remaining: 1500, started: -1500))
check("paused pill keeps the same size and its right edge", pausedPanelWidth == floating.frame.width && floating.frame.maxX == defaultFrame.maxX, "\(floating.frame)")
ui.update(session(goal: "Write the quarterly planning document for the whole team", remaining: 1500, started: -1500))
check("a long goal does not change the pill's size", floating.frame.width == floating.controlsWidth && floating.frame.height == 40, "\(floating.frame)")
do {
  let pill = floating.pill
  let rect = pill.goalRect
  check("the goal starts after the chip", rect.minX == pill.chipRect.maxX + PanelStyle.goalGap, "\(rect)")
  check("the goal ends inside the pill", rect.maxX <= pill.bounds.width - PanelStyle.goalTrailing + 2 && rect.width > 40, "\(rect) \(pill.bounds)")
  check("a long goal is truncated in that box", pill.goalIsTruncated)
  check("the full goal is still read out", (pill.accessibilityLabel() ?? "").contains("Write the quarterly planning document for the whole team"))
  ui.update(session(goal: "Deep Work", remaining: 1500, started: -1500))
  check("a short goal is not truncated", !floating.pill.goalIsTruncated)
}
ui.update(session(remaining: 1500, started: -1500))

// The pill changes width while the controls show (paused adds a glyph):
// the row is laid out from the anchored edge, so it does not move.
floating.mouseEntered()
let rowBefore = floating.frame
ui.update(session(state: "paused", remaining: 1500, started: -1500))
check("a width change under the controls leaves them in place", floating.frame == rowBefore, "\(floating.frame) \(rowBefore)")
floating.setHovering(false, animated: false)
check("the pill comes back on the same right edge", floating.frame.maxX == rowBefore.maxX && floating.frame.width == pausedPanelWidth)
ui.update(session(remaining: 1500, started: -1500))

// Hover: controls, then back after a short delay.
let idle = floating.frame
floating.mouseEntered()
check("hover shows the controls", floating.isHovering && !floating.controls.isHidden && floating.controls.alphaValue == 1 && floating.pill.isHidden)
check("hover row is 40 tall with the controls' width", floating.frame.height == 40 && floating.frame.width == floating.controlsWidth, "\(floating.frame)")
check("hover keeps the top edge and the right edge", floating.frame.maxY == idle.maxY && floating.frame.maxX == idle.maxX, "\(floating.frame) \(idle)")
check("buttons: Pause, Complete, …", floating.pauseButton.title == "Pause" && floating.completeButton.title == "Complete" && floating.moreButton.title == "" && floating.moreButton.accessibilityLabel() == "More")
check("the handle sits at the right end", floating.handle.frame.maxX <= floating.controlsWidth && floating.handle.frame.minX > floating.moreButton.frame.maxX, "\(floating.handle.frame)")
floating.mouseExited()
check("leaving waits before going back", floating.isHovering)
scheduler.advance(0.1)
floating.mouseEntered()
scheduler.advance(0.2)
check("coming back within the delay keeps the controls", floating.isHovering)
floating.mouseExited()
scheduler.advance(0.15)
check("after 150 ms the pill is back", !floating.isHovering && !floating.pill.isHidden && floating.controls.isHidden && floating.frame == idle, "\(floating.frame)")

// The pointer poll and the tracking area report crossings once.
floating.pointerMoved(inside: true)
check("pointer in: controls", floating.isHovering && floating.pointerInside)
floating.pointerMoved(inside: false)
floating.pointerMoved(inside: false)
scheduler.advance(0.1)
floating.pointerMoved(inside: false)
scheduler.advance(0.06)
check("a repeated 'outside' does not push the exit back", !floating.isHovering)
floating.pointerMoved(inside: true)
floating.pointerMoved(inside: true)
check("in again", floating.isHovering)
floating.pointerMoved(inside: false)
scheduler.advance(0.2)
check("out again", !floating.isHovering)

// Pause menu and the timed pause.
floating.mouseEntered()
fake.calls.removeAll()
floating.pauseButton.performClick(nil)
check("Pause opens the pause menu", popped.last == "Pause", "\(popped)")
check("still hovering after the menu", floating.isHovering)
let pauseTitles = floating.pauseMenu.items.map { $0.isSeparatorItem ? "---" : $0.title }
check(
  "hover glyphs are circled symbols that exist",
  ["pause", "play", "checkmark", "ellipsis"].allSatisfy { NSImage(systemSymbolName: $0 + ".circle", accessibilityDescription: nil) != nil })
check("glow: 85 % at the edge, nothing past 170 pt", abs(GlowView.intensity(at: 0) - 0.85) < 0.001 && GlowView.intensity(at: 170) == 0 && GlowView.intensity(at: 85) < GlowView.intensity(at: 40))
check("glow: inner corners round to about 120 pt", abs(GlowView.band(NSRect(x: 0, y: 0, width: 1512, height: 982), depth: 170).bounds.width - (1512 - 340)) < 0.5 && abs(GlowView.cornerRadius(at: 170) - 120) < 0.01 && GlowView.cornerRadius(at: 10) > 10)
check("pause menu items", pauseTitles == ["1 minute", "2 minutes", "5 minutes", "10 minutes", "---", "Indefinitely"], "\(pauseTitles)")
perform(floating.pauseMenu.items[2])
check("5 minutes pauses", fake.calls == ["pause"], "\(fake.calls)")
check("and arms a 5 minute timer", ui.timedPause?.sessionId == 7, "\(String(describing: ui.timedPause))")
ui.update(session(state: "paused", remaining: 1500, started: -1500))
check("paused: the button reads Resume", floating.pauseButton.title == "Resume" && floating.pauseButton.currentSymbol == "play")
check("Pause and Resume share a width", floating.pauseButton.frame.width == FloatingPanel.pauseSlot)
scheduler.advance(299)
check("nothing before 5 minutes", fake.calls == ["pause"], "\(fake.calls)")
scheduler.advance(1)
check("after 5 minutes: resume", fake.calls == ["pause", "resume"], "\(fake.calls)")
check("the timer is gone", ui.timedPause == nil)
ui.update(session(remaining: 1200, started: -1800))

// Resume from the panel cancels the timer.
fake.calls.removeAll()
perform(floating.pauseMenu.items[1])
ui.update(session(state: "paused", remaining: 1200, started: -1800))
floating.pauseButton.performClick(nil)
check("Resume on the panel resumes", fake.calls == ["pause", "resume"], "\(fake.calls)")
ui.update(session(remaining: 1200, started: -1800))
scheduler.advance(120)
check("and the 2 minute timer never fires", fake.calls == ["pause", "resume"] && ui.timedPause == nil, "\(fake.calls)")

// Resume from the menu bar or the socket cancels it too.
fake.calls.removeAll()
perform(floating.pauseMenu.items[0])
ui.update(session(state: "paused", remaining: 1200, started: -1800))
ui.update(session(remaining: 1190, started: -1810))  // resumed elsewhere
scheduler.advance(60)
check("resumed elsewhere: the timer is dropped", fake.calls == ["pause"] && ui.timedPause == nil, "\(fake.calls)")

// Indefinitely: no timer.
fake.calls.removeAll()
perform(floating.pauseMenu.items[5])
check("Indefinitely pauses with no timer", fake.calls == ["pause"] && ui.timedPause == nil, "\(fake.calls)")
ui.update(session(state: "paused", remaining: 1190, started: -1810))
scheduler.advance(3600)
check("and stays paused", fake.calls == ["pause"], "\(fake.calls)")
floating.pauseButton.performClick(nil)
ui.update(session(remaining: 1190, started: -1810))

// A pause the core refused (still running seconds later) drops the timer.
fake.calls.removeAll()
perform(floating.pauseMenu.items[3])
now = now.addingTimeInterval(1)
ui.update(session(remaining: 1190, started: -1810))
check("still running a second later: the timer waits", ui.timedPause != nil)
now = now.addingTimeInterval(3)
ui.update(session(remaining: 1190, started: -1810))
check("refused pause: the timer is dropped", ui.timedPause == nil)
scheduler.advance(600)
check("and never resumes", fake.calls == ["pause"], "\(fake.calls)")

// A different session drops it.
perform(floating.pauseMenu.items[3])
ui.update(session(id: 99, state: "running"))
check("another session drops the timer", ui.timedPause == nil)
ui.update(session(remaining: 1500, started: -1500))

// Complete and the "…" menu.
fake.calls.removeAll()
floating.completeButton.performClick(nil)
check("Complete stops (the end sheet asks for the rating)", fake.calls == ["stop"], "\(fake.calls)")
floating.moreButton.performClick(nil)
check("… opens its menu", popped.last == "More", "\(popped)")
let moreTitles = floating.moreMenu.items.map { $0.isSeparatorItem ? "---" : $0.title }
check("… menu items", moreTitles == ["Edit", "Cancel", "---", "Move to Menu Bar", "Reset Panel Position"], "\(moreTitles)")
perform(floating.moreMenu.items[0])
check("Edit opens Focus Today", opened == [URL(string: "raycast://extensions/c-wenlong/focus/focusToday")!], "\(opened)")
perform(floating.moreMenu.items[1])
check("Cancel finishes with no rating and no note", fake.calls == ["stop", "finish nil nil"], "\(fake.calls)")

// Move to Menu Bar and back.
perform(floating.moreMenu.items[3])
check("Move to Menu Bar writes the display", fileFields()["countdownDisplay"] == "menuBar")
check("and keeps other keys", fileFields()["futureKey"] == ["keep": [1, 2]] && fileFields()["snoozeSeconds"] == 300)
check("the panel hides at once", !floating.isVisible && !floating.panel.isVisible)
check("the menu bar item shows at once", bar.statusItem.isVisible && bar.titleText == "25:00 Deep Work", bar.titleText)
perform(bar.moveItem)
check("Move to Floating Panel writes it back", fileFields()["countdownDisplay"] == "panel")
check("panel back, menu bar hidden", floating.isVisible && !bar.statusItem.isVisible)
check("the panel comes back where it was", floating.frame == idle, "\(floating.frame)")

// A hand edit of config.json switches the display on the next tick.
try! #"{"countdownDisplay": "menuBar", "futureKey": {"keep": [1, 2]}, "snoozeSeconds": 300}"#
  .write(toFile: configPath, atomically: true, encoding: .utf8)
ui.update(session(remaining: 1499, started: -1501))
check("a changed file switches to the menu bar", !floating.isVisible && bar.statusItem.isVisible)
ui.setDisplay(.panel)
ui.update(session(remaining: 1500, started: -1500))

// Dragging by the handle, and the saved position.
floating.mouseEntered()
floating.beginDrag(at: NSPoint(x: 500, y: 500))
floating.drag(to: NSPoint(x: 460, y: 440))
check("dragging moves the panel", floating.frame.maxX == idle.maxX - 40 && floating.frame.maxY == idle.maxY - 60, "\(floating.frame)")
floating.mouseExited()
check("no leaving while dragging", scheduler.pending == 0 || floating.isHovering)
floating.endDrag()
check("nothing written yet", fileFields()["panelPosition"] == nil || fileFields()["panelPosition"] == .null)
scheduler.advance(0.4)
let moved = NSPoint(x: idle.minX - 40, y: idle.maxY - 60)
check("the idle pill's top-left is saved", fileFields()["panelPosition"] == ["x": .int(Int(moved.x)), "y": .int(Int(moved.y))], "\(String(describing: fileFields()["panelPosition"]))")
scheduler.advance(0.2)
floating.mouseExited()
scheduler.advance(0.2)
check("idle again at the new place", floating.frame == NSRect(x: moved.x, y: moved.y - 40, width: idle.width, height: 40), "\(floating.frame)")

// Hidden and shown again (a new session): same place.
ui.update(nil)
check("idle: panel hidden", !floating.isVisible)
ui.update(session(id: 30, remaining: 600, started: 0))
check("the next session shows where it was left", floating.frame.minX == moved.x && floating.frame.maxY == moved.y, "\(floating.frame)")

// The second screen goes away under the panel: the next tick moves it back.
floating.mouseEntered()
floating.beginDrag(at: NSPoint(x: 0, y: 0))
floating.drag(to: NSPoint(x: 2000 - floating.frame.minX, y: 0))
floating.endDrag()
floating.mouseExited()
scheduler.advance(1)
check("dragged onto the second screen", floating.frame.minX > 1512, "\(floating.frame)")
scheduler.advance(1)
screenList = [laptop]
ui.update(session(id: 30, remaining: 590, started: 10))
check("screen unplugged: back on the main screen", FloatingPanel.isOnScreen(floating.frame, screens: [laptop]) && floating.frame.maxX == 1500, "\(floating.frame)")
screenList = [laptop, external]
ui.panelMoved(topLeft: NSPoint(x: moved.x, y: moved.y))
scheduler.advance(1)

// Parked half off the left edge: moved in so the controls row fits.
let edge = FloatingPanel.fitted(NSRect(x: -100, y: 500, width: 150, height: 34), controlsWidth: 254, anchoredRight: false, screens: [laptop])
check("half off the left edge: slid in", edge == NSRect(x: 0, y: 500, width: 150, height: 34), "\(edge)")
let rightEdge = FloatingPanel.fitted(NSRect(x: 1400, y: 960, width: 150, height: 34), controlsWidth: 254, anchoredRight: true, screens: [laptop])
check("past the right edge and under the menu bar: slid in", rightEdge == NSRect(x: 1362, y: 910, width: 150, height: 34), "\(rightEdge)")
let dockLeft = ScreenGeometry(frame: laptop.frame, visibleFrame: NSRect(x: 70, y: 0, width: 1442, height: 944))
check("clear of a Dock on the left", FloatingPanel.fitted(NSRect(x: 20, y: 500, width: 150, height: 34), controlsWidth: 254, anchoredRight: false, screens: [dockLeft]).minX == 70)
let lowLeft = FloatingPanel.fitted(NSRect(x: 10, y: 2, width: 150, height: 34), controlsWidth: 254, anchoredRight: false, screens: [laptop])
check("the taller row fits at the bottom", lowLeft == NSRect(x: 10, y: 6, width: 150, height: 34), "\(lowLeft)")
let inside = NSRect(x: 600, y: 600, width: 150, height: 34)
check("a panel well inside stays put", FloatingPanel.fitted(inside, controlsWidth: 254, anchoredRight: true, screens: [laptop, external]) == inside)
floating.mouseEntered()
floating.beginDrag(at: NSPoint(x: 0, y: 0))
floating.drag(to: NSPoint(x: -floating.frame.minX - 120, y: 0))
floating.endDrag()
check("dropped half off the left edge: the row slides back on", floating.frame.minX == 0 && floating.idleFrame.minX == 0, "\(floating.frame)")
floating.mouseExited()
scheduler.advance(1)
ui.panelMoved(topLeft: NSPoint(x: moved.x, y: moved.y))
scheduler.advance(1)

// A fresh daemon reads the saved position; off-screen falls back.
let saved = ConfigFile(path: configPath).load().panelPosition
check("the saved position reads back", saved == PanelPosition(x: Double(moved.x), y: Double(moved.y)), "\(String(describing: saved))")
check("a saved position on screen is used", FloatingPanel.idleFrame(width: 150, saved: saved, screens: [laptop, external]).origin == NSPoint(x: moved.x, y: moved.y - 40))
check("on the second screen too", FloatingPanel.idleFrame(width: 150, saved: PanelPosition(x: 2000, y: 700), screens: [laptop, external]).origin == NSPoint(x: 2000, y: 660))
check("off every screen: the default", FloatingPanel.idleFrame(width: 150, saved: PanelPosition(x: 5000, y: 700), screens: [laptop, external]) == FloatingPanel.defaultFrame(width: 150, on: laptop))
check("screen unplugged: the default", FloatingPanel.idleFrame(width: 150, saved: PanelPosition(x: 2000, y: 700), screens: [laptop]) == FloatingPanel.defaultFrame(width: 150, on: laptop))
check("half above the top: the default", FloatingPanel.idleFrame(width: 150, saved: PanelPosition(x: 100, y: 1000), screens: [laptop]) == FloatingPanel.defaultFrame(width: 150, on: laptop))
check("no saved position: the default", FloatingPanel.idleFrame(width: 150, saved: nil, screens: [laptop, external]) == FloatingPanel.defaultFrame(width: 150, on: laptop))
check("left half anchors left", !FloatingPanel.anchorsRight(NSRect(x: 40, y: 800, width: 150, height: 34), screens: [laptop]))
check("right half anchors right", FloatingPanel.anchorsRight(NSRect(x: 1300, y: 800, width: 150, height: 34), screens: [laptop]))
check("resize keeps the left edge when anchored left", FloatingPanel.resized(NSRect(x: 40, y: 800, width: 150, height: 34), to: NSSize(width: 260, height: 40), anchoredRight: false) == NSRect(x: 40, y: 794, width: 260, height: 40))

// On the left half the controls grow to the right.
floating.mouseEntered()
floating.beginDrag(at: NSPoint(x: 0, y: 0))
floating.drag(to: NSPoint(x: -(floating.frame.minX - 40), y: 0))
floating.endDrag()
check("dragged to the left half anchors left", !floating.anchoredRight)
let leftIdle = floating.idleFrame
check("hover grows to the right there", floating.frame.minX == leftIdle.minX && floating.frame.width == floating.controlsWidth, "\(floating.frame) \(leftIdle)")
floating.mouseExited()
scheduler.advance(1)

// Reset Panel Position.
perform(floating.moreMenu.items[4])
check("Reset clears the saved position", fileFields()["panelPosition"] == .null, "\(String(describing: fileFields()["panelPosition"]))")
check("and moves the panel to the default place", floating.frame == FloatingPanel.defaultFrame(width: floating.frame.width, on: laptop) && floating.anchoredRight, "\(floating.frame)")
check("config writes logged no problem", logged.isEmpty, "\(logged)")

// The end sheet hides the panel.
ui.update(session(id: 30, state: "ending", remaining: 0, plannedEnd: 10))
ui.showEndSheet(session(id: 30, state: "ending", remaining: 0, plannedEnd: 10))
check("at the end sheet the panel is hidden", !floating.isVisible && sheet.isVisible)
ui.update(session(id: 30, remaining: 300, started: -600))
check("extended: sheet gone, panel back", !sheet.isVisible && floating.isVisible)
ui.update(nil)

// MARK: Completion and the end card

func cardCentre() -> NSPoint { NSPoint(x: sheet.frame.midX, y: sheet.frame.midY) }
func finishes() -> [String] { fake.calls.filter { $0.hasPrefix("finish") } }
/// A session seen running whose timer then ran out: the card as Core shows it.
func timerRunsOut(_ id: Int, display: Bool = true) -> SessionView {
  ui.update(session(id: id, remaining: 1, started: -1499))
  let over = session(id: id, state: "ending", remaining: 0, started: -1500, plannedEnd: 0)
  ui.update(over)
  ui.showEndSheet(over)
  return over
}
/// Core's answer to a finish: idle, the sheet dismissed.
func sessionFinished() {
  ui.update(nil)
  ui.dismissEndSheet()
}

fake.calls.removeAll()
check("no sound yet", sound.plays == 0)
let startTime = scheduler.time
let over = timerRunsOut(40)
check("timer ran out: the sound plays", sound.plays == 1)
check("then the glow, and no banner", ui.completion.trace == ["sound", "glow"], "\(ui.completion.trace)")
check("a glow window per screen", ui.completion.glowWindows.filter(\.isVisible).count == 2 && ui.completion.glowFrames == [laptop.frame, external.frame])
check("glow windows ignore the mouse and float over everything", ui.completion.glowWindows.allSatisfy { $0.ignoresMouseEvents && $0.level == .screenSaver && !$0.canBecomeKey && $0.collectionBehavior.contains(.canJoinAllSpaces) })
check("the card shows at once", sheet.isVisible && sheet.statusLabel.stringValue.hasPrefix("Time's up") && scheduler.time == startTime)
check("the card starts fully opaque", panel.alphaValue == 1)
check("the card is above the glow", panel.level.rawValue > ui.completion.glowWindows[0].level.rawValue)
check("the card is a non-activating floating panel", panel.styleMask.contains(.nonactivatingPanel) && panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
let cardFrame = sheet.frame
check("the card sits top centre of the main screen, 12 below the menu bar", abs(cardFrame.midX - laptop.frame.midX) <= 1 && cardFrame.maxY == laptop.visibleFrame.maxY - 12 && cardFrame.width == 360, "\(cardFrame)")
check("the card's frame maths", EndSheet.cardFrame(size: NSSize(width: 360, height: 130), on: laptop) == NSRect(x: 576, y: 802, width: 360, height: 130))
check("the panel is hidden at once", !floating.isVisible)
check("the card counts down, not engaged, not hovered", ui.endCard?.sessionId == 40 && ui.endCard?.engaged == false && ui.endCard?.pointerInside == false)
ui.update(over)
ui.showEndSheet(over)
check("a second showEndSheet does not replay the completion", sound.plays == 1 && ui.completion.trace.count == 2)
// Opaque for 1 s, then one continuous linear fade over 5 s: no cliff.
// Core's once-a-second update while ending never lifts it.
scheduler.advance(0.5)
ui.update(over)
check("opaque at 0.5 s", panel.alphaValue == 1, "\(panel.alphaValue)")
scheduler.advance(0.5)
ui.update(over)
check("still opaque at 1 s", panel.alphaValue == 1, "\(panel.alphaValue)")
var alphas: [CGFloat] = [panel.alphaValue]
for _ in 0..<5 {
  scheduler.advance(0.25)
  ui.update(over)
  alphas.append(panel.alphaValue)
}
check("fading after 1 s, 0.05 per 0.25 s", abs(alphas[1] - 0.95) < 0.02 && abs(alphas[5] - 0.75) < 0.02, "\(alphas)")
check("updates during the fade never raise it", zip(alphas, alphas.dropFirst()).allSatisfy { $0.1 < $0.0 }, "\(alphas)")
check("the glow fades out from 1.8 s", ui.completion.trace.last == "fadeOut", "\(ui.completion.trace)")
scheduler.advance(0.25)
check("at 2.5 s the glow is gone", !ui.completion.isGlowVisible && ui.completion.trace.last == "done", "\(ui.completion.trace)")
scheduler.advance(1)
check("at 3.5 s the card is half faded", sheet.isVisible && abs(panel.alphaValue - 0.5) < 0.02, "\(panel.alphaValue)")
for _ in 0..<5 {
  let before = panel.alphaValue
  ui.update(over)
  scheduler.advance(0.3)
  check("an update at \(String(format: "%.1f", scheduler.time - startTime)) s leaves it falling", panel.alphaValue < before, "\(before) -> \(panel.alphaValue)")
}
check("at 5 s about 0.2", abs(panel.alphaValue - 0.2) < 0.02, "\(panel.alphaValue)")
scheduler.advance(0.99)
check("no finish before 6 s", finishes().isEmpty && sheet.isVisible, "\(fake.calls)")
scheduler.advance(0.01)
check("at 6 s: finished with no rating and no note", fake.calls == ["finish nil nil"], "\(fake.calls)")
check("the card is hidden at alpha 0", !sheet.isVisible && panel.alphaValue == 0, "\(panel.alphaValue)")
check("6 s in all", abs(scheduler.time - startTime - 6) < 0.001)
check("no countdown left", ui.endCard == nil)
sessionFinished()
scheduler.advance(30)
check("one finish only", fake.calls == ["finish nil nil"], "\(fake.calls)")

// The next card is opaque again.
fake.calls.removeAll()
_ = timerRunsOut(41)
check("a new card starts opaque", sheet.isVisible && panel.alphaValue == 1)
// A refresh of the card already up keeps its countdown.
scheduler.advance(2)
ui.showEndSheet(session(id: 41, state: "ending", remaining: 0, started: -1500, plannedEnd: 0))
scheduler.advance(3.99)
check("a refresh does not restart the countdown", finishes().isEmpty)
scheduler.advance(0.01)
check("finished 6 s after it first showed", fake.calls == ["finish nil nil"], "\(fake.calls)")
sessionFinished()

// The screen rule: the first screen given (the main one, as for the glow).
screenList = [external, laptop]
fake.calls.removeAll()
_ = timerRunsOut(42)
check("on another main screen: top centre of that one", abs(sheet.frame.midX - external.frame.midX) <= 1 && sheet.frame.maxY == external.visibleFrame.maxY - 12, "\(sheet.frame)")
check("the glow's main screen is the same", ui.completion.glowFrames.first == external.frame)
sheet.finishButton.performClick(nil)
sessionFinished()
screenList = [laptop, external]

// Hover at 4 s: opaque again, no finish until 6 s after the pointer leaves.
fake.calls.removeAll()
_ = timerRunsOut(43)
scheduler.advance(4)
check("mid-fade at 4 s", panel.alphaValue < 1)
pointer = cardCentre()
scheduler.advance(0.1)
check("hover: the poll sees the pointer and pauses", ui.endCard?.pointerInside == true && panel.alphaValue == 1, "\(panel.alphaValue)")
scheduler.advance(20)
check("no finish while hovered", finishes().isEmpty && sheet.isVisible && panel.alphaValue == 1, "\(fake.calls)")
pointer = away
scheduler.advance(0.1)
check("the pointer left", ui.endCard?.pointerInside == false)
scheduler.advance(0.8)
check("leaving holds it opaque for 1 s again", panel.alphaValue == 1, "\(panel.alphaValue)")
scheduler.advance(2.6)
check("half faded 3.5 s after leaving", abs(panel.alphaValue - 0.5) < 0.05, "\(panel.alphaValue)")
scheduler.advance(2.39)
check("fading, and no finish 5.9 s after leaving", finishes().isEmpty && panel.alphaValue < 1 && sheet.isVisible)
scheduler.advance(0.21)
check("finished 6 s after the pointer left (within a poll)", fake.calls == ["finish nil nil"], "\(fake.calls)")
sessionFinished()

// The pointer arriving between two polls, just before the deadline: the
// finish looks for itself and holds the card instead.
fake.calls.removeAll()
_ = timerRunsOut(55)
scheduler.advance(5.95)
pointer = cardCentre()
scheduler.advance(0.05)
check("pointer in just before 6 s, no poll yet: no finish, a hover", finishes().isEmpty && sheet.isVisible && ui.endCard?.pointerInside == true && panel.alphaValue == 1, "\(fake.calls)")
pointer = away
scheduler.advance(6.2)
check("and the finish comes 6 s after it leaves", fake.calls == ["finish nil nil"], "\(fake.calls)")
sessionFinished()

// The glow keeps one image per screen size in use.
_ = GlowImageView.image(for: NSSize(width: 800, height: 600))
_ = GlowImageView.image(for: laptop.frame.size)
check("glow images are cached per size", GlowImageView.cachedSizes.isSuperset(of: [NSSize(width: 800, height: 600), laptop.frame.size]))
_ = timerRunsOut(56)
check("a completion drops the sizes of screens that are gone", !GlowImageView.cachedSizes.contains(NSSize(width: 800, height: 600)) && GlowImageView.cachedSizes.contains(laptop.frame.size), "\(GlowImageView.cachedSizes)")
sheet.finishButton.performClick(nil)
sessionFinished()

// The tracking area reports crossings too; the poll then keeps it honest.
fake.calls.removeAll()
_ = timerRunsOut(44)
scheduler.advance(4.05)
let entered = NSEvent.enterExitEvent(
  with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
  eventNumber: 0, trackingNumber: 0, userData: nil)!
pointer = cardCentre()
sheet.content.mouseEntered(with: entered)
check("an entered event pauses at alpha 1", ui.endCard?.pointerInside == true && panel.alphaValue == 1)
scheduler.advance(10)
check("still up while the pointer stays", finishes().isEmpty && sheet.isVisible)
pointer = away
let exited = NSEvent.enterExitEvent(
  with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
  eventNumber: 0, trackingNumber: 0, userData: nil)!
sheet.content.mouseExited(with: exited)
scheduler.advance(5.95)
check("an exited event restarts the 6 s", finishes().isEmpty)
scheduler.advance(0.1)
check("and it finishes after them", fake.calls == ["finish nil nil"], "\(fake.calls)")
sessionFinished()

// Using the card cancels the auto-finish for good.
fake.calls.removeAll()
_ = timerRunsOut(45)
scheduler.advance(1)
click(star: 3)
check("a star click engages", ui.endCard?.engaged == true && sheet.rating == 3)
scheduler.advance(60)
check("no finish after a star click", finishes().isEmpty && sheet.isVisible && panel.alphaValue == 1, "\(fake.calls)")
sheet.finishButton.performClick(nil)
check("then Finish sends the rating", fake.calls == ["finish 3 nil"], "\(fake.calls)")
sessionFinished()

fake.calls.removeAll()
_ = timerRunsOut(46)
now = now.addingTimeInterval(1)
scheduler.advance(4.2)
check("mid-fade before the key", panel.alphaValue < 1)
key("2", 19)
check("key 2 rates and engages", sheet.rating == 2 && ui.endCard?.engaged == true)
check("and snaps back to opaque", panel.alphaValue == 1)
scheduler.advance(60)
check("no finish after a digit", finishes().isEmpty && sheet.isVisible, "\(fake.calls)")
key("\r", 36)
check("Return finishes with it", fake.calls == ["finish 2 nil"], "\(fake.calls)")
sessionFinished()

fake.calls.removeAll()
_ = timerRunsOut(47)
now = now.addingTimeInterval(1)
scheduler.advance(2)
key("a", 0)
check("a typed character engages", ui.endCard?.engaged == true && sheet.noteField.stringValue == "a", sheet.noteField.stringValue)
scheduler.advance(60)
check("no finish after typing", finishes().isEmpty && sheet.isVisible, "\(fake.calls)")
(sheet.noteField.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
sheet.finishButton.performClick(nil)
check("Finish sends the note", fake.calls == ["finish nil \"a\""], "\(fake.calls)")
sessionFinished()

// A click on bare card (no star, button or field under it) engages too.
fake.calls.removeAll()
_ = timerRunsOut(54)
scheduler.advance(3)
check("mid-fade before the click", panel.alphaValue < 1)
let bare = sheet.content.convert(NSPoint(x: sheet.content.bounds.maxX - 8, y: sheet.content.bounds.maxY - 8), to: nil)
for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
  panel.sendEvent(NSEvent.mouseEvent(
    with: type, location: bare, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
}
check("a click on bare card engages and snaps it opaque", ui.endCard?.engaged == true && panel.alphaValue == 1 && sheet.rating == nil)
scheduler.advance(60)
check("no finish after a click on the card", finishes().isEmpty && sheet.isVisible, "\(fake.calls)")
sheet.finishButton.performClick(nil)
sessionFinished()

// Typing straight into the note (the field editor) engages too.
fake.calls.removeAll()
_ = timerRunsOut(48)
now = now.addingTimeInterval(1)
panel.makeFirstResponder(sheet.noteField)
(sheet.noteField.currentEditor() as? NSTextView)?.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
check("typing in the note field engages", ui.endCard?.engaged == true && sheet.noteField.stringValue == "z", sheet.noteField.stringValue)
scheduler.advance(60)
check("no finish after typing in the field", finishes().isEmpty && sheet.isVisible)
sessionFinished()

fake.calls.removeAll()
_ = timerRunsOut(49)
now = now.addingTimeInterval(1)
panel.makeFirstResponder(sheet.noteField)
(sheet.noteField.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.moveLeft(_:)))
check("an arrow key in the note engages", ui.endCard?.engaged == true)
sessionFinished()

// Keys typed in the grace period (meant for another app) do not engage.
fake.calls.removeAll()
_ = timerRunsOut(50)
key("a", 0)
key("3", 20)
key("\t", 48)
check("keys inside the grace period: no note, no rating, not engaged", sheet.noteField.stringValue == "" && sheet.rating == nil && ui.endCard?.engaged == false, sheet.noteField.stringValue)
scheduler.advance(6)
check("so it still finishes by itself", fake.calls == ["finish nil nil"], "\(fake.calls)")
sessionFinished()

// Extend and Finish presses answer it; nothing comes later.
fake.calls.removeAll()
_ = timerRunsOut(51)
scheduler.advance(1)
sheet.extendButtons[0].performClick(nil)
check("Extend on the card extends", fake.calls == ["extend 300"] && !sheet.isVisible, "\(fake.calls)")
ui.update(session(id: 51, remaining: 300, started: -1500))
scheduler.advance(60)
check("no finish after Extend", fake.calls == ["extend 300"], "\(fake.calls)")
ui.update(nil)

fake.calls.removeAll()
_ = timerRunsOut(52)
scheduler.advance(4.2)
sheet.finishButton.performClick(nil)
check("Finish mid-fade finishes once", fake.calls == ["finish nil nil"], "\(fake.calls)")
scheduler.advance(60)
check("and nothing after it", fake.calls == ["finish nil nil"], "\(fake.calls)")
sessionFinished()

// The same session back after an extend keeps what was entered, and the
// new card's auto-finish sends it (as Finish would).
fake.calls.removeAll()
_ = timerRunsOut(53)
click(star: 4)
sheet.extendButtons[0].performClick(nil)
ui.update(session(id: 53, remaining: 300, started: -1500))
let soundsBack = sound.plays
_ = timerRunsOut(53)
check("back after an extend: the completion again, a new countdown, the rating kept", ui.endCard?.engaged == false && sheet.rating == 4 && sound.plays == soundsBack + 1, "\(sound.plays)")
scheduler.advance(6)
check("left alone, it finishes with the kept rating", fake.calls == ["extend 300", "finish 4 nil"], "\(fake.calls)")
sessionFinished()

// Manual stop: no sound or glow, the same card and timer.
fake.calls.removeAll()
let soundsBefore = sound.plays
ui.update(session(id: 60, remaining: 600, started: -900))
let stopped = session(id: 60, state: "ending", remaining: 0, started: -900, plannedEnd: 600)
ui.update(stopped)
ui.showEndSheet(stopped)
check("manual stop: no sound, the card at once", sound.plays == soundsBefore && sheet.isVisible && sheet.statusLabel.stringValue.hasPrefix("Stopped"))
check("manual stop: top centre too", sheet.frame == cardFrame, "\(sheet.frame)")
scheduler.advance(5.99)
check("manual stop: nothing before 6 s", finishes().isEmpty)
scheduler.advance(0.01)
check("manual stop: finished at 6 s", fake.calls == ["finish nil nil"], "\(fake.calls)")
sessionFinished()

// Paused past its planned end: the completion plays, the card at once.
fake.calls.removeAll()
ui.update(session(id: 61, state: "paused", remaining: 1, started: -1499))
let pausedOver = session(id: 61, state: "ending", remaining: 0, started: -1500, plannedEnd: 0)
ui.update(pausedOver)
ui.showEndSheet(pausedOver)
check("paused past the end: sound and card at once", sound.plays == soundsBefore + 1 && sheet.isVisible)
sheet.finishButton.performClick(nil)
sessionFinished()

// A daemon restarted at the end sheet: no sound, the card and its timer.
fake.calls.removeAll()
ui.showEndSheet(session(id: 62, state: "ending", remaining: 0, plannedEnd: -60))
check("restart at the sheet: no sound, the card at once", sound.plays == soundsBefore + 1 && sheet.isVisible)
scheduler.advance(6)
check("restart at the sheet: finished at 6 s", fake.calls == ["finish nil nil"], "\(fake.calls)")
sessionFinished()

// Extended from the menu bar or Raycast while the card counts down.
fake.calls.removeAll()
_ = timerRunsOut(63)
scheduler.advance(2)
ui.update(session(id: 63, remaining: 300, started: -1500))
check("extended elsewhere: card gone, panel back", !sheet.isVisible && floating.isVisible && ui.endCard == nil)
scheduler.advance(30)
check("and no finish later", finishes().isEmpty, "\(fake.calls)")
ui.update(nil)

// Finished from Raycast while the card counts down.
_ = timerRunsOut(64)
scheduler.advance(2)
sessionFinished()
scheduler.advance(30)
check("finished elsewhere: no finish from the card", finishes().isEmpty && !sheet.isVisible, "\(fake.calls)")

// Cancel: finished straight away, nothing plays.
let soundsAtCancel = sound.plays
ui.update(session(id: 65, remaining: 600, started: -900))
ui.update(nil)
check("cancel: no sound, no card", sound.plays == soundsAtCancel && !sheet.isVisible && !floating.isVisible)

// On the menu bar display the completion plays and the card shows.
ui.setDisplay(.menuBar)
_ = timerRunsOut(66)
check("menu bar display: the completion plays and the card shows", sound.plays == soundsAtCancel + 1 && sheet.isVisible && !floating.isVisible && bar.statusItem.isVisible)
sheet.finishButton.performClick(nil)
sessionFinished()

// Turned off (the UI demo without FOCUS_UI_DEMO_COMPLETE): the card alone.
ui.completionEnabled = false
_ = timerRunsOut(67)
check("completion off: no sound, the card", sound.plays == soundsAtCancel + 1 && sheet.isVisible)
ui.completionEnabled = true
sessionFinished()
ui.setDisplay(.panel)
fake.calls.removeAll()

// MARK: Presenter plumbing

final class Host: PresenterHost, SessionPresenterDelegate {
  var presenter: SessionPresenter = NullPresenter()
  func presenterPause() {}
  func presenterResume() {}
  func presenterExtend(seconds: Int) {}
  func presenterStop() {}
  func presenterFinish(rating: Int?, note: String?) {}
}
let host = Host()
attachPresenter(to: host)
check("attachPresenter sets a UIPresenter on a PresenterHost", host.presenter is UIPresenter)
check("attachPresenter makes the host the delegate", host.presenter.delegate === host)
(host.presenter as? UIPresenter)?.update(nil)
attachPresenter(to: NSObject())
check("attachPresenter ignores other objects", true)

// MARK: Block window

let blockWindow = BlockWindow()
blockWindow.headless = true
check("block title", BlockWindow.title(appName: "Calculator") == "Calculator has been blocked")
check("block title without a name", BlockWindow.title(appName: "  ") == "This app has been blocked")
check("block window hidden at first", !blockWindow.isVisible)
blockWindow.show(appName: "Calculator", bundleId: "com.apple.Calculator", icon: nil, snoozeSeconds: 180)
check("show shows it", blockWindow.isVisible && blockWindow.bundleId == "com.apple.Calculator")
check("title text", blockWindow.titleLabel.stringValue == "Calculator has been blocked", blockWindow.titleLabel.stringValue)
check("snooze label for 180 s", blockWindow.snoozeButton.title == "Snooze for 3 minutes", blockWindow.snoozeButton.title)
check("footer text", blockWindow.footerLabel.stringValue == "End your focus session to access this page")
check("a placeholder icon without the app's", blockWindow.iconView.image != nil)
check("the panel floats below the menu bar", blockWindow.panel.level == .floating && blockWindow.panel.styleMask.contains(.nonactivatingPanel))
blockWindow.show(appName: "Messages", bundleId: "com.apple.MobileSMS", icon: nil, snoozeSeconds: 45)
check("snooze label for 45 s", blockWindow.snoozeButton.title == "Snooze for 45 seconds", blockWindow.snoozeButton.title)
check("showing again retargets", blockWindow.titleLabel.stringValue == "Messages has been blocked" && blockWindow.bundleId == "com.apple.MobileSMS")
blockWindow.backdrop.layoutSubtreeIfNeeded()
check("the button fits its label", blockWindow.snoozeButton.frame.width >= blockWindow.snoozeButton.intrinsicContentSize.width - 0.5, "\(blockWindow.snoozeButton.frame)")
let buttonFrame = blockWindow.snoozeButton.convert(blockWindow.snoozeButton.bounds, to: blockWindow.backdrop)
check("the button sits in the middle", abs(buttonFrame.midX - blockWindow.backdrop.bounds.midX) < 1, "\(buttonFrame)")
check("the title sits above the button", blockWindow.titleLabel.convert(blockWindow.titleLabel.bounds, to: blockWindow.backdrop).minY > buttonFrame.maxY)
blockWindow.show(appName: "<b>Evil</b> & co", bundleId: "x", icon: nil, snoozeSeconds: 180)
check("a name is shown as plain text", blockWindow.titleLabel.stringValue == "<b>Evil</b> & co has been blocked")

var windowSnoozes = 0
blockWindow.onSnooze = { windowSnoozes += 1 }
blockWindow.snoozeButton.performClick(nil)
check("Snooze calls back once and closes", windowSnoozes == 1 && !blockWindow.isVisible)
blockWindow.show(appName: "Calculator", bundleId: "com.apple.Calculator", icon: nil, snoozeSeconds: 180)
blockWindow.panel.cancelOperation(nil)
check("Escape closes without snoozing", !blockWindow.isVisible && windowSnoozes == 1 && blockWindow.bundleId == nil)
blockWindow.show(appName: "Calculator", bundleId: "com.apple.Calculator", icon: nil, snoozeSeconds: 180)
if let up = NSEvent.mouseEvent(
  with: .leftMouseUp, location: NSPoint(x: 40, y: 40), modifierFlags: [], timestamp: 0,
  windowNumber: blockWindow.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
{
  blockWindow.backdrop.mouseUp(with: up)
}
check("a click off the button closes without snoozing", !blockWindow.isVisible && windowSnoozes == 1)

// The app blocker with a real engine: the window's Snooze reaches the engine.
let blockedView = SessionView(
  id: 5, goal: "Deep Work", state: "running", startedAt: now, plannedEnd: now.addingTimeInterval(1500),
  remainingSeconds: 1500, pausedSeconds: 0, calendarTitle: "Work", extendOptions: [])
let engine = BlockEngine(
  loadConfig: { FocusConfig(json: ["snoozeSeconds": 120, "profiles": ["default": ["apps": ["com.example.Blocked"]]]]) },
  clock: { now })
engine.schedule = { _, _ in }
let appBlocker = AppBlocker(engine: engine, window: blockWindow, observe: false)
var hiddenPids: [Int32] = []
appBlocker.hideApp = {
  hiddenPids.append($0.processIdentifier)
  return true
}
engine.workspace = appBlocker
engine.sessionChanged(blockedView, profileName: "default")
check("the engine is on", engine.isOn)
let blockedApp = RunningApp(pid: 999_999, bundleId: "com.example.Blocked", name: "Blocked")
check("a blocked app coming forward is blocked", engine.appCameForward(blockedApp))
check("the page shows for it", blockWindow.isVisible && blockWindow.titleLabel.stringValue == "Blocked has been blocked" && blockWindow.snoozeButton.title == "Snooze for 2 minutes")
blockWindow.snoozeButton.performClick(nil)
let snoozedList = engine.statusFields()["snoozed"]?.arrayValue ?? []
check("Snooze on the page snoozes the app in the engine", snoozedList.count == 1 && snoozedList.first?["target"] == "com.example.Blocked", "\(snoozedList)")
check("the page is closed after Snooze", !blockWindow.isVisible)
check("the snoozed app now passes", !engine.appCameForward(blockedApp) && !blockWindow.isVisible)
check("an app that is gone is not hidden", hiddenPids.isEmpty)
check("our own process is never hidden", !engine.appCameForward(RunningApp(pid: getpid(), bundleId: "com.example.Blocked", name: "Self")))
appBlocker.block(blockedApp, snoozeSeconds: 120)
check("a decision made before a snooze does not hide the snoozed app", !blockWindow.isVisible && hiddenPids.isEmpty)
blockWindow.show(appName: "Blocked", bundleId: "com.example.Blocked", icon: nil, snoozeSeconds: 120)
engine.sessionChanged(nil, profileName: "default")
check("blocking off closes the page", !blockWindow.isVisible)
engine.sessionChanged(SessionView(id: 6, goal: "Next", state: "paused", startedAt: now, plannedEnd: now, remainingSeconds: 0, pausedSeconds: 0, calendarTitle: "", extendOptions: []), profileName: "default")
appBlocker.block(blockedApp, snoozeSeconds: 120)
check("block does nothing once blocking is off", !blockWindow.isVisible)

// MARK: Renders (optional)

if CommandLine.arguments.count > 1 {
  let folder = CommandLine.arguments[1]
  now = now.addingTimeInterval(1)
  ui.showEndSheet(session(id: 12, goal: "Deep Work", state: "ending", remaining: 0, started: -1560, plannedEnd: 0, paused: 60))
  sheet.stars.rating = 4
  func write(_ view: NSView, _ name: String) {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name))
  }
  write(sheet.content, "sheet.png")
  // The menu bar item as the dark (black) bar draws it: running, paused,
  // over an hour and a long goal, one PNG each.
  if let button = bar.statusItem.button {
    button.appearance = NSAppearance(named: .darkAqua)
    let states: [(String, SessionView)] = [
      ("menubar-running.png", session(goal: "Deep Work", remaining: 2680)),
      ("menubar-paused.png", session(goal: "Deep Work", state: "paused", remaining: 2680)),
      ("menubar-hour.png", session(goal: "Deep Work", remaining: 3725)),
      ("menubar-long.png", session(goal: "Write the quarterly planning document", remaining: 2680)),
    ]
    for (name, view) in states {
      ui.update(view)
      // At 2x, on black like Kai's menu bar.
      guard let image = button.image,
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2) + 16, pixelsHigh: 48, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      else { continue }
      rep.size = NSSize(width: image.size.width + 8, height: 24)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      NSColor.black.setFill()
      NSRect(x: 0, y: 0, width: rep.size.width, height: 24).fill()
      image.draw(in: NSRect(x: 4, y: 3, width: image.size.width, height: image.size.height))
      NSGraphicsContext.restoreGraphicsState()
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name))
    }
  }
  ui.dismissEndSheet()

  // The floating panel at 2x over a mid-grey desktop: idle near the start,
  // half way, paused, and the controls on hover. Then one glow screen at
  // half size, and the card over it where it shows.
  func render(_ view: NSView, _ name: String, background: NSColor, scale: CGFloat = 2, pad: CGFloat = 12) {
    view.layoutSubtreeIfNeeded()
    let size = NSSize(width: view.bounds.width + pad * 2, height: view.bounds.height + pad * 2)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let inner = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)
    else { return }
    rep.size = size
    inner.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: inner)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    background.setFill()
    NSRect(origin: .zero, size: size).fill()
    inner.draw(in: NSRect(x: pad, y: pad, width: view.bounds.width, height: view.bounds.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name))
  }
  let desktop = NSColor(white: 0.42, alpha: 1)
  ui.setDisplay(.panel)
  floating.setHovering(false, animated: false)
  let panelStates: [(String, SessionView)] = [
    ("panel-idle.png", session(goal: "Deep Work", remaining: 2690, started: -10)),
    ("panel-half.png", session(goal: "Deep Work", remaining: 1350, started: -1350)),
    ("panel-late.png", session(goal: "Deep Work", remaining: 300, started: -2400)),
    ("panel-paused.png", session(goal: "Deep Work", state: "paused", remaining: 1350, started: -1350)),
  ]
  for (name, view) in panelStates {
    ui.update(view)
    render(floating.chrome, name, background: desktop)
  }
  ui.update(session(goal: "Deep Work", remaining: 1350, started: -1350))
  floating.setHovering(true, animated: false)
  render(floating.chrome, "panel-hover.png", background: desktop)
  ui.update(session(goal: "Deep Work", state: "paused", remaining: 1350, started: -1350))
  render(floating.chrome, "panel-hover-paused.png", background: desktop)
  floating.setHovering(false, animated: false)
  // The chrome is what renders headless: the painted tint, the sweep, the
  // chip and the edges, without the glass's blur of the desktop. The
  // fallback's denser tint half way for comparison.
  fallback.show(session(goal: "Deep Work", remaining: 1350, started: -1350), saved: nil)
  render(fallback.chrome, "panel-fallback.png", background: desktop)
  fallback.hide()
  ui.update(nil)
  let glow = GlowView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
  render(glow, "glow.png", background: desktop, scale: 0.5, pad: 0)
  // The card over the glow on the laptop screen, as the timer runs out.
  ui.showEndSheet(session(id: 13, goal: "Deep Work", state: "ending", remaining: 0, started: -1560, plannedEnd: 0, paused: 60))
  sheet.content.layoutSubtreeIfNeeded()
  let screenView = NSView(frame: laptop.frame)
  let glowCopy = GlowView(frame: screenView.bounds)
  screenView.addSubview(glowCopy)
  if let cardRep = sheet.content.bitmapImageRepForCachingDisplay(in: sheet.content.bounds) {
    sheet.content.cacheDisplay(in: sheet.content.bounds, to: cardRep)
    let image = NSImage(size: sheet.content.bounds.size)
    image.addRepresentation(cardRep)
    let cardView = NSImageView(frame: sheet.frame)
    cardView.image = image
    cardView.imageScaling = .scaleNone
    screenView.addSubview(cardView)
  }
  render(screenView, "card-over-glow.png", background: desktop, scale: 0.5, pad: 0)
  // The card alone at 2x over the desktop grey, as it appears (0 s) and at
  // 2.5 s (1 s held, then 1.5 s of the 5 s fade: alpha 0.7).
  for (name, alpha) in [("card-0s.png", 1.0), ("card-2.5s.png", 0.7)] as [(String, CGFloat)] {
    guard let cardRep = sheet.content.bitmapImageRepForCachingDisplay(in: sheet.content.bounds) else { continue }
    sheet.content.cacheDisplay(in: sheet.content.bounds, to: cardRep)
    let pad: CGFloat = 16
    let size = NSSize(width: sheet.content.bounds.width + pad * 2, height: sheet.content.bounds.height + pad * 2)
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { continue }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    desktop.setFill()
    NSRect(origin: .zero, size: size).fill()
    cardRep.draw(
      in: NSRect(x: pad, y: pad, width: sheet.content.bounds.width, height: sheet.content.bounds.height), from: .zero,
      operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name))
  }
  ui.dismissEndSheet()

  // The block window at a laptop size, with Calculator's icon.
  let calculator = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
  blockWindow.show(appName: "Calculator", bundleId: "com.apple.Calculator", icon: calculator, snoozeSeconds: 180)
  write(blockWindow.backdrop, "block.png")
  blockWindow.close()
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
