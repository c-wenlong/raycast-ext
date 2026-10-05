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

print("\(count - failures)/\(count) passed")
exit(failures == 0 ? 0 : 1)
