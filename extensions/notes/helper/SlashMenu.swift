import AppKit
import Foundation

// MARK: - Slash menu
//
// The menu that "/" opens under the caret: every block format the note
// knows, filtered by what is typed after the slash. The menu itself is an
// InlinePicker; this file holds its entries and how they match.

final class SlashMenu: InlinePicker {
  struct Entry {
    let id: String
    let title: String
    /// The markdown the entry stands for, shown at the right.
    let hint: String
    let symbol: String
    let format: NoteTextView.Format
    /// Extra words the entry answers to ("todo" for the task list).
    let aliases: [String]
  }

  static let entries: [Entry] = [
    Entry(id: "text", title: "Text", hint: "", symbol: "textformat", format: .plain, aliases: ["plain", "paragraph"]),
    Entry(id: "h1", title: "Heading 1", hint: "#", symbol: "textformat.size.larger", format: .prefix(.heading(1)), aliases: ["h1", "title"]),
    Entry(id: "h2", title: "Heading 2", hint: "##", symbol: "textformat.size", format: .prefix(.heading(2)), aliases: ["h2"]),
    Entry(id: "h3", title: "Heading 3", hint: "###", symbol: "textformat.size.smaller", format: .prefix(.heading(3)), aliases: ["h3"]),
    Entry(id: "h4", title: "Heading 4", hint: "####", symbol: "textformat.size.smaller", format: .prefix(.heading(4)), aliases: ["h4"]),
    Entry(id: "bullet", title: "Bulleted list", hint: "-", symbol: "list.bullet", format: .prefix(.bullet), aliases: ["ul", "unordered"]),
    Entry(id: "ordered", title: "Numbered list", hint: "1.", symbol: "list.number", format: .prefix(.ordered), aliases: ["ol", "ordered"]),
    Entry(id: "task", title: "To-do list", hint: "[]", symbol: "checklist", format: .prefix(.task), aliases: ["todo", "checkbox", "task", "check"]),
    Entry(id: "quote", title: "Quote", hint: "|", symbol: "text.quote", format: .prefix(.quote), aliases: ["blockquote"]),
    Entry(id: "toggle", title: "Toggle", hint: ">", symbol: "chevron.right", format: .prefix(.toggle), aliases: ["collapse", "fold", "details", "disclosure"]),
    Entry(id: "callout", title: "Callout", hint: "!>", symbol: "rectangle.on.rectangle", format: .prefix(.callout), aliases: ["box", "note", "highlight"]),
    Entry(id: "code-block", title: "Code block", hint: "```", symbol: "curlybraces", format: .codeBlock, aliases: ["code", "fence"]),
  ]

  /// The entries matching `query`: every word of the query is a prefix
  /// of a word in the title or of an alias. An empty query matches all.
  static func matches(_ query: String) -> [Entry] {
    let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
    guard !words.isEmpty else { return entries }
    return entries.filter { entry in
      let haystack = entry.title.lowercased().split(separator: " ").map(String.init) + entry.aliases
      return words.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
    }
  }

  /// The picker for these entries; `pick` gets the chosen entry.
  init(pick: @escaping (Entry) -> Void) {
    super.init(
      title: "Blocks", accessibilityLabel: "Block formats",
      source: { query in SlashMenu.matches(query).map { InlinePicker.Item(id: $0.id, title: $0.title, hint: $0.hint, symbol: $0.symbol) } },
      pick: { item in
        guard let entry = SlashMenu.entries.first(where: { $0.id == item.id }) else { return }
        pick(entry)
      })
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
