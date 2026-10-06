import AppKit
import Foundation

// MARK: - The menu bar attachment's visible part
//
// While the window is attached to the menu bar this status item is all
// that shows: a note symbol that toggles the attached editor under it.
// Retained for as long as the attachment is "menuBar" so its position is
// stable; Focus's item stays its own separate thing.

final class MenuBarItem: NSObject {
  /// The status item; created on `statusBar` (the system bar in the app,
  /// a private one in tests).
  let statusItem: NSStatusItem
  /// A click (or the shortcut routed by the controller) asks to toggle.
  var onToggle: () -> Void = {}

  init(statusBar: NSStatusBar = .system) {
    statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    statusItem.autosaveName = "notes-panel.notes"
    let button = statusItem.button
    button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notes")?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    button?.target = self
    button?.action = #selector(clicked)
    button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button?.setAccessibilityLabel("Notes")
  }

  /// The button's frame in screen coordinates, where the card anchors;
  /// nil until AppKit has placed the item.
  var anchor: NSRect? {
    guard let button = statusItem.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  @objc private func clicked() { onToggle() }

  /// Drops the item back out of the status bar (attachment changed away).
  func remove(from statusBar: NSStatusBar = .system) {
    statusBar.removeStatusItem(statusItem)
  }
}
