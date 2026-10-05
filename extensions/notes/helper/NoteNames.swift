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

/// First free path for `filename` in `directory`. A new note (`renaming`
/// false) whose generated name is taken draws a new id, checked against
/// the folder (`NoteNames.clashCandidate`); a rename keeps its id and gets
/// -2, -3, ... on the slug (`renameClashCandidate`), as any other name does.
func uniqueNotePath(for filename: String, in directory: String, renaming: Bool = false) -> String {
  var attempt = 1
  while true {
    let candidate = renaming
      ? NoteNames.renameClashCandidate(filename, attempt: attempt)
      : NoteNames.clashCandidate(filename, attempt: attempt) {
        NoteNames.newID(avoiding: NoteNames.usedIDs(in: directory))
      }
    let path = (directory as NSString).appendingPathComponent(candidate)
    if !FileManager.default.fileExists(atPath: path) { return path }
    attempt += 1
  }
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

  /// For a new note: the name to try after `filename` was taken, on
  /// attempt 2, 3...: a generated name with an id draws a new id
  /// (`newID`), so two notes never share one; any other name gets "-2",
  /// "-3". Mirrors clashCandidate in src/lib/notes.ts.
  static func clashCandidate(_ filename: String, attempt: Int, newID: () -> String) -> String {
    guard attempt > 1 else { return filename }
    if let generated = parse(filename), generated.id != nil {
      return Self.filename(stamp: generated.stamp, id: newID(), slug: generated.slug)
    }
    return renameClashCandidate(filename, attempt: attempt)
  }

  /// For a rename: the name to try after `filename` was taken. A rename
  /// never changes the id, so the slug gets "-2", "-3". Mirrors
  /// renameClashCandidate in src/lib/notes.ts.
  static func renameClashCandidate(_ filename: String, attempt: Int) -> String {
    guard attempt > 1 else { return filename }
    return "\((filename as NSString).deletingPathExtension)-\(attempt).md"
  }

  /// The name a generated note gets for the title `title`: same stamp and
  /// id (a fresh one from `newID` for a name from before ids), the title's
  /// slug, or the slug with "-2", "-3" when the names before it are taken
  /// (`exists`, by filename in the note's folder) by other notes. Nil for a
  /// name that is not generated, or when that lands on its current name, so
  /// a note that took "-2" by a clash stays put save after save, while
  /// "plan-2" retitled "Plan" becomes "plan" once that name is free.
  /// Mirrors renameTarget in src/lib/notes.ts.
  static func renamed(_ filename: String, title: String, newID: () -> String, exists: (String) -> Bool) -> String? {
    guard let generated = parse(filename) else { return nil }
    let base = Self.filename(stamp: generated.stamp, id: generated.id ?? newID(), slug: slugify(title))
    var attempt = 1
    while attempt < 10_000 {
      let candidate = renameClashCandidate(base, attempt: attempt)
      if candidate == filename { return nil }
      if !exists(candidate) { return candidate }
      attempt += 1
    }
    return nil
  }

  /// The renames that give every generated name in `names` without an id
  /// one, each unique among the folder's ids and each other. Daily notes
  /// and hand-named files are left alone; run again, it finds nothing.
  /// A name whose rename is already `logged` (an earlier run could not
  /// move it) gets the logged name again, so a retry reserves no new id.
  static func migration(
    of names: [String], avoiding used: Set<String> = [], logged: [String: String] = [:], random: () -> String = randomID
  ) -> [(from: String, to: String)] {
    var taken = ids(in: names).union(used)
    let existing = Set(names)
    var plan: [(from: String, to: String)] = []
    for name in names.sorted() {
      guard let generated = parse(name), generated.id == nil else { continue }
      if let target = logged[name], let id = parse(target)?.id, parse(target)?.stamp == generated.stamp,
        !existing.contains(target)
      {
        taken.insert(id)
        plan.append((name, target))
        continue
      }
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

  // MARK: Migrating a folder

  /// What the migration renamed in a folder, and the ids retired there,
  /// kept beside the notes as `.note-renames.jsonl` (hidden, so no list
  /// shows it). It is append-only JSON Lines, one event per line, each line
  /// written by a single O_APPEND write so the window and Browse Notes can
  /// both write without losing each other's events:
  ///   {"rename":["old filename","new filename"]}  the migration renamed it
  ///   {"retire":"k3x9"}                            a deleted note's id
  ///   {"links":"pending"} / {"links":"done"}       links not yet / all rewritten
  /// Readers fold every line in order and skip a line that does not parse
  /// (a half-written last line included). State follows line order: the
  /// last "links" event wins, so a "done" never outlives a later
  /// "pending", and a "rename" counts as "pending" by itself.
  /// Browse Notes moves pins with the renames, a stale link to an old name
  /// (which has no id to look up) still opens through them, and no new note
  /// gets a logged or retired id. Mirrors readNoteLog in src/lib/notes.ts.
  struct RenameLog: Codable, Equatable {
    var renames: [String: String] = [:]
    var linksRewritten = true
    /// Ids of notes deleted from the window or Browse Notes: never drawn
    /// again, so an old link or pin can never land on an unrelated note
    /// that happened to get the same id. (A note deleted in Finder is not
    /// seen; with 36^4 ids the chance of a reuse there is tiny.)
    var retiredIDs: [String]? = nil
  }

  enum LogEvent: Equatable {
    case rename(String, String)
    case retire(String)
    case links(done: Bool)

    var json: [String: Any] {
      switch self {
      case .rename(let old, let new): return ["rename": [old, new]]
      case .retire(let id): return ["retire": id]
      case .links(let done): return ["links": done ? "done" : "pending"]
      }
    }
  }

  static let renameLogName = ".note-renames.jsonl"

  private static func fold(_ event: [String: Any], into log: inout RenameLog) {
    if let pair = event["rename"] as? [String], pair.count == 2 {
      log.renames[pair[0]] = pair[1]
      // A rename means its links are not rewritten yet, even if the
      // "pending" written after it was lost.
      log.linksRewritten = false
    } else if let id = event["retire"] as? String {
      var retired = log.retiredIDs ?? []
      if !retired.contains(id) { retired.append(id) }
      log.retiredIDs = retired
    } else if let links = event["links"] as? String {
      log.linksRewritten = links == "done"
    }
  }

  /// The folder's log, folded; nil when it has none.
  static func renameLog(in directory: String) -> RenameLog? {
    let path = (directory as NSString).appendingPathComponent(renameLogName)
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    var log = RenameLog()
    var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
    // Only lines ended by "\n" are whole; a last one without is half written.
    if data.last != 0x0A { lines.removeLast() }
    for line in lines where !line.isEmpty {
      guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
      fold(event, into: &log)
    }
    return log
  }

  /// Appends `events` to the folder's log, each line by one O_APPEND write
  /// (starting on a fresh line if a writer stopped half way). False when
  /// it cannot write.
  @discardableResult
  static func appendLog(_ events: [LogEvent], in directory: String) -> Bool {
    let path = (directory as NSString).appendingPathComponent(renameLogName)
    let all = events.map(\.json)
    // Read-write so the last byte can be checked; writes still go to the end.
    let fd = open(path, O_RDWR | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var needsBreak = false
    var size = stat()
    if fstat(fd, &size) == 0, size.st_size > 0 {
      var last: UInt8 = 0
      if pread(fd, &last, 1, size.st_size - 1) == 1, last != 0x0A { needsBreak = true }
    }
    for event in all {
      guard var line = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return false }
      line.append(0x0A)
      if needsBreak {
        line.insert(0x0A, at: 0)
        needsBreak = false
      }
      let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      guard written == line.count else { return false }
    }
    return true
  }

  /// Every id a new note must not take in `directory`: those its notes
  /// carry, those in the rename log, and retired ones.
  static func usedIDs(in directory: String) -> Set<String> {
    var used = ids(in: (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
    if let log = renameLog(in: directory) {
      used.formUnion(ids(in: Array(log.renames.keys) + Array(log.renames.values)))
      used.formUnion(log.retiredIDs ?? [])
    }
    return used
  }

  /// Records the id of the deleted note `filename` as retired in its
  /// folder's log. False when the name has no id or the log cannot be written.
  @discardableResult
  static func retireID(of filename: String, in directory: String) -> Bool {
    guard let id = parse(filename)?.id else { return false }
    return appendLog([.retire(id)], in: directory)
  }

  struct MigrationOutcome {
    /// Old path to new, for the renames made in this run.
    var renamed: [String: String] = [:]
    /// Old path to new, for every logged rename whose links this run
    /// rewrote (a note that failed is retried next run); the caller applies
    /// it to the open note's text.
    var rewritten: [String: String] = [:]
    /// True when nothing is left to do: every rename and every link
    /// rewrite succeeded. Otherwise the next run tries again.
    var complete = false
  }

  static func defaultMove(_ from: String, _ to: String) -> Bool {
    (try? FileManager.default.moveItem(atPath: from, toPath: to)) != nil
  }

  static func defaultWrite(_ path: String, _ text: String) -> Bool {
    (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
  }

  /// Gives every name from before ids in `directory` an id (`migration`),
  /// logging each rename before it is made, then rewrites links to the
  /// renamed notes in every note under `root` except `openPath` (the
  /// window rewrites that one in its text). Safe to run again: it only
  /// picks up what is left (names still without an id, links not yet
  /// rewritten). Never touches anything outside `root`.
  static func migrateFolder(
    _ directory: String, root: String, openPath: String?, random: () -> String = randomID,
    move: (String, String) -> Bool = defaultMove, write: (String, String) -> Bool = defaultWrite
  ) -> MigrationOutcome {
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).filter { name in
      let path = (directory as NSString).appendingPathComponent(name)
      return !name.hasPrefix(".") && name.lowercased().hasSuffix(".md")
        && (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
    }
    var outcome = MigrationOutcome()
    var log = renameLog(in: directory) ?? RenameLog()
    // Ids reserved by the log stay reserved, except that a logged rename
    // not yet made is planned again under its logged name.
    let plan = migration(of: names, avoiding: usedIDs(in: directory), logged: log.renames, random: random)
    let fresh = plan.filter { log.renames[$0.from] != $0.to }
    if !fresh.isEmpty {
      // Logged first, so a rename is never made without its record.
      guard appendLog(fresh.map { .rename($0.from, $0.to) } + [.links(done: false)], in: directory) else { return outcome }
      for step in fresh { log.renames[step.from] = step.to }
      log.linksRewritten = false
    }
    var failed = false
    for step in plan {
      let from = (directory as NSString).appendingPathComponent(step.from)
      let to = (directory as NSString).appendingPathComponent(step.to)
      if !fm.fileExists(atPath: to), move(from, to) {
        outcome.renamed[from] = to
      } else {
        failed = true
      }
    }
    if !log.linksRewritten {
      var moves: [String: String] = [:]
      for (old, new) in log.renames {
        let to = (directory as NSString).appendingPathComponent(new)
        if fm.fileExists(atPath: to) { moves[(directory as NSString).appendingPathComponent(old)] = to }
      }
      let skip = openPath.map { outcome.renamed[$0] ?? $0 }
      // Every note that could be rewritten is, one by one; the open note
      // gets the mapping whatever happened to the others.
      outcome.rewritten = moves
      if rewriteLinks(underRoot: root, moves: moves, skipping: skip, write: write) {
        if !failed, !appendLog([.links(done: true)], in: directory) { failed = true }
      } else {
        failed = true
      }
    }
    outcome.complete = !failed
    return outcome
  }

  /// Rewrites links to the notes in `moves` in every note under `root`
  /// except `skipping`. Each changed file is written atomically and its
  /// modification date moves on, so an editor holding it (Raycast's edit
  /// form checks the date before saving) sees the change rather than
  /// writing over it. False when any note could not be read or written.
  @discardableResult
  static func rewriteLinks(
    underRoot root: String, moves: [String: String], skipping: String?,
    write: (String, String) -> Bool = defaultWrite
  ) -> Bool {
    guard !moves.isEmpty else { return true }
    var ok = true
    for path in markdownFiles(under: root) where path != skipping {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        ok = false
        continue
      }
      let directory = (path as NSString).deletingLastPathComponent
      guard let updated = rewriteLinks(in: text, directory: directory, moves: moves) else { continue }
      if !write(path, updated) { ok = false }
    }
    return ok
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
