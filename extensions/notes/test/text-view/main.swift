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
check("caret on closing fence goes to end of last body line", caret() == 17, "\(caret())")

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

// 6d. arrow up from the line after a block enters its last line
load("```\nx\nyy\n```\nafter\n")
tv.setSelectedRange(NSRange(location: 14, length: 0))  // start of "after"
tv.moveUp(nil)
check("arrow up from below enters last body line", caret() == 8, "\(caret())")

// 6e. arrow up inside a wrapped first body line stays in the block
load("```\n" + String(repeating: "word ", count: 30) + "\n```\n")
tv.frame.size.width = 160
tv.layoutManager?.ensureLayout(for: tv.textContainer!)
tv.setSelectedRange(NSRange(location: 4 + 100, length: 0))  // deep into the wrapped line
tv.moveUp(nil)
check("arrow up within a wrapped line stays in block", caret() > 4 && caret() < 104, "\(caret())")
tv.frame.size.width = 420

// 6f. loading a note does not edit it
tv.suppressFenceRelocation = true
load("```\n```")
tv.suppressFenceRelocation = false
tv.suppressFenceEdits = true
tv.setSelectedRange(NSRange(location: 7, length: 0))
tv.suppressFenceEdits = false
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check("placing the caret while loading leaves the file alone", tv.string == "```\n```", tv.string.debugDescription)

// 6g. loading a note that ends with a closing fence lands in the body
tv.suppressFenceRelocation = true
load("```\nx\n```")
tv.suppressFenceRelocation = false
tv.suppressFenceEdits = true
tv.setSelectedRange(NSRange(location: 9, length: 0))
tv.suppressFenceEdits = false
check("caret at end of a fence-terminated note goes to the body", caret() == 5, "\(caret())")

// 8. hidden inline markers are not editable
load("a **bold** c")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.moveRight(nil)
check("right arrow skips the opening marker", caret() == 4, "\(caret())")
tv.moveLeft(nil)
check("left arrow skips it back", caret() == 2, "\(caret())")
tv.setSelectedRange(NSRange(location: 10, length: 0))
tv.deleteBackward(nil)
check("backspace after bold deletes the last bold char", tv.string == "a **bol** c" && caret() == 7, "\(tv.string) \(caret())")
load("a **b** c")
tv.setSelectedRange(NSRange(location: 7, length: 0))
tv.deleteBackward(nil)
check("emptying a bold pair removes it", tv.string == "a  c" && caret() == 2, "\(tv.string.debugDescription) \(caret())")
load("a **bold** c")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.deleteForward(nil)
check("delete forward looks through the opening marker", tv.string == "a **old** c", tv.string)
load("x `k` y")
tv.setSelectedRange(NSRange(location: 5, length: 0))
tv.deleteBackward(nil)
check("emptying a code span removes the backticks", tv.string == "x  y", tv.string.debugDescription)
load("## Title")
tv.setSelectedRange(NSRange(location: 3, length: 0))
tv.deleteBackward(nil)
check("backspace after a heading marker removes it", tv.string == "Title" && caret() == 0, "\(tv.string) \(caret())")
load("a ****b")
Markdown.apply(to: tv.textStorage!)
var emptyHidden = false
if let v = tv.textStorage!.attribute(Markdown.hiddenRun, at: 3, effectiveRange: nil) as? Bool { emptyHidden = v }
check("an empty pair is hidden", emptyHidden)

// 7. render a selection over task lines
load("- [ ] one\n- [x] two\n- three\n")
tv.setSelectedRange(NSRange(location: 0, length: 28))
tv.needsDisplay = true
let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
tv.cacheDisplay(in: tv.bounds, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
// Pixels: the first line band must show the accent box and no bright glyph pixels left of the text.
func colour(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
  let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
  return (c.redComponent, c.greenComponent, c.blueComponent)
}
let scale = Int(rep.pixelsWide) / Int(tv.bounds.width)
var accentPixels = 0
var brightPixels = 0
for y in (16 * scale)..<(40 * scale) {
  for x in (18 * scale)..<(44 * scale) {
    let (r, g, b) = colour(x, y)
    if r > 0.75 && g < 0.5 && b < 0.5 { accentPixels += 1 }
    if r > 0.85 && g > 0.85 && b > 0.85 { brightPixels += 1 }
  }
}
check("selection render shows the box", accentPixels > 20, "\(accentPixels)")
check("selection render shows no hidden characters", brightPixels == 0, "\(brightPixels)")
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
