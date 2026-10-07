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
  tv.allowsUndo = true
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
  let editorClip = rootView.superview!.superview!
  let editorMask = editorClip.layer?.mask as? CAShapeLayer
  check("the editor clips both bottom corners to the notch outline",
    editorMask?.path?.contains(NSPoint(x: 1, y: 1)) == false
      && editorMask?.path?.contains(NSPoint(x: editorClip.bounds.maxX - 1, y: 1)) == false
      && editorMask?.path?.contains(NSPoint(x: editorClip.bounds.midX, y: 1)) == true)

  // Commands through the window: ⌘K, Esc, ⌘W all route.
  var commands: [String] = []
  host.run = { commands.append($0) }
  host.window.onCommand?("hide")
  check("window commands route", commands == ["hide"])
  host.collapse()

  // Hovering a tab switches panes: no click, no pin, no first responder.
  host.update(session: session)
  host.expand(tab: .notes, pinned: false)
  let notesCardHeight = host.window.frame.height
  let keyBefore = host.window.firstResponder
  hoverTab(host.header.focusTab, in: host) { pointer = $0 }
  check("hovering the Focus tab switches to it", host.tab == .focus && !host.pinned)
  check("hover keeps the first responder", host.window.firstResponder === keyBefore)
  check("the Focus card is compact", host.window.frame.height < notesCardHeight,
    "\(host.window.frame.height) vs \(notesCardHeight)")
  let focusCardHeight = host.window.frame.height
  hoverTab(host.header.focusTab, in: host) { pointer = $0 }
  check("re-entering the selected tab is a no-op", host.tab == .focus && host.window.frame.height == focusCardHeight)
  // A pass-through (in and out inside the dwell) never switches.
  host.header.notesTab.mouseEntered(with: NSEvent())
  host.header.notesTab.mouseExited(with: NSEvent())
  spin(0.2)
  check("in and out inside the dwell never switches", host.tab == .focus)
  // A pending switch is cancelled by leaving, and entering the other tab
  // supersedes it: on Notes, enter Focus (pending), leave Focus, enter
  // Notes (the current tab), dwell: the pending Focus switch never fires.
  hoverTab(host.header.notesTab, in: host) { pointer = $0 }
  check("back on Notes for the supersession case", host.tab == .notes)
  host.header.focusTab.mouseEntered(with: NSEvent())
  host.header.focusTab.mouseExited(with: NSEvent())
  host.header.notesTab.mouseEntered(with: NSEvent())
  spin(0.2)
  check("a superseding entry wins the dwell", host.tab == .notes)
  // The shared top nav does not move: same global x and y while the card
  // shrinks and grows under it.
  func headerGlobal() -> NSPoint {
    let p = host.header.convert(host.header.bounds.origin, to: nil)
    return NSPoint(x: p.x + host.window.frame.minX, y: p.y + host.window.frame.minY)
  }
  hoverTab(host.header.focusTab, in: host) { pointer = $0 }
  let headerBefore = headerGlobal()
  hoverTab(host.header.notesTab, in: host) { pointer = $0 }
  check("hovering the Notes tab switches back", host.tab == .notes && !host.pinned
    && host.window.frame.height == notesCardHeight && headerGlobal() == headerBefore,
    "\(host.window.frame.height) \(headerGlobal())")
  hoverTab(host.header.focusTab, in: host) { pointer = $0 }
  check("the header keeps its global spot after a compact resize", headerGlobal() == headerBefore)
  hoverTab(host.header.notesTab, in: host) { pointer = $0 }

  // Hidden tabs never switch on hover.
  host.update(session: nil)
  dwellOn(host.header.focusTab)
  check("no tabs, no hover switch", host.tab == .notes)
  host.update(session: session)
  host.collapse()
  dwellOn(host.header.focusTab)
  check("a collapsed card ignores tab hover", host.tab == .notes && !host.expanded)

  // A pinned card stays pinned through hover switches.
  host.expand(tab: .notes, pinned: true)
  hoverTab(host.header.focusTab, in: host) { pointer = $0 }
  check("hover preserves an existing pin", host.pinned && host.tab == .focus)
  hoverTab(host.header.notesTab, in: host) { pointer = $0 }

  // Editor continuity across hover switches, on a real long document the
  // user has scrolled and selected inside.
  let longScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
  longScroll.hasVerticalScroller = true
  longScroll.drawsBackground = false
  let longTV = NoteTextView(frame: longScroll.bounds)
  longTV.textContainer?.replaceLayoutManager(TaskBoxLayoutManager())
  longTV.isRichText = false
  longTV.font = Markdown.baseFont
  longTV.allowsUndo = true
  longTV.minSize = .zero
  longTV.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
  longTV.isVerticallyResizable = true
  longTV.textContainer?.widthTracksTextView = true
  longTV.textContainer?.containerSize = NSSize(width: 524, height: CGFloat.greatestFiniteMagnitude)
  longScroll.documentView = longTV
  let longRoot = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
  longRoot.addSubview(longScroll)
  longScroll.autoresizingMask = [.width, .height]
  let longHost = AttachedPanel(mode: .notch)
  longHost.screen = { screen }
  var longPointer = NSPoint(x: -1000, y: -1000)
  longHost.pointerLocation = { longPointer }
  longHost.attach(root: longRoot)
  longTV.string = (1...100).map { "line \($0) of the long note body" }.joined(separator: "\n")
  longTV.textStorage.map { Markdown.apply(to: $0) }
  longHost.update(session: session)
  longHost.expand(tab: .notes, pinned: false)
  // Let the real layout settle (the document size at this width) before
  // the fixture scrolls and captures its expectations.
  longHost.window.display()
  longTV.layoutManager?.ensureLayout(for: longTV.textContainer!)
  spin(0.05)
  longTV.setSelectedRange(NSRange(location: 1200, length: 25))
  longScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, longTV.frame.height - 250)))
  longScroll.reflectScrolledClipView(longScroll.contentView)
  let savedFrame = longRoot.frame
  let savedOrigin = longScroll.contentView.bounds.origin
  let savedSel = longTV.selectedRange()
  check("the long editor is really scrolled", savedOrigin.y > 10, "\(savedOrigin)")
  hoverTab(longHost.header.focusTab, in: longHost) { longPointer = $0 }
  check("Focus tab up: editor frozen", longHost.tab == .focus
    && longRoot.frame == savedFrame && longScroll.contentView.bounds.origin == savedOrigin
    && longTV.selectedRange() == savedSel && longRoot.autoresizingMask == [],
    "\(longRoot.frame) \(longScroll.contentView.bounds.origin)")
  // Snapshot updates while on the Focus tab must not touch the editor.
  longHost.update(session: session)
  check("a Focus tick leaves the frozen editor alone",
    longRoot.frame == savedFrame && longScroll.contentView.bounds.origin == savedOrigin
    && longTV.selectedRange() == savedSel)
  for _ in 0..<3 {
    hoverTab(longHost.header.notesTab, in: longHost) { longPointer = $0 }
    hoverTab(longHost.header.focusTab, in: longHost) { longPointer = $0 }
  }
  hoverTab(longHost.header.notesTab, in: longHost) { longPointer = $0 }
  check("hover round trips keep the editor exactly", longHost.editorRoot === longRoot
    && longRoot.frame == savedFrame && longScroll.contentView.bounds.origin == savedOrigin
    && longTV.selectedRange() == savedSel && longTV.string.hasPrefix("line 1"),
    "\(longScroll.contentView.bounds.origin) \(longTV.selectedRange())")
  longTV.insertText("x", replacementRange: longTV.selectedRange())
  hoverTab(longHost.header.focusTab, in: longHost) { longPointer = $0 }
  hoverTab(longHost.header.notesTab, in: longHost) { longPointer = $0 }
  longTV.undoManager?.undo()
  check("undo still works after hover switches",
    longTV.string == (1...100).map { "line \($0) of the long note body" }.joined(separator: "\n"), longTV.string)

  // Collapse while on Focus, then reopen on Notes: the editor must never
  // see the compact Focus frame. The undo above legitimately moved the
  // viewport to its edit, so the expectations are captured fresh here.
  let postEditFrame = longRoot.frame
  let postEditOrigin = longScroll.contentView.bounds.origin
  let postEditSel = longTV.selectedRange()
  hoverTab(longHost.header.focusTab, in: longHost) { longPointer = $0 }
  check("still on Focus after the pin-free switch", longHost.tab == .focus)
  longHost.collapse()
  longHost.expand(tab: .notes, pinned: true)
  check("collapse on Focus, reopen on Notes: editor exact",
    longHost.editorRoot === longRoot && longRoot.frame == postEditFrame
      && longScroll.contentView.bounds.origin == postEditOrigin
      && longTV.selectedRange() == postEditSel && !longRoot.isHidden,
    "\(longRoot.frame) \(longScroll.contentView.bounds.origin)")

  // Same shape via the session vanishing while collapsed on Focus.
  hoverTab(longHost.header.focusTab, in: longHost) { longPointer = $0 }
  longHost.collapse()
  longHost.update(session: nil)
  longHost.update(session: session)
  longHost.expand(tab: .notes, pinned: true)
  check("session lost while collapsed: editor still exact",
    longHost.editorRoot === longRoot && longRoot.frame == postEditFrame
      && longScroll.contentView.bounds.origin == postEditOrigin
      && longTV.selectedRange() == postEditSel,
    "\(longRoot.frame) \(longScroll.contentView.bounds.origin)")
  longHost.collapse()
  longHost.window.orderOut(nil)

  // A display too short for the compact card: the viewport shrinks, the
  // document keeps its full 98 and every control scrolls into reach.
  let tinyScreen = NotesNotchScreen(
    frame: NSRect(x: 0, y: 0, width: 1512, height: 150),
    notch: NSRect(x: 656, y: 118, width: 200, height: 32), barHeight: 32)
  let tinyHost = AttachedPanel(mode: .notch)
  tinyHost.screen = { tinyScreen }
  tinyHost.update(session: session)
  tinyHost.expand(tab: .focus, pinned: true)
  let tinyScroll = tinyHost.focusView.enclosingScrollView!
  tinyScroll.layoutSubtreeIfNeeded()
  let tinyViewport = tinyScroll.contentView.bounds.height
  check("tiny display: viewport under 98, document full", tinyViewport < FocusTabView.naturalHeight
    && tinyHost.focusView.frame.height == FocusTabView.naturalHeight,
    "\(tinyViewport) \(tinyHost.focusView.frame.height)")
  tinyScroll.contentView.scroll(to: NSPoint(x: 0, y: FocusTabView.naturalHeight - tinyViewport))
  tinyScroll.reflectScrolledClipView(tinyScroll.contentView)
  check("tiny display: the upper pill scrolls into reach",
    tinyScroll.documentVisibleRect.maxY >= tinyHost.focusView.frame.maxY - 1)
  tinyScroll.contentView.scroll(to: .zero)
  tinyScroll.reflectScrolledClipView(tinyScroll.contentView)
  check("tiny display: the lower controls scroll into reach", tinyScroll.documentVisibleRect.minY <= 8)
  tinyHost.collapse()
  tinyHost.window.orderOut(nil)

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
  controller.handle("palette")
  let actions = Mirror(reflecting: controller).children.first { $0.label == "palette" }!.value as! ActionPalette
  check("command palette excludes appearance font and attachment choices",
    actions.shownRows.contains { $0.command == "settings" && $0.keys == "⌘," } && actions.shownRows.allSatisfy { NoteSettings.change(forCommand: $0.command) == nil })
  controller.handle("palette")
  let notePath = notesDir + "/Floating geometry.md"
  try! FileManager.default.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
  try! "# Floating geometry\nPreserve this text".write(toFile: notePath, atomically: true, encoding: .utf8)
  controller.handle("open " + notePath)
  let preferences = NSApp.mainMenu!.items.first!.submenu!.items.first { $0.keyEquivalent == "," }!
  check("settings has a command-comma menu action", preferences.title == "Settings…" && preferences.target === controller)
  let settingsUI = Mirror(reflecting: controller).children.first { $0.label == "settingsPopover" }!.value as! SettingsPopover
  controller.handle("settings")
  check("keyboard settings command opens the popover", settingsUI.popover.isShown)
  settingsUI.close()
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
  controller.handle("hide")
  bridge.receive(.success(incompatible), kind: .probe)
  check("collapsed notch fallback keeps the floating editor hidden",
    status()["degraded"] as? Bool == true && status()["panelVisible"] as? Bool == false)
  bridge.receive(.success(compatible), kind: .probe)
  check("collapsed notch recovery keeps the editor collapsed",
    status()["degraded"] as? Bool == false && status()["expanded"] as? Bool == false)
  controller.handle("show")
  controller.handle("attachment-menuBar")
  check("switching an open editor to menu bar keeps it open", status()["expanded"] as? Bool == true)
  bridge.receive(.success(incompatible), kind: .release)
  check("late bridge replies cannot degrade menu bar mode", status()["degraded"] as? Bool == false)
  controller.handle("attachment-floating")
  check("switching an open editor to floating keeps it visible", status()["panelVisible"] as? Bool == true)
  controller.handle("hide")
  controller.handle("attachment-menuBar")
  check("switching a hidden editor to menu bar keeps it hidden", status()["expanded"] as? Bool == false)
  controller.handle("attachment-floating")
  check("switching a hidden editor to floating keeps it hidden", status()["panelVisible"] as? Bool == false)
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

// Settings gear routes the anchor in both hosts, apart from the action menu.
do {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
  let chrome = TitlebarChrome { _ in }
  var clicked: NSView?
  chrome.onSettings = { clicked = $0 }
  chrome.install(in: window)
  let pill = window.toolbar!.items.compactMap(\.view).first { $0.subviews.contains { $0.toolTip == "Settings" } }!
  let gear = pill.subviews.first { $0.toolTip == "Settings" } as! NSButton
  let command = pill.subviews.first { $0.toolTip == "Actions (⌘K)" }!
  gear.performClick(nil)
  check("floating settings gear follows command and passes its anchor", clicked === gear && gear.frame.minX > command.frame.maxX)
  let host = AttachedPanel(mode: .menuBar)
  host.onSettings = { clicked = $0 }
  host.header.frame = NSRect(x: 0, y: 0, width: 420, height: 40)
  host.header.layout()
  let attachedGear = host.header.subviews.first { $0.toolTip == "Settings" } as! NSButton
  attachedGear.performClick(nil)
  check("attached settings gear passes its anchor", clicked === attachedGear)
}

runBridgeReviewRegressions()
runAttachmentReviewRegressions()

/// Performs a menu item's action the way NSMenu does (honouring isEnabled).
func perform(_ item: NSMenuItem) {
  guard item.isEnabled, item.submenu == nil, let action = item.action else { return }
  _ = item.target?.perform(action, with: item)
}

/// A tab's centre in screen coordinates, for the fake pointer.
func tabCenter(_ host: AttachedPanel, _ button: ChromeButton) -> NSPoint {
  let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
  return host.window.convertToScreen(NSRect(origin: center, size: .zero)).origin
}

/// Moves the fake pointer onto a tab (via `movePointer`, so the caller's
/// pointer location updates), then lets the 0.15 s dwell fire.
func hoverTab(_ button: ChromeButton, in host: AttachedPanel, movePointer: (NSPoint) -> Void) {
  movePointer(tabCenter(host, button))
  host.pointerMoved(inside: true)
  button.mouseEntered(with: NSEvent())
  spin(0.2)
}

/// Enters a hidden or unreachable tab: the pointer stays put, the dwell
/// fires anyway, and nothing should happen.
func dwellOn(_ button: ChromeButton) {
  button.mouseEntered(with: NSEvent())
  spin(0.2)
}

// MARK: - The hosted Focus card's native controls

do {
  let t0 = Date(timeIntervalSince1970: 1_790_000_000)
  var fakeNow = t0
  func makeSession(state: String, pauseStopsClock: Bool, remaining: Int = 1500, started: String = "2026-10-07T00:00:00Z", end: String = "2026-10-07T00:25:00Z", extend: [Int] = [300, 600, 900, 1500]) -> FocusSession {
    FocusSession(json: .object([
      "id": 3, "goal": "Deep Work", "state": .string(state), "startedAt": .string(started),
      "plannedEnd": .string(end), "remainingSeconds": .int(remaining), "pausedSeconds": 60,
      "calendarTitle": "", "extendOptions": .array(extend.map { .int($0) }), "pauseStopsClock": .bool(pauseStopsClock),
    ]), at: fakeNow)!
  }

  // remaining(): a paused calendar session keeps ticking to its planned
  // end; only an ad-hoc pause freezes.
  let calPaused = makeSession(state: "paused", pauseStopsClock: false)
  let adPaused = makeSession(state: "paused", pauseStopsClock: true)
  check("paused calendar session still ticks", calPaused.remaining(at: fakeNow.addingTimeInterval(30)) == 1470)
  check("paused ad-hoc session freezes", adPaused.remaining(at: fakeNow.addingTimeInterval(30)) == 1500)
  let running = makeSession(state: "running", pauseStopsClock: false)
  check("a clock skew never adds time", running.remaining(at: fakeNow.addingTimeInterval(-30)) == 1500)

  // The hosted card: the real pill, slab and controls, top-aligned.
  let card = FocusTabView(frame: NSRect(x: 0, y: 0, width: 560, height: FocusTabView.naturalHeight))
  var sent: [(String, Int?)] = []
  card.onAction = { action, seconds in sent.append((action, seconds)) }
  var menus: [NSMenu] = []
  card.popUpMenu = { menu, _ in menus.append(menu) }
  var engaged = 0
  card.onEngage = { engaged += 1 }
  card.now = { fakeNow }
  let allCaps: Set<String> = ["pause", "resume", "stop", "extend", "pauseFor", "edit", "cancel", "moveToPanel", "moveToMenuBar"]
  card.update(session: running, actions: allCaps, at: fakeNow)
  card.layout()
  check("the Focus card uses the shared pill", card.subviews.contains { $0 is CountdownPillView })
  check("the card body is compact", FocusTabView.naturalHeight == 98)

  // Pause on a running session opens the original choices; each timed item
  // sends pauseFor seconds; Indefinitely sends the legacy pause.
  card.pauseButton.performClick(nil)
  check("Pause pops the original menu", menus.count == 1 && engaged == 1)
  let pauseTitles = menus.last!.items.map { $0.isSeparatorItem ? "---" : $0.title }
  check("the pause choices are the panel's",
    pauseTitles == ["1 minute", "2 minutes", "5 minutes", "10 minutes", "---", "Indefinitely"], "\(pauseTitles)")
  perform(menus.last!.items[2])
  check("5 minutes sends pauseFor 300", sent.last?.0 == "pauseFor" && sent.last?.1 == 300, "\(sent)")
  perform(menus.last!.items[5])
  check("Indefinitely sends the legacy pause", sent.last?.0 == "pause" && sent.last?.1 == nil)

  // Paused: the button is Resume and dispatches resume, no menu.
  card.update(session: calPaused, actions: allCaps, at: fakeNow)
  card.pauseButton.performClick(nil)
  check("paused: Resume dispatches and no menu", sent.last?.0 == "resume" && menus.count == 1, "\(sent) \(menus.count)")
  card.update(session: running, actions: allCaps, at: fakeNow)

  // Complete and the … menu.
  card.completeButton.performClick(nil)
  check("Complete dispatches stop", sent.last?.0 == "stop")
  card.moreButton.performClick(nil)
  check("More pops its menu and engages", menus.count == 2 && engaged == 2)
  let more = menus.last!
  let moreTitles = more.items.map { $0.isSeparatorItem ? "---" : $0.title }
  check("the more menu is the panel's",
    moreTitles == ["Edit", "Cancel", "---", "Move to Floating Panel", "Move to Menu Bar", "---", "Extend"], "\(moreTitles)")
  let extendItem = more.items.last!
  check("Extend carries the live options",
    extendItem.submenu?.items.map(\.title) == ["+5 min", "+10 min", "+15 min", "+25 min"]
      && extendItem.submenu?.items.map(\.tag) == [300, 600, 900, 1500],
    "\(extendItem.submenu?.items ?? [])")
  perform(more.items[0])
  check("Edit dispatches", sent.last?.0 == "edit")
  perform(more.items[1])
  check("Cancel dispatches", sent.last?.0 == "cancel")
  perform(more.items[3])
  check("Move to Floating Panel dispatches", sent.last?.0 == "moveToPanel")
  perform(more.items[4])
  check("Move to Menu Bar dispatches", sent.last?.0 == "moveToMenuBar")
  perform(extendItem.submenu!.items[0])
  check("Extend dispatches its seconds", sent.last?.0 == "extend" && sent.last?.1 == 300)

  // Capability gating: an old daemon advertises nothing new; legacy verbs
  // stay live, extras stay disabled and never dispatch.
  card.update(session: running, actions: [], at: fakeNow)
  card.pauseButton.performClick(nil)
  let oldPause = menus.last!
  check("old daemon: timed pause items disabled, Indefinitely live",
    oldPause.items.filter { !$0.isSeparatorItem && $0.tag > 0 }.allSatisfy { !$0.isEnabled }
      && oldPause.items.last?.isEnabled == true)
  sent.removeAll()
  perform(oldPause.items[0])
  check("a disabled pause choice never dispatches", sent.isEmpty)
  perform(oldPause.items.last!)
  check("Indefinitely still dispatches", sent.last?.0 == "pause")
  card.moreButton.performClick(nil)
  let oldMore = menus.last!
  check("old daemon: new items disabled", !oldMore.items[0].isEnabled && !oldMore.items[1].isEnabled
    && !oldMore.items[3].isEnabled && !oldMore.items[4].isEnabled && oldMore.items.last?.isEnabled == true)
  sent.removeAll()
  perform(oldMore.items[0])
  perform(oldMore.items[3])
  check("disabled items never dispatch", sent.isEmpty)

  // A menu outlives the session it was built for: every item is bound to
  // that session's id and re-checks its capability, so a stale click
  // reaches neither the card nor the bridge.
  let id3 = running
  let id4 = FocusSession(json: .object([
    "id": 4, "goal": "Other", "state": "running", "startedAt": "2026-10-07T00:00:00Z",
    "plannedEnd": "2026-10-07T00:25:00Z", "remainingSeconds": 1500, "pausedSeconds": 0,
    "calendarTitle": "", "extendOptions": .array([300, 600, 900, 1500].map { .int($0) }),
    "pauseStopsClock": false,
  ]), at: fakeNow)!

  // Through a real host so the bridge callback path is covered too.
  let staleHost = AttachedPanel(mode: .notch)
  var bridged: [(String, Int?)] = []
  staleHost.onFocusAction = { action, seconds in bridged.append((action, seconds)) }
  staleHost.focusView.now = { fakeNow }
  staleHost.focusView.popUpMenu = { menu, _ in menus.append(menu) }
  staleHost.update(session: id3, actions: allCaps)
  staleHost.focusView.pauseButton.performClick(nil)
  staleHost.focusView.moreButton.performClick(nil)
  let stalePause = menus[menus.count - 2]
  let staleMore = menus[menus.count - 1]
  staleHost.update(session: id4, actions: allCaps)
  for item in stalePause.items + staleMore.items + (staleMore.items.last?.submenu?.items ?? []) {
    perform(item)
  }
  check("stale menus never dispatch after the session changed", bridged.isEmpty, "\(bridged)")
  // Same id, capability revoked while the menu is open: still refused.
  staleHost.update(session: id4, actions: [])
  staleHost.focusView.pauseButton.performClick(nil)
  staleHost.focusView.moreButton.performClick(nil)
  let capPause = menus[menus.count - 2]
  let capMore = menus[menus.count - 1]
  staleHost.update(session: id4, actions: allCaps)
  for item in capMore.items { perform(item) }
  check("a menu built without capabilities never dispatches extras", bridged.isEmpty, "\(bridged)")
  for item in capPause.items.filter({ !$0.isSeparatorItem }) { perform(item) }
  check("legacy verbs still dispatch from a revoked menu", bridged.last?.0 == "pause", "\(bridged)")
  bridged.removeAll()
  // Session gone entirely: nothing acts.
  staleHost.update(session: id4, actions: allCaps)
  staleHost.focusView.moreButton.performClick(nil)
  let liveMore = menus.last!
  staleHost.update(session: nil, actions: allCaps)
  for item in liveMore.items { perform(item) }
  check("a menu outliving the session never dispatches", bridged.isEmpty)
  // A menu built for the live session still works.
  staleHost.update(session: id4, actions: allCaps)
  staleHost.focusView.moreButton.performClick(nil)
  perform(menus.last!.items[0])
  check("a fresh menu for the current session dispatches", bridged.last?.0 == "edit", "\(bridged)")
  bridged.removeAll()
  // Capability withdrawn mid-menu, same session id: new verbs refuse.
  staleHost.focusView.moreButton.performClick(nil)
  let revMore = menus.last!
  staleHost.update(session: id4, actions: [])
  for item in revMore.items { perform(item) }
  check("a capability removed while open refuses the new verbs", bridged.isEmpty, "\(bridged)")

  // A session ending stops the sweep and disables the controls.
  let deadCard = FocusTabView(frame: NSRect(x: 0, y: 0, width: 560, height: FocusTabView.naturalHeight))
  deadCard.now = { fakeNow }
  deadCard.update(session: running, actions: allCaps, at: fakeNow)
  deadCard.setActive(true)
  check("sweep runs while active", deadCard.sweepRunning)
  deadCard.update(session: nil, actions: [], at: fakeNow)
  check("a nil session stops the sweep and disables controls",
    !deadCard.sweepRunning && !deadCard.pauseButton.isEnabled
      && !deadCard.completeButton.isEnabled && !deadCard.moreButton.isEnabled)
  // A card moved off its window stops too.
  let win = NSWindow()
  let winCard = FocusTabView(frame: NSRect(x: 0, y: 0, width: 560, height: FocusTabView.naturalHeight))
  win.contentView = winCard
  winCard.now = { fakeNow }
  winCard.update(session: running, actions: allCaps, at: fakeNow)
  winCard.setActive(true)
  check("attached card sweeps", winCard.sweepRunning)
  winCard.removeFromSuperview()
  check("detaching the card stops the sweep", !winCard.sweepRunning)
  win.orderOut(nil)

  // Ordered-out host: the active predicate reads window visibility.
  staleHost.screen = {
    NotesNotchScreen(frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
      notch: NSRect(x: 656, y: 950, width: 200, height: 32), barHeight: 32)
  }
  staleHost.update(session: running, actions: allCaps)
  staleHost.expand(tab: .focus, pinned: true)
  staleHost.updateChrome()
  check("expanded Focus tab sweeps while visible", staleHost.focusView.sweepRunning || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  staleHost.window.orderOut(nil)
  staleHost.updateChrome()
  check("an ordered-out host stops the sweep", !staleHost.focusView.sweepRunning)
  staleHost.collapse()

  // advanceSweep interpolates only: the model's clock is anchored on
  // snapshots, never re-anchored by the 30 Hz path, even when the session's
  // absolute timestamps disagree with its whole-second remaining.
  let skewed = FocusSession(json: .object([
    "id": 3, "goal": "Deep Work", "state": "running", "startedAt": "2026-10-07T00:00:00Z",
    "plannedEnd": "2026-10-07T00:26:40Z", "remainingSeconds": 1500, "pausedSeconds": 0,
    "calendarTitle": "", "extendOptions": .array([300, 600].map { .int($0) }),
    "pauseStopsClock": false,
  ]), at: fakeNow)!
  let skewCard = FocusTabView(frame: NSRect(x: 0, y: 0, width: 560, height: FocusTabView.naturalHeight))
  skewCard.now = { fakeNow }
  skewCard.update(session: skewed, actions: allCaps, at: fakeNow)
  var refSweep = PanelSweep()
  refSweep.update(FocusTabView.adapter(skewed, at: fakeNow), at: fakeNow)
  let anchorBefore = skewCard.sweep.clock
  fakeNow += 0.75
  skewCard.advanceSweep()
  check("advanceSweep keeps the snapshot's clock", skewCard.sweep.clock == anchorBefore)
  check("advanceSweep follows the original sweep math",
    abs(skewCard.sweep.progress(at: fakeNow) - refSweep.progress(at: fakeNow)) < 0.0001)
  fakeNow += 1.25
  skewCard.update(session: skewed, actions: allCaps, at: fakeNow)
  refSweep.update(FocusTabView.adapter(skewed, at: fakeNow), at: fakeNow)
  check("a snapshot update still behaves like the model",
    abs(skewCard.sweep.progress(at: fakeNow) - refSweep.progress(at: fakeNow)) < 0.0001)

  // The sweep follows the shared PanelSweep across pause and extend.
  var reference = PanelSweep()
  card.update(session: running, actions: allCaps, at: fakeNow)
  reference.update(FocusTabView.adapter(running, at: fakeNow), at: fakeNow)
  check("sweep matches the original math running",
    abs(card.sweep.progress(at: fakeNow) - reference.progress(at: fakeNow)) < 0.001)
  fakeNow += 5
  card.update(session: adPaused, actions: allCaps, at: fakeNow)
  reference.update(FocusTabView.adapter(adPaused, at: fakeNow), at: fakeNow)
  check("sweep matches during an ad-hoc pause",
    abs(card.sweep.progress(at: fakeNow) - reference.progress(at: fakeNow)) < 0.001)
  card.setActive(true)
  check("the sweep timer stops on a frozen session", !card.sweepRunning)
  let extended = makeSession(state: "running", pauseStopsClock: true, remaining: 1800, end: "2026-10-07T00:30:00Z")
  card.update(session: extended, actions: allCaps, at: fakeNow)
  reference.update(FocusTabView.adapter(extended, at: fakeNow), at: fakeNow)
  check("sweep matches after an extend",
    abs(card.sweep.progress(at: fakeNow) - reference.progress(at: fakeNow)) < 0.001)
  check("the sweep timer runs while active and moving", card.sweepRunning)
  card.setActive(false)
  check("the sweep timer stops when hidden", !card.sweepRunning)

  // Widths at both ends: pill and controls inside the card, none overlap.
  for width: CGFloat in [280, 560] {
    let narrow = FocusTabView(frame: NSRect(x: 0, y: 0, width: width, height: FocusTabView.naturalHeight))
    narrow.update(session: running, actions: allCaps, at: fakeNow)
    narrow.layout()
    let controls = narrow.subviews.filter { $0 is CountdownPillView || $0 is PanelButton }
    check("controls inside a \(Int(width))-wide card", controls.allSatisfy { narrow.bounds.contains($0.frame) },
      controls.map { "\($0.frame)" }.joined(separator: "; "))
  }
}


// MARK: - The bridge lease survives menu tracking

/// A tiny fake daemon on a private socket: real JSON lines, a real 3 s
/// lease, renewals after expiry refused, every request recorded under a
/// lock and read back through a snapshot.
final class MenuTrackingDaemon {
  struct Stats {
    var claims = 0
    var renews = 0
    var refused = 0
    var acceptedActionNames: [String] = []
  }

  private let listener: Int32
  private let lock = NSLock()
  private var stop = false
  private var leaseUntil = Date.distantPast
  private var stats = Stats()
  private let served = DispatchSemaphore(value: 0)
  private(set) var bound = false

  init(path: String) {
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    if bytes.count <= 104 {
      withUnsafeMutablePointer(to: &address.sun_path) { field in
        field.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
          for (offset, byte) in bytes.enumerated() { destination[offset] = byte }
        }
      }
      let rc = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      bound = rc == 0 && listen(listener, 4) == 0
    }
  }

  func statsSnapshot() -> Stats {
    lock.lock(); defer { lock.unlock() }
    return stats
  }

  private func snapshot() -> String {
    "{\"id\":3,\"goal\":\"Deep Work\",\"state\":\"running\","
      + "\"startedAt\":\"2026-10-07T00:00:00Z\",\"plannedEnd\":\"2026-10-07T00:25:00Z\","
      + "\"remainingSeconds\":1500,\"pausedSeconds\":0,\"calendarTitle\":\"\","
      + "\"extendOptions\":[300,600,900,1500],\"pauseStopsClock\":true}"
  }

  func serve() {
    defer { served.signal() }
    guard bound else { return }
    while true {
      let client = accept(listener, nil, nil)
      lock.lock()
      let stopping = stop
      lock.unlock()
      if stopping { if client >= 0 { Darwin.close(client) }; break }
      if client < 0 { continue }
      handle(client)
    }
  }

  private func handle(_ client: Int32) {
    defer { Darwin.close(client) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var yes: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    // Newline-framed: read until the request's line ends, bounded.
    var bytes = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(2)
    while !bytes.contains(0x0A), bytes.count < 4096, Date() < deadline {
      let n = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, min($0.count, 4096 - bytes.count), 0) }
      guard n > 0 else { return }
      bytes.append(contentsOf: chunk.prefix(n))
    }
    guard let newline = bytes.firstIndex(of: 0x0A) else { return }
    let line = String(decoding: bytes.prefix(newline), as: UTF8.self)
    guard let request = try? BridgeValue.parse(line) else { return }

    let now = Date()
    lock.lock()
    let live = leaseUntil >= now
    let claimed: Bool
    let body: String
    if request["cmd"]?.stringValue == "notchBridge" {
      switch request["op"]?.stringValue {
      case "claim":
        stats.claims += 1
        leaseUntil = now.addingTimeInterval(3)
        claimed = true
        body = replyBody(claimed: true)
      case "renew":
        if live {
          leaseUntil = now.addingTimeInterval(3)
          stats.renews += 1
          claimed = true
          body = replyBody(claimed: true)
        } else {
          stats.refused += 1
          claimed = false
          body = "{\"ok\":false,\"bridgeVersion\":1,\"error\":\"no live claim for this owner\"}"
        }
      case "release":
        leaseUntil = .distantPast
        claimed = false
        body = "{\"ok\":true,\"bridgeVersion\":1,\"display\":\"notch\",\"claimed\":false,\"ttlSeconds\":3,\"session\":null}"
      default:
        claimed = live
        body = replyBody(claimed: claimed)
      }
    } else if request["cmd"]?.stringValue == "notchAction" {
      if live {
        stats.acceptedActionNames.append(request["action"]?.stringValue ?? "")
        claimed = true
        body = replyBody(claimed: true)
      } else {
        stats.refused += 1
        claimed = false
        body = "{\"ok\":false,\"bridgeVersion\":1,\"error\":\"no live claim for this owner\"}"
      }
    } else {
      claimed = live
      body = replyBody(claimed: claimed)
    }
    lock.unlock()
    _ = (body + "\n").withCString { pointer in
      var offset = 0
      let size = strlen(pointer)
      while offset < size {
        let sent = send(client, pointer + offset, size - offset, 0)
        guard sent > 0 else { return }
        offset += sent
      }
    }
  }

  private func replyBody(claimed: Bool) -> String {
    "{\"ok\":true,\"bridgeVersion\":1,\"display\":\"notch\",\"claimed\":\(claimed),\"ttlSeconds\":3,"
      + "\"session\":\(snapshot()),\"actions\":[\"pause\",\"resume\",\"stop\",\"extend\"]}"
  }

  /// Stops the server: the accept loop exits once the listener is gone.
  /// Returns false if it did not exit inside the bound.
  @discardableResult
  func closeOwned() -> Bool {
    lock.lock(); stop = true; lock.unlock()
    Darwin.shutdown(listener, SHUT_RDWR)
    Darwin.close(listener)
    return served.wait(timeout: .now() + 2) == .success
  }
}

do {
  // Synthetic menu tracking only: the run loop is driven in eventTracking
  // mode (the same mode a tracked NSMenu uses), never the real pointer.
  let focusDir = ProcessInfo.processInfo.environment["FOCUS_DIR"]!
  try! FileManager.default.createDirectory(atPath: focusDir, withIntermediateDirectories: true)
  let socketPath = focusDir + "/focus.sock"
  try? FileManager.default.removeItem(atPath: socketPath)
  let daemon = MenuTrackingDaemon(path: socketPath)
  check("the menu-tracking fake daemon binds", daemon.bound)
  DispatchQueue.global().async { daemon.serve() }

  let controller = PanelController(initialCommand: "show")
  controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
  controller.handle("attachment-notch")
  let mirror = Mirror(reflecting: controller)
  let leaseTimer = mirror.children.first { $0.label == "bridgeTimer" }!.value as! Timer
  check("the bridge timer is scheduled", leaseTimer.isValid)
  let bridge = mirror.children.first { $0.label == "bridge" }!.value as! FocusBridgeClient
  var actionProblems: [String] = []
  bridge.onActionProblem = { actionProblems.append($0) }

  // Establish the claim on the ordinary run loop first.
  let claimedDeadline = Date().addingTimeInterval(2)
  while !bridge.last.claimed && Date() < claimedDeadline { spin(0.05) }
  check("the controller claimed the notch lease", bridge.last.claimed)

  // Now only eventTracking turns, as inside a tracked native menu, for
  // longer than the daemon's 3 s TTL.
  let before = daemon.statsSnapshot()
  let trackingDeadline = Date().addingTimeInterval(4.2)
  while Date() < trackingDeadline {
    RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.2))
  }
  spin(0.2)
  let after = daemon.statsSnapshot()
  check("the lease kept renewing inside event tracking", after.renews - before.renews >= 3,
    "\(after.renews - before.renews) renews in 4.2 s")
  check("no renewal arrived after expiry, no reclaim",
    after.refused == before.refused && after.claims == before.claims,
    "refused \(after.refused - before.refused) claims \(after.claims - before.claims)")
  check("the controller still reports the claim", controller.debugStatus().contains("\"claimed\": true"))

  // A control still reaches the daemon after the tracked interval.
  if let session = bridge.last.session {
    let actionsBefore = after.acceptedActionNames.count
    bridge.action("pause", session: session)
    let actionDeadline = Date().addingTimeInterval(2)
    while daemon.statsSnapshot().acceptedActionNames.count == actionsBefore && Date() < actionDeadline {
      spin(0.05)
    }
    let final = daemon.statsSnapshot()
    check("a pause action succeeded after menu tracking",
      final.acceptedActionNames.last == "pause" && actionProblems.isEmpty && final.refused == before.refused,
      "\(final.acceptedActionNames) \(actionProblems)")
  } else {
    check("a pause action succeeded after menu tracking", false, "session lost with the lease")
  }

  bridge.release()
  leaseTimer.invalidate()
  controller.handle("attachment-floating")
  controller.handle("hide")
  check("the fake daemon exited", daemon.closeOwned())
}

print("\(count - failures)/\(count) passed")
if failures == 0 { print("all passed") }
exit(failures == 0 ? 0 : 1)
