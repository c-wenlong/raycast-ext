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

check("enter inside a fence is plain", ListEditing.newline(in: "```\n- x", cursor: 7) == nil)
check("tab inside a fence is plain", ListEditing.indent(in: "```\n- a\n- b", cursor: 11, by: 1) == nil)
check("closed fence ends", ListEditing.insideFence("```\ncode\n```\n- x", cursor: 14) == false)
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
  check("quote prefix and cursor", text == "> x" && cursor == 3, "\(text) \(cursor)")
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

print("\(count - failures)/\(count) passed")
exit(failures == 0 ? 0 : 1)
