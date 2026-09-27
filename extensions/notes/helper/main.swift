// notes-panel: a floating, always-on-top markdown editor over the notes
// folder, in the spirit of the Raycast Notes window.
//
//   notes-panel [toggle|show|hide|new|open <path>] [--dir <folder>]
//
// The first invocation becomes a small server on a unix socket and shows
// the panel; later invocations just forward their command to it and exit.
// Built with: swiftc -O -swift-version 5 -o assets/notes-panel helper/main.swift

import AppKit
import Foundation

// MARK: - Arguments

let diskFiles = FileManager.default
var notesDir = NSString(string: "~/.raycast/notes").expandingTildeInPath
var arguments = Array(CommandLine.arguments.dropFirst())
if let flag = arguments.firstIndex(of: "--dir"), flag + 1 < arguments.count {
  notesDir = NSString(string: arguments[flag + 1]).expandingTildeInPath
  arguments.removeSubrange(flag...(flag + 1))
}
let requestedCommand = arguments.isEmpty ? "toggle" : arguments.joined(separator: " ")

let supportDir = NSString(string: "~/Library/Application Support/notes-panel")
  .expandingTildeInPath
let socketPath = supportDir + "/notes-panel.sock"

// MARK: - Unix socket plumbing

func withSocketAddress(
  _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
) -> Int32 {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8CString)
  withUnsafeMutablePointer(to: &address.sun_path) { field in
    field.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
      for (offset, byte) in bytes.prefix(103).enumerated() {
        destination[offset] = byte
      }
    }
  }
  let length = socklen_t(MemoryLayout<sockaddr_un>.size)
  return withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
  }
}

/// Forwards a command (and the notes folder) to a running instance.
/// Returns the connect() errno when nobody is listening.
func forwardToRunningInstance(_ line: String) -> Int32? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return errno }
  defer { close(fd) }
  guard withSocketAddress(socketPath, { connect(fd, $0, $1) }) == 0 else {
    return errno
  }
  let payload = Array((line + "\u{0}" + notesDir).utf8)
  _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
  var reply = [UInt8](repeating: 0, count: 16)
  _ = reply.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 16, 0) }
  return nil
}

final class CommandServer {
  private let fd: Int32

  /// `staleSocket` is true when connect() got ECONNREFUSED: a leftover
  /// file from a dead instance that has to be removed before binding.
  /// bind() failing with EADDRINUSE means another launch got there first.
  init?(staleSocket: Bool) {
    try? diskFiles.createDirectory(
      atPath: supportDir, withIntermediateDirectories: true)
    if staleSocket { unlink(socketPath) }
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard withSocketAddress(socketPath, { bind(fd, $0, $1) }) == 0,
      listen(fd, 8) == 0
    else {
      close(fd)
      return nil
    }
  }

  func run(_ handler: @escaping (String) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async { [fd] in
      while true {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { continue }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes {
          recv(client, $0.baseAddress, 4096, 0)
        }
        let line =
          count > 0
          ? String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          : ""
        let parts = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        DispatchQueue.main.async {
          if parts.count == 2, !parts[1].isEmpty { notesDir = parts[1] }
          handler(parts.first ?? "")
        }
        _ = "ok\n".withCString { send(client, $0, 3, 0) }
        close(client)
      }
    }
  }
}

// MARK: - Notes on disk

struct Note {
  let path: String
  let modified: Date
  var filename: String { (path as NSString).lastPathComponent }
}

let generatedNamePattern = try! NSRegularExpression(
  pattern: #"^(\d{4}-\d{2}-\d{2} \d{4}) - (.+)\.md$"#)
let dailyNamePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}\.md$"#)
let headingPattern = try! NSRegularExpression(pattern: #"^#\s+(.+?)\s*$"#, options: .anchorsMatchLines)
let taskPattern = try! NSRegularExpression(pattern: #"^(\s*[-*+]\s+)\[([ xX])\]"#)

func fullRange(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

func listNotes() -> [Note] {
  try? diskFiles.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
  let names = (try? diskFiles.contentsOfDirectory(atPath: notesDir)) ?? []
  return names
    .filter { $0.lowercased().hasSuffix(".md") && !$0.hasPrefix(".") }
    .compactMap { name -> Note? in
      let path = (notesDir as NSString).appendingPathComponent(name)
      guard let attributes = try? diskFiles.attributesOfItem(atPath: path),
        (attributes[.type] as? FileAttributeType) == .typeRegular
      else { return nil }
      let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
      return Note(path: path, modified: modified)
    }
    .sorted { $0.modified > $1.modified }
}

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

func humanize(_ slug: String) -> String {
  slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
    .joined(separator: " ")
}

func title(of text: String, filename: String) -> String {
  if let first = Titles.firstLine(of: text) { return first }
  let base = (filename as NSString).deletingPathExtension
  if let match = generatedNamePattern.firstMatch(in: filename, range: fullRange(filename)) {
    return humanize((filename as NSString).substring(with: match.range(at: 2)))
  }
  return humanize(base)
}

func timestampPrefix(_ date: Date = Date()) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd HHmm"
  return formatter.string(from: date)
}

/// First free path for `filename` in `directory`, adding -2, -3, ...
func uniquePath(for filename: String, in directory: String = notesDir) -> String {
  let base = (filename as NSString).deletingPathExtension
  var attempt = 1
  while true {
    let candidate = attempt == 1 ? filename : "\(base)-\(attempt).md"
    let path = (directory as NSString).appendingPathComponent(candidate)
    if !diskFiles.fileExists(atPath: path) { return path }
    attempt += 1
  }
}

// MARK: - Entry point

var connectError = forwardToRunningInstance(requestedCommand)
if connectError == nil { exit(0) }

var server = CommandServer(staleSocket: connectError == ECONNREFUSED)
if server == nil {
  // Lost a race with another launch that is now listening: hand over.
  usleep(200_000)
  connectError = forwardToRunningInstance(requestedCommand)
  if connectError == nil { exit(0) }
  server = CommandServer(staleSocket: connectError == ECONNREFUSED)
}
guard let server else {
  FileHandle.standardError.write("notes-panel: could not listen on \(socketPath)\n".data(using: .utf8)!)
  exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PanelController(initialCommand: requestedCommand == "hide" ? "show" : requestedCommand)
app.delegate = controller
server.run { command in controller.handle(command) }
app.run()
