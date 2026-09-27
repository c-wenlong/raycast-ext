// Headless checks of the menu bar countdown, the end sheet and the block
// window, with a fake delegate in place of the session logic and a real
// BlockEngine behind the app blocker. Run with scripts/test-ui.sh.
// Pass a folder to also write sheet.png, menubar-*.png and block.png there.
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

var now = Date(timeIntervalSince1970: 1_790_000_000)
let ui = UIPresenter(statusBar: NSStatusBar(), clock: { now })
ui.endSheet.headless = true
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
check("running menu", visibleTitles() == [info, "---", "Pause", "Extend", "Stop"], "\(visibleTitles())")
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
check("paused menu", visibleTitles() == [info, "---", "Resume", "Extend", "Stop"], "\(visibleTitles())")
perform(bar.pauseItem)
check("Resume calls presenterResume", lastCall() == "resume", lastCall())

ui.update(session(state: "ending", remaining: 0, plannedEnd: 0))
check("ending menu: extend only", visibleTitles() == ["Work · until \(MenuBar.timeOfDay(now))", "---", "Extend"], "\(visibleTitles())")
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
  // The block window at a laptop size, with Calculator's icon.
  let calculator = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
  blockWindow.show(appName: "Calculator", bundleId: "com.apple.Calculator", icon: calculator, snoozeSeconds: 180)
  write(blockWindow.backdrop, "block.png")
  blockWindow.close()
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
