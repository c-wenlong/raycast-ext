import Foundation

// MARK: - Note filenames
//
// A note made by the window or the extension is named
// `YYYY-MM-DD HHmm <id> - slug.md`: the minute it was made, a stable id
// (four lowercase base36 characters, unique in its folder), and the slug of
// its title. A save renames it when the title changes; only the slug moves,
// so the id finds the note again from a link that went stale. Names from
// before ids (`YYYY-MM-DD HHmm - slug.md`) get one once, by `migration`.
// Daily notes (`YYYY-MM-DD.md`) and hand-named files are never renamed.
// Mirrors src/lib/notes.ts (parseGeneratedFilename and friends).

/// Mirrors slugify() in src/lib/notes.ts so both editors name files alike.
func slugify(_ title: String) -> String {
  let folded = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
  let kept = folded.unicodeScalars.filter {
    ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == " " || $0 == "-"
  }
  let words = String(String.UnicodeScalarView(kept)).split(whereSeparator: { $0 == " " || $0 == "-" })
  let slug = words.joined(separator: "-")
  return slug.isEmpty ? "untitled" : slug
}

/// A slug or filename as words: "-", "_" and spaces split, each word
/// capitalised, "Untitled" for nothing. Mirrors humanizeSlug() in
/// src/lib/notes.ts.
func humanize(_ slug: String) -> String {
  let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " || $0 == "\t" || $0 == "\n" })
    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
  return words.isEmpty ? "Untitled" : words.joined(separator: " ")
}

/// The note's title: its first line, or for an empty note a title made
/// from the filename's slug (never its date, time or id).
func title(of text: String, filename: String) -> String {
  if let first = Titles.firstLine(of: text) { return first }
  return NoteNames.fallbackTitle(filename: filename)
}

enum NoteNames {
  struct Generated: Equatable {
    /// "2026-10-05 1200"
    let stamp: String
    /// Nil for a name from before ids.
    let id: String?
    let slug: String
  }

  static let pattern = try! NSRegularExpression(
    pattern: #"^(\d{4}-\d{2}-\d{2} \d{4})(?: ([0-9a-z]{4}))? - (.+)\.md$"#)

  static func parse(_ filename: String) -> Generated? {
    let ns = filename as NSString
    guard let match = pattern.firstMatch(in: filename, range: NSRange(location: 0, length: ns.length)) else { return nil }
    let id = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
    return Generated(stamp: ns.substring(with: match.range(at: 1)), id: id, slug: ns.substring(with: match.range(at: 3)))
  }

  static func filename(stamp: String, id: String, slug: String) -> String { "\(stamp) \(id) - \(slug).md" }

  /// The title an empty note shows: the slug of a generated name made
  /// readable, else the filename without ".md".
  static func fallbackTitle(filename: String) -> String {
    if let generated = parse(filename) { return humanize(generated.slug) }
    return humanize((filename as NSString).deletingPathExtension)
  }

  static func timestamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HHmm"
    return formatter.string(from: date)
  }

  private static let idAlphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

  static func randomID() -> String { String((0..<4).map { _ in idAlphabet.randomElement()! }) }

  /// The ids the generated names in `names` carry.
  static func ids(in names: [String]) -> Set<String> { Set(names.compactMap { parse($0)?.id }) }

  /// A fresh id, drawn again while it clashes with `taken`.
  static func newID(avoiding taken: Set<String>, random: () -> String = randomID) -> String {
    var id = random()
    var tries = 0
    while taken.contains(id), tries < 10_000 {
      id = random()
      tries += 1
    }
    return id
  }

  /// The name a generated note gets for the title `title`: same stamp and
  /// id (a fresh one from `newID` for a name from before ids), the title's
  /// slug. Nil for a name that is not generated, or already right.
  static func renamed(_ filename: String, title: String, newID: () -> String) -> String? {
    guard let generated = parse(filename) else { return nil }
    let slug = slugify(title)
    if generated.id != nil, generated.slug == slug { return nil }
    return Self.filename(stamp: generated.stamp, id: generated.id ?? newID(), slug: slug)
  }

  /// The renames that give every generated name in `names` without an id
  /// one, each unique among the folder's ids and each other. Daily notes
  /// and hand-named files are left alone; run again, it finds nothing.
  static func migration(of names: [String], random: () -> String = randomID) -> [(from: String, to: String)] {
    var taken = ids(in: names)
    let existing = Set(names)
    var plan: [(from: String, to: String)] = []
    for name in names.sorted() {
      guard let generated = parse(name), generated.id == nil else { continue }
      var target: String
      repeat {
        let id = newID(avoiding: taken, random: random)
        taken.insert(id)
        target = filename(stamp: generated.stamp, id: id, slug: generated.slug)
      } while existing.contains(target)
      plan.append((name, target))
    }
    return plan
  }

  // MARK: Rewriting links after a rename

  /// Every markdown note under `root`, subfolders included, as paths
  /// under `root` as given (not resolved through symlinks such as /tmp):
  /// regular files only (never a symlink, which could lead outside), no
  /// hidden files or folders.
  static func markdownFiles(under root: String) -> [String] {
    let fm = FileManager.default
    guard let walker = fm.enumerator(atPath: root) else { return [] }
    var files: [String] = []
    while let relative = walker.nextObject() as? String {
      let path = (root as NSString).appendingPathComponent(relative)
      let type = walker.fileAttributes?[.type] as? FileAttributeType
      if (relative as NSString).lastPathComponent.hasPrefix(".") {
        if type == .typeDirectory { walker.skipDescendants() }
        continue
      }
      guard type == .typeRegular, (relative as NSString).pathExtension.lowercased() == "md" else { continue }
      files.append(path)
    }
    return files.sorted()
  }

  /// The markdown link `[text](target)`; Markdown.link is this pattern.
  static let linkPattern = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^)\s]+)(\))"#)

  /// `text` (a note in `directory`) with every link whose target resolves
  /// to a key of `moves` (absolute paths) pointing at the new path
  /// instead, written as the picker writes it: relative to `directory`
  /// (or absolute when it was), percent-encoded, any "#fragment" kept.
  /// Link text and everything else stay as they are, and so do links in
  /// code. Nil when nothing changed.
  static func rewriteLinks(in text: String, directory: String, moves: [String: String]) -> String? {
    guard !moves.isEmpty, text.contains("](") else { return nil }
    // A cheap look for the old names before parsing anything: an id, or a
    // slug for a name from before ids, survives percent-encoding.
    let tokens = moves.keys.map { old -> String in
      let name = (old as NSString).lastPathComponent
      return parse(name).map { $0.id ?? $0.slug } ?? (name as NSString).deletingPathExtension
    }
    guard tokens.contains(where: { text.contains($0) }) else { return nil }
    var standardized: [String: String] = [:]
    for (old, new) in moves { standardized[(old as NSString).standardizingPath] = new }
    let ns = text as NSString
    let result = NSMutableString(string: text)
    var changed = false
    for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
      guard !ListEditing.inCodeSpan(ns, match.range), !ListEditing.inCodeBlock(text, match.range) else { continue }
      let targetRange = match.range(at: 4)
      let raw = ns.substring(with: targetRange)
      let hash = raw.firstIndex(of: "#")
      let address = hash.map { String(raw[..<$0]) } ?? raw
      let fragment = hash.map { String(raw[$0...]) } ?? ""
      guard let url = URL(string: address), let resolved = NoteLinks.notePath(for: url, in: directory),
        let newPath = standardized[resolved]
      else { continue }
      let replacement: String
      if url.scheme?.lowercased() == "file" {
        replacement = URL(fileURLWithPath: newPath).absoluteString
      } else if address.hasPrefix("/") {
        replacement = ListEditing.encodedLinkTarget(newPath)
      } else {
        replacement = ListEditing.encodedLinkTarget(NoteLinks.linkTarget(for: newPath, from: directory))
      }
      result.replaceCharacters(in: targetRange, with: replacement + fragment)
      changed = true
    }
    return changed ? result as String : nil
  }

  /// The one edit that turns `old` into `new` (what lies between their
  /// common start and end), with `caret` carried over, for rewriting the
  /// open note's text in place as one undo step.
  static func edit(from old: String, to new: String, caret: Int) -> ListEditing.Edit? {
    let a = old as NSString
    let b = new as NSString
    guard old != new else { return nil }
    let shortest = min(a.length, b.length)
    var prefix = 0
    while prefix < shortest, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
    var suffix = 0
    while suffix < shortest - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
      suffix += 1
    }
    let range = NSRange(location: prefix, length: a.length - prefix - suffix)
    let replacement = b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix))
    let delta = b.length - a.length
    let cursor = caret >= NSMaxRange(range) ? caret + delta : min(caret, prefix + (replacement as NSString).length)
    return ListEditing.Edit(range: range, replacement: replacement, cursor: cursor)
  }
}
