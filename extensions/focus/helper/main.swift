// focus-daemon: the long-running half of the Focus extension. Owns EventKit,
// the sqlite log, the session timer, the menu bar countdown and the end sheet
// (UIPresenter.swift), and blocking (BlockEngine.swift, AppBlocker.swift).
//
//   focus-daemon [serve]              start the daemon if it is not running
//   focus-daemon <cmd>                send {"cmd": "<cmd>"}, print the reply
//   focus-daemon '{"cmd": ..., ...}'  send a full request, print the reply
//
// One instance serves ~/.raycast/focus/focus.sock (FOCUS_DIR overrides the
// folder). Client invocations start it on demand. The server is spawned as
// its own session with TCC responsibility disclaimed, so the Calendar
// permission belongs to focus-daemon rather than whatever launched it.
// Protocol: extensions/focus/HELPER.md. Build: scripts/build-helper.sh.

import AppKit
import Darwin
import Foundation

// MARK: - Paths and logging

let environment = ProcessInfo.processInfo.environment
let focusDir = NSString(string: environment["FOCUS_DIR"] ?? "~/.raycast/focus").expandingTildeInPath
let socketPath = focusDir + "/focus.sock"
let lockPath = focusDir + "/focus.lock"
let logPath = focusDir + "/daemon.log"

func log(_ message: String) {
  FileHandle.standardError.write(Data("\(ISO.local(Date())) focus-daemon[\(getpid())] \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("focus-daemon: \(message)\n".utf8))
  exit(2)
}

func ensureFocusDir() {
  guard !FileManager.default.fileExists(atPath: focusDir) else { return }
  do {
    try FileManager.default.createDirectory(
      atPath: focusDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  } catch {
    fail("could not create \(focusDir): \(error.localizedDescription)")
  }
}

// MARK: - Unix socket plumbing

func withSocketAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8CString)
  withUnsafeMutablePointer(to: &address.sun_path) { field in
    field.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
      for (offset, byte) in bytes.prefix(103).enumerated() { destination[offset] = byte }
    }
  }
  let length = socklen_t(MemoryLayout<sockaddr_un>.size)
  return withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
  }
}

func setOption(_ fd: Int32, _ name: Int32, seconds: Int? = nil) {
  if let seconds {
    var value = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, name, &value, socklen_t(MemoryLayout<timeval>.size))
  } else {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, name, &one, socklen_t(MemoryLayout<Int32>.size))
  }
}

func writeAll(_ fd: Int32, _ text: String) -> Bool {
  let bytes = Array(text.utf8)
  var sent = 0
  while sent < bytes.count {
    let count = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    if count < 0 && errno == EINTR { continue }
    guard count > 0 else { return false }
    sent += count
  }
  return true
}

/// Reads up to the first newline (or EOF). Nil on timeout or error.
func readLine(_ fd: Int32, limit: Int = 1 << 20) -> String? {
  var data = [UInt8]()
  var chunk = [UInt8](repeating: 0, count: 4096)
  while data.count < limit {
    let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
    if count < 0 && errno == EINTR { continue }
    if count < 0 { return nil }
    if count == 0 { break }
    if let newline = chunk[0..<count].firstIndex(of: 10) {
      data.append(contentsOf: chunk[0..<newline])
      break
    }
    data.append(contentsOf: chunk[0..<count])
  }
  return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Sends one request line to the running daemon and returns its reply, or
/// nil when nobody is listening.
func sendRequest(_ line: String, timeout: Int = 30) -> String? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  guard withSocketAddress(socketPath, { connect(fd, $0, $1) }) == 0 else { return nil }
  setOption(fd, SO_NOSIGPIPE)
  setOption(fd, SO_RCVTIMEO, seconds: timeout)
  guard writeAll(fd, line + "\n") else { return nil }
  return readLine(fd)
}

func isOk(_ reply: String?) -> Bool {
  guard let reply, let value = try? JSONValue.parse(reply) else { return false }
  return value["ok"]?.boolValue == true
}

func daemonAnswers() -> Bool {
  isOk(sendRequest(#"{"cmd":"ping"}"#, timeout: 5))
}

// MARK: - Starting the server process

/// Spawns `focus-daemon serve` detached: new session, stdio to the log file,
/// no inherited descriptors (a caller's pipes would otherwise stay open), and
/// TCC responsibility disclaimed so the permission prompt names focus-daemon.
func spawnServer() -> Bool {
  ensureFocusDir()
  if let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? Int, size > 1 << 20 {
    _ = try? FileManager.default.removeItem(atPath: logPath + ".1")
    _ = try? FileManager.default.moveItem(atPath: logPath, toPath: logPath + ".1")
  }
  guard let executable = Bundle.main.executablePath else { return false }

  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
  posix_spawn_file_actions_adddup2(&actions, 1, 2)

  var attributes: posix_spawnattr_t?
  posix_spawnattr_init(&attributes)
  defer { posix_spawnattr_destroy(&attributes) }
  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
  typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
  if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
    _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
  }

  var childEnvironment = environment
  childEnvironment["FOCUS_DAEMON_CHILD"] = "1"
  let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("serve"), nil]
  let envp: [UnsafeMutablePointer<CChar>?] = childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
  defer { (argv + envp).forEach { free($0) } }

  var pid: pid_t = 0
  let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
  if status != 0 { FileHandle.standardError.write(Data("focus-daemon: spawn failed: \(status)\n".utf8)) }
  return status == 0
}

func waitForDaemon(seconds: Double) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if daemonAnswers() { return true }
    usleep(100_000)
  }
  return false
}

// MARK: - Server

var keepAlive: [AnyObject] = []

func runServer() -> Never {
  ensureFocusDir()

  // The lock decides who serves; the holder may remove a stale socket file.
  let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
  guard lock >= 0 else { fail("could not open \(lockPath)") }
  var locked = false
  for _ in 0..<30 {
    if flock(lock, LOCK_EX | LOCK_NB) == 0 {
      locked = true
      break
    }
    usleep(100_000)
  }
  guard locked else {
    log("another focus-daemon holds \(lockPath); exiting")
    exit(0)
  }
  ftruncate(lock, 0)
  let pidLine = Array("\(getpid())\n".utf8)
  _ = pidLine.withUnsafeBytes { write(lock, $0.baseAddress, $0.count) }

  unlink(socketPath)
  let server = socket(AF_UNIX, SOCK_STREAM, 0)
  guard server >= 0 else { fail("socket() failed") }
  let previousMask = umask(0o077)
  let bound = withSocketAddress(socketPath) { bind(server, $0, $1) }
  umask(previousMask)
  guard bound == 0, listen(server, 16) == 0 else { fail("could not listen on \(socketPath): errno \(errno)") }
  signal(SIGPIPE, SIG_IGN)

  // The menu bar countdown, the end sheet and the block window need a
  // running NSApplication. Accessory: no Dock icon, no app switcher entry.
  // The socket and timers below run on GCD and a thread of their own, so
  // app.run() serves them too.
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)

  let work = DispatchQueue(label: "focus-daemon.work")
  let backend = EventKitBackend(queue: work, log: log)
  let configFile = ConfigFile(path: focusDir + "/config.json", log: log)

  // Blocking (BlockEngine.swift). The app side is wired here; the site side
  // (tab watcher and block page) is `engine.siteBlocker`. Both are set before
  // the core exists, so a session recovered at launch is blocked at once.
  let engine = BlockEngine(config: configFile, log: log)
  let appBlocker = AppBlocker(engine: engine, log: log)
  engine.workspace = appBlocker
  engine.siteBlocker = makeSiteBlocker(log: log)
  keepAlive.append(appBlocker)

  let core: FocusCore
  do {
    core = FocusCore(
      config: configFile, db: try Database(path: focusDir + "/focus.db"), calendar: backend, log: log, queue: work,
      blocker: engine)
  } catch {
    unlink(socketPath)
    fail(error.localizedDescription)
  }
  if environment["FOCUS_DEBUG"] == "1" {
    core.extraHandler = { request in
      // As if the app had just come forward: macOS refuses to activate
      // another app from a background shell, so the live check uses this.
      if request.cmd == "debugBlockApp" {
        let bundleId = try request.requiredString("bundleId")
        let blocked = DispatchQueue.main.sync { () -> Bool? in
          guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return nil
          }
          return appBlocker.activated(running)
        }
        guard let blocked else { throw FocusError("\(bundleId) is not running") }
        return .ok(["blocked": .bool(blocked)])
      }
      // The block window as the daemon draws it right now, as a PNG, plus
      // its state (screencapture needs Screen Recording, which a shell may lack).
      if request.cmd == "debugBlockWindow" {
        let path = try request.requiredString("path")
        let state = DispatchQueue.main.sync { () -> [String: JSONValue] in
          let window = appBlocker.window
          let view = window.backdrop
          if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
          }
          return [
            "visible": .bool(window.isVisible), "key": .bool(window.panel.isKeyWindow),
            "appActive": .bool(NSApp.isActive), "title": .string(window.titleLabel.stringValue),
            "button": .string(window.snoozeButton.title), "frame": .string(NSStringFromRect(window.panel.frame)),
          ]
        }
        return .ok(state)
      }
      // Presses the block window's Snooze button, as a click would.
      if request.cmd == "debugPressSnooze" {
        DispatchQueue.main.sync { appBlocker.window.snoozeButton.performClick(nil) }
        return .ok()
      }
      return try backend.debug(request)
    }
    log("debug commands enabled")
  }

  installEditMenu()
  attachPresenter(to: core)
  log("serving \(socketPath) (version \(FocusCore.version))")

  // Recovery at launch, and again as soon as access is granted.
  work.async {
    _ = core.config.load()
    backend.onAccessGranted = { core.tick() }
    backend.requestAccessIfNeeded()
    log("calendar access is \(backend.accessState)")
    if backend.accessState == "fullAccess" { core.tick() }
  }

  // Heartbeat and recovery every 30 seconds.
  let timer = DispatchSource.makeTimerSource(queue: work)
  timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(1))
  timer.setEventHandler { core.tick() }
  timer.resume()
  keepAlive.append(timer as AnyObject)

  Thread.detachNewThread {
    while true {
      let client = accept(server, nil, nil)
      guard client >= 0 else {
        if errno != EINTR { usleep(10_000) }
        continue
      }
      DispatchQueue.global(qos: .userInitiated).async {
        setOption(client, SO_NOSIGPIPE)
        setOption(client, SO_RCVTIMEO, seconds: 5)
        let line = readLine(client) ?? ""
        let reply =
          line.isEmpty
          ? Reply.failure(FocusError("empty request"))
          : work.sync { core.handle(line: line) }
        _ = writeAll(client, reply.body.serialized() + "\n")
        close(client)
        if reply.quit {
          work.async {
            log("quit")
            unlink(socketPath)
            exit(0)
          }
        }
      }
    }
  }

  app.run()
  exit(0)
}

// MARK: - Entry point

guard socketPath.utf8.count < 104 else { fail("socket path is too long: \(socketPath)") }

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--help" || arguments.first == "-h" {
  print("usage: focus-daemon [serve | <cmd> | '<json request>']  (protocol: extensions/focus/HELPER.md)")
  exit(0)
}

if arguments.isEmpty || arguments == ["serve"] {
  if environment["FOCUS_DAEMON_CHILD"] == "1" || environment["FOCUS_FOREGROUND"] == "1" { runServer() }
  if daemonAnswers() { exit(0) }
  guard spawnServer(), waitForDaemon(seconds: 10) else { fail("the daemon did not start; see \(logPath)") }
  exit(0)
}

let line: String
if arguments[0].hasPrefix("{") {
  line = arguments.joined(separator: " ")
} else if arguments.count == 1 {
  line = JSONValue.object(["cmd": .string(arguments[0])]).serialized()
} else {
  fail("pass one command name or one JSON request")
}

var reply = sendRequest(line)
if reply == nil {
  if arguments == ["quit"] {
    print(#"{"error":"focus-daemon is not running","ok":false}"#)
    exit(1)
  }
  guard spawnServer(), waitForDaemon(seconds: 10) else { fail("the daemon did not start; see \(logPath)") }
  reply = sendRequest(line)
}
guard let reply else { fail("no reply from the daemon") }
print(reply)
exit(isOk(reply) ? 0 : 1)
