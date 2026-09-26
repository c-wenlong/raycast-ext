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
load("#### Four\n> quoted\n> \nplain")
let h4 = tv.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as! NSFont
check("#### is a heading", h4.pointSize == 15 * Markdown.zoom && h4.fontDescriptor.symbolicTraits.contains(.bold), "\(h4)")
check("the #### marker is hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) != nil)
check("the > marker is hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 10, effectiveRange: nil) != nil)
let quoteStyle = tv.textStorage!.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as! NSParagraphStyle
check("quote text is indented past the bar", quoteStyle.headIndent == Markdown.quoteIndent && quoteStyle.firstLineHeadIndent == Markdown.quoteIndent)
var quoteRun = NSRange()
_ = tv.textStorage!.attribute(Markdown.quoteBar, at: 10, longestEffectiveRange: &quoteRun, in: NSRange(location: 0, length: tv.textStorage!.length))
check("consecutive quote lines share one bar", quoteRun == NSRange(location: 10, length: 12), "\(quoteRun)")
check("an empty quote line gets the placeholder", tv.textStorage!.attribute(Markdown.quotePlaceholder, at: 19, effectiveRange: nil) != nil)
check("plain text is not a quote", tv.textStorage!.attribute(Markdown.quoteBar, at: 22, effectiveRange: nil) == nil)
tv.setSelectedRange(NSRange(location: 18, length: 0))
tv.insertNewline(nil)
check("Enter in a quote continues it", tv.string.hasPrefix("#### Four\n> quoted\n> \n> \n"), tv.string.debugDescription)

// 14b. callouts
load(">> one\n>> two\n\n>>\n> q")
check("the >> marker is hidden", tv.textStorage!.attribute(Markdown.hiddenRun, at: 0, effectiveRange: nil) != nil && tv.textStorage!.attribute(Markdown.hiddenRun, at: 1, effectiveRange: nil) != nil)
var calloutRun = NSRange()
_ = tv.textStorage!.attribute(Markdown.calloutBox, at: 0, longestEffectiveRange: &calloutRun, in: NSRange(location: 0, length: tv.textStorage!.length))
check("consecutive callout lines share one box", calloutRun == NSRange(location: 0, length: 14), "\(calloutRun)")
let calloutStyle = tv.textStorage!.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as! NSParagraphStyle
check("callout text is inset on both sides", calloutStyle.headIndent == Markdown.calloutPad && calloutStyle.tailIndent == -Markdown.calloutPad)
check("an empty callout line gets its placeholder", tv.textStorage!.attribute(Markdown.calloutPlaceholder, at: 15, effectiveRange: nil) != nil)
check("a callout is not a quote", tv.textStorage!.attribute(Markdown.quoteBar, at: 3, effectiveRange: nil) == nil)
check("a quote after a callout is still a quote", tv.textStorage!.attribute(Markdown.quoteBar, at: 18, effectiveRange: nil) != nil && tv.textStorage!.attribute(Markdown.calloutBox, at: 18, effectiveRange: nil) == nil)
check("slash finds the callout", SlashMenu.matches("call").map(\.id) == ["callout"] && SlashMenu.matches("box").map(\.id) == ["callout"])

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
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))  // closes the typing undo group, as the event loop would
tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
check("return applies the entry and removes the /query", tv.string == "## hello " && !tv.slashMenuIsOpen, tv.string.debugDescription)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
tv.undoManager?.undo()
check("one undo restores the typed text", tv.string == "hello /h2", tv.string.debugDescription)
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
load(">   \n> m")
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
load("a\n> one\n> two\nb\n>\tc")
let firstQuote = tv.textStorage!.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as! NSParagraphStyle
let lastQuote = tv.textStorage!.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as! NSParagraphStyle
check("a quote keeps air above its first line and below its last", firstQuote.paragraphSpacingBefore == Markdown.quoteGap && lastQuote.paragraphSpacing == Markdown.quoteGap && firstQuote.paragraphSpacing == 2 * Markdown.zoom && lastQuote.paragraphSpacingBefore == 0)
check("a tab after > stays visible rather than kerned", tv.textStorage!.attribute(Markdown.hiddenRun, at: 16, effectiveRange: nil) == nil && tv.textStorage!.attribute(Markdown.quoteBar, at: 16, effectiveRange: nil) != nil)
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
