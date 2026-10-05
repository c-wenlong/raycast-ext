import Foundation

// MARK: - Links between notes
//
// "[[" opens a picker over the other notes in the folder; a pick inserts
// `[Title](file.md)` (ListEditing.noteLink). Clicking such a link opens the
// note in the window instead of handing it to the browser.

enum NoteLinks {
  /// A note the picker offers.
  struct Target: Equatable {
    let title: String
    /// The address the link gets, before encoding: the filename for a
    /// note beside the open one, else the full path.
    let target: String
    let modified: Date
  }

  /// The targets matching `query`: every word of it appears in the title
  /// or the address (any case). Order (most recently modified first) is
  /// kept. An empty query matches all.
  static func matches(_ query: String, in targets: [Target], limit: Int = 200) -> [Target] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    let found = words.isEmpty ? targets : targets.filter { target in
      let title = target.title.lowercased()
      let address = target.target.lowercased()
      return words.allSatisfy { title.contains($0) || address.contains($0) }
    }
    return Array(found.prefix(limit))
  }

  /// The address for a link from a note in `directory` to the note at
  /// `path`: relative to that folder (its filename beside it, `sub/x.md`
  /// below it, `../x.md` from a subfolder), so it resolves the same way a
  /// click does.
  static func linkTarget(for path: String, from directory: String) -> String {
    let target = ((path as NSString).standardizingPath as NSString).pathComponents
    let base = ((directory as NSString).standardizingPath as NSString).pathComponents
    var shared = 0
    while shared < min(target.count - 1, base.count), target[shared] == base[shared] { shared += 1 }
    let up = Array(repeating: "..", count: base.count - shared)
    return (up + target[shared...]).joined(separator: "/")
  }

  /// True when the note at `path` sits directly in the notes folder
  /// `root`, the only folder the window lists and keeps a note open from;
  /// a link to anything else opens in its default app.
  static func opensInWindow(_ path: String, root: String) -> Bool {
    let folder = ((path as NSString).standardizingPath as NSString).deletingLastPathComponent
    return folder == (root as NSString).standardizingPath
  }

  /// How much of a note the "[[" picker reads for its title.
  static let headLimit = 4096

  /// The start of the file at `path`, up to `limit` bytes, as text (a
  /// character cut at the end is dropped): enough for the title without
  /// reading a long note whole. Nil when the file cannot be read.
  static func headText(atPath path: String, limit: Int = headLimit) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit) else { return "" }
    var bytes = data
    // Drop a UTF-8 sequence cut by the limit, so the text decodes.
    while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil, data.count - bytes.count < 4 { bytes.removeLast() }
    return String(data: bytes, encoding: .utf8)
  }

  /// The file a note link points at, resolved against `directory` (the
  /// open note's folder): a link with no scheme (or file:) whose path ends
  /// in ".md". Nil for web links and anything else.
  static func notePath(for url: URL, in directory: String) -> String? {
    guard url.scheme == nil || url.scheme?.lowercased() == "file" else { return nil }
    let path = url.path
    guard !path.isEmpty, path.lowercased().hasSuffix(".md") else { return nil }
    let full = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
    return (full as NSString).standardizingPath
  }

  /// For a link whose file is gone: the one note in `names` carrying the
  /// same id as the link's filename (`YYYY-MM-DD HHmm <id> - slug.md`), as
  /// after a rename the window did not see. Nil when the link has no id,
  /// or no note or more than one carries it.
  static func noteWithSameID(as filename: String, among names: [String]) -> String? {
    guard let id = NoteNames.parse(filename)?.id else { return nil }
    let candidates = names.filter { $0 != filename && NoteNames.parse($0)?.id == id }
    return candidates.count == 1 ? candidates[0] : nil
  }

  /// For a link whose file is gone: where the migration's rename log
  /// (`NoteNames.RenameLog`) says that name went, following a name renamed
  /// again, when the file `exists`. This is how a link to a name from
  /// before ids, which has no id to look up, still opens.
  static func renamedByLog(_ filename: String, renames: [String: String], exists: (String) -> Bool) -> String? {
    var name = filename
    var steps = 0
    while let next = renames[name], steps < 16 {
      name = next
      steps += 1
    }
    return name != filename && exists(name) ? name : nil
  }
}
