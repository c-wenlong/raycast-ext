import AppKit
import Foundation

// MARK: - Text view with the Raycast Notes key bindings

final class NoteTextView: NSTextView {
  var onCommand: ((String) -> Bool)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" {
      return onCommand?("copy") == true
    }
    if flags == .control, event.charactersIgnoringModifiers == "x" {
      return onCommand?("delete") == true
    }
    if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
      undoManager?.redo()
      return true
    }
    if flags == .command, let key = event.charactersIgnoringModifiers {
      switch key {
      case "z": undoManager?.undo(); return true
      case "x": cut(nil); return true
      case "c": copy(nil); return true
      case "v": paste(nil); return true
      case "a": selectAll(nil); return true
      default: break
      }
      let command: String?
      switch key {
      case "[": command = "prev"
      case "]": command = "next"
      case "n": command = "new"
      case "p": command = "browse"
      case "w": command = "hide"
      case "k": command = "palette"
      case "f": command = "find"
      case "d": command = "duplicate"
      case "\r": command = "toggle-task"
      default: command = nil
      }
      if let command, onCommand?(command) == true { return true }
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {  // escape
      _ = onCommand?("hide")
      return
    }
    super.keyDown(with: event)
  }
}
