import AppKit
import Foundation

func runAttachmentReviewRegressions() {
  let screen = NotesNotchScreen(
    frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
    notch: NSRect(x: 656, y: 950, width: 200, height: 32), barHeight: 32)
  let host = AttachedPanel(mode: .notch)
  host.screen = { screen }
  host.pointerLocation = { NSPoint(x: -1000, y: -1000) }
  host.begin()
  let root = host.window.contentView!
  let point = host.window.convertPoint(fromScreen: NSPoint(x: 646, y: 966))
  let hit = root.hitTest(root.convert(point, from: nil))
  check("collapsed notch routes its visible wing click to the root", hit === root)
  let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
    timestamp: 0, windowNumber: host.window.windowNumber, context: nil,
    eventNumber: 0, clickCount: 1, pressure: 1)!
  hit?.mouseDown(with: event)
  check("clicking the collapsed notch opens and pins it", host.expanded && host.pinned)
  host.pointerMoved(inside: false)
  spin(NotchMetrics.exitDelay + 0.1)
  check("a click-opened notch survives pointer departure", host.expanded && host.pinned)
  host.collapse()
  host.window.orderOut(nil)

  let header = AttachedHeaderView(frame: NSRect(x: 0, y: 0, width: 560, height: 40))
  header.update(tabs: true, title: "Note", clock: "25:00", paused: false)
  header.layoutSubtreeIfNeeded()
  header.layout()
  check("header layout does not invalidate itself", !header.needsLayout)
  header.set(tab: .focus)
  check("changing the header tab requests layout", header.needsLayout)

  let session = FocusSession(json: .object([
    "id": 3, "goal": "Deep Work", "state": "running", "startedAt": "2026-01-01T10:00:00.000Z",
    "plannedEnd": "2026-01-01T10:25:00.000Z", "remainingSeconds": 1500, "pausedSeconds": 0,
    "calendarTitle": "", "extendOptions": [300, 600, 900, 1500], "pauseStopsClock": true,
  ]), at: Date())!
  let shortHost = AttachedPanel(mode: .notch)
  shortHost.screen = {
    NotesNotchScreen(frame: NSRect(x: 0, y: 0, width: 1512, height: 420),
      notch: NSRect(x: 656, y: 388, width: 200, height: 32), barHeight: 32)
  }
  shortHost.update(session: session)
  shortHost.expand(tab: .focus, pinned: true)
  let scroll = shortHost.focusView.enclosingScrollView!
  scroll.layoutSubtreeIfNeeded()
  check("a 98-point Focus viewport keeps the full controls scrollable",
    scroll.frame.height == 98 && shortHost.focusView.frame.height == FocusTabView.naturalHeight
      && scroll.hasVerticalScroller,
    "scroll \(scroll.frame.height) document \(shortHost.focusView.frame.height)")
  scroll.contentView.scroll(to: NSPoint(x: 0, y: shortHost.focusView.frame.height - 98))
  scroll.reflectScrolledClipView(scroll.contentView)
  check("the short Focus viewport can reach its upper controls",
    scroll.documentVisibleRect.maxY >= shortHost.focusView.frame.maxY - 1)
  shortHost.collapse()
  shortHost.window.orderOut(nil)

  for height: CGFloat in [98, 150, 600] {
    let focus = FocusTabView(frame: NSRect(x: 0, y: 0, width: 560, height: height))
    focus.update(session: session, actions: [], at: Date())
    focus.layout()
    let views = focus.subviews.filter { !$0.isHidden }
    check("Focus controls fit in a \(Int(height))-point body",
      views.allSatisfy { focus.bounds.contains($0.frame) })
    // The slab and edges underlay the pill; only the interactive controls
    // (pill, Pause, Complete, More) must not overlap each other.
    let controls = views.filter { $0 is CountdownPillView || $0 is PanelButton }
    let overlaps = controls.enumerated().contains { index, view in
      controls.dropFirst(index + 1).contains { view.frame.intersects($0.frame) }
    }
    check("Focus controls do not overlap in a \(Int(height))-point body", !overlaps,
      controls.map { "\(type(of: $0))\($0.frame)" }.joined(separator: "; "))
  }
}
