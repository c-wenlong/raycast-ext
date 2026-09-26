// Headless checks of NoteTextView caret rules around code blocks and a
// render of a selection across task lines. Run with `npm run test-view`.

import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
tv.textContainer?.replaceLayoutManager(TaskBoxLayoutManager())
tv.isRichText = false
tv.linkTextAttributes = [:]
tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
tv.backgroundColor = NSColor(white: 0.12, alpha: 1)
tv.textContainerInset = NSSize(width: 18, height: 16)
tv.allowsUndo = true
win.contentView = tv
win.makeFirstResponder(tv)
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  " + detail)); if !ok { failures += 1 } }
func load(_ text: String) { tv.undoManager?.removeAllActions(); tv.string = text; Markdown.apply(to: tv.textStorage!); tv.layoutManager?.ensureLayout(for: tv.textContainer!) }
func caret() -> Int { tv.selectedRange().location }

// 1. clicking the header lands in the body
load("a\n```python\nx = 1\n```\nb\n")
tv.setSelectedRange(NSRange(location: 3, length: 0))
check("caret on opening fence moves to body", caret() == 12, "\(caret())")
tv.setSelectedRange(NSRange(location: 19, length: 0))  // on closing ```
check("caret on closing fence moves past block", caret() == 22, "\(caret())")

// 2. arrow down from last body line leaves the block
tv.setSelectedRange(NSRange(location: 14, length: 0))
tv.moveDown(nil)
check("arrow down leaves block", caret() == 22, "\(caret())")

// 3. arrow down at end of note adds a line
load("```\nx\n```")
tv.setSelectedRange(NSRange(location: 4, length: 0))
tv.moveDown(nil)
check("arrow down at end adds a line", tv.string == "```\nx\n```\n" && caret() == 10, "\(tv.string.debugDescription) \(caret())")

// 4. arrow up from first body line skips the opening fence
load("a\n```\nx\n```\n")
tv.setSelectedRange(NSRange(location: 6, length: 0))
tv.moveUp(nil)
check("arrow up skips opening fence", caret() == 1, "\(caret())")

// 5. backspace on empty block removes it
load("a\n```\n\n```\nb\n")
tv.setSelectedRange(NSRange(location: 6, length: 0))
tv.deleteBackward(nil)
check("backspace removes empty block", tv.string == "a\nb\n" && caret() == 2, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
check("undo restores block in one step", tv.string == "a\n```\n\n```\nb\n", tv.string.debugDescription)

// 6. backspace at start of non-empty body is a no-op; delete forward before closing fence too
load("```\nx\n```\n")
tv.setSelectedRange(NSRange(location: 4, length: 0))
tv.deleteBackward(nil)
check("backspace at body start keeps fence", tv.string == "```\nx\n```\n", tv.string.debugDescription)
tv.setSelectedRange(NSRange(location: 5, length: 0))
tv.deleteForward(nil)
check("delete forward keeps closing fence", tv.string == "```\nx\n```\n", tv.string.debugDescription)

// 6b. an empty closed block gets a body line when entered
load("a\n```\n```\nb\n")
tv.setSelectedRange(NSRange(location: 3, length: 0))
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check("entering an empty block adds a body line", tv.string == "a\n```\n\n```\nb\n" && caret() == 6, "\(tv.string.debugDescription) \(caret())")

// 6c. arrow up between body lines stays inside the block
load("```\nx\ny\n```\n")
tv.setSelectedRange(NSRange(location: 6, length: 0))  // column 0 of "y"
tv.moveUp(nil)
check("arrow up from second body line stays in block", caret() == 4, "\(caret())")

// 7. render a selection over task lines
load("- [ ] one\n- [x] two\n- three\n")
tv.setSelectedRange(NSRange(location: 0, length: 28))
tv.needsDisplay = true
let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
tv.cacheDisplay(in: tv.bounds, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
