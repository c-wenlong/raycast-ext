import AppKit
import Foundation

// MARK: - App blocking
//
// The app side of blocking (AppWorkspace, driven by BlockEngine): watches
// NSWorkspace for apps coming forward, hides a blocked one with
// NSRunningApplication.hide() and shows the block window (BlockWindow.swift)
// in its place: a card over where the app's front window was, read just
// before the hide (on screen, else off screen for a hidden app), or the
// whole screen when that window is unknown, the hide was refused, or the
// app ignored it (a launching app can), since then any of its windows may
// still show. The engine decides; this file only acts, always on the main
// thread. The daemon itself, Raycast and the always-allowed set never reach
// `block` (Matching.alwaysAllowedApps, and the engine skips its own pid).

final class AppBlocker: NSObject, AppWorkspace {
  private weak var engine: BlockEngine?
  let window: BlockWindow
  private let log: (String) -> Void
  private var observer: NSObjectProtocol?
  /// Hides an app; tests replace it so nothing real is hidden.
  var hideApp: (NSRunningApplication) -> Bool = { $0.hide() }
  /// The front window of a pid, in screen coordinates; tests replace it.
  var frontWindow: (pid_t) -> NSRect? = AppBlocker.frontWindow(pid:)
  /// Whether an app still shows after a hide; tests replace it.
  var isShowing: (NSRunningApplication) -> Bool = { !$0.isTerminated && !$0.isHidden }
  /// Runs a hide retry after a delay; tests replace it to run them at once.
  var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, body in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
  }
  /// A launching app can ignore the first hide, so it is repeated after these delays while the app still shows.
  static let hideRetries: [TimeInterval] = [0.3, 1.0]
  /// Another app coming forward this long after the page appeared closes it
  /// (the user switched away); earlier ones are the system activating the next
  /// app after the hide.
  static let switchAwayGrace: TimeInterval = 0.75

  /// `observe: false` (tests) skips the NSWorkspace observer.
  init(
    engine: BlockEngine, window: BlockWindow = BlockWindow(), observe: Bool = true,
    log: @escaping (String) -> Void = { _ in }
  ) {
    self.engine = engine
    self.window = window
    self.log = log
    super.init()
    window.onClose = { reason in
      log("block window closed (\(reason))")
      // Give activation back unless the page closed because another app came forward (it has it).
      if !reason.hasPrefix("switched to"), NSApp.isActive, NSApp.keyWindow == nil || NSApp.keyWindow === window.panel {
        NSApp.deactivate()
      }
    }
    guard observe else { return }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      self?.activated(app)
    }
  }

  deinit {
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
  }

  static func describe(_ app: NSRunningApplication) -> RunningApp {
    RunningApp(
      pid: app.processIdentifier, bundleId: app.bundleIdentifier,
      name: app.localizedName ?? app.bundleIdentifier ?? "This app")
  }

  private func onMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
  }

  /// An app came forward. Returns true when it was blocked.
  @discardableResult
  func activated(_ app: NSRunningApplication) -> Bool {
    guard let engine else { return false }
    if engine.appCameForward(Self.describe(app)) { return true }
    if window.isVisible, app.processIdentifier != getpid(),
      Date().timeIntervalSince(window.shownAt) > Self.switchAwayGrace
    {
      window.close(reason: "switched to \(app.bundleIdentifier ?? app.localizedName ?? "another app")")
    }
    return false
  }

  // MARK: AppWorkspace

  func checkFrontmost() {
    onMain { [weak self] in
      guard let self, let engine = self.engine, let app = NSWorkspace.shared.frontmostApplication else { return }
      engine.appCameForward(Self.describe(app))
    }
  }

  func block(_ app: RunningApp, snoozeSeconds: Int) {
    onMain { [weak self] in
      // The decision was made off the main thread's queue: the app may have
      // been snoozed or unlisted since, and then must not be hidden.
      guard let self, self.engine?.blocksApp(app.bundleId) == true else { return }
      let running = NSRunningApplication(processIdentifier: app.pid)
      // Read before the hide; a card only when the hide was accepted, so no other window of the app can show.
      let window = running.flatMap { self.frontWindow($0.processIdentifier) }
      let hidden = running.map { self.hide($0, bundleId: app.bundleId) } ?? false
      // A refused hide still covers the screen the app's window is on, not just the one with the mouse.
      let screen = hidden ? nil : window.flatMap(BlockWindow.screen(under:))
      self.present(app, icon: running?.icon, snoozeSeconds: snoozeSeconds, over: hidden ? window : nil, screen: screen)
    }
  }

  /// The frontmost ordinary window (layer 0, visible, at least 100 pt each
  /// way) a pid has, in AppKit screen coordinates: on screen if it has one,
  /// else off screen (a hidden app, or one just unhidden, whose windows are
  /// not back yet when it activates, keeps them listed with their bounds).
  /// Window bounds need no Screen Recording permission (only titles do).
  static func frontWindow(pid: pid_t) -> NSRect? {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
    for options: CGWindowListOption in [[.optionOnScreenOnly, .excludeDesktopElements], [.optionAll, .excludeDesktopElements]] {
      guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { continue }
      // Front to back, so the first match is the front window.
      for info in list {
        guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
          (info[kCGWindowLayer as String] as? Int) == 0,
          (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
          let bounds = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
          rect.width >= 100, rect.height >= 100
        else { continue }
        return BlockWindow.appKitRect(fromCG: rect, primaryHeight: primaryHeight)
      }
    }
    return nil
  }

  /// Shows the page for `app`, its Snooze wired to the engine.
  func present(_ app: RunningApp, icon: NSImage?, snoozeSeconds: Int, over appWindow: NSRect? = nil, screen: NSScreen? = nil) {
    let bundleId = app.bundleId ?? ""
    window.onSnooze = { [weak self] in
      guard !bundleId.isEmpty else { return }
      self?.engine?.snoozeApp(bundleId: bundleId, activate: true)
    }
    window.show(appName: app.name, bundleId: app.bundleId, icon: icon, snoozeSeconds: snoozeSeconds, over: appWindow, screen: screen)
    // A non-activating panel of a background app never becomes key, so
    // Escape would go to whatever app macOS brought forward after the hide.
    // Taking activation for the page fixes that; closing it hands it back.
    if !window.headless && !NSApp.isActive {
      NSApp.activate(ignoringOtherApps: true)
      window.panel.makeKeyAndOrderFront(nil)
    }
    let place = window.isCard ? "over its window \(NSStringFromRect(window.panel.frame))" : "full screen"
    log("block window shown for \(app.name), \(place) (key: \(window.panel.isKeyWindow))")
  }

  /// Hides the app and retries while it still shows. Returns whether the first hide was accepted.
  private func hide(_ running: NSRunningApplication, bundleId: String?) -> Bool {
    let accepted = hideApp(running)
    for delay in Self.hideRetries {
      after(delay) { [weak self] in
        guard let self, let engine = self.engine, engine.blocksApp(bundleId) else { return }
        let ours = bundleId.map { self.window.bundleId?.lowercased() == $0.lowercased() } ?? false
        guard self.isShowing(running) else {
          // Hidden now: a launching app's window may have turned up since, so a full-screen page becomes a card over it.
          if ours, !self.window.isCard, let appWindow = self.frontWindow(running.processIdentifier) {
            self.window.refit(over: appWindow)
          }
          return
        }
        _ = self.hideApp(running)
        // It ignored the hide, so any of its windows may show: the page covers the whole screen again.
        if ours { self.window.cover() }
      }
    }
    return accepted
  }

  func unblock(bundleId: String, activate: Bool) {
    onMain { [weak self] in
      guard let self else { return }
      let id = bundleId.lowercased()
      if self.window.bundleId?.lowercased() == id { self.window.close(reason: "snoozed \(bundleId)") }
      let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.lowercased() == id }
      for app in apps { app.unhide() }
      // Through LaunchServices, like `open -a`: a background app may not
      // activate another one directly under cooperative activation.
      if activate, let url = apps.first?.bundleURL {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
      }
    }
  }

  func closeBlockWindow() {
    onMain { [weak self] in self?.window.close(reason: "blocking off") }
  }
}
