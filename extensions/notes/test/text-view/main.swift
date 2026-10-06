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
// As PanelController sets them: no system substitutions on top of the typing rules.
tv.isAutomaticQuoteSubstitutionEnabled = false
tv.isAutomaticDashSubstitutionEnabled = false
tv.isAutomaticTextReplacementEnabled = false
tv.isAutomaticSpellingCorrectionEnabled = false
win.contentView = tv
win.makeFirstResponder(tv)
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  " + detail)); if !ok { failures += 1 } }
func load(_ text: String) { tv.undoManager?.removeAllActions(); tv.string = text; Markdown.apply(to: tv.textStorage!); tv.layoutManager?.ensureLayout(for: tv.textContainer!) }
func caret() -> Int { tv.selectedRange().location }
/// Runs the run loop until everything already queued on the main queue
/// has run (a marker block queued now runs after it) and the text view's
/// undo group for the current event has closed, as the event loop would,
/// however loaded the machine is; gives up after `timeout`.
func drainMain(timeout: TimeInterval = 10) {
  var done = false
  DispatchQueue.main.async { done = true }
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  } while (!done || (tv.undoManager?.groupingLevel ?? 0) > 0) && Date() < deadline
}

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
drainMain()
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
drainMain()
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
check("a rule line is not treated as an empty pair", tv.textStorage!.attribute(Markdown.hiddenRun, at: 1, effectiveRange: nil) as? String == Markdown.HiddenRole.line.rawValue)

// Markdown links hide the complete address as one marker.
let atomicLinkText = "a [Link](https://x) b"
let atomicLinkClose = (atomicLinkText as NSString).range(of: "](https://x)")
load(atomicLinkText)
tv.setSelectedRange(NSRange(location: atomicLinkClose.location, length: 0))
tv.moveRight(nil)
check("right arrow skips the complete hidden link address", caret() == NSMaxRange(atomicLinkClose), "\(caret())")
tv.moveLeft(nil)
check("left arrow skips the complete hidden link address", caret() == atomicLinkClose.location, "\(caret())")
for offset in 1..<atomicLinkClose.length {
  load(atomicLinkText)
  tv.setSelectedRange(NSRange(location: 0, length: 0))
  tv.setSelectedRange(NSRange(location: atomicLinkClose.location + offset, length: 0))
  check("caret inside hidden link address at \(offset) skips the whole run", caret() == NSMaxRange(atomicLinkClose), "\(caret())")
}
for operation in ["backspace", "delete", "cut", "replace"] {
  load(atomicLinkText)
  tv.setSelectedRange(NSRange(location: atomicLinkClose.location + 3, length: 1))
  switch operation {
  case "backspace": tv.deleteBackward(nil)
  case "delete": tv.deleteForward(nil)
  case "cut": tv.cut(nil)
  default: tv.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
  }
  let expected = operation == "replace" ? "a Z b" : "a  b"
  check("\(operation) of partial hidden link address removes both markers", tv.string == expected, tv.string.debugDescription)
}
load("a **[Link](https://x)** b")
let nestedLinkClose = (tv.string as NSString).range(of: "](https://x)")
tv.setSelectedRange(NSRange(location: nestedLinkClose.location, length: 0))
tv.moveRight(nil)
check("link closer stays separate from touching bold closer", caret() == NSMaxRange(nestedLinkClose), "\(caret())")
for label in ["k", "😀"] {
  for fromOpening in [false, true] {
    load("a [\(label)](https://x) b")
    tv.setSelectedRange(NSRange(location: fromOpening ? 2 : 3, length: 0))
    tv.deleteForward(nil)
    check("Delete empties link with \(label) from \(fromOpening ? "opener" : "label") without raw syntax", tv.string == "a  b", tv.string.debugDescription)
  }
}
load("a [k](https://x) b")
tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: " b").location, length: 0))
tv.deleteBackward(nil)
check("Backspace empties a link without raw syntax", tv.string == "a  b", tv.string.debugDescription)

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

// 9b. formatting again inside styled text removes the pair
for (name, selection, expected) in [
  ("⌘B with the caret in bold unwraps", NSRange(location: 5, length: 0), NSRange(location: 3, length: 0)),
  ("⌘B with a selection in bold unwraps", NSRange(location: 5, length: 2), NSRange(location: 3, length: 2)),
  ("⌘B over bold and its markers unwraps", NSRange(location: 2, length: 8), NSRange(location: 2, length: 4)),
] {
  load("a **bold** c")
  tv.setSelectedRange(selection)
  tv.applyFormat(.wrap("**"))
  check(name, tv.string == "a bold c" && tv.selectedRange() == expected, "\(tv.string) \(tv.selectedRange())")
}

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
check("two backticks stay visible until there is text between them", tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) == nil)
load("x `k` y")
check("backticks around text are hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 2, effectiveRange: nil) != nil)
load("x `k` y")
tv.setSelectedRange(NSRange(location: 4, length: 0))
tv.deleteBackward(nil)
check("deleting a span's only character from inside removes the backticks", tv.string == "x  y" && caret() == 2, "\(tv.string.debugDescription) \(caret())")
load("x `ab` y")
tv.setSelectedRange(NSRange(location: 4, length: 0))
tv.deleteBackward(nil)
check("deleting one of two characters keeps the span", tv.string == "x `b` y", tv.string.debugDescription)
load("```\nbelow\nmore")
check("an opening fence on its own is not a code block", Markdown.codeBlocks(in: tv.string).isEmpty && tv.textStorage!.attribute(Markdown.codeBlock, at: 5, effectiveRange: nil) == nil)
load("```\ncode\n```\nafter")
check("a closed fence is a code block that ends at its closing fence", Markdown.codeBlocks(in: tv.string).count == 1 && tv.textStorage!.attribute(Markdown.codeBlock, at: 5, effectiveRange: nil) != nil && tv.textStorage!.attribute(Markdown.codeBlock, at: 14, effectiveRange: nil) == nil)

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

// 14. link editing rewrites the whole markdown span
func rewritten(_ text: String, at index: Int, _ label: String, _ url: String) -> String {
  guard let edit = LinkController.rewrite(in: text, at: index, text: label, url: url) else { return "<no link>" }
  return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
}
var result = rewritten("x [a](https://x) y", at: 3, "b", "y.com")
check("edit a link's text and url", result == "x [b](https://y.com) y", result)
result = rewritten("see https://a.com now", at: 6, "https://a.com", "https://b.com/p")
check("bare URL with unchanged text takes just the new url", result == "see https://b.com/p now", result)
result = rewritten("see https://a.com.", at: 6, "A site", "https://a.com")
check("bare URL with new text becomes a markdown link", result == "see [A site](https://a.com).", result)
result = LinkController.removal(in: "x [a](https://x) y", at: 3).map { ("x [a](https://x) y" as NSString).replacingCharacters(in: $0.range, with: $0.replacement) } ?? "<no link>"
check("remove link keeps the text", result == "x a y", result)
result = rewritten("[a](https://x)", at: 1, "", "  ")
check("empty url removes the link", result == "a", result)
result = rewritten("[a](https://x)", at: 1, "  ", " z.org/a b ")
check("empty text keeps the old text; url trimmed and encoded", result == "[a](https://z.org/a%20b)", result)
result = rewritten("[a](https://x)", at: 1, "a", "mailto:me@x.org")
check("a url with a scheme is kept as is", result == "[a](mailto:me@x.org)", result)
check("no link outside a span", LinkController.rewrite(in: "plain [a](https://x)", at: 2, text: "b", url: "y") == nil)
load("one [a](https://x) two")
let linkController = LinkController(textView: tv)
tv.setSelectedRange(NSRange(location: 21, length: 0))
linkController.rewriteLink(at: 5, text: "bee", url: "y.com")
check("rewrite through the view", tv.string == "one [bee](https://y.com) two" && caret() == 27,"\(tv.string) \(caret())")
tv.undoManager?.undo()
check("undo takes the rewrite back in one step", tv.string == "one [a](https://x) two", tv.string)
tv.apply(ListEditing.Edit(range: NSRange(location: 0, length: 3), replacement: "ONE", cursor: 3))
tv.undoManager?.setActionName("Shout")
tv.setSelectedRange(NSRange(location: 1, length: 0))
linkController.rewriteLink(at: 5, text: "a", url: "https://x")
check(
  "an unchanged rewrite leaves the text, caret and undo name alone",
  tv.string == "ONE [a](https://x) two" && caret() == 1 && tv.undoManager?.undoActionName == "Shout",
  "\(tv.string) \(caret()) \(tv.undoManager?.undoActionName ?? "-")")

// 14. headings go to level 4; quotes hide their marker and indent
load("#### Four\n| quoted\n| \nplain")
let h4 = tv.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as! NSFont
check("#### is a heading", h4.pointSize == 15 * Markdown.zoom && h4.fontDescriptor.symbolicTraits.contains(.bold), "\(h4)")
check("the #### marker is hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) != nil)
check("the | marker is hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 10, effectiveRange: nil) != nil)
let quoteStyle = tv.textStorage!.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as! NSParagraphStyle
check("quote text is indented past the bar", quoteStyle.headIndent == Markdown.quoteIndent && quoteStyle.firstLineHeadIndent == Markdown.quoteIndent)
var quoteRun = NSRange()
_ = tv.textStorage!.attribute(Markdown.quoteBar, at: 10, longestEffectiveRange: &quoteRun, in: NSRange(location: 0, length: tv.textStorage!.length))
check("consecutive quote lines share one bar", quoteRun == NSRange(location: 10, length: 12), "\(quoteRun)")
check("an empty quote line gets the placeholder", tv.textStorage!.attribute(Markdown.quotePlaceholder, at: 19, effectiveRange: nil) != nil)
check("plain text is not a quote", tv.textStorage!.attribute(Markdown.quoteBar, at: 22, effectiveRange: nil) == nil)
tv.setSelectedRange(NSRange(location: 18, length: 0))
tv.insertNewline(nil)
check("Enter in a quote continues it", tv.string.hasPrefix("#### Four\n| quoted\n| \n| \n"), tv.string.debugDescription)

// 14b. callouts
load("!> one\n!> two\n\n!> \n| q")
check("the !> marker is hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) != nil && tv.textStorage!.attribute(Markdown.hiddenRun, at: 1, effectiveRange: nil) != nil)
var calloutRun = NSRange()
_ = tv.textStorage!.attribute(Markdown.calloutBox, at: 0, longestEffectiveRange: &calloutRun, in: NSRange(location: 0, length: tv.textStorage!.length))
check("consecutive callout lines share one box", calloutRun == NSRange(location: 0, length: 14), "\(calloutRun)")
let calloutStyle = tv.textStorage!.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as! NSParagraphStyle
check("callout text is inset on both sides", calloutStyle.headIndent == Markdown.calloutPad && calloutStyle.tailIndent == -Markdown.calloutPad)
check("an empty callout line gets its placeholder", tv.textStorage!.attribute(Markdown.calloutPlaceholder, at: 15, effectiveRange: nil) != nil)
check("a callout is not a quote", tv.textStorage!.attribute(Markdown.quoteBar, at: 3, effectiveRange: nil) == nil)
check("a quote after a callout is still a quote", tv.textStorage!.attribute(Markdown.quoteBar, at: 20, effectiveRange: nil) != nil && tv.textStorage!.attribute(Markdown.calloutBox, at: 20, effectiveRange: nil) == nil)
load("|note\n>note\n!>note\n|\n>\n>> two")
let bareStorage = tv.textStorage!
let bareKeys: [NSAttributedString.Key] = [Markdown.quoteBar, Markdown.calloutBox, Markdown.toggleChevron, Markdown.hiddenRun]
check("a marker with no space after it is plain text, as the editing rules see it", (0..<bareStorage.length).allSatisfy { index in bareKeys.allSatisfy { bareStorage.attribute($0, at: index, effectiveRange: nil) == nil } })
check("slash finds the callout", SlashMenu.matches("call").map(\.id) == ["callout"] && SlashMenu.matches("box").map(\.id) == ["callout"])

// 14c. boxed blocks share one padding and line up with the text column
load("text\n```\ncode\n```\n!> box")
let cardLM = tv.layoutManager as! TaskBoxLayoutManager
let blocks = Markdown.codeBlocks(in: tv.string)
let card = cardLM.codeCardRect(forCharacterRange: blocks[0].range)!
let edge = tv.textContainer!.lineFragmentPadding
check("the code card starts at the text column's left edge", abs(card.minX - edge) < 0.5, "\(card)")
check("the code card ends at the text column's right edge", abs(card.maxX - (tv.textContainer!.size.width - edge)) < 0.5, "\(card)")
let codeStyle = tv.textStorage!.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as! NSParagraphStyle
let boxStyle = tv.textStorage!.attribute(.paragraphStyle, at: 21, effectiveRange: nil) as! NSParagraphStyle
check("code and callout text share the block padding", codeStyle.firstLineHeadIndent == Markdown.blockPad && codeStyle.headIndent == Markdown.blockPad && codeStyle.tailIndent == -Markdown.blockPad && boxStyle.headIndent == Markdown.blockPad)
// The language and copy controls stay inside the card at every width.
let overlay = CodeBlockOverlay(textView: tv)
tv.textContainer!.widthTracksTextView = true  // as in the panel: the column follows the view
var cardWidths: [CGFloat] = []
for width in [420, 560, 900] as [CGFloat] {
  tv.frame = NSRect(x: 0, y: 0, width: width, height: 400)
  tv.layoutManager?.ensureLayout(for: tv.textContainer!)
  overlay.update()
  cardWidths.append(cardLM.codeCardRect(forCharacterRange: Markdown.codeBlocks(in: tv.string)[0].range)!.width)
  let cardNow = cardLM.codeCardRect(forCharacterRange: Markdown.codeBlocks(in: tv.string)[0].range)!
    .offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
  let frames = overlay.visibleControlFrames
  check("code controls sit inside the card at \(Int(width))pt", frames.count == 1 && frames[0].maxX <= cardNow.maxX && frames[0].minX >= cardNow.minX && frames[0].minY >= cardNow.minY, "\(frames) in \(cardNow)")
}
check("each width lays the card out afresh", cardWidths[0] < cardWidths[1] && cardWidths[1] < cardWidths[2], "\(cardWidths)")
tv.frame = NSRect(x: 0, y: 0, width: 420, height: 400)

// 15. slash menu
check("slash entries match by title word prefix", SlashMenu.matches("head").map(\.id) == ["h1", "h2", "h3", "h4"])
check("slash entries match aliases", SlashMenu.matches("todo").map(\.id) == ["task"])
check("slash entries match several words", SlashMenu.matches("numbered li").map(\.id) == ["ordered"])
check("an empty query lists everything", SlashMenu.matches("").count == SlashMenu.entries.count)
check("nothing matches nonsense", SlashMenu.matches("zzz").isEmpty)
load("hello ")
tv.setSelectedRange(NSRange(location: 6, length: 0))
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
check("/ after a space opens the menu", tv.slashMenuIsOpen)
tv.insertText("h", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.insertText("2", replacementRange: NSRange(location: NSNotFound, length: 0))
check("typing filters and keeps the menu open", tv.slashMenuIsOpen)
drainMain()  // closes the typing undo group, as the event loop would
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
check("return applies the entry and removes the /query", tv.string == "## hello " && !tv.slashMenuIsOpen, tv.string.debugDescription)
drainMain()
tv.undoManager?.undo()
check("one undo restores the text from before the slash", tv.string == "hello ", tv.string.debugDescription)
tv.undoManager?.redo()
check("one redo reapplies the pick", tv.string == "## hello ", tv.string.debugDescription)
// Typing right before the "/" and the query itself: each keystroke is its
// own event in the app, so the run loop turns between them here too. The
// "/" starts its own typing group, so the pick can take exactly the query
// back out and leave the earlier typing as its own undo step.
load("")
tv.insertText("h", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.insertText("i", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
drainMain()
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.insertText("h", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.insertText("2", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
check("return applies the entry after earlier typing", tv.string == "## hi ", tv.string.debugDescription)
tv.undoManager?.undo()
check("one undo still restores just the text from before the slash, keeping the earlier typing", tv.string == "hi ", tv.string.debugDescription)
tv.undoManager?.redo()
check("one redo still reapplies the pick", tv.string == "## hi ", tv.string.debugDescription)
tv.undoManager?.undo()
tv.undoManager?.undo()
check("a further undo still reaches the typing from before the slash, not lost", tv.string == "", tv.string.debugDescription)
// A query edited with Backspace spans more than one typing group.
load("hello ")
tv.setSelectedRange(NSRange(location: 6, length: 0))
drainMain()
for ch in ["/", "h", "e", "a"] { tv.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0)); drainMain() }
tv.deleteBackward(nil)
drainMain()
tv.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
drainMain()
check("the edited query still filters", tv.slashMenuIsOpen && tv.string == "hello /hea", "open=\(tv.slashMenuIsOpen) \(tv.string.debugDescription)")
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
check("return applies the entry after an edited query (Heading 1 is first for \"hea\")", tv.string == "# hello ", tv.string.debugDescription)
tv.undoManager?.undo()
check("one undo restores the text from before the slash after an edited query", tv.string == "hello ", tv.string.debugDescription)
// A query edited many times over (well past eight groups).
load("hello ")
tv.setSelectedRange(NSRange(location: 6, length: 0))
drainMain()
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
for _ in 0..<12 {
  drainMain()
  tv.insertText("h", replacementRange: NSRange(location: NSNotFound, length: 0))
  drainMain()
  tv.deleteBackward(nil)
}
drainMain()
tv.insertText("q", replacementRange: NSRange(location: NSNotFound, length: 0))
drainMain()
check("a much-edited query still filters", tv.slashMenuIsOpen && tv.string == "hello /q", tv.string.debugDescription)
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
check("return applies Quote for \"q\"", tv.string == "| hello ", tv.string.debugDescription)
tv.undoManager?.undo()
check("one undo restores the pre-slash text after a much-edited query", tv.string == "hello ", tv.string.debugDescription)
load("")
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
check("/ at the start of the note opens the menu", tv.slashMenuIsOpen)
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!)
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
check("down then return picks the second entry (Heading 1)", tv.string == "# ", tv.string.debugDescription)
load("a/")
tv.setSelectedRange(NSRange(location: 1, length: 0))
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
check("/ inside a word does not open the menu", !tv.slashMenuIsOpen)
load("x ")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!)
check("escape closes the menu and keeps the slash", !tv.slashMenuIsOpen && tv.string == "x /")
load("x ")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.insertText("zzz", replacementRange: NSRange(location: NSNotFound, length: 0))
check("no match closes the menu", !tv.slashMenuIsOpen)
load("x ")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.setSelectedRange(NSRange(location: 0, length: 0))
check("moving the caret away closes the menu", !tv.slashMenuIsOpen)
load("- item ")
tv.setSelectedRange(NSRange(location: 7, length: 0))
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.insertText("text", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
check("Text drops the list marker", tv.string == "item ", tv.string.debugDescription)
load("x ")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.insertText("head", replacementRange: NSRange(location: NSNotFound, length: 0))
tv.setSelectedRange(NSRange(location: 5, length: 0))
check("moving the caret back inside the query closes the menu", !tv.slashMenuIsOpen)
load("x \n## head")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
check("the menu is open before the relocation", tv.slashMenuIsOpen)
tv.setSelectedRange(NSRange(location: 5, length: 0))  // inside the hidden "## ", relocated
check("a caret relocated off a hidden marker closes the menu", !tv.slashMenuIsOpen && caret() != 5, "\(caret())")
load("|   \n| m")
check("a whitespace-only quote line gets the placeholder", tv.textStorage!.attribute(Markdown.quotePlaceholder, at: 0, effectiveRange: nil) != nil)
check("a quote line with text does not", tv.textStorage!.attribute(Markdown.quotePlaceholder, at: 6, effectiveRange: nil) == nil)
let emptyQuoteFont = tv.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
check("the hidden quote marker keeps the body font, so empty and full quote lines are the same height", emptyQuoteFont == Markdown.baseFont, "\(emptyQuoteFont)")
let emptyLine = tv.layoutManager!.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
let fullLine = tv.layoutManager!.lineFragmentUsedRect(forGlyphAt: tv.layoutManager!.glyphIndexForCharacter(at: 7), effectiveRange: nil)
check("empty and full quote lines have the same height", abs(emptyLine.height - fullLine.height) < 0.5, "\(emptyLine.height) \(fullLine.height)")
let menu = SlashMenu { _ in }
menu.filter("")
menu.place(below: NSRect(x: 0, y: 100, width: 1, height: 20), within: NSRect(x: 0, y: 0, width: 400, height: 200), container: tv.textContainer!)
load("a\n| one\n| two\nb\n|\tc")
let firstQuote = tv.textStorage!.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as! NSParagraphStyle
let lastQuote = tv.textStorage!.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as! NSParagraphStyle
check("a quote keeps air above its first line and below its last", firstQuote.paragraphSpacingBefore == Markdown.quoteGap && lastQuote.paragraphSpacing == Markdown.quoteGap && firstQuote.paragraphSpacing == 2 * Markdown.zoom && lastQuote.paragraphSpacingBefore == 0)
check("a tab after | is no quote marker (a marker needs a space)", tv.textStorage!.attribute(Markdown.hiddenRun, at: 16, effectiveRange: nil) == nil && tv.textStorage!.attribute(Markdown.quoteBar, at: 16, effectiveRange: nil) == nil)
let barHost = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
let bar = FormatBar(apply: { _ in })
barHost.addSubview(bar)
NSLayoutConstraint.activate([
  bar.leadingAnchor.constraint(equalTo: barHost.leadingAnchor), bar.trailingAnchor.constraint(equalTo: barHost.trailingAnchor),
  bar.bottomAnchor.constraint(equalTo: barHost.bottomAnchor, constant: -10),
])
barHost.layoutSubtreeIfNeeded()
check("a click on the format bar's pill hits the bar", bar.hitTest(NSPoint(x: bar.frame.midX, y: bar.frame.midY)) != nil)
check("a click beside the pill falls through to what is under the bar", bar.hitTest(NSPoint(x: bar.frame.maxX - 20, y: bar.frame.midY)) == nil, "\(bar.frame)")
check("a short window trims the menu to fit", menu.frame.maxY <= 200 && menu.frame.minY >= 0 && menu.frame.height >= 2 * SlashMenu.rowHeight, "\(menu.frame)")

// 15b. emoji picker
func typeKeys(_ text: String) {
  for ch in text {
    tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
    drainMain()  // each keystroke is its own event in the app
  }
}
func press(_ keyCode: UInt16, _ characters: String = "") {
  tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!)
}
check("the emoji table has a few hundred entries", Emoji.entries.count >= 300, "\(Emoji.entries.count)")
check("every emoji is listed once", Set(Emoji.entries.map(\.emoji)).count == Emoji.entries.count)
check(":cla finds clap first", Emoji.matches("cla").first == Emoji.Match(name: "clap", emoji: "👏"), "\(Emoji.matches("cla").prefix(3))")
check("an exact name comes before longer ones", Emoji.matches("eyes").first?.name == "eyes" && Emoji.matches("eyes").contains { $0.name == "heart_eyes" })
check("a word inside a name matches (thumbs finds +1 by its thumbsup name)", Emoji.matches("thumbs").first?.emoji == "👍")
check("the query is not case-sensitive", Emoji.matches("CLA").first?.name == "clap")
check("lookup takes any of an emoji's names", Emoji.lookup("+1") == "👍" && Emoji.lookup("thumbsup") == "👍" && Emoji.lookup("nope") == nil)
check("nonsense matches nothing", Emoji.matches("zzzq").isEmpty)
load("hi ")
tv.setSelectedRange(NSRange(location: 3, length: 0))
drainMain()
typeKeys(":c")
check("one letter after : does not open the picker", !tv.emojiPickerIsOpen)
typeKeys("la")
check(":cla opens the emoji picker", tv.emojiPickerIsOpen && !tv.slashMenuIsOpen)
press(36, "\r")
check("return inserts the emoji in place of :cla", tv.string == "hi 👏" && caret() == 5 && !tv.emojiPickerIsOpen, "\(tv.string.debugDescription) \(caret())")
drainMain()
tv.undoManager?.undo()
check("one undo restores the text from before the colon", tv.string == "hi ", tv.string.debugDescription)
tv.undoManager?.redo()
check("one redo puts the emoji back", tv.string == "hi 👏", tv.string.debugDescription)
load("")
typeKeys(":cla")
press(125)
press(36, "\r")
check("down then return picks the second match", tv.string == Emoji.matches("cla")[1].emoji, tv.string.debugDescription)
load("")
typeKeys(":cla")
press(53)
check("escape closes the picker and keeps the text", !tv.emojiPickerIsOpen && tv.string == ":cla")
typeKeys("p")
check("typing on after escape does not reopen it", !tv.emojiPickerIsOpen && tv.string == ":clap")
load("")
typeKeys(":cla ")
check("a space closes the picker and keeps the text", !tv.emojiPickerIsOpen && tv.string == ":cla ", tv.string.debugDescription)
load("")
typeKeys(":clap:")
check(":clap: converts as you type the closing colon", tv.string == "👏" && !tv.emojiPickerIsOpen, tv.string.debugDescription)
tv.undoManager?.undo()
check("undo gives back the typed name", tv.string == ":clap:", tv.string.debugDescription)
load(":clap")
tv.setSelectedRange(NSRange(location: 5, length: 0))
let emojiBoard = NSPasteboard(name: NSPasteboard.Name("notes-emoji-test-\(getpid())"))
emojiBoard.clearContents()
emojiBoard.setString(":", forType: .string)
_ = tv.readSelection(from: emojiBoard, type: .string)
check("pasting the closing colon leaves :clap: as text", tv.string == ":clap:", tv.string.debugDescription)
emojiBoard.releaseGlobally()
load("")
typeKeys(":clapx:")
check("an unknown name stays text", tv.string == ":clapx:" && !tv.emojiPickerIsOpen, tv.string.debugDescription)
load("")
typeKeys("at 10:ab")
check("a colon after a digit opens nothing", !tv.emojiPickerIsOpen)
load("")
typeKeys("`x :ab")
check("a colon in a code span opens nothing", !tv.emojiPickerIsOpen)
load("")
typeKeys(":zzq")
check("no match opens nothing", !tv.emojiPickerIsOpen)
load("")
typeKeys(":cla")
tv.deleteBackward(nil)
check("backspace keeps the picker open while two letters remain", tv.emojiPickerIsOpen && tv.string == ":cl", tv.string.debugDescription)
tv.deleteBackward(nil)
check("backspace to one letter closes it", !tv.emojiPickerIsOpen && tv.string == ":c", tv.string.debugDescription)
load("ab ")
tv.setSelectedRange(NSRange(location: 3, length: 0))
typeKeys(":cla")
tv.setSelectedRange(NSRange(location: 0, length: 0))
check("moving the caret away closes the emoji picker", !tv.emojiPickerIsOpen)
load("")
typeKeys(":cla")
let emojiTop = tv.subviews.first { ($0 as? InlinePicker)?.isHidden == false }
check("the emoji picker hangs under the caret's line", emojiTop.map { $0.frame.minY > tv.textContainerOrigin.y } ?? false, "\(String(describing: emojiTop?.frame))")
check("its first row is clap with the emoji drawn", (emojiTop as? InlinePicker)?.selectedItem?.glyph == "👏")
press(53)
load("")
typeKeys("hey ")
typeKeys("/")
check("the slash menu still opens beside the emoji picker", tv.slashMenuIsOpen && !tv.emojiPickerIsOpen)
press(53)

// 15c. note links
let day: TimeInterval = 86_400
let targets = [
  NoteLinks.Target(title: "Project plan", target: "2026-10-05 1200 - project-plan.md", modified: Date()),
  NoteLinks.Target(title: "Groceries", target: "groceries.md", modified: Date(timeIntervalSinceNow: -day)),
  NoteLinks.Target(title: "Old project notes", target: "/elsewhere/old.md", modified: Date(timeIntervalSinceNow: -40 * day)),
]
check("an empty note query lists every note, newest first", NoteLinks.matches("", in: targets) == targets)
check("words match the title in any case, order kept", NoteLinks.matches("PROJ", in: targets).map(\.title) == ["Project plan", "Old project notes"])
check("every word must match", NoteLinks.matches("proj old", in: targets).map(\.title) == ["Old project notes"])
check("the filename matches too", NoteLinks.matches("grocer", in: targets).map(\.title) == ["Groceries"] && NoteLinks.matches("elsewhere", in: targets).count == 1)
check("a note beside the open one is linked by filename", NoteLinks.linkTarget(for: "/n/a b.md", from: "/n") == "a b.md" && NoteLinks.linkTarget(for: "/n/a.md", from: "/n/") == "a.md")
check("a note elsewhere by a relative path", NoteLinks.linkTarget(for: "/m/a.md", from: "/n") == "../m/a.md", NoteLinks.linkTarget(for: "/m/a.md", from: "/n"))
check("from a subfolder note, a root note is ../name and resolves back", NoteLinks.linkTarget(for: "/n/a b.md", from: "/n/sub") == "../a b.md"
  && NoteLinks.notePath(for: URL(string: ListEditing.encodedLinkTarget(NoteLinks.linkTarget(for: "/n/a b.md", from: "/n/sub")))!, in: "/n/sub") == "/n/a b.md")
check("a note in a folder below is sub/name", NoteLinks.linkTarget(for: "/n/sub/a.md", from: "/n") == "sub/a.md")
check("only a note directly in the notes folder opens in the window", NoteLinks.opensInWindow("/n/a.md", root: "/n") && NoteLinks.opensInWindow("/n/./a.md", root: "/n/")
  && !NoteLinks.opensInWindow("/n/sub/a.md", root: "/n") && !NoteLinks.opensInWindow("/m/a.md", root: "/n") && !NoteLinks.opensInWindow("/n/../m/a.md", root: "/n"))
check("a relative .md link resolves in the note's folder", NoteLinks.notePath(for: URL(string: "My%20Note.md")!, in: "/n") == "/n/My Note.md")
check("parent folders and fragments resolve", NoteLinks.notePath(for: URL(string: "../x.md#top")!, in: "/n/sub") == "/n/x.md")
check("an absolute or file: path stays", NoteLinks.notePath(for: URL(string: "/a/b.md")!, in: "/n") == "/a/b.md" && NoteLinks.notePath(for: URL(string: "file:///a/b.md")!, in: "/n") == "/a/b.md")
check("web links and other files are not notes", NoteLinks.notePath(for: URL(string: "https://x.com/a.md")!, in: "/n") == nil && NoteLinks.notePath(for: URL(string: "pic.png")!, in: "/n") == nil)
let inserted = ListEditing.noteLink(title: "Project plan", target: "2026-10-05 1200 - project-plan.md")
let insertedSpan = LinkController.span(in: "x " + inserted, at: 3)
check("the inserted link is one markdown link the window styles", insertedSpan?.range == NSRange(location: 2, length: (inserted as NSString).length) && insertedSpan.flatMap { URL(string: $0.url) }.flatMap { NoteLinks.notePath(for: $0, in: "/n") } == "/n/2026-10-05 1200 - project-plan.md",
  "\(String(describing: insertedSpan))")
check("a link to a renamed note is resolved by its id", NoteLinks.noteWithSameID(as: "2026-10-05 1200 ab12 - old.md", among: ["2026-10-05 1200 ab12 - new.md", "2026-10-05 1200 cd34 - other.md"]) == "2026-10-05 1200 ab12 - new.md")
let headFile = NSTemporaryDirectory() + "notes-head-\(getpid()).md"
try! ("# Big note\n" + String(repeating: "word ", count: 400_000)).write(toFile: headFile, atomically: true, encoding: .utf8)
let head = NoteLinks.headText(atPath: headFile)
check("a large note is read only as far as its title needs", head.map { ($0 as NSString).length <= NoteLinks.headLimit } == true && head.flatMap(Titles.firstLine(of:)) == "Big note", "\(head?.count ?? -1)")
try? FileManager.default.removeItem(atPath: headFile)
check("editing a note link keeps it relative", LinkController.normalizedURL("Other%20Note.md") == "Other%20Note.md" && LinkController.normalizedURL("example.com") == "https://example.com")

var targetReads = 0
tv.noteLinkTargets = { targetReads += 1; return targets }
load("see ")
tv.setSelectedRange(NSRange(location: 4, length: 0))
drainMain()
typeKeys("[")
check("one bracket opens nothing", !tv.notePickerIsOpen)
typeKeys("[")
check("[[ opens the note picker with every note", tv.notePickerIsOpen && (tv.subviews.first { ($0 as? InlinePicker)?.isHidden == false } as? InlinePicker)?.items.count == 3)
typeKeys("proj pl")
check("typing filters, spaces included", tv.notePickerIsOpen && (tv.subviews.first { ($0 as? InlinePicker)?.isHidden == false } as? InlinePicker)?.items.map(\.title) == ["Project plan"])
check("the folder is read once per [[", targetReads == 1, "\(targetReads)")
press(36, "\r")
check("return inserts a markdown link in place of [[query", tv.string == "see [Project plan](2026-10-05%201200%20-%20project-plan.md)" && !tv.notePickerIsOpen, tv.string.debugDescription)
check("the caret lands after the link", caret() == (tv.string as NSString).length, "\(caret())")
drainMain()
tv.undoManager?.undo()
check("one undo restores the text from before the brackets", tv.string == "see ", tv.string.debugDescription)
load("")
typeKeys("[[gro")
press(53)
check("escape closes the note picker and keeps the text", !tv.notePickerIsOpen && tv.string == "[[gro")
typeKeys("c")
check("typing on after escape does not reopen it", !tv.notePickerIsOpen)
load("")
typeKeys("[[zzz")
check("no matching note closes it", !tv.notePickerIsOpen)
load("")
typeKeys("[[gro]")
check("a closing bracket closes it", !tv.notePickerIsOpen && tv.string == "[[gro]")
load("")
typeKeys("[[pro /")
check("a slash in a note query does not open the block menu", !tv.slashMenuIsOpen)
press(53)
let realTargets = tv.noteLinkTargets
tv.noteLinkTargets = { [NoteLinks.Target(title: "a -- b", target: "ab.md", modified: Date())] }
load("")
typeKeys("[[a --")
check("typography waits while a picker is open (-- stays in a matching note query)", tv.notePickerIsOpen && tv.string == "[[a --", tv.string.debugDescription)
press(53)
tv.noteLinkTargets = { [NoteLinks.Target(title: "@today plan", target: "plan.md", modified: Date())] }
load("")
typeKeys("[[@today ")
drainMain()  // the date conversion would land on this pass
check("a date keyword in an open note query stays text", tv.notePickerIsOpen && tv.string == "[[@today ", tv.string.debugDescription)
press(53)
// A note loaded in place of another drops the cached targets and any dismissal.
tv.noteLinkTargets = { [NoteLinks.Target(title: "Alpha", target: "alpha.md", modified: Date())] }
load("")
typeKeys("[[")
press(53)
tv.noteLinkTargets = { [NoteLinks.Target(title: "Beta", target: "beta.md", modified: Date())] }
load("[[")
tv.setSelectedRange(NSRange(location: 2, length: 0))
typeKeys("b")
check("another note's [[ reads the folder afresh", tv.notePickerIsOpen && (tv.subviews.first { ($0 as? InlinePicker)?.isHidden == false } as? InlinePicker)?.items.map(\.title) == ["Beta"])
press(53)
// Each picker keeps its own dismissal.
tv.noteLinkTargets = { [NoteLinks.Target(title: "gro: list", target: "g.md", modified: Date())] }
load("")
typeKeys("[[gro")
press(53)
typeKeys(":")
typeKeys(" ")
check("a : typed after an escaped [[ does not bring the note picker back", !tv.notePickerIsOpen && tv.string == "[[gro: ", tv.string.debugDescription)
tv.noteLinkTargets = realTargets
load("`")
tv.setSelectedRange(NSRange(location: 1, length: 0))
typeKeys("[[")
check("[[ in a code span opens nothing", !tv.notePickerIsOpen)
tv.noteLinkTargets = nil
load("")
typeKeys("[[")
check("with no note source there is no note picker", !tv.notePickerIsOpen)

// 16. a held ⌃X does not repeat the delete command
var deleteCommands = 0
tv.onCommand = { command in
  if command == "delete" { deleteCommands += 1 }
  return true
}
let ctrlX = { (repeated: Bool) in
  NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil, characters: "\u{18}", charactersIgnoringModifiers: "x", isARepeat: repeated, keyCode: 7)!
}
_ = tv.performKeyEquivalent(with: ctrlX(false))
_ = tv.performKeyEquivalent(with: ctrlX(true))
_ = tv.performKeyEquivalent(with: ctrlX(true))
check("⌃X trashes once per press, not per key repeat", deleteCommands == 1, "\(deleteCommands)")
tv.onCommand = nil

// 17. the title is the first line, markdown stripped
check("a heading is the title without its marks", Titles.firstLine(of: "## Hello **world**\nmore") == "Hello world")
check("plain text is the title", Titles.firstLine(of: "hello\n") == "hello")
check("a list item is the title without its marker", Titles.firstLine(of: "- [ ] buy milk") == "buy milk")
check("a numbered item is the title without its number", Titles.firstLine(of: "1. first") == "first")
check("a quote is the title without its |", Titles.firstLine(of: "| quoted _words_") == "quoted words")
check("a toggle is the title without its >", Titles.firstLine(of: "> folded") == "folded")
check("a callout is the title without its !>", Titles.firstLine(of: "!> boxed") == "boxed")
check("a whole marker stack is stripped", Titles.firstLine(of: "| > ## Deep") == "Deep")
check(">text with no space keeps its >", Titles.firstLine(of: ">text") == ">text")
check(">> is not special any more", Titles.firstLine(of: ">> two") == ">> two")
check("blank lines and fences are skipped", Titles.firstLine(of: "\n```\ncode\n```\nafter") == "code")
check("a link keeps its text", Titles.firstLine(of: "see [the manual](https://x.y)") == "see the manual")
check("an empty note has no title", Titles.firstLine(of: "\n\n") == nil)
check("a long first line is cut", Titles.firstLine(of: String(repeating: "a", count: 100))!.count == Titles.maxLength)
check("an image keeps its alt text", Titles.firstLine(of: "![diagram](image.png) here") == "diagram here")
check("a long emoji line is cut at whole characters", Titles.firstLine(of: String(repeating: "👍🏽", count: 90))!.count == Titles.maxLength)
check("the title line range covers the raw line", Titles.titleLineRange(of: "\n# Hi there\nmore") == NSRange(location: 1, length: 10))

// 18. toggles: hidden markers, chevron, children, collapse
let toggleText = "> Title\n  child one\n  child two\nafter"
load(toggleText)
let ts = tv.textStorage!
let tlm = tv.layoutManager as! TaskBoxLayoutManager
check("the > of a toggle is hidden", ts.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) != nil && ts.attribute(Markdown.hiddenRun, at: 1, effectiveRange: nil) != nil)
check("a toggle gets a chevron, open by default", ts.attribute(Markdown.toggleChevron, at: 0, effectiveRange: nil) as? Bool == false)
check("a child's indent is hidden", ts.attribute(Markdown.hiddenRun, at: 8, effectiveRange: nil) != nil && ts.attribute(Markdown.hiddenRun, at: 9, effectiveRange: nil) != nil)
check("the title text sits one column in, past the chevron", abs(textX(0, 2) - column) < 0.5, "\(textX(0, 2))")
check("children line up with the title text", abs(textX(1, 2) - column) < 0.5, "\(textX(1, 2))")
check("the line after the children is not indented", abs(textX(3, 0)) < 0.5, "\(textX(3, 0))")
let chevronColumn = tlm.chevronRect(forMarkerAt: 0)!
check("the chevron's column is the gutter left of the title", abs(chevronColumn.maxX - tv.textContainer!.lineFragmentPadding - column) < 0.5, "\(chevronColumn)")
let chevronPoint = NSPoint(x: chevronColumn.midX + tv.textContainerOrigin.x, y: chevronColumn.midY + tv.textContainerOrigin.y)
check("a point on the chevron finds the toggle", tlm.toggleMarker(at: chevronPoint, origin: tv.textContainerOrigin) == 0)
check("a point on the title text does not", tlm.toggleMarker(at: NSPoint(x: chevronPoint.x + 60, y: chevronPoint.y), origin: tv.textContainerOrigin) == nil)
let openHeight = tlm.usedRect(for: tv.textContainer!).height
tv.setSelectedRange(NSRange(location: 12, length: 0))  // inside "child one"
tv.toggleCollapse(atMarker: 0)
tlm.ensureLayout(for: tv.textContainer!)
check("collapsing folds the children, not the line after", ts.attribute(Markdown.folded, at: 8, effectiveRange: nil) != nil && ts.attribute(Markdown.folded, at: 31, effectiveRange: nil) != nil && ts.attribute(Markdown.folded, at: 32, effectiveRange: nil) == nil)
check("the chevron says collapsed", ts.attribute(Markdown.toggleChevron, at: 0, effectiveRange: nil) as? Bool == true)
check("collapsing leaves the text alone", tv.string == toggleText)
check("a caret in children that fold goes to the end of the title", caret() == 7, "\(caret())")
let foldedHeight = tlm.usedRect(for: tv.textContainer!).height
check("collapsed children take no height", foldedHeight < openHeight - 40, "\(foldedHeight) vs \(openHeight)")
let titleBottom = tlm.lineFragmentRect(forGlyphAt: tlm.glyphIndexForCharacter(at: 0), effectiveRange: nil).maxY
let afterTop = tlm.lineFragmentRect(forGlyphAt: tlm.glyphIndexForCharacter(at: 32), effectiveRange: nil).minY
check("the line after sits right under the title", abs(afterTop - titleBottom) < 0.5, "\(afterTop) vs \(titleBottom)")
check("folded children have no glyphs to draw", tlm.propertyForGlyph(at: tlm.glyphIndexForCharacter(at: 12)) == .null)
tv.setSelectedRange(NSRange(location: 7, length: 0))
tv.moveRight(nil)
check("right arrow from the title's end jumps past the children", caret() == 32, "\(caret())")
tv.moveLeft(nil)
check("left arrow from the next line jumps back to the title", caret() == 7, "\(caret())")
tv.moveDown(nil)
check("down from the title skips the children", caret() >= 32, "\(caret())")
tv.moveUp(nil)
check("up from below skips them too", caret() <= 7, "\(caret())")
tv.setSelectedRange(NSRange(location: 32, length: 0))
tv.setSelectedRange(NSRange(location: 20, length: 0))
check("a caret put inside the children moving back lands on the title", caret() == 7, "\(caret())")
tv.setSelectedRange(NSRange(location: 7, length: 0))
tv.insertNewline(nil)
check("Enter on a collapsed title adds a sibling toggle after the children", tv.string == "> Title\n  child one\n  child two\n> \nafter" && caret() == 34, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
Markdown.apply(to: ts)
check("undo takes the sibling back and the toggle stays collapsed", tv.string == toggleText && ts.attribute(Markdown.folded, at: 8, effectiveRange: nil) != nil, tv.string.debugDescription)
tv.setSelectedRange(NSRange(location: 7, length: 0))
tv.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
Markdown.apply(to: ts)
check("editing the title keeps it collapsed", ts.attribute(Markdown.folded, at: 9, effectiveRange: nil) != nil && ts.attribute(Markdown.toggleChevron, at: 0, effectiveRange: nil) as? Bool == true)
tv.setSelectedRange(NSRange(location: 8, length: 0))
tv.deleteForward(nil)
Markdown.apply(to: ts)
check("Delete at a collapsed title's end joins the line after the children", tv.string == "> Title!after\n  child one\n  child two", tv.string.debugDescription)
tv.undoManager?.undo()
Markdown.apply(to: ts)
let afterStart = (tv.string as NSString).range(of: "after").location
let titleEnd = (tv.string as NSString).range(of: "\n").location
let expectedJoin = (tv.string as NSString).substring(to: titleEnd) + "after" + (tv.string as NSString).substring(with: NSRange(location: titleEnd, length: afterStart - 1 - titleEnd))
tv.setSelectedRange(NSRange(location: afterStart, length: 0))
tv.deleteBackward(nil)
Markdown.apply(to: ts)
check("Backspace on the line after a collapsed toggle joins it onto the title", tv.string == expectedJoin && caret() == titleEnd, "\(tv.string.debugDescription) \(caret())")
check("the remembered folds name the collapsed toggle", tv.collapsedToggleKeys().count == 1, "\(tv.collapsedToggleKeys())")
let rememberedKeys = tv.collapsedToggleKeys()
let rememberedTitle = (tv.string as NSString).substring(to: (tv.string as NSString).range(of: "\n").location)
let rememberedChild = 2 + (rememberedTitle as NSString).length + 1
load("x\n" + rememberedTitle + "\n  c")
tv.restoreCollapsedToggles(rememberedKeys)
Markdown.apply(to: ts)
check("restoring collapses the same toggle, now one line down", ts.attribute(Markdown.folded, at: rememberedChild, effectiveRange: nil) != nil)
tv.toggleCollapse(atMarker: 2)
check("toggling again expands it", ts.attribute(Markdown.folded, at: rememberedChild, effectiveRange: nil) == nil && ts.attribute(Markdown.toggleChevron, at: 2, effectiveRange: nil) as? Bool == false)
load("> # Big\n> ")
check("a heading toggle has the heading font", (ts.attribute(.font, at: 5, effectiveRange: nil) as! NSFont).pointSize == 24 * Markdown.zoom)
check("a heading toggle has a chevron", ts.attribute(Markdown.toggleChevron, at: 0, effectiveRange: nil) != nil)
check("an empty toggle gets the Toggle placeholder", ts.attribute(Markdown.togglePlaceholder, at: 8, effectiveRange: nil) != nil)
load("| > # Q\n  | kid")
check("a quoted heading toggle has a bar, a chevron and the heading font", ts.attribute(Markdown.quoteBar, at: 0, effectiveRange: nil) != nil && ts.attribute(Markdown.toggleChevron, at: 2, effectiveRange: nil) != nil && (ts.attribute(.font, at: 6, effectiveRange: nil) as! NSFont).pointSize == 24 * Markdown.zoom)
check("its quoted child lines up with the title text", abs(textX(1, 4) - textX(0, 6)) < 0.5, "\(textX(1, 4)) vs \(textX(0, 6))")
load("> Title")
tv.setSelectedRange(NSRange(location: 7, length: 0))
tv.insertNewline(nil)
check("Enter on an open toggle opens a child", tv.string == "> Title\n  " && caret() == 10, "\(tv.string.debugDescription) \(caret())")
Markdown.apply(to: ts)
tv.insertText("kid", replacementRange: NSRange(location: NSNotFound, length: 0))
Markdown.apply(to: ts)
tlm.ensureLayout(for: tv.textContainer!)
check("the child lines up with the title text", abs(textX(1, 2) - column) < 0.5, "\(textX(1, 2))")
tv.insertNewline(nil)
Markdown.apply(to: ts)
tv.insertNewline(nil)
check("Enter on an empty child steps out of the toggle", tv.string == "> Title\n  kid\n" && caret() == 14, "\(tv.string.debugDescription) \(caret())")
load("> - a\n  - [ ] b")
check("a list inside a toggle sits one column in", abs(textX(1, 8) - 2 * column) < 0.5, "\(textX(1, 8))")

// 19. stacking, peeling, and markers that never show
load("# Title")
tv.setSelectedRange(NSRange(location: 2, length: 0))
drainMain()
tv.insertText(">", replacementRange: NSRange(location: NSNotFound, length: 0))
drainMain()
tv.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
drainMain()
check("> then space on an H1 makes a heading toggle", tv.string == "> # Title" && caret() == 4, "\(tv.string) \(caret())")
tv.undoManager?.undo()
check("one undo takes the rewrite back to what was typed", tv.string == "# > Title", tv.string.debugDescription)
load("# Title")
tv.setSelectedRange(NSRange(location: 2, length: 0))
for ch in ["#", "#", " "] { tv.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0)) }
check("## then space on an H1 makes an H2", tv.string == "## Title" && caret() == 3, "\(tv.string) \(caret())")
load("> # Title")
tv.setSelectedRange(NSRange(location: 4, length: 0))
for ch in ["|", " "] { tv.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0)) }
check("| then space on a heading toggle makes a plain quote", tv.string == "| Title" && caret() == 2, "\(tv.string) \(caret())")
load("| > # Deep")
tv.setSelectedRange(NSRange(location: 6, length: 0))
drainMain()
tv.deleteBackward(nil); Markdown.apply(to: ts)
drainMain()
check("backspace peels the heading first", tv.string == "| > Deep" && caret() == 4, "\(tv.string) \(caret())")
tv.deleteBackward(nil); Markdown.apply(to: ts)
drainMain()
check("then the toggle", tv.string == "| Deep" && caret() == 2, "\(tv.string) \(caret())")
tv.deleteBackward(nil); Markdown.apply(to: ts)
drainMain()
check("then the quote", tv.string == "Deep" && caret() == 0, "\(tv.string) \(caret())")
tv.undoManager?.undo()
check("each peel is its own undo step", tv.string == "| Deep", tv.string)
load("a\n# Head")
tv.setSelectedRange(NSRange(location: 0, length: 0))
tv.setSelectedRange(NSRange(location: 2, length: 0))
check("a caret at the start of a heading line goes to its text", caret() == 4, "\(caret())")
tv.moveLeft(nil)
check("left from the text's start goes on to the line before", caret() == 1, "\(caret())")
tv.moveRight(nil)
check("right from the line before skips the markers", caret() == 4, "\(caret())")
load("ab\n# Head")
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.deleteForward(nil)
check("Delete before a heading line drops its marker with the break", tv.string == "abHead", tv.string)
load("ab\n| > Quote")
tv.setSelectedRange(NSRange(location: 1, length: 4))
tv.deleteBackward(nil)
check("deleting a selection into a marker line takes its markers whole", tv.string == "aQuote", tv.string)
for (location, length) in [(1, 2), (1, 3), (1, 4), (0, 3)] {
  load("x\n# Title")
  tv.setSelectedRange(NSRange(location: location, length: length))
  tv.deleteBackward(nil)
  check("deleting \(location)+\(length) of x/# Title leaves no raw #", !tv.string.contains("#"), tv.string.debugDescription)
  load("x\n# Title")
  tv.setSelectedRange(NSRange(location: location, length: length))
  tv.cut(nil)
  check("cutting \(location)+\(length) of x/# Title leaves no raw #", !tv.string.contains("#"), tv.string.debugDescription)
}
load("> T\n  a\n# Head")
tv.toggleCollapse(atMarker: 0)
tv.setSelectedRange(NSRange(location: 3, length: 0))
tv.deleteForward(nil)
check("Delete at a collapsed title before a heading joins its text without the #", tv.string == "> THead\n  a", tv.string.debugDescription)
load("> A\n  a\n> B\n  b")
tv.toggleCollapse(atMarker: 8)
let foldKeys = tv.collapsedToggleKeys()
check("only the collapsed toggle is remembered, not one that inherited the attribute from the last note", foldKeys == ["0\u{1}> B"], "\(foldKeys)")
load("new line\n> A\n  a\n> B\n  b")
tv.restoreCollapsedToggles(foldKeys)
Markdown.apply(to: ts)
check("a line added above keeps the fold on the same toggle", ts.attribute(Markdown.folded, at: 21, effectiveRange: nil) != nil && ts.attribute(Markdown.folded, at: 13, effectiveRange: nil) == nil)
load("> B\n  b\n> A\n  a")
tv.restoreCollapsedToggles(foldKeys)
Markdown.apply(to: ts)
check("toggles that swap places keep their own folds", ts.attribute(Markdown.folded, at: 4, effectiveRange: nil) != nil && ts.attribute(Markdown.folded, at: 12, effectiveRange: nil) == nil)
load("> A\n  a\n> Bee\n  b")
tv.restoreCollapsedToggles(foldKeys)
Markdown.apply(to: ts)
check("a toggle whose title changed drops the fold", (0..<ts.length).allSatisfy { ts.attribute(Markdown.folded, at: $0, effectiveRange: nil) == nil })
load("> S\n  1\n> S\n  2")
tv.toggleCollapse(atMarker: 8)
let twinKeys = tv.collapsedToggleKeys()
load("> S\n  1\n> S\n  2")
tv.restoreCollapsedToggles(twinKeys)
Markdown.apply(to: ts)
check("toggles with the same title are told apart by order", ts.attribute(Markdown.folded, at: 12, effectiveRange: nil) != nil && ts.attribute(Markdown.folded, at: 4, effectiveRange: nil) == nil)
load("ab\n# Head")
tv.setSelectedRange(NSRange(location: 1, length: 3))
tv.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
check("typing over a selection into a marker line leaves no raw marker", tv.string == "aZHead", tv.string)
load("one two\n# Head")
tv.setSelectedRange(NSRange(location: 10, length: 0))
tv.deleteWordBackward(nil)
check("⌥⌫ across a line start leaves no raw marker", !tv.string.contains("#") && tv.string.hasSuffix("Head"), tv.string)
load("one\n> # Head")
tv.setSelectedRange(NSRange(location: 8, length: 0))
tv.deleteToBeginningOfLine(nil)
check("⌘⌫ from a toggle heading's text start removes its markers whole", tv.string == "one\nHead", tv.string.debugDescription)

// Atomic list prefixes include the drawn marker, indent, and its spacing.
for prefix in ["- [ ] ", "- [x] ", "  - [ ] ", "- ", "  + ", "123. ", "-\t[ ]\t", "1.\t"] {
  let body = 2 + (prefix as NSString).length
  let text = "a\n" + prefix + "Task"
  load(text)
  for offset in 2..<body {
    tv.setSelectedRange(NSRange(location: 1, length: 0))
    tv.setSelectedRange(NSRange(location: offset, length: 0))
    check("\(prefix.debugDescription) caret skips prefix offset \(offset)", caret() == body, "\(caret())")
  }
  tv.setSelectedRange(NSRange(location: body, length: 0))
  tv.setSelectedRanges([NSValue(range: NSRange(location: body - 1, length: 0))], affinity: .downstream, stillSelecting: true)
  check("\(prefix.debugDescription) mouse tracking keeps caret past spacing", caret() == body, "\(caret())")
  tv.setSelectedRange(NSRange(location: body, length: 0))
  tv.moveLeftAndModifySelection(nil)
  check("\(prefix.debugDescription) shift-left selects the whole prefix", tv.selectedRange() == NSRange(location: 2, length: body - 2), "\(tv.selectedRange())")
  tv.setSelectedRange(NSRange(location: body, length: 0))
  tv.moveLeft(nil)
  check("\(prefix.debugDescription) left skips the complete prefix", caret() == 1, "\(caret())")
  tv.moveRight(nil)
  check("\(prefix.debugDescription) right enters the content", caret() == body, "\(caret())")
  load(text)
  tv.setSelectedRange(NSRange(location: 1, length: 0))
  tv.deleteForward(nil)
  check("\(prefix.debugDescription) forward join removes the whole prefix", tv.string == "aTask", tv.string.debugDescription)
  for offset in 3..<body {
    load(text)
    tv.setSelectedRange(NSRange(location: 1, length: offset - 1))
    tv.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
    check("\(prefix.debugDescription) replacement cannot split marker at \(offset)", tv.string == "aZTask", tv.string.debugDescription)
  }
}
load("- [ ] Task")
tv.setSelectedRange(NSRange(location: 6, length: 0))
tv.moveLeft(nil)
check("left at first task stays at content", caret() == 6, "\(caret())")
tv.deleteBackward(nil)
check("one backspace removes the checkbox", tv.string == "Task", tv.string.debugDescription)

// Existing block prefixes share the same mouse and selection contract.
for prefix in ["> ", "| ", "!> ", "### ", "| > ## "] {
  let text = "a\n" + prefix + "Body"
  let body = 2 + (prefix as NSString).length
  load(text)
  for offset in 2..<body {
    tv.setSelectedRange(NSRange(location: body, length: 0))
    tv.setSelectedRanges([NSValue(range: NSRange(location: offset, length: 0))], affinity: .downstream, stillSelecting: true)
    check("\(prefix.debugDescription) provisional click enters content", caret() == body, "\(caret())")
  }
  tv.moveLeft(nil)
  check("\(prefix.debugDescription) left skips prefix", caret() == 1, "\(caret())")
  tv.moveRight(nil)
  check("\(prefix.debugDescription) right skips prefix", caret() == body, "\(caret())")
}
load("")
tv.setSelectedRange(NSRange(location: 0, length: 0))
for ch in "[] " {
  tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
  drainMain()
}
Markdown.apply(to: tv.textStorage!)
check("checkbox shortcut consumes its trigger space", tv.string == "- [ ] " && caret() == 6, "\(tv.string.debugDescription) \(caret())")
tv.moveLeft(nil)
check("new empty checkbox has no interior caret stop", caret() == 6, "\(caret())")
tv.deleteBackward(nil)
drainMain()
check("new empty checkbox deletes as one unit", tv.string.isEmpty, tv.string.debugDescription)
tv.undoManager?.undo()
Markdown.apply(to: tv.textStorage!)
check("one undo restores the complete checkbox", tv.string == "- [ ] ", tv.string.debugDescription)

for divider in ["---  ", "***\t", "___ \t"] {
  load("a\n" + divider + "\nb")
  let end = 2 + (divider as NSString).length
  tv.setSelectedRange(NSRange(location: 1, length: 0))
  tv.moveRight(nil)
  check("divider trailing whitespace has no caret stops", caret() == end, "\(caret())")
  tv.moveLeft(nil)
  check("left crosses divider and its spacing in one move", caret() == 1, "\(caret())")
}

load("12. [ ] Task")
check("numbered checkbox prefix is displayed literally", tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) == nil)
tv.setSelectedRange(NSRange(location: 0, length: 1))
tv.deleteBackward(nil)
check("deleting literal list text removes only the selection", tv.string == "2. [ ] Task", tv.string)
load("![k](url)")
check("punctuation before a link remains visible text", tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) == nil)
tv.setSelectedRange(NSRange(location: 2, length: 0))
tv.deleteForward(nil)
check("deleting a link preserves preceding visible punctuation", tv.string == "!", tv.string)

// 20. typed arrows: "->" and "=>" become one character, as their own undo step
func type(_ s: String) {
  for ch in s {
    tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
    drainMain()  // one event per key, as in the app
  }
}
load("")
type("a->")
check("typing -> makes an arrow", tv.string == "a\u{2192}" && caret() == 2, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
check("one undo gives back the typed ->", tv.string == "a->" && tv.selectedRange() == NSRange(location: 3, length: 0), "\(tv.string.debugDescription) \(tv.selectedRange())")
tv.undoManager?.redo()
check("redo brings the arrow back, caret after it", tv.string == "a\u{2192}" && tv.selectedRange() == NSRange(location: 2, length: 0), "\(tv.string.debugDescription) \(tv.selectedRange())")
tv.deleteBackward(nil)
check("backspace takes the arrow as one character", tv.string == "a" && caret() == 1, "\(tv.string.debugDescription) \(caret())")
load("")
type("x=>y")
check("typing => makes a double arrow", tv.string == "x\u{21D2}y", tv.string.debugDescription)
tv.setSelectedRange(NSRange(location: 1, length: 0))
tv.deleteForward(nil)
check("delete takes the double arrow as one character", tv.string == "xy" && caret() == 1, "\(tv.string.debugDescription) \(caret())")
load("")
type("-->")
check("--> keeps the first dash", tv.string == "-\u{2192}", tv.string.debugDescription)
load("")
type("`a->")
check("no arrow in an inline code span being typed", tv.string == "`a->", tv.string.debugDescription)
load("```\na\n```")
tv.setSelectedRange(NSRange(location: 5, length: 0))
type("->")
check("no arrow in a fenced block", tv.string == "```\na->\n```", tv.string.debugDescription)
load("")
type("[a](http://x->")
check("no arrow in a link address", !tv.string.contains("\u{2192}"), tv.string.debugDescription)
load("a-")
tv.setSelectedRange(NSRange(location: 2, length: 0))
let arrowBoard = NSPasteboard(name: NSPasteboard.Name("notes-arrows-test-\(getpid())"))
arrowBoard.clearContents()
arrowBoard.setString(">", forType: .string)
_ = tv.readSelection(from: arrowBoard, type: .string)
check("pasting > after - leaves it alone", tv.string == "a->", tv.string.debugDescription)
arrowBoard.releaseGlobally()
load("")
type("> T")
Markdown.apply(to: tv.textStorage!)  // the window restyles on every change; the harness has no delegate
check("> then space still makes a toggle", tv.string == "> T" && tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) != nil, tv.string.debugDescription)
load("")
type("- >")
check("a > after a bullet's space stays a >", tv.string == "- >", tv.string.debugDescription)
load("")
type("->")
check("-> at a line start is an arrow", tv.string == "\u{2192}", tv.string.debugDescription)

// 21. typography: the same rule machinery for dashes, comparisons, ellipses
load("")
type("a--")
check("-- mid-line makes an en dash", tv.string == "a\u{2013}", tv.string.debugDescription)
tv.undoManager?.undo()
check("one undo gives back the typed --", tv.string == "a--" && tv.selectedRange() == NSRange(location: 3, length: 0), "\(tv.string.debugDescription) \(tv.selectedRange())")
load("")
type("wait...")
check("... makes an ellipsis", tv.string == "wait\u{2026}" && caret() == 5, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
check("one undo gives back the typed ...", tv.string == "wait..." && caret() == 7, "\(tv.string.debugDescription) \(caret())")
load("")
type("x<=y>=z<-")
check("<=, >= and <- make ≤ ≥ ←", tv.string == "x\u{2264}y\u{2265}z\u{2190}", tv.string.debugDescription)
tv.deleteBackward(nil)
check("backspace takes ← as one character", tv.string == "x\u{2264}y\u{2265}z", tv.string.debugDescription)
load("")
type("a-->b<->c<=>")
check("--> gives →, <-> gives ↔, <=> gives ⇔", tv.string == "a\u{2192}b\u{2194}c\u{21D4}", tv.string.debugDescription)
load("")
type("`a... b--")
check("no typography in a code span being typed", tv.string == "`a... b--", tv.string.debugDescription)
load("a-")
tv.setSelectedRange(NSRange(location: 2, length: 0))
arrowBoard.clearContents()
arrowBoard.setString("-", forType: .string)
_ = tv.readSelection(from: arrowBoard, type: .string)
check("pasting - after - leaves it alone", tv.string == "a--", tv.string.debugDescription)
load("")
type("---")
Markdown.apply(to: tv.textStorage!)
check("--- at a line start still types a divider", tv.string == "---" && tv.textStorage!.attribute(Markdown.divider, at: 0, effectiveRange: nil) != nil, tv.string.debugDescription)
load("---")
tv.setSelectedRange(NSRange(location: 3, length: 0))
type(">")
check("a divider's hidden dash never starts an arrow", tv.string == "--->", tv.string.debugDescription)

// 21b. a symbol finishing the next one: one ⌘Z gives back everything typed
for (typedText, symbol) in [("<->", "\u{2194}"), ("-->", "\u{2192}"), ("<=>", "\u{21D4}"), ("<-->", "\u{2194}")] {
  load("")
  type("a" + typedText)
  check("a\(typedText) makes \(symbol)", tv.string == "a" + symbol && caret() == 2, "\(tv.string.debugDescription) \(caret())")
  drainMain()
  tv.undoManager?.undo()
  let back = "a" + typedText
  check("one undo after a\(typedText) gives back what was typed", tv.string == back && tv.selectedRange() == NSRange(location: (back as NSString).length, length: 0), "\(tv.string.debugDescription) \(tv.selectedRange())")
  tv.undoManager?.redo()
  check("redo after a\(typedText) brings \(symbol) back", tv.string == "a" + symbol, tv.string.debugDescription)
}
load("")
type("a<->")
drainMain()
tv.undoManager?.undo()
tv.undoManager?.undo()
check("a second undo steps back through the typing, never leaving a symbol", !tv.string.contains("\u{2190}") && "a<->".hasPrefix(tv.string), tv.string.debugDescription)
load("a\u{2190}")
tv.setSelectedRange(NSRange(location: 2, length: 0))
type(">")
check("a pasted ← then > makes ↔", tv.string == "a\u{2194}", tv.string.debugDescription)
drainMain()
tv.undoManager?.undo()
check("and undo gives back the ← and the typed >", tv.string == "a\u{2190}>", tv.string.debugDescription)

// 21c. the same through real key events: keyDown → interpretKeyEvents →
// insertText, with the run loop closing each event's undo group (the
// window's undo manager groups by event), and ⌘Z through
// performKeyEquivalent, the window's own path (the harness has no menu).
func settle(timeout: TimeInterval = 5) {
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
  } while (tv.undoManager?.groupingLevel ?? 0) > 0 && Date() < deadline
}
func keyEvent(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
    windowNumber: win.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
    isARepeat: false, keyCode: keyCode)!
}
let keyCodes: [Character: (UInt16, NSEvent.ModifierFlags)] = [
  "a": (0, []), "-": (27, []), "=": (24, []), "<": (43, .shift), ">": (47, .shift), ".": (47, []),
]
func press(_ text: String) {
  for ch in text {
    let (code, flags) = keyCodes[ch]!
    tv.keyDown(with: keyEvent(String(ch), keyCode: code, flags: flags))
    settle()
  }
}
func commandZ() -> Bool {
  let handled = tv.performKeyEquivalent(with: keyEvent("z", keyCode: 6, flags: .command))
  settle()
  return handled
}
check("the note view is first responder for key events", win.firstResponder === tv)
for (typedText, symbol) in [("->", "\u{2192}"), ("<->", "\u{2194}"), ("-->", "\u{2192}"), ("<=>", "\u{21D4}"), ("<-->", "\u{2194}"), ("...", "\u{2026}")] {
  load("")
  settle()
  press("a" + typedText)
  check("keys a\(typedText) make \(symbol)", tv.string == "a" + symbol && caret() == 2, "\(tv.string.debugDescription) \(caret())")
  let handled = commandZ()
  let back = "a" + typedText
  check("one ⌘Z after keys a\(typedText) gives back what was typed", handled && tv.string == back && tv.selectedRange() == NSRange(location: (back as NSString).length, length: 0), "\(handled) \(tv.string.debugDescription) \(tv.selectedRange())")
  _ = commandZ()
  check("a second ⌘Z after keys a\(typedText) leaves no symbol", !tv.string.unicodeScalars.contains { $0.value > 0x7F } && back.hasPrefix(tv.string), tv.string.debugDescription)
}

// 22. dividers: a drawn hairline, dashes hidden, removed whole
let dividerText = "a\n---\nb"
load(dividerText)
let dts = tv.textStorage!
check("a divider's dashes are hidden", (2...4).allSatisfy { dts.attribute(Markdown.hiddenRun, at: $0, effectiveRange: nil) != nil })
check("a divider line is marked for the hairline", dts.attribute(Markdown.divider, at: 2, effectiveRange: nil) != nil && dts.attribute(Markdown.divider, at: 0, effectiveRange: nil) == nil)
tv.setSelectedRange(NSRange(location: 3, length: 0))
check("the caret never rests inside the dashes", caret() == 5 || caret() == 2, "\(caret())")
tv.setSelectedRange(NSRange(location: 5, length: 0))
tv.deleteBackward(nil)
check("backspace on a divider removes it in one keystroke", tv.string == "a\n\nb" && caret() == 2, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
check("undo brings the divider back", tv.string == dividerText, tv.string.debugDescription)
load(dividerText)
tv.setSelectedRange(NSRange(location: 6, length: 0))
tv.deleteBackward(nil)
check("backspace after a divider removes its line, no raw dashes", tv.string == "a\nb" && caret() == 2, "\(tv.string.debugDescription) \(caret())")
load(dividerText)
tv.setSelectedRange(NSRange(location: 1, length: 0))
tv.deleteForward(nil)
check("delete before a divider takes it whole", tv.string == "a\nb", tv.string.debugDescription)
load(dividerText)
tv.setSelectedRange(NSRange(location: 5, length: 0))
tv.deleteForward(nil)
check("delete on a divider removes it", tv.string == "a\n\nb", tv.string.debugDescription)
load(dividerText)
tv.setSelectedRange(NSRange(location: 0, length: 3))
tv.deleteBackward(nil)
check("deleting a selection into a divider takes it whole", tv.string == "\nb", tv.string.debugDescription)
load("```\n---\n```")
check("--- in a code block is not a divider", tv.textStorage!.attribute(Markdown.divider, at: 4, effectiveRange: nil) == nil)
let infoFence = "``` hello world\n---\n```"
load(infoFence)
check("--- under a multi-word info string is code, not a divider", tv.textStorage!.attribute(Markdown.divider, at: 16, effectiveRange: nil) == nil)
tv.setSelectedRange(NSRange(location: 19, length: 0))
tv.deleteBackward(nil)
check("backspace there deletes one dash", tv.string == "``` hello world\n--\n```", tv.string.debugDescription)
load(infoFence)
tv.setSelectedRange(NSRange(location: 16, length: 0))
tv.deleteForward(nil)
check("delete there deletes one dash", tv.string == "``` hello world\n--\n```", tv.string.debugDescription)
load(dividerText)
tv.setSelectedRange(NSRange(location: 0, length: 0))
tv.needsDisplay = true
let drep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
tv.cacheDisplay(in: tv.bounds, to: drep)
let dscale = Int(drep.pixelsWide) / Int(tv.bounds.width)
let dlm = tv.layoutManager!
let dline = dlm.lineFragmentRect(forGlyphAt: dlm.glyphIndexForCharacter(at: 2), effectiveRange: nil).offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
var hairRows = 0
var brightGlyphs = 0
for y in Int(dline.minY) * dscale..<Int(dline.maxY) * dscale {
  var lit = 0
  for x in stride(from: 30 * dscale, to: 390 * dscale, by: 2) {
    let c = drep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    if c.redComponent > 0.18 { lit += 1 }
    if c.redComponent > 0.5 { brightGlyphs += 1 }
  }
  if lit > 170 * dscale * 9 / 10 { hairRows += 1 }
}
check("a divider draws one hairline across the column", hairRows >= 1 && hairRows <= dscale, "\(hairRows) rows in \(dline)")
check("and no dash shows", brightGlyphs == 0, "\(brightGlyphs)")

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
// Overscroll: a long note scrolls past its last line, and typing there
// keeps the caret line out of the bottom band.
let scrollWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
let scroller = NSScrollView(frame: scrollWin.contentView!.bounds)
scroller.automaticallyAdjustsContentInsets = false
scroller.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 30, right: 0)
let stv = NoteTextView(frame: scroller.bounds)
stv.isRichText = false
stv.textContainerInset = NSSize(width: 18, height: 16)
stv.minSize = NSSize(width: 0, height: scroller.bounds.height)
stv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
stv.isVerticallyResizable = true
stv.autoresizingMask = [.width]
stv.textContainer?.widthTracksTextView = true
scroller.documentView = stv
scrollWin.contentView = scroller
scrollWin.makeFirstResponder(stv)
let visible: CGFloat = 400 - 52 - 30
func bandLimit() -> CGFloat { scroller.contentView.bounds.maxY - 30 - visible * NoteTextView.overscrollShare }
func caretLineBottom() -> CGFloat {
  let lm = stv.layoutManager!
  let r = lm.extraLineFragmentRect.isEmpty ? lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil) : lm.extraLineFragmentRect
  return r.maxY + stv.textContainerOrigin.y
}
stv.string = "short"
stv.sizeToFit()
check("a short note does not grow past the window", stv.frame.height <= 400, "\(stv.frame.height)")
stv.string = (1...40).map { "line \($0)" }.joined(separator: "\n")
stv.sizeToFit()
let used = stv.layoutManager!.usedRect(for: stv.textContainer!).height + 32
check("a long note scrolls 40% past its last line", abs(stv.frame.height - (used + visible * 0.4)) < 1, "\(stv.frame.height) vs \(used)")
stv.setSelectedRange(NSRange(location: (stv.string as NSString).length, length: 0))
stv.insertText("\nmore", replacementRange: stv.selectedRange())
check("typing at the end lifts the line out of the bottom band", caretLineBottom() <= bandLimit() + 0.5, "\(caretLineBottom()) > \(bandLimit())")
check("and the line is still on screen", caretLineBottom() > scroller.contentView.bounds.minY + 52, "\(caretLineBottom())")
scroller.contentView.scroll(to: NSPoint(x: 0, y: -52))
let endLength = (stv.string as NSString).length
let selectionStart = stv.layoutManager!.lineFragmentRect(forGlyphAt: (endLength - 120), effectiveRange: nil).minY + stv.textContainerOrigin.y
stv.scrollRangeToVisible(NSRange(location: endLength - 120, length: 120))
check("a selection is not lifted past its start", selectionStart >= scroller.contentView.bounds.minY + 52, "\(selectionStart) vs \(scroller.contentView.bounds.minY)")
stv.setSelectedRange(NSRange(location: 0, length: 0))
stv.scrollRangeToVisible(stv.selectedRange())
check("the top of a note scrolls back to the start", scroller.contentView.bounds.minY <= -52 + 0.5, "\(scroller.contentView.bounds.minY)")
// Checking a task near the bottom of a scrolled viewport must not run
// the typing caret lift, or move an existing selection to its marker.
final class TaskRestyleDelegate: NSObject, NSTextViewDelegate {
  func textDidChange(_ notification: Notification) {
    guard let view = notification.object as? NoteTextView, let storage = view.textStorage else { return }
    let selection = view.selectedRange()
    Markdown.apply(to: storage)
    view.setSelectedRange(selection)
  }
}
let taskRestyleDelegate = TaskRestyleDelegate()
stv.delegate = taskRestyleDelegate
stv.allowsUndo = true
stv.string = (1...80).map { "- [ ] task \($0)" }.joined(separator: "\n")
Markdown.apply(to: stv.textStorage!)
stv.sizeToFit()
let taskBox = (stv.string as NSString).range(of: "[ ] task 35").location
let taskGlyph = stv.layoutManager!.glyphIndexForCharacter(at: taskBox)
let taskY = stv.layoutManager!.lineFragmentRect(forGlyphAt: taskGlyph, effectiveRange: nil).maxY + stv.textContainerOrigin.y
let readingOrigin = NSPoint(x: 0, y: taskY - 340)
let readingSelection = NSRange(location: 6, length: 4)
stv.setSelectedRange(readingSelection)
scroller.contentView.scroll(to: readingOrigin)
stv.undoManager?.removeAllActions()
stv.toggleTaskMark(at: taskBox)
drainMain()
check("checking a visible task preserves the scrolled viewport", abs(scroller.contentView.bounds.minY - readingOrigin.y) < 0.5)
check("checking a task preserves an unrelated selection", stv.selectedRange() == readingSelection)
check("checking changes its mark", (stv.string as NSString).substring(with: NSRange(location: taskBox, length: 3)) == "[x]")
stv.undoManager?.undo()
check("undo keeps the task toggle selection and viewport", stv.selectedRange() == readingSelection && abs(scroller.contentView.bounds.minY - readingOrigin.y) < 0.5, "selection: \(stv.selectedRange()), origin: \(scroller.contentView.bounds.origin)")
check("checking a task is undoable", (stv.string as NSString).substring(with: NSRange(location: taskBox, length: 3)) == "[ ]")
stv.undoManager?.redo()
check("redo keeps the task toggle selection and viewport", stv.selectedRange() == readingSelection && abs(scroller.contentView.bounds.minY - readingOrigin.y) < 0.5, "selection: \(stv.selectedRange()), origin: \(scroller.contentView.bounds.origin)")
check("checking a task is redoable", (stv.string as NSString).substring(with: NSRange(location: taskBox, length: 3)) == "[x]")
let taskCaret = NSRange(location: taskBox + 8, length: 0)
stv.setSelectedRange(taskCaret)
scroller.contentView.scroll(to: readingOrigin)
stv.toggleTaskMark(at: taskBox)
drainMain()
check("unchecking the current task preserves its caret and viewport", stv.selectedRange() == taskCaret && abs(scroller.contentView.bounds.minY - readingOrigin.y) < 0.5)
check("unchecking clears its mark", (stv.string as NSString).substring(with: NSRange(location: taskBox, length: 3)) == "[ ]")
stv.delegate = nil
// Collapsed children take no part in the overscroll height.
stv.textContainer?.replaceLayoutManager(TaskBoxLayoutManager())
stv.string = "> Fold\n" + (1...60).map { "  line \($0)" }.joined(separator: "\n") + "\nend"
Markdown.apply(to: stv.textStorage!)
stv.sizeToFit()
let openUsed = stv.layoutManager!.usedRect(for: stv.textContainer!).height
check("an open toggle with many children makes a long note", stv.frame.height > 1000, "\(stv.frame.height)")
stv.toggleCollapse(atMarker: 0)
stv.sizeToFit()
let foldedUsed = stv.layoutManager!.usedRect(for: stv.textContainer!).height
check("collapsing it leaves only the title and the line after in the used height", foldedUsed < openUsed / 10, "\(foldedUsed) vs \(openUsed)")
check("and the note is short again, no overscroll", stv.frame.height <= 400.5, "\(stv.frame.height)")

// Date keywords and chips. The clock is pinned: 2026-10-05 in Singapore.
Dates.now = { Date(timeIntervalSince1970: 1_791_214_200) }
Dates.calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Singapore")!; return c }
let none = NSRange(location: NSNotFound, length: 0)
/// One pass of the run loop, as after each key event: closes the event's
/// undo group and runs the date conversion queued for after it (`type`
/// above makes one per key).
func pass() { drainMain() }
load("")
type("@today ")
check("typing @today then space gives the date", tv.string == "2026-10-05 " && caret() == 11, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
// As everywhere in NSTextView, the undone text comes back selected.
check("one undo gives back @today and the space", tv.string == "@today " && tv.selectedRange() == NSRange(location: 0, length: 6), "\(tv.string.debugDescription) \(tv.selectedRange())")
load("")
type("@today")
tv.insertText(" ", replacementRange: none)
tv.insertText("x", replacementRange: none)
pass()
check("a key typed before the conversion runs is kept", tv.string == "2026-10-05 x" && caret() == 12, "\(tv.string.debugDescription) \(caret())")
load("")
type("@today...")
check("@today then ... gives the date and an ellipsis", tv.string == "2026-10-05\u{2026}" && caret() == 11, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
check("undo takes back the ellipsis alone", tv.string == "2026-10-05...", tv.string.debugDescription)
// How the typed dots group depends on the run loop; the date's own step
// still comes back before the keyword's typing goes.
var undoStates: [String] = []
while tv.undoManager?.canUndo == true, undoStates.count < 6 { tv.undoManager?.undo(); undoStates.append(tv.string) }
check("further undos give back @today before removing it", undoStates.contains { $0.hasPrefix("@today") }, "\(undoStates)")
load("")
type("@today --> ")
check("a date then an arrow both convert", tv.string == "2026-10-05 \u{2192} ", tv.string.debugDescription)
load("")
type("@today")
tv.insertText(" ", replacementRange: none)
load("@today ")  // another note loads before the queued conversion runs
pass()
check("a queued conversion never edits the next note", tv.string == "@today ", tv.string.debugDescription)
load("")
type("see @Tomorrow.")
check("a period ends the keyword and stays", tv.string == "see 2026-10-06." && caret() == 15, "\(tv.string.debugDescription) \(caret())")
load("")
type("- buy @yesterday")
tv.insertNewline(nil)
pass()
check("enter converts and continues the list", tv.string == "- buy 2026-10-04\n- " && caret() == 19, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
check("one undo after enter gives back the keyword, keeping the new item", tv.string == "- buy @yesterday\n- ", tv.string.debugDescription)
load("- a\n- b @today")
tv.setSelectedRange(NSRange(location: 14, length: 0))
tv.insertTab(nil)
pass()
check("tab nests the item and converts", tv.string == "- a\n  - b 2026-10-05" && caret() == 20, "\(tv.string.debugDescription) \(caret())")
tv.undoManager?.undo()
check("one undo after tab gives back the keyword, still nested", tv.string == "- a\n  - b @today", tv.string.debugDescription)
load("x @today")
tv.setSelectedRange(NSRange(location: 8, length: 0))
tv.insertTab(nil)
pass()
check("tab on plain text keeps the tab", tv.string == "x 2026-10-05\t" && caret() == 13, "\(tv.string.debugDescription) \(caret())")
load("")
type("mail kai@today ")
check("an email is left alone", tv.string == "mail kai@today ", tv.string.debugDescription)
load("")
type("`@today ")
check("a code span being typed is left alone", tv.string == "`@today ", tv.string.debugDescription)
load("```\n\n```")
tv.setSelectedRange(NSRange(location: 4, length: 0))
type("@today ")
check("a code block is left alone", tv.string == "```\n@today \n```", tv.string.debugDescription)
let board = NSPasteboard(name: NSPasteboard.Name("notes-dates-test"))
board.clearContents()
board.setString("@today ", forType: .string)
load("")
_ = tv.readSelection(from: board, type: .string)
pass()
check("pasting @today and a space does not convert", tv.string == "@today ", tv.string.debugDescription)
board.clearContents()
board.setString(" ", forType: .string)
load("@today")
tv.setSelectedRange(NSRange(location: 6, length: 0))
_ = tv.readSelection(from: board, type: .string)
pass()
check("pasting a space after @today does not convert", tv.string == "@today ", tv.string.debugDescription)
board.releaseGlobally()

let chipText = "Due 2026-10-05, saved 2026-10-05 1008 - x.md, `2026-10-06`, [a](https://x.com/2026-10-07)\n```\n2026-10-08\n```\n| 2026-10-09\n"
load(chipText)
func chipAt(_ needle: String, from: Int = 0) -> Bool {
  let ns = tv.string as NSString
  let found = ns.range(of: needle, range: NSRange(location: from, length: ns.length - from))
  return tv.textStorage!.attribute(Markdown.dateChip, at: found.location, effectiveRange: nil) != nil
}
check("a standalone date gets a chip", chipAt("2026-10-05"))
var chipRange = NSRange()
_ = tv.textStorage!.attribute(Markdown.dateChip, at: 4, longestEffectiveRange: &chipRange, in: NSRange(location: 0, length: 20))
check("the chip covers just the date", chipRange == NSRange(location: 4, length: 10), "\(chipRange)")
check("a generated filename's date gets none", !chipAt("2026-10-05 1008"))
check("inline code gets none", !chipAt("2026-10-06"))
check("a link address gets none", !chipAt("2026-10-07"))
check("a code block gets none", !chipAt("2026-10-08"))
check("a quote's date gets one", chipAt("2026-10-09"))
check("the text is unchanged", tv.string == chipText)
let chipRects = (tv.layoutManager as! TaskBoxLayoutManager).chipRects(forCharacterRange: NSRange(location: 4, length: 10))
let dateBounds = tv.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 4, length: 10), in: tv.textContainer!)
let kernAfter = (tv.textStorage!.attribute(.kern, at: 13, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
let kernBefore = (tv.textStorage!.attribute(.kern, at: 3, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
check("the date gets room for the chip on both sides", abs(kernAfter - Double(Markdown.dateChipPad)) < 0.01 && abs(kernBefore - Double(Markdown.dateChipPad)) < 0.01, "\(kernBefore) \(kernAfter)")
load("- 2026-10-05\n2026-10-06")
check("a date that starts the line's text keeps its column", abs(textX(0, 2) - column) < 0.5, "\(textX(0, 2))")
load(chipText)
let natural = ("2026-10-05" as NSString).size(withAttributes: [.font: Markdown.baseFont]).width
check("one chip rect, the date's width plus its padding", chipRects.count == 1 && abs(chipRects[0].width - (natural + 2 * Markdown.dateChipPad)) < 1 && chipRects[0].minX < dateBounds.minX && chipRects[0].height > 12 && chipRects[0].height < dateBounds.height + 2, "\(chipRects) \(dateBounds) \(natural)")

// Appearance and font settings
let settingsSuite = "notes-theme-tests-\(getpid())"
let settingsDefaults = UserDefaults(suiteName: settingsSuite)!
check("settings default to the system appearance and sans serif", NoteSettings.appearance(in: settingsDefaults) == .system && NoteSettings.font(in: settingsDefaults) == .sans)
NoteSettings.save(.dark, in: settingsDefaults)
NoteSettings.save(.serif, in: settingsDefaults)
settingsDefaults.synchronize()
let settingsReloaded = UserDefaults(suiteName: settingsSuite)!
check("settings persist and reload", NoteSettings.appearance(in: settingsReloaded) == .dark && NoteSettings.font(in: settingsReloaded) == .serif)
settingsDefaults.set("purple", forKey: NoteSettings.appearanceKey)
settingsDefaults.set("comic", forKey: NoteSettings.fontKey)
check("an unknown stored setting falls back to the default", NoteSettings.appearance(in: settingsDefaults) == .system && NoteSettings.font(in: settingsDefaults) == .sans)
settingsDefaults.removePersistentDomain(forName: settingsSuite)
check("socket commands pick each setting",
  NoteSettings.change(forCommand: "appearance-dark") == .appearance(.dark) && NoteSettings.change(forCommand: "appearance-light") == .appearance(.light)
    && NoteSettings.change(forCommand: "appearance-system") == .appearance(.system) && NoteSettings.change(forCommand: "font-serif") == .font(.serif)
    && NoteSettings.change(forCommand: "font-mono") == .font(.mono) && NoteSettings.change(forCommand: "font-sans") == .font(.sans)
    && NoteSettings.change(forCommand: "font-comic") == nil)
check("light and dark force their appearance, system follows", NoteAppearance.system.nsAppearance == nil && NoteAppearance.light.nsAppearance?.name == .aqua && NoteAppearance.dark.nsAppearance?.name == .darkAqua)

let settingRows = NoteSettings.paletteActions(appearance: .dark, font: .serif)
check("the palette lists three appearances and three fonts", settingRows.map(\.title) == ["Appearance: System", "Appearance: Light", "Appearance: Dark", "Font: Sans Serif", "Font: Serif", "Font: Mono"], "\(settingRows.map(\.title))")
check("the current choices are checked", settingRows.filter(\.checked).map(\.title) == ["Appearance: Dark", "Font: Serif"])
check("every setting row runs its own command", settingRows.allSatisfy { NoteSettings.change(forCommand: $0.command) != nil })
check("every setting row has a symbol", settingRows.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
func found(_ query: String) -> [String] { settingRows.filter { $0.matches(query) }.map(\.title) }
check("\"theme\" finds the appearances", found("theme") == ["Appearance: System", "Appearance: Light", "Appearance: Dark"], "\(found("theme"))")
check("\"dark\" and \"light\" find their appearance", found("dark") == ["Appearance: Dark"] && found("light") == ["Appearance: Light"], "\(found("dark")) \(found("light"))")
check("\"font\" finds the fonts", found("font") == ["Font: Sans Serif", "Font: Serif", "Font: Mono"], "\(found("font"))")
check("\"serif\" and \"mono\" find their fonts", found("serif") == ["Font: Sans Serif", "Font: Serif"] && found("mono") == ["Font: Mono"] && found("monospace") == ["Font: Mono"], "\(found("serif")) \(found("mono"))")
check("keys still match by title", PaletteAction(title: "Zoom In", keys: "⌘+", symbol: "x", command: "zoom-in").matches("zoom in"))

// Each typeface: body and headings change, code stays mono, lists keep the grid.
let fontNote = "# Head\nbody **bold** _it_ `code` x\n```\nlet x = 1\n```\n- a\n1. b\n- [ ] c\n> t\n"
for choice in NoteFont.allCases {
  Markdown.font = choice
  load(fontNote)
  let ts = tv.textStorage!
  let ns = tv.string as NSString
  func fontAt(_ needle: String) -> NSFont { ts.attribute(.font, at: ns.range(of: needle).location, effectiveRange: nil) as! NSFont }
  let body = fontAt("body")
  let expected = choice.font(ofSize: 15 * Markdown.zoom)
  check("\(choice): body text is the \(choice) design", body.fontName == expected.fontName && body.pointSize == 15 * Markdown.zoom, body.fontName)
  check("\(choice): the design resolves", choice == .sans || expected.fontName != NoteFont.sans.font(ofSize: 15).fontName, expected.fontName)
  check("\(choice): mono is fixed pitch, the others are not", (choice == .mono) == body.isFixedPitch, body.fontName)
  let head = fontAt("Head")
  check("\(choice): headings keep their size and weight", head.pointSize == 24 * Markdown.zoom && head.fontDescriptor.symbolicTraits.contains(.bold) && head.familyName == body.familyName, "\(head)")
  let bold = fontAt("bold")
  let italic = fontAt("it_")
  check("\(choice): bold and italic stay in the design", bold.familyName == body.familyName && bold.fontDescriptor.symbolicTraits.contains(.bold) && italic.familyName == body.familyName && italic.fontDescriptor.symbolicTraits.contains(.italic), "\(bold.fontName) \(italic.fontName)")
  let span = fontAt("code")
  let block = fontAt("let x")
  check("\(choice): code spans and blocks stay monospaced", span.isFixedPitch && block.isFixedPitch && span.pointSize == Markdown.monoFont.pointSize && block.pointSize == Markdown.monoFont.pointSize, "\(span) \(block)")
  let col = Markdown.listColumn
  let lines = ns.components(separatedBy: "\n")
  let bulletLine = lines.firstIndex(of: "- a")!
  check("\(choice): bullet, number and task text sit at one column",
    abs(textX(bulletLine, 2) - col) < 0.5 && abs(textX(bulletLine + 1, 3) - col) < 0.5 && abs(textX(bulletLine + 2, 6) - col) < 0.5,
    "\(textX(bulletLine, 2)) \(textX(bulletLine + 1, 3)) \(textX(bulletLine + 2, 6)) vs \(col)")
  check("\(choice): the typing font follows", Markdown.baseFont.fontName == expected.fontName)
}
Markdown.font = .sans
load("x")

// Colours read in both appearances.
func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
  var out = color
  NSAppearance(named: name)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB)! }
  return out
}
func luminance(_ c: NSColor) -> CGFloat {
  func channel(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
}
func contrast(_ a: NSColor, on b: NSColor) -> CGFloat {
  // `a` may be translucent: composite it over `b` first.
  let alpha = a.alphaComponent
  let mixed = NSColor(srgbRed: a.redComponent * alpha + b.redComponent * (1 - alpha), green: a.greenComponent * alpha + b.greenComponent * (1 - alpha), blue: a.blueComponent * alpha + b.blueComponent * (1 - alpha), alpha: 1)
  let (x, y) = (luminance(mixed), luminance(b))
  return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
for name in [NSAppearance.Name.aqua, .darkAqua] {
  let canvas = resolved(Markdown.canvas, name)
  let label = name == .aqua ? "light" : "dark"
  check("\(label): body text reads on the canvas", contrast(resolved(.labelColor, name), on: canvas) >= 7, "\(contrast(resolved(.labelColor, name), on: canvas))")
  check("\(label): the accent reads as text (links, numbers)", contrast(resolved(Markdown.accent, name), on: canvas) >= 4.5, "\(contrast(resolved(Markdown.accent, name), on: canvas))")
  let selected = resolved(Markdown.selection, name)
  let selectedGround = NSColor(srgbRed: selected.redComponent * selected.alphaComponent + canvas.redComponent * (1 - selected.alphaComponent), green: selected.greenComponent * selected.alphaComponent + canvas.greenComponent * (1 - selected.alphaComponent), blue: selected.blueComponent * selected.alphaComponent + canvas.blueComponent * (1 - selected.alphaComponent), alpha: 1)
  check("\(label): selected text reads", contrast(resolved(.labelColor, name), on: selectedGround) >= 4.5, "\(contrast(resolved(.labelColor, name), on: selectedGround))")
  let cardTint = resolved(Markdown.codeCardColor, name)
  let card = NSColor(srgbRed: cardTint.redComponent * cardTint.alphaComponent + canvas.redComponent * (1 - cardTint.alphaComponent), green: cardTint.greenComponent * cardTint.alphaComponent + canvas.greenComponent * (1 - cardTint.alphaComponent), blue: cardTint.blueComponent * cardTint.alphaComponent + canvas.blueComponent * (1 - cardTint.alphaComponent), alpha: 1)
  for (kind, color) in [("keyword", Highlighter.keywordColor), ("string", Highlighter.stringColor), ("number", Highlighter.numberColor), ("type", Highlighter.typeColor), ("removed", Highlighter.removedColor)] {
    check("\(label): \(kind) highlight reads on the code card", contrast(resolved(color, name), on: card) >= 4.5, "\(contrast(resolved(color, name), on: card))")
  }
  check("\(label): dividers and callout borders show", contrast(resolved(Markdown.dividerColor, name), on: canvas) >= 1.3 && contrast(resolved(Markdown.calloutBorder, name), on: canvas) >= 1.3, "\(contrast(resolved(Markdown.dividerColor, name), on: canvas)) \(contrast(resolved(Markdown.calloutBorder, name), on: canvas))")
}

// The palette's last row has the same margin below it as the first row has above it.
let gapPalette = ActionPalette(actions: []) { _ in }
for count in [1, 3, 6, 23] {
  gapPalette.actions = (0..<count).map { PaletteAction(title: "Row \($0)", keys: "", symbol: "plus", command: "x") }
  gapPalette.show(over: win)
  if count == 23 {
    check("palette with \(count) rows stops at the window's height and scrolls", gapPalette.fittedHeight == win.frame.height - 40, "\(gapPalette.fittedHeight)")
  } else if let gaps = gapPalette.listGaps {
    check("palette with \(count) rows: the margin under the last row matches the one over the first", abs(gaps.top - gaps.bottom) < 0.5 && gaps.top > 4, "\(gaps)")
  } else {
    check("palette with \(count) rows lays out", false)
  }
  gapPalette.hide()
}

// An open palette follows a setting change from any path: checkmarks move
// and key badges take the new appearance's colour.
func pollUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
  return condition()
}
let liveSuite = "notes-theme-live-\(getpid())"
let liveDefaults = UserDefaults(suiteName: liveSuite)!
NoteSettings.save(.light, in: liveDefaults)
let liveSettings = SettingsController(defaults: liveDefaults)
liveSettings.commandActions = [PaletteAction(title: "Zoom In", keys: "⌘+", symbol: "plus.magnifyingglass", command: "zoom-in")]
let livePalette = ActionPalette(actions: liveSettings.paletteActions) { _ in }
liveSettings.palette = livePalette
livePalette.show(over: win)
func liveChecked() -> [String] { livePalette.shownRows.filter(\.checked).map(\.title) }
func liveBadge() -> [CGFloat] { livePalette.badgeColor(atRow: 0)?.components ?? [] }
check("the open palette starts on the stored choices", liveChecked() == ["Appearance: Light", "Font: Sans Serif"], "\(liveChecked())")
let lightBadge = liveBadge()
check("the open palette's rows have key badges", !lightBadge.isEmpty)
check("a font command moves the open palette's checkmark", liveSettings.handle("font-mono") && liveChecked() == ["Appearance: Light", "Font: Mono"], "\(liveChecked())")
check("an appearance command moves it too", liveSettings.handle("appearance-dark") && liveChecked() == ["Appearance: Dark", "Font: Mono"], "\(liveChecked())")
check("the open palette's key badges change colour", pollUntil { !liveBadge().isEmpty && liveBadge() != lightBadge }, "\(liveBadge())")
let refreshedBadge = liveBadge()
livePalette.hide()
livePalette.show(over: win)
check("they match a palette opened in dark", pollUntil { liveBadge() == refreshedBadge }, "\(liveBadge()) vs \(refreshedBadge)")
check("other commands are left to the window", !liveSettings.handle("zoom-in"))
check("the changes are saved", NoteSettings.appearance(in: liveDefaults) == .dark && NoteSettings.font(in: liveDefaults) == .mono)
livePalette.hide()
NSApp.appearance = nil
Markdown.font = .sans
liveDefaults.removePersistentDomain(forName: liveSuite)

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
