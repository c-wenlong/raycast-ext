// Headless checks of the menu bar countdown, the floating panel, the end
// sheet, the completion sequence and the block window, with a fake delegate
// in place of the session logic, a fake scheduler and sound, and a real
// BlockEngine behind the app blocker. Run with scripts/test-ui.sh.
// Pass a folder to also write sheet.png, menubar-*.png, panel-*.png,
// banner.png, glow.png and block.png there.
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
check("sheet does not activate the app", panel.styleMask.contains(.nonactivatingPanel))
check("sheet is 420 wide", panel.frame.width == 420, "\(panel.frame)")
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
check("the green part is half the chip", abs(floating.pill.progressRect.width - chip.width / 2) <= 1, "\(floating.pill.progressRect) \(chip)")
check("the chip is 22 tall, rounded 8", chip.height == 22 && PanelStyle.chipRadius == 8)
check("the panel is 34 tall", floating.frame.height == 34, "\(floating.frame)")
check("panel floats on every space, above the block page", floating.panel.collectionBehavior.contains(.canJoinAllSpaces)
  && floating.panel.collectionBehavior.contains(.fullScreenAuxiliary) && floating.panel.level.rawValue > NSWindow.Level.floating.rawValue
  && floating.panel.level.rawValue < sheet.panel.level.rawValue)
check("panel never activates or takes focus", floating.panel.styleMask.contains(.nonactivatingPanel) && !floating.panel.canBecomeKey
  && !floating.panel.hidesOnDeactivate && !floating.panel.isMovableByWindowBackground)
let defaultFrame = FloatingPanel.defaultFrame(width: floating.frame.width, on: laptop)
check("default place: top right of the main screen, 12 in", defaultFrame == NSRect(x: 1512 - 12 - floating.frame.width, y: 944 - 12 - 34, width: floating.frame.width, height: 34), "\(defaultFrame)")
check("first show uses the default place", floating.frame == defaultFrame, "\(floating.frame)")
check("default place maths", FloatingPanel.defaultFrame(width: 160, on: laptop) == NSRect(x: 1340, y: 898, width: 160, height: 34))
check("anchored to the right edge there", floating.anchoredRight)

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
check("paused pill is wider (the glyph) and keeps its right edge", pausedPanelWidth > floating.frame.width && floating.frame.maxX == defaultFrame.maxX, "\(floating.frame)")
ui.update(session(goal: "Write the quarterly planning document for the whole team", remaining: 1500, started: -1500))
check("a long goal is cut at the pill's limit", floating.frame.width <= CountdownPillView.width(PanelContent(clock: "25:00", paused: false, progress: 0, goal: "")) + PanelStyle.goalGap + PanelStyle.goalMaxWidth + PanelStyle.goalTrailing, "\(floating.frame)")
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
check("pause menu items", pauseTitles == ["1 minute", "2 minutes", "5 minutes", "10 minutes", "---", "Indefinitely"], "\(pauseTitles)")
perform(floating.pauseMenu.items[2])
check("5 minutes pauses", fake.calls == ["pause"], "\(fake.calls)")
check("and arms a 5 minute timer", ui.timedPause?.sessionId == 7, "\(String(describing: ui.timedPause))")
ui.update(session(state: "paused", remaining: 1500, started: -1500))
check("paused: the button reads Resume", floating.pauseButton.title == "Resume" && floating.pauseButton.currentSymbol == "play.fill")
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
check("idle again at the new place", floating.frame == NSRect(x: moved.x, y: moved.y - 34, width: idle.width, height: 34), "\(floating.frame)")

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
check("past the right and top edges: slid in", rightEdge == NSRect(x: 1362, y: 948, width: 150, height: 34), "\(rightEdge)")
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
check("a saved position on screen is used", FloatingPanel.idleFrame(width: 150, saved: saved, screens: [laptop, external]).origin == NSPoint(x: moved.x, y: moved.y - 34))
check("on the second screen too", FloatingPanel.idleFrame(width: 150, saved: PanelPosition(x: 2000, y: 700), screens: [laptop, external]).origin == NSPoint(x: 2000, y: 666))
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

// MARK: Completion

fake.calls.removeAll()
check("no sound yet", sound.plays == 0)
let startTime = scheduler.time
ui.update(session(id: 40, remaining: 1, started: -1499))
now = now.addingTimeInterval(1)
let over = session(id: 40, state: "ending", remaining: 0, started: -1500, plannedEnd: 0)
ui.update(over)
ui.showEndSheet(over)
check("timer ran out: the sound plays", sound.plays == 1)
check("then the glow and the banner", ui.completion.trace == ["sound", "glow", "banner"], "\(ui.completion.trace)")
check("a glow window per screen", ui.completion.glowWindows.filter(\.isVisible).count == 2 && ui.completion.glowFrames == [laptop.frame, external.frame])
check("glow windows ignore the mouse and float over everything", ui.completion.glowWindows.allSatisfy { $0.ignoresMouseEvents && $0.level == .screenSaver && !$0.canBecomeKey && $0.collectionBehavior.contains(.canJoinAllSpaces) })
check("the banner shows top centre of the main screen", ui.completion.isBannerVisible && abs(ui.completion.bannerFrame.midX - laptop.frame.midX) <= 1 && ui.completion.bannerFrame.maxY == laptop.visibleFrame.maxY - 12, "\(ui.completion.bannerFrame)")
check("the banner is above the glow and ignores the mouse", ui.completion.banner.level.rawValue > NSWindow.Level.screenSaver.rawValue && ui.completion.banner.ignoresMouseEvents)
check("the banner's words", BannerView.title == "Focus session completed" && BannerView.subtitle == "You stayed focused.")
check("the panel is hidden at once", !floating.isVisible)
check("the end sheet waits", !sheet.isVisible && ui.pendingSheet?.id == 40)
ui.update(over)
check("ticks while the banner shows keep the sheet waiting", !sheet.isVisible && !floating.isVisible && ui.pendingSheet != nil)
ui.showEndSheet(over)
check("a second showEndSheet does not replay it", sound.plays == 1 && ui.completion.trace.count == 3)
scheduler.advance(1.8)
check("fading out from 1.8 s", ui.completion.trace.last == "fadeOut" && !sheet.isVisible, "\(ui.completion.trace)")
scheduler.advance(0.69)
check("still no sheet before 2.5 s", !sheet.isVisible && ui.completion.isGlowVisible)
scheduler.advance(0.01)
check("at 2.5 s the glow and banner are gone", !ui.completion.isGlowVisible && !ui.completion.isBannerVisible && ui.completion.trace.last == "done", "\(ui.completion.trace)")
check("and the end sheet shows", sheet.isVisible && sheet.statusLabel.stringValue.hasPrefix("Time's up") && ui.pendingSheet == nil)
check("2.5 s in all", abs(scheduler.time - startTime - 2.5) < 0.001)
check("the completion calls nothing on the session", fake.calls.isEmpty, "\(fake.calls)")
ui.update(nil)

// Manual stop: no completion, sheet at once.
ui.update(session(id: 41, remaining: 600, started: -900))
ui.update(session(id: 41, state: "ending", remaining: 0, started: -900, plannedEnd: 600))
ui.showEndSheet(session(id: 41, state: "ending", remaining: 0, started: -900, plannedEnd: 600))
check("manual stop: no sound, sheet at once", sound.plays == 1 && sheet.isVisible && ui.pendingSheet == nil)
ui.update(nil)

// Cancel: finished straight away, nothing plays.
ui.update(session(id: 42, remaining: 600, started: -900))
ui.update(nil)
check("cancel: no sound, no sheet", sound.plays == 1 && !sheet.isVisible && !floating.isVisible)

// A daemon restarted at the end sheet does not replay it.
ui.showEndSheet(session(id: 43, state: "ending", remaining: 0, plannedEnd: -60))
check("restart at the sheet: no sound, sheet at once", sound.plays == 1 && sheet.isVisible)
ui.update(nil)

// Extended (from the menu bar or Raycast) while the banner shows: no sheet after it.
ui.update(session(id: 44, remaining: 1, started: -1499))
let over44 = session(id: 44, state: "ending", remaining: 0, started: -1500, plannedEnd: 0)
ui.update(over44)
ui.showEndSheet(over44)
check("second completion plays", sound.plays == 2)
ui.update(session(id: 44, remaining: 300, started: -1500))
check("extended during the banner: no sheet pending, panel back", ui.pendingSheet == nil && floating.isVisible)
scheduler.advance(2.5)
check("and no sheet after it", !sheet.isVisible)
ui.update(nil)

// Finished from Raycast during the banner: dismiss drops the sheet.
ui.update(session(id: 45, remaining: 1, started: -1499))
let over45 = session(id: 45, state: "ending", remaining: 0, started: -1500, plannedEnd: 0)
ui.update(over45)
ui.showEndSheet(over45)
ui.update(nil)
ui.dismissEndSheet()
scheduler.advance(2.5)
check("finished during the banner: no sheet", !sheet.isVisible && ui.pendingSheet == nil)

// On the menu bar display the completion plays too.
ui.setDisplay(.menuBar)
ui.update(session(id: 46, remaining: 1, started: -1499))
let over46 = session(id: 46, state: "ending", remaining: 0, started: -1500, plannedEnd: 0)
ui.update(over46)
ui.showEndSheet(over46)
check("menu bar display: the completion plays", sound.plays == 4 && !floating.isVisible && bar.statusItem.isVisible, "\(sound.plays)")
scheduler.advance(2.5)
check("menu bar display: then the sheet", sheet.isVisible)
ui.update(nil)
ui.dismissEndSheet()

// Turned off (the UI demo without FOCUS_UI_DEMO_COMPLETE): sheet at once.
ui.completionEnabled = false
ui.update(session(id: 47, remaining: 1, started: -1499))
ui.update(session(id: 47, state: "ending", remaining: 0, started: -1500, plannedEnd: 0))
ui.showEndSheet(session(id: 47, state: "ending", remaining: 0, started: -1500, plannedEnd: 0))
check("completion off: sheet at once", sound.plays == 4 && sheet.isVisible)
ui.completionEnabled = true
ui.update(nil)
ui.dismissEndSheet()
ui.setDisplay(.panel)

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
  // half way, paused, and the controls on hover. Then the banner, and one
  // glow screen at a quarter size.
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
  ui.update(nil)
  ui.completion.bannerView.frame = NSRect(x: 0, y: 0, width: BannerView.width, height: CompletionStyle.bannerHeight)
  render(ui.completion.bannerView, "banner.png", background: desktop)
  let glow = GlowView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
  render(glow, "glow.png", background: desktop, scale: 0.5, pad: 0)

  // The block window at a laptop size, with Calculator's icon.
  let calculator = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
  blockWindow.show(appName: "Calculator", bundleId: "com.apple.Calculator", icon: calculator, snoozeSeconds: 180)
  write(blockWindow.backdrop, "block.png")
  blockWindow.close()
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
