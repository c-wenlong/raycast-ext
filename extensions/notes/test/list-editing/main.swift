// Command-line tests for ListEditing. Run with `npm run test-helper`.

import Foundation

var failures = 0
var count = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
  count += 1
  if condition() {
    print("ok   \(name)")
  } else {
    failures += 1
    print("FAIL \(name) \(detail())")
  }
}

/// Applies an edit the way the text view does and returns (text, cursor).
func applied(_ text: String, _ edit: ListEditing.Edit?) -> (String, Int)? {
  guard let edit else { return nil }
  let ns = text as NSString
  return (ns.replacingCharacters(in: edit.range, with: edit.replacement), edit.cursor)
}

func cursorAtEnd(_ text: String) -> Int { (text as NSString).length }

// Enter continues bullets, tasks and numbers

do {
  let (text, cursor) = applied("- one", ListEditing.newline(in: "- one", cursor: 5))!
  check("bullet continues", text == "- one\n- ", text)
  check("bullet cursor after marker", cursor == 8, "\(cursor)")
}
do {
  let (text, _) = applied("- [x] done", ListEditing.newline(in: "- [x] done", cursor: 10))!
  check("task continues unchecked", text == "- [x] done\n- [ ] ", text)
}
do {
  let (text, cursor) = applied("1. one", ListEditing.newline(in: "1. one", cursor: 6))!
  check("number increments", text == "1. one\n2. ", text)
  check("number cursor", cursor == 10, "\(cursor)")
}
do {
  let src = "1. one\n2. two\n3. three"
  let (text, _) = applied(src, ListEditing.newline(in: src, cursor: 13))!  // end of "2. two"
  check("insert in middle renumbers", text == "1. one\n2. two\n3. \n4. three", text)
}
do {
  let src = "1. one two"
  let (text, cursor) = applied(src, ListEditing.newline(in: src, cursor: 6))!  // after "one"
  check("split moves tail to new item", text == "1. one\n2. two", text)
  check("split cursor", cursor == 10, "\(cursor)")
}
do {
  let src = "- one\n- "
  let (text, cursor) = applied(src, ListEditing.newline(in: src, cursor: 8))!
  check("enter on empty item ends list", text == "- one\n", text)
  check("end list cursor", cursor == 6, "\(cursor)")
}
do {
  let src = "1. one\n   1. child\n   2. "
  let (text, _) = applied(src, ListEditing.newline(in: src, cursor: cursorAtEnd(src)))!
  check("enter on empty nested item outdents", text == "1. one\n   1. child\n2. ", text)
}
check("enter on plain text is nil", ListEditing.newline(in: "hello", cursor: 5) == nil)

// Tab nests, Shift-Tab unnests, numbers restart per level

do {
  let src = "1. one\n2. two"
  let (text, cursor) = applied(src, ListEditing.indent(in: src, cursor: cursorAtEnd(src), by: 1))!
  check("tab nests number under number, restarts at 1", text == "1. one\n   1. two", text)
  check("tab cursor keeps column", cursor == cursorAtEnd("1. one\n   1. two"), "\(cursor)")
}
do {
  let src = "1. one\n   1. a\n2. two\n3. three"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: 22, by: 1))!  // on "3. three"
  check("tab on a later sibling continues the child list", text == "1. one\n   1. a\n2. two\n   1. three", text)
}
do {
  let src = "1. one\n   1. a\n   2. b\n2. two"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: 21, by: -1))!  // on "   2. b"
  check("shift-tab unnests and renumbers both levels", text == "1. one\n   1. a\n2. b\n3. two", text)
}
do {
  let src = "- one\n- two"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: cursorAtEnd(src), by: 1))!
  check("bullet nests by two spaces", text == "- one\n  - two", text)
}
do {
  let src = "- [ ] one\n- [ ] two"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: cursorAtEnd(src), by: 1))!
  check("task nests", text == "- [ ] one\n  - [ ] two", text)
}
do {
  let src = "- one\n  - two"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: cursorAtEnd(src), by: -1))!
  check("shift-tab on nested bullet", text == "- one\n- two", text)
}
check("tab on the first item has no parent", ListEditing.indent(in: "- one", cursor: 5, by: 1) == nil)
check("shift-tab at top level is nil", ListEditing.indent(in: "- one\n- two", cursor: 11, by: -1) == nil)
check("tab on plain text is nil", ListEditing.indent(in: "hello", cursor: 5, by: 1) == nil)

// [] + space becomes a task

do {
  let (text, cursor) = applied("[]", ListEditing.taskShortcut(in: "[]", cursor: 2))!
  check("[] becomes task", text == "- [ ] ", text)
  check("[] cursor at end", cursor == 6, "\(cursor)")
}
do {
  let (text, _) = applied("- []", ListEditing.taskShortcut(in: "- []", cursor: 4))!
  check("- [] becomes task", text == "- [ ] ", text)
}
do {
  let (text, _) = applied("  [ ]", ListEditing.taskShortcut(in: "  [ ]", cursor: 5))!
  check("indented [ ] keeps indent", text == "  - [ ] ", text)
}
check("[] mid-line is nil", ListEditing.taskShortcut(in: "text []", cursor: 7) == nil)
check("[] not at line end is nil", ListEditing.taskShortcut(in: "[] tail", cursor: 2) == nil)

// renumber keeps blank-separated blocks and mixed markers sane

check(
  "renumber restarts after a non-list line",
  ListEditing.renumber(["3. a", "7. b", "text", "9. c"]) == ["1. a", "2. b", "text", "1. c"])
check(
  "renumber: bullet between numbers restarts",
  ListEditing.renumber(["1. a", "- x", "5. b"]) == ["1. a", "- x", "1. b"])

// fences

check("enter inside a fence is plain", ListEditing.newline(in: "```\n- x\n```", cursor: 7) == nil)
check("tab inside a fence is plain", ListEditing.indent(in: "```\n- a\n- b\n```", cursor: 11, by: 1) == nil)
check("closed fence ends", ListEditing.insideFence("```\ncode\n```\n- x", cursor: 14) == false)
check("an unclosed fence is not a block, so list rules still run below it", ListEditing.insideFence("```\n- item", cursor: 10) == false && ListEditing.newline(in: "```\n- item", cursor: 10) != nil)
check("hasUnclosedFence sees the open fence", ListEditing.hasUnclosedFence("```\n- item") && !ListEditing.hasUnclosedFence("```\nx\n```"))
check("inside a closed fence still counts", ListEditing.insideFence("```\ncode\n```", cursor: 5))
do {
  let (text, cursor) = applied("```sh", ListEditing.codeFence(in: "```sh", cursor: 5))!
  check("``` opens a block with a closing fence", text == "```sh\n\n```", text)
  check("``` cursor on the empty line", cursor == 6, "\(cursor)")
}
do {
  let (text, _) = applied("~~~", ListEditing.codeFence(in: "~~~", cursor: 3))!
  check("~~~ opens a block", text == "~~~\n\n~~~", text)
}
check("``` mid line is nil", ListEditing.codeFence(in: "a ```", cursor: 5) == nil)
do {
  let (text, _) = applied("[x]", ListEditing.taskShortcut(in: "[x]", cursor: 3))!
  check("[x] becomes done task", text == "- [x] ", text)
}

// backspace after a marker

do {
  let (text, cursor) = applied("- one", ListEditing.backspace(in: "- one", cursor: 2))!
  check("backspace removes bullet", text == "one", text)
  check("backspace cursor", cursor == 0, "\(cursor)")
}
do {
  let src = "1. a\n   1. b"
  let (text, _) = applied(src, ListEditing.backspace(in: src, cursor: 11))!
  check("backspace outdents nested number", text == "1. a\n2. b", text)
}
check("backspace mid-content is nil", ListEditing.backspace(in: "- one", cursor: 4) == nil)

// inline wrap

do {
  let edit = ListEditing.toggleWrap(in: "hello world", selection: NSRange(location: 0, length: 5), marker: "**")
  let (text, _) = applied("hello world", edit)!
  check("bold wraps", text == "**hello** world", text)
  check("bold keeps selection on the word", edit.cursor == 2 && edit.selectionLength == 5, "\(edit.cursor) \(edit.selectionLength)")
}
do {
  let edit = ListEditing.toggleWrap(in: "**hello** world", selection: NSRange(location: 2, length: 5), marker: "**")
  let (text, _) = applied("**hello** world", edit)!
  check("bold unwraps when surrounded", text == "hello world", text)
}
do {
  let edit = ListEditing.toggleWrap(in: "ab", selection: NSRange(location: 1, length: 0), marker: "_")
  let (text, cursor) = applied("ab", edit)!
  check("empty selection inserts a pair", text == "a__b" && cursor == 2, "\(text) \(cursor)")
}

do {
  let edit = ListEditing.toggleWrap(in: "**bold** x", selection: NSRange(location: 8, length: 0), marker: "**")
  check("⌘B right after a closing pair changes nothing", edit.range == NSRange(location: 8, length: 0) && edit.replacement == "" && edit.cursor == 8, "\(edit)")
  let front = ListEditing.toggleWrap(in: "x **bold**", selection: NSRange(location: 2, length: 0), marker: "**")
  check("⌘B right before an opening pair changes nothing", front.replacement == "" && front.range == NSRange(location: 2, length: 0) && front.cursor == 2, "\(front)")
  let between = ListEditing.toggleWrap(in: "**a****b**", selection: NSRange(location: 5, length: 0), marker: "**")
  let merged = ("**a****b**" as NSString).replacingCharacters(in: between.range, with: between.replacement)
  check("a caret between two pairs still merges them", merged == "**ab**", merged)
  let fenced = "**a**\n```\n**b**\n```"
  let acrossFence = ListEditing.toggleWrap(in: fenced, selection: NSRange(location: 0, length: (fenced as NSString).length), marker: "**")
  let fencedOut = (fenced as NSString).replacingCharacters(in: acrossFence.range, with: acrossFence.replacement)
  check("a selection across lines and a fence leaves the fenced pair alone", fencedOut.contains("```\n**b**\n```"), fencedOut.debugDescription)
  func toggledAll(_ src: String, _ marker: String) -> String {
    let edit = ListEditing.toggleWrap(in: src, selection: NSRange(location: 0, length: (src as NSString).length), marker: marker)
    return (src as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
  }
  check("styled lines unwrap line by line", toggledAll("**a**\n**b**", "**") == "a\nb", toggledAll("**a**\n**b**", "**").debugDescription)
  check("plain lines wrap line by line", toggledAll("a\nb", "**") == "**a**\n**b**", toggledAll("a\nb", "**").debugDescription)
  check("mixed lines all end up styled", toggledAll("**a**\nb\n\nc **d** e", "**") == "**a**\n**b**\n\n**c d e**", toggledAll("**a**\nb\n\nc **d** e", "**").debugDescription)
  check("the fenced line is skipped when wrapping across lines", toggledAll("a\n```\nb\n```\nc", "**") == "**a**\n```\nb\n```\n**c**", toggledAll("a\n```\nb\n```\nc", "**").debugDescription)
}
do {
  let src = "**a** and **b**"
  let edit = ListEditing.toggleWrap(in: src, selection: NSRange(location: 0, length: (src as NSString).length), marker: "**")
  let out = (src as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
  check("a selection over two pairs becomes one pair", out == "**a and b**", out)
  check("the merged run stays selected", edit.cursor == 2 && edit.selectionLength == 7, "\(edit)")
  let partial = ListEditing.toggleWrap(in: src, selection: NSRange(location: 3, length: 9), marker: "**")  // "** and **b" … visible " and b"
  let partialOut = (src as NSString).replacingCharacters(in: partial.range, with: partial.replacement)
  check("a selection reaching into pairs folds them in whole", partialOut == "**a and b**", partialOut)
  check("the selection keeps to the visible text it covered (\" and \")", partial.cursor == 3 && partial.selectionLength == 5, "\(partial)")
  let lines = ListEditing.toggleWrap(in: "xx **a**\nb yy", selection: NSRange(location: 7, length: 4), marker: "**")  // "a**\nb " visible "a\nb "
  let linesOut = ("xx **a**\nb yy" as NSString).replacingCharacters(in: lines.range, with: lines.replacement)
  check("across lines, styled and plain parts end up styled", linesOut == "xx **a**\n**b **yy", linesOut.debugDescription)
  check("across lines the selection still covers just the visible text it did", lines.cursor == 7 && lines.selectionLength == 6, "\(lines)")
  let mixed = ListEditing.toggleWrap(in: "plain **b** c", selection: NSRange(location: 0, length: 13), marker: "**")
  let mixedOut = ("plain **b** c" as NSString).replacingCharacters(in: mixed.range, with: mixed.replacement)
  check("a mixed selection becomes all styled", mixedOut == "**plain b c**", mixedOut)
  let italic = ListEditing.toggleWrap(in: "_a_ _b_", selection: NSRange(location: 0, length: 7), marker: "_")
  let italicOut = ("_a_ _b_" as NSString).replacingCharacters(in: italic.range, with: italic.replacement)
  check("the same for italic", italicOut == "_a b_", italicOut)
}

/// Runs toggleWrap and returns (text, selection) after the edit.
func toggled(_ src: String, _ location: Int, _ length: Int, _ marker: String) -> (String, NSRange) {
  let edit = ListEditing.toggleWrap(in: src, selection: NSRange(location: location, length: length), marker: marker)
  let (text, cursor) = applied(src, edit)!
  return (text, NSRange(location: cursor, length: edit.selectionLength))
}
do {
  // "a **bold** c": markers at 2-3 and 8-9, "bold" at 4-7
  let cases: [(String, Int, Int, NSRange)] = [
    ("caret inside bold unwraps", 5, 0, NSRange(location: 3, length: 0)),
    ("caret at bold start unwraps", 4, 0, NSRange(location: 2, length: 0)),
    ("caret at bold end unwraps", 8, 0, NSRange(location: 6, length: 0)),
    ("selection inside bold unwraps", 5, 2, NSRange(location: 3, length: 2)),
    ("selection over bold and its markers unwraps", 2, 8, NSRange(location: 2, length: 4)),
    ("selection over bold and one marker unwraps", 2, 6, NSRange(location: 2, length: 4)),
    ("selection from mid-marker unwraps", 3, 7, NSRange(location: 2, length: 4)),
  ]
  for (name, location, length, expected) in cases {
    let (text, selection) = toggled("a **bold** c", location, length, "**")
    check(name, text == "a bold c" && selection == expected, "\(text) \(selection)")
  }
}
do {
  let (text, selection) = toggled("an _em_ word", 5, 0, "_")
  check("caret inside italic unwraps", text == "an em word" && selection.location == 4, "\(text) \(selection)")
}
do {
  let (text, selection) = toggled("~~gone~~ now", 3, 2, "~~")
  check("selection inside strike unwraps", text == "gone now" && selection == NSRange(location: 1, length: 2), "\(text) \(selection)")
}
do {
  let (text, selection) = toggled("x `k` y", 3, 0, "`")
  check("caret inside code unwraps", text == "x k y" && selection.location == 2, "\(text) \(selection)")
}
do {
  let (text, selection) = toggled("**a** and **b**", 12, 0, "**")
  check("caret picks the pair it is in", text == "**a** and b" && selection.location == 10, "\(text) \(selection)")
}
do {
  let (text, _) = toggled("_a **b** c_", 6, 0, "_")
  check("⌘I inside bold inside italic unwraps the italic", text == "a **b** c", text)
  let (bold, _) = toggled("_a **b** c_", 6, 0, "**")
  check("⌘B inside bold inside italic unwraps the bold", bold == "_a b c_", bold)
}
do {
  let (text, selection) = toggled("ab**cd**", 0, 2, "**")
  check("a selection touching a pair still wraps", text == "**ab****cd**" && selection == NSRange(location: 2, length: 2), "\(text) \(selection)")
  let (after, caret) = toggled("**bold** x", 8, 0, "**")
  check("a caret after the closing marker neither unwraps nor adds a pair", after == "**bold** x" && caret.location == 8, "\(after) \(caret)")
  let (before, _) = toggled("x **bold**", 2, 0, "**")
  check("a caret before the opening marker does not unwrap", before.hasSuffix("**bold**"), before)
}
do {
  let (text, _) = toggled("a **bold** c", 5, 0, "_")
  check("another marker inside bold adds its own pair", text == "a **b__old** c", text)
  let (fenced, _) = toggled("```\n**b**\n```", 6, 0, "**")
  check("bold markers in a code block are not a pair", fenced != "```\nb\n```", fenced)
  let (swallowed, _) = toggled("*x _y_ z*", 4, 0, "_")
  check("underscores inside a star italic are not a pair", swallowed != "*x y z*", swallowed)
  let (underscored, _) = toggled("__a **b** c__", 6, 0, "**")
  check("stars inside an underscore bold are not a pair", underscored != "__a b c__", underscored)
}
do {
  let edit = ListEditing.link(in: "see docs", selection: NSRange(location: 4, length: 4), url: "https://x.y")
  let (text, _) = applied("see docs", edit)!
  check("paste url over selection links it", text == "see [docs](https://x.y)", text)
}
do {
  let edit = ListEditing.link(in: "see docs", selection: NSRange(location: 4, length: 4), url: nil)
  let (text, cursor) = applied("see docs", edit)!
  check("⌘L caret inside parens", text == "see [docs]()" && cursor == 11, "\(text) \(cursor)")
}

// line prefixes

do {
  let (text, _) = applied("title", ListEditing.setLinePrefix(in: "title", cursor: 3, prefix: .heading(2)))!
  check("heading prefix added", text == "## title", text)
}
do {
  let (text, _) = applied("## title", ListEditing.setLinePrefix(in: "## title", cursor: 3, prefix: .heading(2)))!
  check("same heading prefix removed", text == "title", text)
}
do {
  let (text, _) = applied("- item", ListEditing.setLinePrefix(in: "- item", cursor: 3, prefix: .task))!
  check("bullet to task", text == "- [ ] item", text)
}
do {
  let (text, _) = applied("  2. item", ListEditing.setLinePrefix(in: "  2. item", cursor: 5, prefix: .bullet))!
  check("number to bullet keeps indent", text == "  - item", text)
}
do {
  let (text, cursor) = applied("x", ListEditing.setLinePrefix(in: "x", cursor: 1, prefix: .quote))!
  check("quote prefix and cursor", text == "| x" && cursor == 3, "\(text) \(cursor)")
}
do {
  let edit = ListEditing.toggleCodeBlock(in: "a\nb\nc", selection: NSRange(location: 2, length: 1))
  let (text, _) = applied("a\nb\nc", edit)!
  check("code block wraps the line", text == "a\n```\nb\n```\nc", text)
}
do {
  let src = "```\nb\n```"
  let edit = ListEditing.toggleCodeBlock(in: src, selection: NSRange(location: 0, length: (src as NSString).length))
  let (text, _) = applied(src, edit)!
  check("code block unwraps", text == "b", text)
}

// end of file, CRLF

do {
  let (text, cursor) = applied("- one\n", ListEditing.newline(in: "- one\n", cursor: 5))!
  check("enter before a final newline continues", text == "- one\n- \n" && cursor == 8, "\(text.debugDescription) \(cursor)")
}
check("enter on the empty last line is plain", ListEditing.newline(in: "- one\n", cursor: 6) == nil)
check("enter in empty text is plain", ListEditing.newline(in: "", cursor: 0) == nil)
do {
  let src = "- one\r\n- two"
  let (text, cursor) = applied(src, ListEditing.newline(in: src, cursor: 5))!
  check("crlf list keeps crlf", text == "- one\r\n- \r\n- two", text.debugDescription)
  check("crlf cursor counts both characters", cursor == 9, "\(cursor)")
}
do {
  let (text, cursor) = applied("```\r\nx", ListEditing.codeFence(in: "```\r\nx", cursor: 3))!
  check("crlf fence uses crlf", text == "```\r\n\r\n```\r\nx" && cursor == 5, "\(text.debugDescription) \(cursor)")
}
do {
  let edit = ListEditing.toggleCodeBlock(in: "a\r\nb", selection: NSRange(location: 0, length: 0))
  let (text, _) = applied("a\r\nb", edit)!
  check("crlf code block", text == "```\r\na\r\n```\r\nb", text.debugDescription)
}

// tab finds the previous sibling and moves nested lines along

do {
  let src = "- a\n  - b\n- c"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: cursorAtEnd(src), by: 1))!
  check("tab after a child list joins it", text == "- a\n  - b\n  - c", text)
}
do {
  let src = "- a\n- b\n  - c"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: 7, by: 1))!  // end of "- b"
  check("tab carries children", text == "- a\n  - b\n    - c", text)
}
do {
  let src = "- a\n  - b\n    - c"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: 9, by: -1))!  // end of "  - b"
  check("shift-tab carries children", text == "- a\n- b\n  - c", text)
}
do {
  let src = "1. a\n2. b\n   1. c\n3. d"
  let (text, _) = applied(src, ListEditing.indent(in: src, cursor: 9, by: 1))!  // end of "2. b"
  check("tab carries numbered children and renumbers", text == "1. a\n   1. b\n      1. c\n2. d", text)
}
check("tab on a first child is nil", ListEditing.indent(in: "- a\n  - b", cursor: 9, by: 1) == nil)
check("tab does not reach across a blank line", ListEditing.indent(in: "- a\n\n- b", cursor: 8, by: 1) == nil)

// typed space

do {
  let (text, cursor) = applied("[] ", ListEditing.afterSpace(in: "[] ", cursor: 3))!
  check("space after [] makes a task", text == "- [ ] " && cursor == 6, "\(text) \(cursor)")
}
do {
  let src = "a\n  [x] "
  let (text, _) = applied(src, ListEditing.afterSpace(in: src, cursor: cursorAtEnd(src)))!
  check("space after indented [x] makes a done task", text == "a\n  - [x] ", text)
}
do {
  let (text, cursor) = applied("``` ", ListEditing.afterSpace(in: "``` ", cursor: 4))!
  check("space after ``` opens a block", text == "```\n\n```" && cursor == 4, "\(text.debugDescription) \(cursor)")
}
check("space after a task marker is a no-op", ListEditing.afterSpace(in: "- [ ] ", cursor: 6) == nil)
check("space mid-line is nil", ListEditing.afterSpace(in: "[] x", cursor: 3) == nil)
check("other characters are nil", ListEditing.afterSpace(in: "[]x", cursor: 3) == nil)

// fences that are already closed

check("``` that opens an existing block is left alone", ListEditing.codeFence(in: "```\ncode\n```", cursor: 3) == nil)
do {
  let src = "```js\n```\nA\n```"  // typed above an existing block
  let (text, _) = applied(src, ListEditing.codeFence(in: src, cursor: 5))!
  check("``` typed above a closed block closes itself", text == "```js\n\n```\n```\nA\n```", text.debugDescription)
}

// code block toggles off from inside

do {
  let src = "x\n```\none\ntwo\n```\ny"
  let edit = ListEditing.toggleCodeBlock(in: src, selection: NSRange(location: 8, length: 0))  // in "one"
  let (text, cursor) = applied(src, edit)!
  check("code block unwraps from a caret inside", text == "x\none\ntwo\ny", text.debugDescription)
  check("unwrap keeps the caret in place", cursor == 4, "\(cursor)")
}
do {
  let src = "```\nopen"
  let (text, _) = applied(src, ListEditing.toggleCodeBlock(in: src, selection: NSRange(location: 5, length: 0)))!
  check("unclosed block loses its fence", text == "open", text)
}

// backspace and links

check("backspace after a non-space is nil", ListEditing.backspace(in: "- a", cursor: 3) == nil)
do {
  let src = "- a\n- "
  let (text, cursor) = applied(src, ListEditing.backspace(in: src, cursor: 6))!
  check("backspace on an empty item clears it", text == "- a\n" && cursor == 4, "\(text.debugDescription) \(cursor)")
}
do {
  let (text, cursor) = applied("ab", ListEditing.link(in: "ab", selection: NSRange(location: 1, length: 0), url: nil))!
  check("⌘L with no selection puts the caret in the brackets", text == "a[]()b" && cursor == 2, "\(text) \(cursor)")
}

// renumbering stays local to the edited run

do {
  let src = "1. one\nplain\n2. two"
  let (text, _) = applied(src, ListEditing.newline(in: src, cursor: 6))!
  check("enter does not renumber a list past a plain line", text == "1. one\n2. \nplain\n2. two", text)
}
do {
  let src = "5. a\n\n1. one"
  let (text, _) = applied(src, ListEditing.newline(in: src, cursor: cursorAtEnd(src)))!
  check("blank-separated earlier list untouched", text == "5. a\n\n1. one\n2. ", text)
}
do {
  let src = "1. one\n2. \n3. three"
  let (text, _) = applied(src, ListEditing.newline(in: src, cursor: 10))!
  check("ending a list restarts the one after it", text == "1. one\n\n1. three", text)
}
do {
  let edit = ListEditing.link(in: "text", selection: NSRange(location: 0, length: 4), url: "https://en.wikipedia.org/wiki/Function_(mathematics)")
  let (text, _) = applied("text", edit)!
  check("parentheses in a pasted url are encoded", text == "[text](https://en.wikipedia.org/wiki/Function_%28mathematics%29)", text)
}


// Quotes: Enter continues, Enter on an empty quote ends it

do {
  let (text, cursor) = applied("| one", ListEditing.quoteNewline(in: "| one", cursor: 5))!
  check("Enter on a quote line continues the quote", text == "| one\n| " && cursor == 8, "\(text.debugDescription) \(cursor)")
  let (mid, midCursor) = applied("| one two", ListEditing.quoteNewline(in: "| one two", cursor: 5))!
  check("Enter mid-quote carries the rest to the next quote line", mid == "| one\n|  two" && midCursor == 8, mid.debugDescription)
  let (ended, endCursor) = applied("| ", ListEditing.quoteNewline(in: "| ", cursor: 2))!
  check("Enter on an empty quote ends it", ended == "" && endCursor == 0, ended.debugDescription)
  let (heading, _) = applied("| # Big", ListEditing.quoteNewline(in: "| # Big", cursor: 7))!
  check("Enter on a quote heading continues as a plain quote line", heading == "| # Big\n| ", heading.debugDescription)
  let (callout, calloutCursor) = applied("!> box", ListEditing.quoteNewline(in: "!> box", cursor: 6))!
  check("Enter on a callout line continues the callout", callout == "!> box\n!> " && calloutCursor == 10, callout.debugDescription)
  let (endedCallout, _) = applied("!> ", ListEditing.quoteNewline(in: "!> ", cursor: 3))!
  check("Enter on an empty callout ends it", endedCallout == "", endedCallout.debugDescription)
  let (asCallout, _) = applied("text", ListEditing.setLinePrefix(in: "text", cursor: 4, prefix: .callout))!
  check("setLinePrefix makes a callout", asCallout == "!> text", asCallout)
  let (fromQuote, _) = applied("| q", ListEditing.setLinePrefix(in: "| q", cursor: 3, prefix: .callout))!
  check("a quote becomes a callout, not a nested quote", fromQuote == "!> q", fromQuote)
  let (cleared, _) = applied("!> q", ListEditing.clearLinePrefix(in: "!> q", cursor: 4))!
  check("clearLinePrefix drops a callout marker whole", cleared == "q", cleared)
  check("Enter off a quote line is not a quote newline", ListEditing.quoteNewline(in: "plain", cursor: 5) == nil)
  check("Enter inside a fence is not a quote newline", ListEditing.quoteNewline(in: "```\n| x\n```", cursor: 7) == nil)
  check("> is a toggle now, not a quote", ListEditing.quoteNewline(in: "> one", cursor: 5) == nil)
  check(">> is no longer a callout", ListEditing.quoteNewline(in: ">> one", cursor: 6) == nil)
}

// Plain text: the block prefix goes

do {
  let (text, cursor) = applied("## Title", ListEditing.clearLinePrefix(in: "## Title", cursor: 8))!
  check("clearLinePrefix drops a heading marker", text == "Title" && cursor == 5, "\(text) \(cursor)")
  let (task, taskCursor) = applied("  - [ ] do", ListEditing.clearLinePrefix(in: "  - [ ] do", cursor: 4))!
  check("clearLinePrefix keeps the indent and puts a caret inside the prefix at the text", task == "  do" && taskCursor == 2, "\(task) \(taskCursor)")
  check("clearLinePrefix is nil on plain text", ListEditing.clearLinePrefix(in: "plain", cursor: 2) == nil)
  let (quote, _) = applied("| q", ListEditing.clearLinePrefix(in: "| q", cursor: 3))!
  check("clearLinePrefix drops a quote marker", quote == "q", quote)
  let (stack, _) = applied("| > # q", ListEditing.clearLinePrefix(in: "| > # q", cursor: 7))!
  check("clearLinePrefix drops a whole marker stack", stack == "q", stack)
}

// Block marker parsing: each marker needs its space

do {
  func kinds(_ line: String) -> [ListEditing.MarkerKind] { ListEditing.blockPrefix(of: line).units.map(\.kind) }
  check("| is a quote", kinds("| q") == [.quote])
  check("> is a toggle", kinds("> t") == [.toggle])
  check("!> is a callout", kinds("!> c") == [.callout])
  check("the canonical stack parses in order", kinds("| > ## x") == [.quote, .toggle, .heading] && ListEditing.blockPrefix(of: "| > ## x").contentStart == 7)
  check("|text is plain", kinds("|text").isEmpty)
  check(">text is plain", kinds(">text").isEmpty)
  check("a bare > is plain", kinds(">").isEmpty)
  check("a bare | is plain", kinds("|").isEmpty)
  check("a bare # is plain", kinds("#").isEmpty)
  check("##### is not a heading", kinds("##### x").isEmpty)
  check("markers out of order stop at the first one out of place", kinds("# > x") == [.heading] && kinds("> | x") == [.toggle])
  check("a callout takes nothing after it", kinds("!> # x") == [.callout])
  check("an indented toggle keeps its indent", ListEditing.blockPrefix(of: "  > c").indent == 2 && kinds("  > c") == [.toggle])
  check("an empty toggle has an empty title", ListEditing.blockPrefix(of: "> ").contentStart == 2)
}

// Stacking: Space after a marker typed at a line's content start

func spaced(_ before: String, _ cursor: Int) -> (String, Int)? {
  // The text as it is once the space is in: `before` with a space at `cursor`.
  let ns = before as NSString
  let text = ns.replacingCharacters(in: NSRange(location: cursor, length: 0), with: " ")
  return applied(text, ListEditing.afterSpace(in: text, cursor: cursor + 1))
}
do {
  // "## " on an H1: the caret was at the content start (2), "##" typed.
  let r = spaced("# ##Title", 4)
  check("## on an H1 makes an H2", r?.0 == "## Title" && r?.1 == 3, "\(String(describing: r))")
  let r2 = spaced("## #Title", 4)
  check("# on an H2 makes an H1", r2?.0 == "# Title" && r2?.1 == 2, "\(String(describing: r2))")
  let toggle = spaced("# >Title", 3)
  check("> on an H1 makes a heading toggle", toggle?.0 == "> # Title" && toggle?.1 == 4, "\(String(describing: toggle))")
  let heading = spaced("> #Title", 3)
  check("# on a toggle is already canonical (no rewrite)", heading == nil, "\(String(describing: heading))")
  let deeper = spaced("> # ##Title", 6)
  check("## on a heading toggle replaces its level", deeper?.0 == "> ## Title" && deeper?.1 == 5, "\(String(describing: deeper))")
  let toggleOnToggle = spaced("> >Title", 3)
  check("> on a toggle just consumes what was typed", toggleOnToggle?.0 == "> Title" && toggleOnToggle?.1 == 2, "\(String(describing: toggleOnToggle))")
  let quoteOnQuote = spaced("| |q", 3)
  check("| on a quote just consumes what was typed", quoteOnQuote?.0 == "| q" && quoteOnQuote?.1 == 2, "\(String(describing: quoteOnQuote))")
  let quoteHeading = spaced("| #q", 3)
  check("# in a quote is already canonical", quoteHeading == nil)
  let quoteToggle = spaced("| # >q", 5)
  check("> on a quote heading goes between them", quoteToggle?.0 == "| > # q" && quoteToggle?.1 == 6, "\(String(describing: quoteToggle))")
  let quoteOverHeading = spaced("# |Title", 3)
  check("| on a heading replaces it with a plain quote", quoteOverHeading?.0 == "| Title" && quoteOverHeading?.1 == 2, "\(String(describing: quoteOverHeading))")
  let quoteOverToggle = spaced("> # |Title", 5)
  check("| on a heading toggle replaces both", quoteOverToggle?.0 == "| Title" && quoteOverToggle?.1 == 2, "\(String(describing: quoteOverToggle))")
  let quoteOnQuoteToggle = spaced("| > |x", 5)
  check("| on a toggle inside a quote is a no-op", quoteOnQuoteToggle?.0 == "| > x", "\(String(describing: quoteOnQuoteToggle))")
  let indented = spaced("  # >x", 5)
  check("an indented line keeps its indent", indented?.0 == "  > # x", "\(String(describing: indented))")
  check("> typed mid-text does nothing", spaced("# Title >", 9) == nil)
  check("> typed after a list marker does nothing", spaced("- >x", 3) == nil)
  check("> typed on a callout does nothing", spaced("!> >x", 4) == nil)
  check("a space before any symbol does nothing", spaced("# x", 2) == nil)
  check("##### is not a heading level", spaced("# #####x", 7) == nil)
  check("plain > then space is left as typed (it already is a toggle)", spaced(">", 1) == nil)
  check("stacking stays out of fences", spaced("```\n# >x\n```", 7) == nil)
  let crlf = spaced("a\r\n# >Title", 6)
  check("stacking on a CRLF line", crlf?.0 == "a\r\n> # Title", "\(String(describing: crlf))")
}

// Backspace peels one marker, innermost first

do {
  func peeled(_ text: String, _ cursor: Int) -> (String, Int)? { applied(text, ListEditing.peelMarker(in: text, cursor: cursor)) }
  let a = peeled("| > # x", 6)
  check("backspace takes the heading first", a?.0 == "| > x" && a?.1 == 4, "\(String(describing: a))")
  let b = peeled("| > x", 4)
  check("then the toggle", b?.0 == "| x" && b?.1 == 2, "\(String(describing: b))")
  let c = peeled("| x", 2)
  check("then the quote", c?.0 == "x" && c?.1 == 0, "\(String(describing: c))")
  check("then nothing (a plain Backspace joins lines)", peeled("a\nx", 2) == nil)
  let d = peeled("!> x", 3)
  check("a callout goes whole", d?.0 == "x", "\(String(describing: d))")
  let e = peeled("a\n# x", 2)
  check("a caret at the line start of a marker line peels too", e?.0 == "a\nx" && e?.1 == 2, "\(String(describing: e))")
  check("backspace inside the text does not peel", peeled("# xy", 3) == nil)
  let f = peeled("> t\n  child", 6)
  check("on a toggle's child it outdents one level", f?.0 == "> t\nchild" && f?.1 == 4, "\(String(describing: f))")
  let g = peeled("> t\n  > u\n    deep", 14)
  check("a nested child outdents to its parent's level", g?.0 == "> t\n  > u\n  deep", "\(String(describing: g))")
  check("indented plain text that is no child is left to Backspace", peeled("a\n  x", 4) == nil)
  check("peeling stays out of fences", peeled("```\n# x\n```", 6) == nil)
}

// Toggles: children, Enter

do {
  let layout = ListEditing.toggleLayout(in: "> t\n  a\n  b\nafter\n> e")
  check("children are the deeper lines after a toggle", layout.toggles.count == 2 && layout.toggles[0].childLines == [4, 8], "\(layout.toggles)")
  check("the children range runs to the next line", layout.toggles[0].children == NSRange(location: 4, length: 8), "\(layout.toggles[0].children)")
  check("a toggle with nothing under it has no children", layout.toggles[1].children.length == 0)
  check("children are one level deep", layout.depth[4] == 1 && layout.depth[12] == nil)
  let nested = ListEditing.toggleLayout(in: "> a\n  > b\n    c\n  d")
  check("nested toggles count depth", nested.depth[10] == 2 && nested.depth[16] == 1 && nested.toggles[1].childLines == [10], "\(nested.depth)")
  let blank = ListEditing.toggleLayout(in: "> a\n\n  b")
  check("an empty line ends a toggle", blank.toggles[0].childLines.isEmpty)
  let fenced = ListEditing.toggleLayout(in: "> a\n  ```\nx\n  ```\nb")
  check("a fenced block opened as a child is a child to its closing fence", fenced.toggles[0].childLines.count == 3, "\(fenced.toggles)")
  check("a > inside a fence is no toggle", ListEditing.toggleLayout(in: "```\n> x\n  y\n```").toggles.isEmpty)

  let open = applied("> Title", ListEditing.toggleNewline(in: "> Title", cursor: 7, collapsed: false))!
  check("Enter on an open toggle opens a first child", open.0 == "> Title\n  " && open.1 == 10, "\(open)")
  let withKids = applied("> T\n  old", ListEditing.toggleNewline(in: "> T\n  old", cursor: 3, collapsed: false))!
  check("the new child goes before the others", withKids.0 == "> T\n  \n  old" && withKids.1 == 6, "\(withKids)")
  let split = applied("> one two", ListEditing.toggleNewline(in: "> one two", cursor: 5, collapsed: false))!
  check("Enter mid-title moves the rest into the child", split.0 == "> one\n  two" && split.1 == 8, "\(split)")
  let atStart = applied("> one", ListEditing.toggleNewline(in: "> one", cursor: 2, collapsed: false))!
  check("Enter at the title's start works as at its end", atStart.0 == "> one\n  ", "\(atStart)")
  let quoted = applied("| > q", ListEditing.toggleNewline(in: "| > q", cursor: 5, collapsed: false))!
  check("a quoted toggle's child stays quoted", quoted.0 == "| > q\n  | ", "\(quoted)")
  let collapsed = applied("> T\n  a\n  b\nnext", ListEditing.toggleNewline(in: "> T\n  a\n  b\nnext", cursor: 3, collapsed: true))!
  check("Enter on a collapsed toggle adds a sibling after its children", collapsed.0 == "> T\n  a\n  b\n> \nnext" && collapsed.1 == 14, "\(collapsed)")
  let collapsedEnd = applied("> # T\n  a", ListEditing.toggleNewline(in: "> # T\n  a", cursor: 5, collapsed: true))!
  check("a collapsed heading toggle's sibling is a heading toggle, at the end of the note too", collapsedEnd.0 == "> # T\n  a\n> # " && collapsedEnd.1 == 14, "\(collapsedEnd)")
  let collapsedSplit = applied("> one two\n  a", ListEditing.toggleNewline(in: "> one two\n  a", cursor: 5, collapsed: true))!
  check("a collapsed split carries the rest to the sibling", collapsedSplit.0 == "> one\n  a\n> two" && collapsedSplit.1 == 12, "\(collapsedSplit)")
  let empty = applied("> ", ListEditing.toggleNewline(in: "> ", cursor: 2, collapsed: false))!
  check("Enter on an empty toggle removes the toggle marker", empty.0 == "" && empty.1 == 0, "\(empty)")
  let emptyHeading = applied("| > # ", ListEditing.toggleNewline(in: "| > # ", cursor: 6, collapsed: false))!
  check("Enter on an empty quoted heading toggle removes only the toggle", emptyHeading.0 == "| # " && emptyHeading.1 == 4, "\(emptyHeading)")
  check("Enter off a toggle is not a toggle newline", ListEditing.toggleNewline(in: "x", cursor: 1, collapsed: false) == nil)

  let child = applied("> T\n  a", ListEditing.childNewline(in: "> T\n  a", cursor: 7))!
  check("Enter on a child continues at its indent", child.0 == "> T\n  a\n  " && child.1 == 10, "\(child)")
  let out = applied("> T\n  a\n  ", ListEditing.childNewline(in: "> T\n  a\n  ", cursor: 10))!
  check("Enter on an empty child steps out of the toggle", out.0 == "> T\n  a\n" && out.1 == 8, "\(out)")
  check("Enter on indented text outside a toggle is plain", ListEditing.childNewline(in: "x\n  a", cursor: 5) == nil)
  check("a list item inside a toggle goes to the list rules", ListEditing.childNewline(in: "> T\n  - a", cursor: 9) == nil)
  let listed = applied("> T\n  - a", ListEditing.newline(in: "> T\n  - a", cursor: 9))!
  check("and the list continues at its indent", listed.0 == "> T\n  - a\n  - ", "\(listed)")
}

// Joining across a collapsed toggle

do {
  let joined = applied("> T\n  a\nnext\nz", ListEditing.joinLine(in: "> T\n  a\nnext\nz", lineStart: 8, onto: 3))!
  check("the line after a collapsed toggle joins its title", joined.0 == "> Tnext\n  a\nz" && joined.1 == 3, "\(joined)")
  let heading = applied("> T\n  a\n# Head\nz", ListEditing.joinLine(in: "> T\n  a\n# Head\nz", lineStart: 8, onto: 3))!
  check("a joined heading line leaves its markers behind, not on the title", heading.0 == "> THead\n  a\nz", "\(heading)")
  let stacked = applied("> T\n  a\n| > # Deep", ListEditing.joinLine(in: "> T\n  a\n| > # Deep", lineStart: 8, onto: 3))!
  check("a joined marker stack goes whole", stacked.0 == "> TDeep\n  a", "\(stacked)")
  let listed = applied("> T\n  a\n- item", ListEditing.joinLine(in: "> T\n  a\n- item", lineStart: 8, onto: 3))!
  check("a joined list item drops its marker too", listed.0 == "> Titem\n  a", "\(listed)")
}

// Deleting a range keeps markers whole

do {
  func deleted(_ text: String, _ location: Int, _ length: Int, folded: [NSRange] = []) -> String {
    let range = ListEditing.deletionRange(in: text, range: NSRange(location: location, length: length), folded: folded)
    return (text as NSString).replacingCharacters(in: range, with: "")
  }
  check("joining onto a heading line drops its markers", deleted("ab\n# T", 2, 1) == "abT", deleted("ab\n# T", 2, 1))
  check("a deletion ending inside markers takes them", deleted("ab\n| > T", 1, 4) == "aT", deleted("ab\n| > T", 1, 4))
  check("a deletion across two markers takes both whole", deleted("| > T", 1, 2) == "T", deleted("| > T", 1, 2))
  check("a deletion starting inside a marker takes it whole", deleted("| > T", 1, 1) == "> T", deleted("| > T", 1, 1))
  check("a deletion ending inside a marker on the same line takes that marker", deleted("| > # T", 2, 1) == "| # T", deleted("| > # T", 2, 1))
  check("a whole line from its start leaves the next line's markers", deleted("x\n# T", 0, 2) == "# T", deleted("x\n# T", 0, 2))
  check("deleting from a quote's text start into a heading drops the heading", deleted("| q\n# T", 2, 2) == "| T", deleted("| q\n# T", 2, 2))
  check("joining onto a toggle child drops its indent", deleted("> a\n  b", 3, 1) == "> ab", deleted("> a\n  b", 3, 1))
  check("plain indented lines keep their spaces", deleted("a\n  b", 1, 1) == "a  b", deleted("a\n  b", 1, 1))
  check("a deletion inside text is untouched", deleted("# Title", 3, 2) == "# Tle")
  check("a range reaching into folded children takes all of them", deleted("> T\n  a\n  b\nz", 2, 4, folded: [NSRange(location: 4, length: 8)]) == "> z", deleted("> T\n  a\n  b\nz", 2, 4, folded: [NSRange(location: 4, length: 8)]))
}

// Line prefixes stack like typing

do {
  func set(_ text: String, _ prefix: ListEditing.LinePrefix) -> String { applied(text, ListEditing.setLinePrefix(in: text, cursor: (text as NSString).length, prefix: prefix))!.0 }
  check("toggle on a heading adds to it", set("# T", .toggle) == "> # T", set("# T", .toggle))
  check("toggle on a toggle removes it", set("> # T", .toggle) == "# T", set("> # T", .toggle))
  check("heading on a toggle adds to it", set("> T", .heading(2)) == "> ## T", set("> T", .heading(2)))
  check("the same heading removes it, keeping the toggle", set("> ## T", .heading(2)) == "> T", set("> ## T", .heading(2)))
  check("quote on a heading toggle replaces both", set("> # T", .quote) == "| T", set("> # T", .quote))
  check("quote on a quote stack removes only the quote", set("| > T", .quote) == "> T", set("| > T", .quote))
  check("a bullet replaces the whole stack", set("| > T", .bullet) == "- T", set("| > T", .bullet))
  check("a toggle replaces a list marker", set("- T", .toggle) == "> T", set("- T", .toggle))
  check("a heading keeps the indent", set("  > T", .heading(1)) == "  > # T", set("  > T", .heading(1)))
}

// Typed arrows and typography

do {
  func arrow(_ text: String) -> String? { applied(text, ListEditing.typography(in: text, cursor: (text as NSString).length))?.0 }
  let edit = ListEditing.typography(in: "a->", cursor: 3)
  check("-> becomes an arrow", arrow("a->") == "a\u{2192}", arrow("a->") ?? "nil")
  check("the caret lands after the arrow", edit?.cursor == 2 && edit?.range == NSRange(location: 1, length: 2), "\(String(describing: edit))")
  check("=> becomes a double arrow", arrow("a=>") == "a\u{21D2}", arrow("a=>") ?? "nil")
  check("-> at a line start converts", arrow("x\n->") == "x\n\u{2192}", arrow("x\n->") ?? "nil")
  check("--> at a line start keeps the first dash (its -- stayed literal)", arrow("-->") == "-\u{2192}", arrow("-->") ?? "nil")
  check("–> (a --> mid-line) becomes an arrow", arrow("a\u{2013}>") == "a\u{2192}", arrow("a\u{2013}>") ?? "nil")
  check("==> keeps the first equals", arrow("==>") == "=\u{21D2}", arrow("==>") ?? "nil")
  check("a lone > is nil", arrow(">") == nil)
  check("> after other text is nil", arrow("a>") == nil)
  check("> after a bullet's space is nil", arrow("- >") == nil)
  check("the caret must follow the >", ListEditing.typography(in: "a->b", cursor: 4) == nil)
  check("no arrow in a code span being typed", arrow("`a->") == nil)
  check("no arrow inside a closed code span", ListEditing.typography(in: "`a->b`", cursor: 4) == nil)
  check("an arrow after a closed code span", arrow("`x` a->") == "`x` a\u{2192}", arrow("`x` a->") ?? "nil")
  check("no arrow in a fenced block", ListEditing.typography(in: "```\na->\n```", cursor: 7) == nil)
  check("no arrow on a fence line", arrow("```->") == nil)
  check("no arrow on a tilde fence line being typed", arrow("~~~->") == nil && arrow("~~~py ->") == nil)
  check("no arrow on an indented fence line", arrow("   ```x=>") == nil)
  check("an arrow after two tildes (strike, not a fence)", arrow("~~a->") == "~~a\u{2192}", arrow("~~a->") ?? "nil")
  check("an arrow after a fenced block", arrow("```\nx\n```\na->") == "```\nx\n```\na\u{2192}", arrow("```\nx\n```\na->") ?? "nil")
  check("no arrow in a link address being typed", arrow("[a](http://x->") == nil)
  check("no arrow at the start of a link address", arrow("[a](->") == nil)
  check("no arrow inside a closed link address", ListEditing.typography(in: "[a](x->y)", cursor: 7) == nil)
  check("no arrow in a bare URL", arrow("see https://x.com/a->") == nil)
  check("no arrow in an upper-case URL", arrow("see HTTPS://x.com/a->") == nil && arrow("see Http://x.com/a=>") == nil)
  check("an arrow right after a URL in parentheses", arrow("(https://example.com)->") == "(https://example.com)\u{2192}", arrow("(https://example.com)->") ?? "nil")
  check("an arrow right after a URL in brackets", arrow("[https://x.com]=>") == "[https://x.com]\u{21D2}", arrow("[https://x.com]=>") ?? "nil")
  check("an arrow after a link", arrow("[a](u) b->") == "[a](u) b\u{2192}", arrow("[a](u) b->") ?? "nil")
  check("an arrow in link text", arrow("[a->") == "[a\u{2192}", arrow("[a->") ?? "nil")
}

do {
  func typo(_ text: String) -> String? { applied(text, ListEditing.typography(in: text, cursor: (text as NSString).length))?.0 }
  check("<- becomes a left arrow", typo("a<-") == "a\u{2190}", typo("a<-") ?? "nil")
  check("-- becomes an en dash", typo("a--") == "a\u{2013}", typo("a--") ?? "nil")
  check("-- at a line start stays literal, for a divider", typo("--") == nil && typo("x\n--") == nil)
  check("-- after only an indent stays literal", typo("  --") == nil)
  check("--- and ---- at a line start stay literal", typo("---") == nil && typo("----") == nil && typo("  ---") == nil)
  check("-- after a bullet becomes an en dash", typo("- --") == "- \u{2013}", typo("- --") ?? "nil")
  check(">= becomes ≥", typo("a>=") == "a\u{2265}", typo("a>=") ?? "nil")
  check("<= becomes ≤", typo("a<=") == "a\u{2264}", typo("a<=") ?? "nil")
  check(">= at a line start becomes ≥", typo(">=") == "\u{2265}", typo(">=") ?? "nil")
  check("a toggle's > then = is not a pair", typo("> =") == nil)
  check("... becomes an ellipsis", typo("a...") == "a\u{2026}", typo("a...") ?? "nil")
  check("the caret lands after the ellipsis", ListEditing.typography(in: "a...", cursor: 4)?.cursor == 2)
  check(".. alone is nil", typo("a..") == nil)
  check(".... gives ….", typo("a\u{2026}.") == nil)
  check("<-> becomes ↔", typo("a\u{2190}>") == "a\u{2194}", typo("a\u{2190}>") ?? "nil")
  check("<=> becomes ⇔", typo("a\u{2264}>") == "a\u{21D4}", typo("a\u{2264}>") ?? "nil")
  check("<--> becomes ↔", typo("a\u{2190}->") == "a\u{2194}", typo("a\u{2190}->") ?? "nil")
  check("<-- gives ←-", typo("a\u{2190}-") == nil)
  check("--- mid-line gives –-", typo("a\u{2013}-") == nil)
  check("no typography in a code span", typo("`a--") == nil && typo("`a...") == nil && typo("`a<=") == nil)
  check("no typography in a link address", typo("[a](x--") == nil && typo("see http://x/a...") == nil)
  check("no typography in a fenced block", ListEditing.typography(in: "```\na...\n```", cursor: 8) == nil)
  for (pair, symbol) in [("->", "\u{2192}"), ("=>", "\u{21D2}"), ("<-", "\u{2190}"), ("--", "\u{2013}"), (">=", "\u{2265}"), ("<=", "\u{2264}"), ("...", "\u{2026}")] {
    let n = (pair as NSString).length
    check("\(pair) stays literal in a double-backtick span being typed", typo("``a " + pair) == nil && typo("``" + pair) == nil)
    check("\(pair) stays literal inside a closed double-backtick span",
      ListEditing.typography(in: "``a" + pair + "b``", cursor: 3 + n) == nil && ListEditing.typography(in: "`a" + pair + "b`", cursor: 2 + n) == nil)
    check("\(pair) converts in prose after closed spans",
      typo("``x`` a" + pair) == "``x`` a" + symbol && typo("`x` and `y` a" + pair) == "`x` and `y` a" + symbol, typo("``x`` a" + pair) ?? "nil")
    check("\(pair) right after a URL in parentheses", typo("(https://example.com)" + pair) == "(https://example.com)" + symbol, typo("(https://example.com)" + pair) ?? "nil")
    check("\(pair) stays literal in a bare URL", typo("see https://x.com/a" + pair) == nil)
    check("\(pair) stays literal on a tilde fence line", typo("~~~" + pair) == nil && typo("~~~py " + pair) == nil)
    check("\(pair) stays literal on a backtick fence line", typo("```" + pair) == nil && typo("   ```x " + pair) == nil)
  }
}

// Dividers: removed whole, never left as raw dashes

do {
  func back(_ text: String, _ cursor: Int) -> (String, Int)? { applied(text, ListEditing.dividerBackspace(in: text, cursor: cursor)) }
  func del(_ text: String, _ cursor: Int) -> (String, Int)? { applied(text, ListEditing.dividerDelete(in: text, cursor: cursor)) }
  let t = "a\n---\nb"
  check("backspace on a divider empties its line", back(t, 5).map { $0 == ("a\n\nb", 2) } == true, "\(String(describing: back(t, 5)))")
  check("backspace after a divider removes its line", back(t, 6).map { $0 == ("a\nb", 2) } == true, "\(String(describing: back(t, 6)))")
  check("backspace on *** and ___ dividers", back("***", 3)?.0 == "" && back("x\n___  ", 7)?.0 == "x\n")
  check("backspace on plain lines is nil", back("a\nb", 2) == nil && back("a\n--", 4) == nil)
  check("a --- in a code block is not a divider", back("```\n---\n```", 7) == nil && back("```\n---\nx\n```", 8) == nil)
  let info = "``` hello world\n---\n```"
  check("a --- under a multi-word info string is code", back(info, 19) == nil && back(info + "\nb", 24) == nil && del(info, 16) == nil, "\(String(describing: back(info, 19)))")
  check("joining onto a --- in code is a plain join", ListEditing.deletionRange(in: "``` a b\nx\n---\n```", range: NSRange(location: 9, length: 1)) == NSRange(location: 9, length: 1))
  check("no typography in a block with a multi-word info string", ListEditing.typography(in: "``` hello world\na->\n```", cursor: 19) == nil)
  check("delete on a divider empties its line", del(t, 5).map { $0 == ("a\n\nb", 2) } == true, "\(String(describing: del(t, 5)))")
  check("delete off a divider is nil", del(t, 1) == nil)
  check("joining onto a divider takes it whole", ListEditing.deletionRange(in: t, range: NSRange(location: 1, length: 1)) == NSRange(location: 1, length: 4))
  check("a selection ending in the dashes takes them all", ListEditing.deletionRange(in: t, range: NSRange(location: 0, length: 3)) == NSRange(location: 0, length: 5))
  check("a selection starting in the dashes starts at the line", ListEditing.deletionRange(in: t, range: NSRange(location: 3, length: 4)) == NSRange(location: 2, length: 5))
}

// Date keywords: "@today" and friends become the ISO date on a terminator

do {
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(identifier: "Asia/Singapore")!
  // 2026-10-05 23:30 in Singapore (15:30 UTC): still the 5th locally.
  let now = Date(timeIntervalSince1970: 1_791_214_200)
  func typed(_ text: String) -> String? {
    applied(text, Dates.afterTerminator(in: text, cursor: (text as NSString).length, now: now, calendar: utc))?.0
  }
  func cursor(_ text: String) -> Int? {
    Dates.afterTerminator(in: text, cursor: (text as NSString).length, now: now, calendar: utc)?.cursor
  }
  check("the clock fixture is the 5th in Singapore", Dates.iso(now, calendar: utc) == "2026-10-05", Dates.iso(now, calendar: utc))
  check("@today then space", typed("@today ") == "2026-10-05 ", typed("@today ") ?? "nil")
  check("@tomorrow then space", typed("@tomorrow ") == "2026-10-06 ", typed("@tomorrow ") ?? "nil")
  check("@yesterday then space", typed("@yesterday ") == "2026-10-04 ", typed("@yesterday ") ?? "nil")
  check("the cursor stays after the terminator", cursor("due @today ") == 15, "\(cursor("due @today ") ?? -1)")
  check("@tomorrow crosses a month end", applied("@tomorrow ", Dates.afterTerminator(
    in: "@tomorrow ", cursor: 10, now: Date(timeIntervalSince1970: 1_793_455_200), calendar: utc))?.0 == "2026-11-01 ")
  check("@yesterday crosses a year start", applied("@yesterday ", Dates.afterTerminator(
    in: "@yesterday ", cursor: 11, now: Date(timeIntervalSince1970: 1_798_732_800), calendar: utc))?.0 == "2026-12-31 ")
  check("any case: @Today", typed("@Today ") == "2026-10-05 ", typed("@Today ") ?? "nil")
  check("any case: @TOMORROW", typed("@TOMORROW ") == "2026-10-06 ", typed("@TOMORROW ") ?? "nil")
  for terminator in ["\t", "\n", ".", ",", ";", ":", "!", "?", ")", "]", "\"", "*", "~", "…"] {
    let text = "ship @today" + terminator
    check("terminator \(terminator.debugDescription)", typed(text) == "ship 2026-10-05" + terminator, typed(text) ?? "nil")
  }
  for other in ["s", "_", "'", "-", "/", "1", "@", "("] {
    check("no terminator \(other.debugDescription)", typed("@today" + other) == nil, typed("@today" + other) ?? "nil")
  }
  check("in the middle of a line", typed("call @today") == nil)
  check("in the middle, then a space", applied("a @today b", Dates.afterTerminator(in: "a @today b", cursor: 9, now: now, calendar: utc))?.0 == "a 2026-10-05 b")
  check("after an opening bracket", typed("(@today)") == "(2026-10-05)", typed("(@today)") ?? "nil")
  check("inside bold", typed("**@today*") == "**2026-10-05*", typed("**@today*") ?? "nil")
  check("in a task", typed("- [ ] pay @tomorrow ") == "- [ ] pay 2026-10-06 ")
  check("in a heading", typed("# @today ") == "# 2026-10-05 ")
  check("not part of an email", typed("kai@today.") == nil && typed("kai@today ") == nil)
  check("not after a word and an opener", typed("a(@today)") == nil && typed("x_@today ") == nil)
  check("not a longer word", typed("@todays ") == nil && typed("@xtoday ") == nil && typed("@yesterdays ") == nil)
  check("not a bare @", typed("@ ") == nil && typed("today ") == nil)
  check("not inside a code span being typed", typed("`@today ") == nil)
  check("not inside a closed code span", applied("`a @today b`", Dates.afterTerminator(in: "`a @today b`", cursor: 10, now: now, calendar: utc)) == nil)
  check("after a closed code span", typed("`x` @today ") == "`x` 2026-10-05 ")
  check("not inside a double-backtick span being typed", typed("``@today ") == nil && typed("``a @today ") == nil)
  check("after a closed double-backtick span", typed("``x`` @today ") == "``x`` 2026-10-05 ", typed("``x`` @today ") ?? "nil")
  check("not inside a closed double-backtick span", Dates.afterTerminator(in: "``a @today b``", cursor: 11, now: now, calendar: utc) == nil)
  check("after two closed spans", typed("`x` and `y` @today ") == "`x` and `y` 2026-10-05 ")
  check("not in a link address", typed("[a](@today)") == nil)
  check("in link text", typed("[@today]") == "[2026-10-05]")
  check("not in a URL", typed("https://x.com/@today ") == nil)
  check("an unclosed fence is plain text, so it converts", typed("```\n@today ") == "```\n2026-10-05 ")
  let fenced = "```\n@today \n```"
  check("not inside a closed fence", Dates.afterTerminator(in: fenced, cursor: 11, now: now, calendar: utc) == nil)
  let after = "```\nx\n```\n@today "
  check("after a closed fence", typed(after) == "```\nx\n```\n2026-10-05 ", typed(after) ?? "nil")
  check("keyword(endingAt:) finds it before the caret", Dates.keyword(endingAt: 6, in: "@today", now: now, calendar: utc)?.replacement == "2026-10-05")
}

// Date chips: standalone ISO dates in prose

do {
  func chips(_ text: String, excluding: [NSRange] = []) -> [String] {
    Dates.chipRanges(in: text, excluding: excluding).map { (text as NSString).substring(with: $0) }
  }
  check("a date alone", chips("2026-10-05") == ["2026-10-05"])
  check("dates in prose", chips("from 2026-10-05 to 2026-10-07.") == ["2026-10-05", "2026-10-07"], "\(chips("from 2026-10-05 to 2026-10-07."))")
  check("in brackets and bold", chips("(2026-10-05) **2026-10-06** _2026-10-07_") == ["2026-10-05", "2026-10-06", "2026-10-07"])
  check("before a colon", chips("2026-10-05: standup") == ["2026-10-05"])
  check("in a task", chips("- [ ] pay 2026-10-06") == ["2026-10-06"])
  check("not a generated filename", chips("2026-10-05 1008 - x.md").isEmpty, "\(chips("2026-10-05 1008 - x.md"))")
  check("not a wiki-linked filename", chips("[[2026-10-05 1008 - x]]").isEmpty)
  check("not a timestamp", chips("2026-10-05 9:30 call").isEmpty && chips("2026-10-05T09:30").isEmpty)
  check("not a file extension", chips("2026-10-05.md").isEmpty)
  check("not glued to a word", chips("x-2026-10-05 2026-10-05x note_2026-10-05").isEmpty)
  check("not in a path", chips("/notes/2026-10-05/ a/2026-10-05").isEmpty)
  check("not a longer number", chips("12026-10-05 2026-10-055").isEmpty)
  check("not an impossible date", chips("2026-02-30 2026-13-01 2026-00-10 2026-10-00").isEmpty)
  check("a leap day", chips("2028-02-29") == ["2028-02-29"] && chips("2026-02-29").isEmpty)
  check("not in inline code", chips("`2026-10-05` and 2026-10-06") == ["2026-10-06"])
  check("not in a link address", chips("[due](https://x.com/2026-10-05) [2026-10-06](x)") == ["2026-10-06"], "\(chips("[due](https://x.com/2026-10-05) [2026-10-06](x)"))")
  check("not in a bare URL", chips("https://x.com/?d=2026-10-05 https://x.com/ 2026-10-06") == ["2026-10-06"])
  let big = String(repeating: "- [ ] task due 2026-10-05, see `2026-10-06` and [x](https://x.com/2026-10-07) and 3-4-5\n", count: 4000)
  let started = Date()
  let found = Dates.chipRanges(in: big, excluding: (0..<200).map { NSRange(location: $0 * 1000, length: 10) })
  let elapsed = Date().timeIntervalSince(started)
  check("chips in a 4000-line note take well under a second", elapsed < 0.5 && found.count >= 3900, "\(elapsed)s \(found.count)")
  check("no dates, no work", Dates.chipRanges(in: String(repeating: "plain words 12 and 3-4\n", count: 100)).isEmpty)
  let fenced = "```\n2026-10-05\n```\n2026-10-06"
  check("not in excluded (fenced) ranges", chips(fenced, excluding: [NSRange(location: 0, length: 18)]) == ["2026-10-06"])
}

// Emoji picker trigger and the :name: shortcut

do {
  func trigger(_ text: String) -> Int? { ListEditing.emojiTrigger(in: text, cursor: (text as NSString).length) }
  check(":cl at a line start opens at the colon", trigger(":cl") == 0, "\(String(describing: trigger(":cl")))")
  check("after a space", trigger("hi :cla") == 3)
  check("after punctuation", trigger("(:cl") == 1 && trigger("**:cl") == 2)
  check("on a later line", trigger("a\n:cl") == 2)
  check("a list item's text counts as after whitespace", trigger("- :cl") == 2)
  check("one letter is not enough", trigger(":c") == nil)
  check("a bare colon is not enough", trigger("hi :") == nil)
  check("the query starts with a letter and holds two", trigger(":3a") == nil && trigger(":a1") == nil && trigger(":-)") == nil && trigger(":a1b") == 0)
  check("digits and +-_ may follow", trigger(":t-r") == 0 && trigger(":heart_ey") == 0)
  check("not after a digit (a time)", trigger("10:30") == nil && trigger("at 10:ab") == nil)
  check("not after a letter (mailto:, key:value)", trigger("mailto:ab") == nil && trigger("key:value") == nil)
  check("not after another colon (std::string)", trigger("std::string") == nil && trigger("::ab") == nil)
  check("not after a slash", trigger("/:ab") == nil)
  check("not inside an inline code span, closed or still open", trigger("`x :ab") == nil && trigger("a `x` :ab") == 6)
  check("not inside a double-backtick span", trigger("``x :ab") == nil)
  let fenced = "```\n:ab\n```"
  check("not in a fenced block (caret after the query)", ListEditing.emojiTrigger(in: fenced, cursor: 7) == nil)
  check("not in a link address", trigger("[x](:ab") == nil && trigger("[x](http://a.com/?q=:ab") == nil)
  check("but after a finished link", trigger("[x](y) :ab") == 7)
  check("not inside a bare URL", trigger("see https://a.com/x=:ab") == nil)
  check("not with the caret mid-word", ListEditing.emojiTrigger(in: ":abc", cursor: 3) == nil)
  check("the caret at the end of the word with text after", ListEditing.emojiTrigger(in: ":ab rest", cursor: 3) == 0)
  check("not after an accented letter", trigger("café:ab") == nil)
  check("after an emoji", trigger("👍:ab") == 2)
  check("emoji query rules", ListEditing.isEmojiQuery("cl") && !ListEditing.isEmojiQuery("c") && !ListEditing.isEmojiQuery("cl ap") && !ListEditing.isEmojiQuery("cl:"))

  let names = ["clap": "👏", "+1": "👍", "tada": "🎉"]
  func lookup(_ name: String) -> String? { names[name.lowercased()] }
  func short(_ text: String) -> (String, Int)? {
    applied(text, ListEditing.emojiShortcode(in: text, cursor: (text as NSString).length, lookup: lookup))
  }
  check(":clap: becomes the emoji", short("great :clap:")?.0 == "great 👏" && short("great :clap:")?.1 == 8, "\(String(describing: short("great :clap:")))")
  check("at a line start", short(":tada:")?.0 == "🎉")
  check("names with + work", short(":+1:")?.0 == "👍")
  check("any case", short(":CLAP:")?.0 == "👏")
  check("an unknown name stays", short(":clapp:") == nil)
  check("an empty name stays", short("::") == nil && short("a ::") == nil)
  check("not after a digit", short("10:clap:") == nil)
  check("not in code", short("`:clap:") == nil)
  check("not in a link address", short("[x](:clap:") == nil)
  check("one after another", short("👏:tada:")?.0 == "👏🎉")
}

// Note link trigger and the link a pick inserts

do {
  func trigger(_ text: String) -> Int? { ListEditing.noteLinkTrigger(in: text, cursor: (text as NSString).length) }
  check("[[ opens at the first bracket", trigger("[[") == 0)
  check("after text, with a query", trigger("see [[Proj") == 4)
  check("the query may hold spaces", trigger("[[my big note") == 0)
  check("a closing bracket ends it", trigger("[[a]") == nil && trigger("[[a]] b") == nil)
  check("a third bracket is not a trigger", trigger("[[[") == nil)
  check("one bracket is not enough", trigger("x [") == nil)
  check("only on the caret's line", trigger("[[a\nb") == nil && trigger("a\n[[b") == 2)
  check("not in a code span", trigger("`[[") == nil)
  check("not in a link address", trigger("[x](a[[") == nil)
  check("not in a fenced block", ListEditing.noteLinkTrigger(in: "```\n[[\n```", cursor: 6) == nil)
  check("the latest [[ on the line wins", trigger("[[a]] and [[b") == 10)
  check("a [ after [ does not start a new one", !ListEditing.noteLinkCanStart(in: "[", at: 1) && ListEditing.noteLinkCanStart(in: "a ", at: 2))

  check("a note link encodes spaces", ListEditing.noteLink(title: "My Note", target: "2026-10-05 1200 - my-note.md") == "[My Note](2026-10-05%201200%20-%20my-note.md)",
    ListEditing.noteLink(title: "My Note", target: "2026-10-05 1200 - my-note.md"))
  check("brackets leave the title", ListEditing.noteLink(title: "[draft] plan", target: "plan.md") == "[draft plan](plan.md)")
  check("an empty title reads Untitled", ListEditing.noteLink(title: "  ", target: "a.md") == "[Untitled](a.md)")
  check("parentheses and colons in the name are encoded", ListEditing.noteLink(title: "T", target: "a (1): b.md") == "[T](a%20%281%29%3A%20b.md)",
    ListEditing.noteLink(title: "T", target: "a (1): b.md"))
  check("a full path keeps its slashes", ListEditing.noteLink(title: "T", target: "/Users/k/My Notes/a.md") == "[T](/Users/k/My%20Notes/a.md)")
  check("accents are percent-encoded", ListEditing.noteLink(title: "Café", target: "café.md") == "[Café](caf%C3%A9.md)")
}

// Note filenames with stable ids (mirrored by test/lib.test.ts over the same fixture)

do {
  struct Case: Decodable {
    struct Parsed: Decodable, Equatable { let stamp: String; let id: String?; let slug: String }
    let name: String
    let parsed: Parsed?
    let title: String
  }
  let cases = try! JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: "test/note-names.json")))
  for c in cases {
    let got = NoteNames.parse(c.name).map { Case.Parsed(stamp: $0.stamp, id: $0.id, slug: $0.slug) }
    check("parses \(c.name)", got == c.parsed, "\(String(describing: got))")
    check("an empty note named \(c.name) is titled \(c.title)", title(of: "# \n", filename: c.name) == c.title, title(of: "# \n", filename: c.name))
  }
  check("the empty-note title never shows the date, time or id", !title(of: "", filename: "2026-10-05 1200 ab12 - untitled.md").contains("ab12")
    && !title(of: "", filename: "2026-10-05 1200 ab12 - untitled.md").contains("2026"))
  check("a filename is stamp, id, slug", NoteNames.filename(stamp: "2026-10-05 1200", id: "ab12", slug: "x") == "2026-10-05 1200 ab12 - x.md")
  let id = NoteNames.randomID()
  check("an id is four lowercase base36 characters", id.range(of: #"^[0-9a-z]{4}$"#, options: .regularExpression) != nil, id)
  var draws = ["ab12", "ab12", "cd34"].makeIterator()
  check("a clashing id is drawn again", NoteNames.newID(avoiding: ["ab12"], random: { draws.next()! }) == "cd34")
  check("the ids of a folder", NoteNames.ids(in: ["2026-10-05 1200 ab12 - x.md", "2026-10-05 1200 - y.md", "z.md"]) == ["ab12"])

  check("a rename keeps the id and follows the title", NoteNames.renamed("2026-10-05 1200 ab12 - old.md", title: "New Title", newID: { "zzzz" }) == "2026-10-05 1200 ab12 - new-title.md")
  check("no rename when the slug already matches", NoteNames.renamed("2026-10-05 1200 ab12 - new-title.md", title: "New title", newID: { "zzzz" }) == nil)
  check("a name from before ids gets one when renamed", NoteNames.renamed("2026-10-05 1200 - old.md", title: "Old", newID: { "zzzz" }) == "2026-10-05 1200 zzzz - old.md")
  check("daily and hand-named notes are never renamed", NoteNames.renamed("2026-10-05.md", title: "X", newID: { "zzzz" }) == nil
    && NoteNames.renamed("groceries.md", title: "X", newID: { "zzzz" }) == nil)

  var ids = ["ab12", "ab12", "cd34", "ef56"].makeIterator()
  let folder = ["2026-10-05 1200 - a.md", "2026-10-05 1201 ab12 - b.md", "2026-10-05.md", "groceries.md", "2026-10-05 1202 - c.md"]
  let plan = NoteNames.migration(of: folder, random: { ids.next()! })
  check("migration gives each name from before ids a fresh, unique id", plan.map(\.from) == ["2026-10-05 1200 - a.md", "2026-10-05 1202 - c.md"]
    && plan.map(\.to) == ["2026-10-05 1200 cd34 - a.md", "2026-10-05 1202 ef56 - c.md"], "\(plan)")
  let migrated = folder.map { name in plan.first { $0.from == name }?.to ?? name }
  check("migration run again finds nothing", NoteNames.migration(of: migrated).isEmpty)
  check("migration leaves daily and hand-named notes alone", migrated.contains("2026-10-05.md") && migrated.contains("groceries.md"))

  check("a stale link finds the note with its id", NoteLinks.noteWithSameID(as: "2026-10-05 1200 ab12 - old.md", among: ["2026-10-05 1200 ab12 - new.md", "x.md"]) == "2026-10-05 1200 ab12 - new.md")
  check("not without an id in the link", NoteLinks.noteWithSameID(as: "2026-10-05 1200 - old.md", among: ["2026-10-05 1200 ab12 - old.md"]) == nil)
  check("not when no note or two carry it", NoteLinks.noteWithSameID(as: "2026-10-05 1200 ab12 - old.md", among: ["2026-10-05 1200 cd34 - x.md"]) == nil
    && NoteLinks.noteWithSameID(as: "2026-10-05 1200 ab12 - old.md", among: ["2026-10-05 1200 ab12 - a.md", "2026-10-05 1200 ab12 - b.md"]) == nil)

  let old = "/n/2026-10-05 1200 ab12 - old.md"
  let new = "/n/2026-10-05 1200 ab12 - new-title.md"
  let moves = [old: new]
  func rewrite(_ text: String, in dir: String = "/n") -> String? { NoteNames.rewriteLinks(in: text, directory: dir, moves: moves) }
  check("a picker link follows the rename", rewrite("See [Old](2026-10-05%201200%20ab12%20-%20old.md).") == "See [Old](2026-10-05%201200%20ab12%20-%20new-title.md).", rewrite("See [Old](2026-10-05%201200%20ab12%20-%20old.md).") ?? "nil")
  check("other encodings of the same name follow too", rewrite("[a](./2026-10-05%201200%20ab12%20-%20old.md) [b](2026-10-05%201200%20ab12%20%2D%20old.md)")
    == "[a](2026-10-05%201200%20ab12%20-%20new-title.md) [b](2026-10-05%201200%20ab12%20-%20new-title.md)", rewrite("[a](./2026-10-05%201200%20ab12%20-%20old.md) [b](2026-10-05%201200%20ab12%20%2D%20old.md)") ?? "nil")
  check("from a subfolder note, ../ stays relative", rewrite("[x](../2026-10-05%201200%20ab12%20-%20old.md)", in: "/n/sub") == "[x](../2026-10-05%201200%20ab12%20-%20new-title.md)")
  check("an absolute link stays absolute; a fragment is kept", rewrite("[x](/n/2026-10-05%201200%20ab12%20-%20old.md#top)") == "[x](/n/2026-10-05%201200%20ab12%20-%20new-title.md#top)")
  check("a file: link stays a file: link", rewrite("[x](file:///n/2026-10-05%201200%20ab12%20-%20old.md)") == "[x](file:///n/2026-10-05%201200%20ab12%20-%20new-title.md)")
  check("link text naming the old file is untouched", rewrite("[2026-10-05%201200%20ab12%20-%20old.md](2026-10-05%201200%20ab12%20-%20old.md)") == "[2026-10-05%201200%20ab12%20-%20old.md](2026-10-05%201200%20ab12%20-%20new-title.md)")
  check("the name outside a link is untouched", rewrite("old file: 2026-10-05%201200%20ab12%20-%20old.md and (2026-10-05 1200 ab12 - old.md)") == nil)
  check("links in code are untouched", rewrite("`[x](2026-10-05%201200%20ab12%20-%20old.md)`") == nil
    && rewrite("```\n[x](2026-10-05%201200%20ab12%20-%20old.md)\n```") == nil)
  check("links to other notes and the web are untouched", rewrite("[a](other.md) [b](https://x.com/2026-10-05%201200%20ab12%20-%20old.md) [c](sub/2026-10-05%201200%20ab12%20-%20old.md)") == nil)
  check("a link from another folder to the same name is not this note", rewrite("[x](2026-10-05%201200%20ab12%20-%20old.md)", in: "/m") == nil)
  check("legacy names migrate with their links", NoteNames.rewriteLinks(in: "[a](2026-10-05%201200%20-%20a.md)", directory: "/n", moves: ["/n/2026-10-05 1200 - a.md": "/n/2026-10-05 1200 cd34 - a.md"])
    == "[a](2026-10-05%201200%20cd34%20-%20a.md)")

  let e = NoteNames.edit(from: "ab [x](old.md) cd", to: "ab [x](new-name.md) cd", caret: 17)
  check("the open note is rewritten as one edit, caret carried", e.map { applied("ab [x](old.md) cd", $0)!.0 } == "ab [x](new-name.md) cd" && e?.cursor == 22, "\(String(describing: e))")

  let root = NSTemporaryDirectory() + "notes-walk-\(getpid())"
  let fm = FileManager.default
  try? fm.removeItem(atPath: root)
  try! fm.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
  try! fm.createDirectory(atPath: root + "/.hidden", withIntermediateDirectories: true)
  for file in ["a.md", "sub/b.md", ".hidden/c.md", ".d.md", "e.txt"] { try! "x".write(toFile: root + "/" + file, atomically: true, encoding: .utf8) }
  try! fm.createSymbolicLink(atPath: root + "/link.md", withDestinationPath: "/etc/hosts")
  let walked = NoteNames.markdownFiles(under: root)
  let walkedNames = NoteNames.markdownFiles(under: root).map { ($0 as NSString).lastPathComponent }
  check("rewriting walks every .md under the root, never hidden files or symlinks", walkedNames == ["a.md", "b.md"], "\(walked) \(walkedNames)")
  check("the walk keeps the root as given, so paths match the window's", NoteNames.markdownFiles(under: root).allSatisfy { $0.hasPrefix(root + "/") }, "\(NoteNames.markdownFiles(under: root))")
  try? fm.removeItem(atPath: root)
}

print("\(count - failures)/\(count) passed")
exit(failures == 0 ? 0 : 1)
