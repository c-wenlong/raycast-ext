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
tv.selectedTextAttributes = [.backgroundColor: Markdown.selection]
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
check("an empty pair is hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 3, effectiveRange: nil) != nil)
load("****")
check("a rule line is not treated as an empty pair", tv.textStorage!.attribute(Markdown.hiddenRun, at: 1, effectiveRange: nil) == nil)

// 9. formatting with no selection, then typing
load("a ")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.applyFormat(.wrap("**"))
Markdown.apply(to: tv.textStorage!)
check("⌘B leaves the caret between the halves", tv.string == "a ****" && caret() == 4, "\(tv.string) \(caret())")
tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
check("typing fills the pair", tv.string == "a **x**", tv.string)
load("a ****")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.moveRight(nil)
check("right arrow enters an empty pair", caret() == 4, "\(caret())")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.deleteForward(nil)
check("delete before a trailing empty pair removes it", tv.string == "a ", tv.string.debugDescription)

// 10. backspace after an opening marker
load("ab **bold**")
tv.setSelectedRange(NSRange(location: 5, length: 0))
tv.deleteBackward(nil)
check("backspace at bold start deletes the char before the pair", tv.string == "ab**bold**" && caret() == 4, "\(tv.string) \(caret())")
load("**bold**")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.deleteBackward(nil)
check("backspace at bold start of a line does nothing", tv.string == "**bold**", tv.string)

// 11. deleting a selection takes whole pairs
load("a **bold** c")
tv.setSelectedRange(NSRange(location: 0, length: 5))
tv.deleteBackward(nil)
check("deleting across a marker removes the whole pair", tv.string == " c", tv.string.debugDescription)
load("a **bold** c")
tv.setSelectedRange(NSRange(location: 4, length: 3))
tv.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
check("typing over styled text keeps the pair intact", tv.string == "a **zd** c", tv.string)
load("_a **b** c_ d")
tv.setSelectedRange(NSRange(location: 0, length: 3))
tv.deleteBackward(nil)
check("nested pairs partner by marker text", tv.string == " d", tv.string.debugDescription)
load("**a _b_** c")
tv.setSelectedRange(NSRange(location: 0, length: 5))
tv.deleteBackward(nil)
check("a selection over two openers takes both pairs", tv.string == " c", tv.string.debugDescription)
load("**a _b_** c")
tv.setSelectedRange(NSRange(location: 3, length: 3))
tv.deleteBackward(nil)
check("a selection over an inner opener takes only the inner pair", tv.string == "**a** c", tv.string.debugDescription)
load("**a _b_**")
tv.setSelectedRange(NSRange(location: 9, length: 0))
tv.deleteBackward(nil)
check("emptying a nested pair removes just that pair", tv.string == "**a **" && caret() == 4, "\(tv.string) \(caret())")
load("**a _b_ c** *d* e")
check("underscore italic nests inside bold", tv.textStorage!.attribute(Markdown.hiddenRun, at: 4, effectiveRange: nil) != nil)
check("star italic still styles", tv.textStorage!.attribute(Markdown.hiddenRun, at: 12, effectiveRange: nil) != nil)
check("bold markers are not italic markers", (tv.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits.contains(.bold))
load("*a **b** c*")
let nestedFont = tv.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as! NSFont
check("bold nests inside star italic", nestedFont.fontDescriptor.symbolicTraits.contains(.bold) && nestedFont.fontDescriptor.symbolicTraits.contains(.italic) && tv.textStorage!.attribute(Markdown.hiddenRun, at: 10, effectiveRange: nil) != nil)
load("**one****two**")
tv.setSelectedRange(NSRange(location: 9, length: 0))
tv.deleteBackward(nil)
check("backspace at the start of an adjacent pair deletes the visible char", tv.string == "**on****two**" && caret() == 8, "\(tv.string) \(caret())")
load("``")
check("an empty code pair on its own line is hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) != nil)

// 12. list grid: text starts one column per level, markers stay off the grid
func textX(_ line: Int, _ column: Int) -> CGFloat {
  let lm = tv.layoutManager!
  let ns = tv.string as NSString
  var start = 0
  for _ in 0..<line { start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) }
  let glyph = lm.glyphIndexForCharacter(at: start + column)
  return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + lm.location(forGlyphAt: glyph).x - tv.textContainer!.lineFragmentPadding
}
let column = Markdown.listColumn
load("- a\n  - b\n    - c\n1. d\n   10. e\n- [ ] f\n  - [x] g\nplain\n  - h")
check("bullet text sits at one column", abs(textX(0, 2) - column) < 0.5, "\(textX(0, 2))")
check("nested bullet text sits at two columns", abs(textX(1, 4) - 2 * column) < 0.5, "\(textX(1, 4))")
check("third level sits at three columns", abs(textX(2, 6) - 3 * column) < 0.5, "\(textX(2, 6))")
check("numbered text sits at one column", abs(textX(3, 3) - column) < 0.5, "\(textX(3, 3))")
check("a wide number keeps a space before its text", textX(4, 7) >= 2 * column, "\(textX(4, 7))")
check("task text sits at one column", abs(textX(5, 6) - column) < 0.5, "\(textX(5, 6))")
check("nested task text sits at two columns", abs(textX(6, 8) - 2 * column) < 0.5, "\(textX(6, 8))")
check("a list after plain text starts over at one column", abs(textX(8, 4) - column) < 0.5, "\(textX(8, 4))")
let wrapped = "- " + String(repeating: "word ", count: 30)
load(wrapped)
let lm = tv.layoutManager!
let secondLineGlyph = (0..<lm.numberOfGlyphs).first { lm.lineFragmentRect(forGlyphAt: $0, effectiveRange: nil).minY > 0 }
check("the wrapped item takes more than one line", secondLineGlyph != nil)
if let glyph = secondLineGlyph {
  let x = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + lm.location(forGlyphAt: glyph).x - tv.textContainer!.lineFragmentPadding
  check("wrapped list lines hang at the text column", abs(x - column) < 0.5, "\(x)")
}

// 13. selection rects hug the text
load("`x` yy\n\n- z")
let hugLM = tv.layoutManager as! TaskBoxLayoutManager
let mixed = hugLM.hugRects(forCharacterRange: NSRange(location: 0, length: 6))
let bodyHeight = Markdown.baseFont.ascender - Markdown.baseFont.descender
check("a mixed-font line's rect is as tall as its body font", mixed.count == 1 && abs(mixed[0].height - bodyHeight) < 0.5, "\(mixed)")
let all = hugLM.hugRects(forCharacterRange: NSRange(location: 0, length: 11))
check("one rect per line, the blank line a thin bar", all.count == 3 && all[1].width == 2, "\(all)")
check("a list line's rect starts at its text, not its marker", all.count == 3 && abs(all[2].minX - column - tv.textContainer!.lineFragmentPadding) < 0.5, "\(all)")
check("rects are shorter than the line pitch", all.allSatisfy { $0.height < 24 }, "\(all)")

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
