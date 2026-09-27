import AppKit
import Foundation

// MARK: - App blocking
//
// The app side of blocking (AppWorkspace, driven by BlockEngine): watches
// NSWorkspace for apps coming forward, hides a blocked one with
// NSRunningApplication.hide() and shows the block window (BlockWindow.swift)
// in its place. The engine decides; this file only acts, always on the main
// thread. The daemon itself, Raycast and the always-allowed set never reach
// `block` (Matching.alwaysAllowedApps, and the engine skips its own pid).

final class AppBlocker: NSObject, AppWorkspace {
  private weak var engine: BlockEngine?
  let window: BlockWindow
  private let log: (String) -> Void
  private var observer: NSObjectProtocol?
  /// Hides an app; tests replace it so nothing real is hidden.
  var hideApp: (NSRunningApplication) -> Bool = { $0.hide() }
  /// A launching app can ignore the first hide, so it is repeated after these delays while the app still shows.
  static let hideRetries: [TimeInterval] = [0.3, 1.0]
  /// Another app coming forward this long after the page appeared closes it
  /// (Kai switched away); earlier ones are the system activating the next
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
      guard let self, self.engine?.isOn == true else { return }
      let running = NSRunningApplication(processIdentifier: app.pid)
      if let running { self.hide(running, bundleId: app.bundleId) }
      self.present(app, icon: running?.icon, snoozeSeconds: snoozeSeconds)
    }
  }

  /// Shows the page for `app`, its Snooze wired to the engine.
  func present(_ app: RunningApp, icon: NSImage?, snoozeSeconds: Int) {
    let bundleId = app.bundleId ?? ""
    window.onSnooze = { [weak self] in
      guard !bundleId.isEmpty else { return }
      self?.engine?.snoozeApp(bundleId: bundleId, activate: true)
    }
    window.show(appName: app.name, bundleId: app.bundleId, icon: icon, snoozeSeconds: snoozeSeconds)
    // A non-activating panel of a background app never becomes key, so
    // Escape would go to whatever app macOS brought forward after the hide.
    // Taking activation for the page fixes that; closing it hands it back.
    if !window.headless && !NSApp.isActive {
      NSApp.activate(ignoringOtherApps: true)
      window.panel.makeKeyAndOrderFront(nil)
    }
    log("block window shown for \(app.name) (key: \(window.panel.isKeyWindow))")
  }

  private func hide(_ running: NSRunningApplication, bundleId: String?) {
    _ = hideApp(running)
    for delay in Self.hideRetries {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, let engine = self.engine, !running.isTerminated, !running.isHidden,
          engine.blocksApp(bundleId)
        else { return }
        _ = self.hideApp(running)
      }
    }
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
