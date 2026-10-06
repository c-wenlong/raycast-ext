// Headless checks of the attachment settings, the notch geometry, the
// Focus bridge client and the attached window: private status bar, fixed
// screens and a fake clock, a fake daemon on a temp socket, windows off
// screen. Run with `npm run test-attachments`.

import AppKit
import Foundation

// Controller checks must never load the user's settings, notes or Focus daemon.
if ProcessInfo.processInfo.environment["NOTES_ATTACHMENT_TEST_CHILD"] != "1" {
  let root = NSTemporaryDirectory() + "nat-\(UUID().uuidString.prefix(8))"
  try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  let suite = "notes-attachment-tests-\(UUID().uuidString)"
  let process = Process()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  process.arguments = ["--dir", root + "/notes"]
  var env = ProcessInfo.processInfo.environment
  env["NOTES_ATTACHMENT_TEST_CHILD"] = "1"
  env["NOTES_PANEL_DEFAULTS_SUITE"] = suite
  env["NOTES_PANEL_SUPPORT_DIR"] = root + "/support"
  env["FOCUS_DIR"] = root + "/focus"
  process.environment = env
  try! process.run()
  process.waitUntilExit()
  UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
  try? FileManager.default.removeItem(atPath: root)
  exit(process.terminationStatus)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

var failures = 0
var count = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
  count += 1
  print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  " + detail))
  if !ok { failures += 1 }
}

/// Spins the main run loop for `seconds` so timers and asyncAfter work.
func spin(_ seconds: TimeInterval) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func tempDir() -> String {
  let path = NSTemporaryDirectory() + "notes-attach-tests-\(UUID().uuidString.prefix(8))"
  try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

// MARK: - Settings

do {
  let suite = "notes-attach-settings-\(getpid())"
  let defaults = UserDefaults(suiteName: suite)!
  check("attachment defaults to floating", NoteSettings.attachment(in: defaults) == .floating)
  NoteSettings.save(.notch, in: defaults)
  defaults.synchronize()
  check("attachment persists and reloads", NoteSettings.attachment(in: UserDefaults(suiteName: suite)!) == .notch)
  defaults.set("cloud", forKey: NoteSettings.attachmentKey)
  check("an unknown stored attachment falls back to floating", NoteSettings.attachment(in: defaults) == .floating)
  check("attachment commands resolve",
    NoteSettings.change(forCommand: "attachment-floating") == .attachment(.floating)
      && NoteSettings.change(forCommand: "attachment-menuBar") == .attachment(.menuBar)
      && NoteSettings.change(forCommand: "attachment-notch") == .attachment(.notch)
      && NoteSettings.change(forCommand: "attachment-cloud") == nil)
  let rows = NoteSettings.paletteActions(appearance: .system, font: .sans, attachment: .menuBar)
  check("the attachment rows check the current one",
    rows.filter { $0.command.hasPrefix("attachment-") && $0.checked }.map(\.command) == ["attachment-menuBar"])
  check("attachment rows match 'notch' and 'attach'",
    rows.first { $0.command == "attachment-notch" }?.matches("notch") == true
      && rows.first { $0.command == "attachment-floating" }?.matches("attach window") == true)

  // The controller persists through its callback and refuses a refusal.
  let settings = SettingsController(defaults: defaults)
  var moved: NoteAttachment?
  settings.onAttachment = { value in moved = value; return value != .notch }
  check("an allowed attachment applies and saves",
    settings.handle("attachment-menuBar") && moved == .menuBar
      && NoteSettings.attachment(in: defaults) == .menuBar)
  check("a refused attachment keeps the old one",
    settings.handle("attachment-notch") && moved == .notch
      && settings.attachment == .menuBar && NoteSettings.attachment(in: defaults) == .menuBar)
  defaults.removePersistentDomain(forName: suite)
}

// MARK: - Notch geometry

do {
  let notched = NotesNotchScreen(
    frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
    notch: NSRect(x: 656, y: 950, width: 200, height: 32), barHeight: 32)
  let strip = NotchGeometry.strip(leftWing: 40, rightWing: 40, on: notched)
  check("the strip hugs the top edge over the notch",
    strip.maxY == notched.frame.maxY && abs(strip.midX - notched.notch!.midX) < 1
      && strip.width == 280 && strip.height == 33, "\(strip)")
  let plain = NotesNotchScreen(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: nil, barHeight: 24)
  let plainStrip = NotchGeometry.strip(leftWing: 40, rightWing: 40, on: plain)
  check("without a notch the strip centres on the screen with a small gap",
    plainStrip.maxY == plain.frame.maxY && plainStrip.width == 92 && abs(plainStrip.midX - 720) < 1, "\(plainStrip)")
  let small = NotesNotchScreen(frame: NSRect(x: 0, y: 0, width: 800, height: 500), notch: nil, barHeight: 24)
  let card = NotchGeometry.card(size: NSSize(width: 560, height: 680), strip: NotchGeometry.strip(leftWing: 40, rightWing: 40, on: small), on: small)
  check("the card hangs from the top edge centred on the strip",
    card.maxY == small.frame.maxY && abs(card.midX - 400) < 1, "\(card)")
  let path = NotchGeometry.path(body: card, radius: NotchMetrics.cardRadius)
  check("the island path encloses the card",
    path.contains(NSPoint(x: card.midX, y: card.midY)) && path.bounds.contains(card))
  check("the window has room for the flares",
    NotchGeometry.window(card: card, strip: card).width == card.width + NotchMetrics.ear * 2)
}

// MARK: - Focus session and bridge client (injected replies)

do {
  let sessionJSON: BridgeValue = .object([
    "id": 7, "goal": "Deep Work", "state": "running", "startedAt": "2026-01-01T10:00:00.000Z",
    "plannedEnd": "2026-01-01T10:25:00.000Z", "remainingSeconds": 1500, "pausedSeconds": 0,
    "calendarTitle": "Work", "extendOptions": [300, 600, 900, 1500], "pauseStopsClock": true,
  ])
  let now = Date(timeIntervalSince1970: 1_000_000)
  let session = FocusSession(json: sessionJSON, at: now)!
  check("a snapshot parses and counts down", session.remaining(at: now.addingTimeInterval(60)) == 1440
    && session.clock(at: now) == "25:00")
  let paused = FocusSession(
    json: sessionJSON.merging(object: ["state": "paused"]), at: now)!
  check("a paused session is frozen", paused.remaining(at: now.addingTimeInterval(600)) == 1500
    && paused.clock(at: now) == "25:00")
  check("a null session parses as nil", FocusSession(json: .null, at: now) == nil)
  check("an ending session is not a live snapshot", FocusSession(
    json: sessionJSON.merging(object: ["state": "ending"]), at: now) == nil)

  // The client with no socket: replies injected.
  let client = FocusBridgeClient(focusDir: tempDir())
  client.performsIO = false
  client.now = { now }
  client.toMain = { $0() }
  var statuses: [FocusBridgeStatus] = []
  client.onStatus = { statuses.append($0) }
  var problems: [String] = []
  client.onActionProblem = { problems.append($0) }

  client.tick(active: true)
  client.receive(.success(.object([
    "ok": true, "bridgeVersion": 1, "display": "notch", "claimed": true, "ttlSeconds": 3,
    "session": sessionJSON,
  ])), kind: .lease)
  check("a claim updates the status", client.claimed && client.last.session?.goal == "Deep Work"
    && statuses.last?.display == "notch")
  let staleGeneration = client.generation
  client.release()
  check("release drops the lease", !client.claimed)
  // A reply from before the release is ignored.
  client.receive(.success(.object([
    "ok": true, "bridgeVersion": 1, "display": "notch", "claimed": true, "ttlSeconds": 3,
    "session": .null,
  ])), kind: .lease, expected: staleGeneration)
  check("a stale generation reply is dropped", !client.claimed)

  // An old daemon: ok:false "unknown command" means incompatible.
  client.receive(.success(.object(["ok": false, "error": "unknown command: notchBridge"])), kind: .probe)
  check("an old daemon reports present but incompatible",
    client.last.present && !client.last.compatible && !client.last.claimed)

  // A refused action surfaces one problem.
  client.receive(.success(.object(["ok": false, "error": "no live claim for this owner"])), kind: .action)
  check("a refused action reports once", problems == ["no live claim for this owner"], "\(problems)")

  // Transport loss: present flips off, the session clears.
  client.receive(.failure(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "gone"])), kind: .lease)
  check("transport loss clears the session and claim", !client.last.present && client.last.session == nil && !client.claimed)
}

extension BridgeValue {
  /// Test helper: `object` fields override.
  func merging(object: [String: BridgeValue]) -> BridgeValue {
    var fields = objectValue ?? [:]
    for (key, value) in object { fields[key] = value }
    return .object(fields)
  }
}

// MARK: - Bridge client over a real socket

do {
  let dir = tempDir()
  let socketPath = dir + "/focus.sock"
  // A tiny fake daemon: one JSON line in, one reply out, then it closes.
  var requests: [String] = []
  let listener = socket(AF_UNIX, SOCK_STREAM, 0)
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(socketPath.utf8CString)
  withUnsafeMutablePointer(to: &address.sun_path) { field in
    field.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
      for (offset, byte) in bytes.prefix(103).enumerated() { destination[offset] = byte }
    }
  }
  let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  check("the fake daemon binds", bound == 0 && listen(listener, 4) == 0)
  let served = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    let client = accept(listener, nil, nil)
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
    let line = String(decoding: buffer[0..<max(0, count)], as: UTF8.self)
    requests.append(line)
    let reply = #"{"ok":true,"bridgeVersion":1,"display":"notch","claimed":true,"ttlSeconds":3,"session":null}"# + "\n"
    _ = reply.withCString { send(client, $0, strlen($0), 0) }
    close(client)
    served.signal()
  }
  let client = FocusBridgeClient(focusDir: dir)
  client.toMain = { $0() }
  var status: FocusBridgeStatus?
  client.onStatus = { status = $0 }
  client.tick(active: true)
  _ = served.wait(timeout: .now() + 5)
  spin(0.05)
  check("the request carried owner, version and op",
    requests.first?.contains("\"claim\"") == true && requests.first?.contains("\"version\":1") == true
      && requests.first?.contains("\"owner\":") == true, requests.first ?? "")
  check("the reply drove the status", client.claimed && status?.claimed == true && status?.display == "notch")
  close(listener)
}

// MARK: - The attached window

do {
  // A fake notched screen and a fixed pointer/clock.
  let screen = NotesNotchScreen(
    frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
    notch: NSRect(x: 656, y: 950, width: 200, height: 32), barHeight: 32)
  var pointer = NSPoint(x: -1000, y: -1000)

  let host = AttachedPanel(mode: .notch)
  host.screen = { screen }
  host.pointerLocation = { pointer }
  host.windowTitle = "Scratch"

  // The same editor root that would come off the floating panel.
  let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
  let scroll = NSScrollView(frame: rootView.bounds)
  let tv = NSTextView(frame: scroll.bounds)
  tv.string = "# Scratch\nbody"
  scroll.documentView = tv
  rootView.addSubview(scroll)
  host.attach(root: rootView)

  host.begin()
  check("the strip orders in collapsed", !host.expanded && host.window.isVisible)
  check("the island hugs the top of the notched screen",
    host.window.frame.maxY == screen.frame.maxY, "\(host.window.frame)")

  // Hover opens the Focus tab when a session is shared, unpinned.
  let session = FocusSession(
    json: .object([
      "id": 3, "goal": "Deep Work", "state": "running", "startedAt": "2026-01-01T10:00:00.000Z",
      "plannedEnd": "2026-01-01T10:25:00.000Z", "remainingSeconds": 1500, "pausedSeconds": 0,
      "calendarTitle": "", "extendOptions": [300, 600, 900, 1500], "pauseStopsClock": true,
    ]), at: Date())!
  host.update(session: session)
  pointer = NSPoint(x: screen.notch!.midX, y: screen.notch!.midY)
  host.pointerMoved(inside: true)
  spin(0.7)
  check("resting on the strip opens the Focus tab", host.expanded && host.tab == .focus && !host.pinned)
  check("the editor stayed the same view", rootView.superview != nil && host.editorRoot === rootView
    && tv.string == "# Scratch\nbody")
  pointer = NSPoint(x: -1000, y: -1000)
  host.pointerMoved(inside: false)
  spin(0.4)
  check("leaving a hover-opened card collapses it", !host.expanded)

  // An explicit open pins: the pointer leaving does nothing.
  host.expand(tab: .notes, pinned: true)
  host.pointerMoved(inside: true)
  host.pointerMoved(inside: false)
  spin(0.4)
  check("a pinned card stays open", host.expanded && host.tab == .notes)

  // Commands through the window: ⌘K, Esc, ⌘W all route.
  var commands: [String] = []
  host.run = { commands.append($0) }
  host.window.onCommand?("hide")
  check("window commands route", commands == ["hide"])
  host.collapse()

  // Losing the session returns the Focus tab to Notes.
  host.update(session: session)
  host.expand(tab: .focus, pinned: true)
  check("the Focus tab selects while live", host.tab == .focus)
  host.update(session: nil)
  check("a session ending returns to Notes", host.tab == .notes)
  host.collapse()

  // Menu bar mode: a plain card under the anchor, nothing while closed.
  let bar = AttachedPanel(mode: .menuBar)
  bar.anchor = { NSRect(x: 1400, y: 982, width: 24, height: 24) }
  check("menu bar starts hidden", !bar.expanded && !bar.window.isVisible)
  bar.expand(tab: .notes, pinned: true)
  let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 957)
  check("the card anchors under the status item, clamped on screen",
    bar.expanded && bar.window.frame.maxX == visible.maxX - 8 && bar.window.frame.maxY <= visible.maxY
      && bar.window.frame.minX >= visible.minX,
    "\(bar.window.frame) vs \(visible)")
  bar.collapse()
  check("collapsing puts it away", !bar.window.isVisible)

  // The status item itself: private bar, note symbol, toggle wiring.
  let item = MenuBarItem(statusBar: NSStatusBar())
  var toggled = false
  item.onToggle = { toggled = true }
  item.statusItem.button?.performClick(nil)
  check("the menu bar item toggles", toggled && item.statusItem.button?.image != nil)
}

// MARK: - Floating editor roundtrip geometry

do {
  let controller = PanelController(initialCommand: "hide")
  controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
  controller.handle("attachment-floating")
  let notePath = notesDir + "/Floating geometry.md"
  try! FileManager.default.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
  try! "# Floating geometry\nPreserve this text".write(toFile: notePath, atomically: true, encoding: .utf8)
  controller.handle("open " + notePath)
  let panel = NSApp.windows.first { $0 is NSPanel && $0.styleMask.contains(.titled) }!
  panel.setFrameAutosaveName("")
  panel.setContentSize(NSSize(width: 420, height: 240))
  let root = panel.contentView!
  let scroll = root.subviews.compactMap { $0 as? NSScrollView }.first!
  let editor = scroll.documentView as! NoteTextView
  let originalText = editor.string
  for mode in ["menuBar", "notch"] {
    controller.handle("attachment-" + mode)
    controller.handle("show")
    controller.handle("attachment-floating")
    controller.handle("show")
    panel.setContentSize(NSSize(width: 420, height: 240))
    editor.scrollToEndOfDocument(nil)
    spin(0.3)
    root.layoutSubtreeIfNeeded()
    check("\(mode) roundtrip reparents the editor into the floating window",
      root.window === panel && root.superview != nil)
    let expectedSize = panel.contentRect(forFrameRect: panel.frame).size
    check("\(mode) roundtrip restores minimum floating editor bounds",
      root.frame.origin == .zero && root.frame.size == expectedSize,
      "\(root.frame) vs \(expectedSize)")
    check("\(mode) roundtrip preserves the editor and text",
      panel.contentView === root && scroll.documentView === editor && editor.string == originalText)
    let fades = root.subviews.compactMap { $0 as? FadeOverlay }
    check("\(mode) roundtrip keeps visible fades inside the floating editor",
      !fades.isEmpty && fades.allSatisfy { !$0.isHidden && root.bounds.contains($0.frame) })
    let header = expectedSize.height - panel.contentLayoutRect.height
    check("\(mode) roundtrip reserves the floating command bar",
      scroll.contentInsets.top >= header && scroll.contentInsets.top >= 52)
  }
  controller.handle("hide")
}

// MARK: - Notch activation and bridge fallback regression

do {
  NoteSettings.save(.floating, in: userDefaults)
  let controller = PanelController(initialCommand: "show")
  controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
  let fields = Mirror(reflecting: controller).children
  let bridge = fields.first { $0.label == "bridge" }!.value as! FocusBridgeClient
  let timer = fields.first { $0.label == "bridgeTimer" }!.value as! Timer
  bridge.performsIO = false
  timer.invalidate()
  func status() -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(controller.debugStatus().utf8)) as! [String: Any]
  }
  let incompatible: BridgeValue = ["ok": false, "error": "unknown command: notchBridge"]
  let compatible: BridgeValue = ["ok": true, "bridgeVersion": 1, "display": "notch", "claimed": false, "session": nil]
  controller.handle("attachment-notch")
  check("selecting notch preserves an open editor", status()["expanded"] as? Bool == true)
  bridge.receive(.success(incompatible), kind: .probe)
  check("an old Focus daemon restores a visible floating editor",
    status()["degraded"] as? Bool == true && status()["panelVisible"] as? Bool == true)
  controller.handle("attachment-floating")
  bridge.receive(.success(compatible), kind: .release)
  bridge.receive(.success(incompatible), kind: .release)
  check("late bridge replies cannot degrade floating mode", status()["degraded"] as? Bool == false)
  controller.handle("show")
  controller.handle("attachment-notch")
  check("reselecting notch reapplies cached incompatibility",
    status()["degraded"] as? Bool == true && status()["panelVisible"] as? Bool == true)
  bridge.receive(.success(compatible), kind: .probe)
  check("bridge recovery restores the open editor to the notch",
    status()["degraded"] as? Bool == false && status()["expanded"] as? Bool == true
      && status()["panelVisible"] as? Bool == false)
  controller.handle("attachment-menuBar")
  bridge.receive(.success(incompatible), kind: .release)
  check("late bridge replies cannot degrade menu bar mode", status()["degraded"] as? Bool == false)
  controller.handle("attachment-floating")
  controller.handle("hide")
}

// MARK: - Toolbar fade pixel coverage

do {
  let fade = FadeOverlay(edge: .top)
  fade.frame = NSRect(x: 0, y: 0, width: 8, height: 80)
  fade.color = .white
  fade.opaqueHeight = 52
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 80,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  fade.draw(fade.bounds)
  NSGraphicsContext.restoreGraphicsState()
  check("top fade is opaque throughout the command bar",
    (0..<52).allSatisfy { bitmap.colorAt(x: 4, y: $0)!.alphaComponent > 0.99 })
  check("top fade dissolves only below the command bar",
    bitmap.colorAt(x: 4, y: 66)!.alphaComponent < 0.8
      && bitmap.colorAt(x: 4, y: 79)!.alphaComponent < 0.1)
}

print("\(count - failures)/\(count) passed")
if failures == 0 { print("all passed") }
exit(failures == 0 ? 0 : 1)
