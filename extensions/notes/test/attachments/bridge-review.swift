import Foundation

func runBridgeReviewRegressions() {
  let reply: BridgeValue = ["ok": true, "bridgeVersion": 1, "display": "notch", "claimed": true, "session": nil]
  let client = FocusBridgeClient(focusDir: "/tmp/unused-notes-bridge-tests")
  client.performsIO = false
  client.receive(.success(reply), kind: .probe)
  check("global claim in a probe is not local ownership", !client.claimed && !client.last.claimed)
  client.receive(.success(reply), kind: .lease)
  check("accepted lease establishes ownership", client.claimed)
  client.release()
  check("release clears cached ownership immediately", !client.last.claimed)
  client.receive(.success(reply), kind: .probe)
  check("probe after release cannot reclaim ownership", !client.claimed)
  client.receive(.success(["ok": false, "error": "the notch is claimed by another host"]), kind: .lease)
  check("foreign lease refusal preserves compatibility", client.last.compatible && !client.claimed)
  var problems: [String] = []
  client.onActionProblem = { problems.append($0) }
  client.receive(.success(["ok": false, "error": "session 7 is not the current session"]), kind: .action)
  check("stale session refusal preserves compatibility and reports the problem", client.last.compatible && problems.count == 1)
  client.receive(.success(["ok": false, "error": "unknown command: notchBridge"]), kind: .probe)
  check("unknown command still marks old daemons incompatible", !client.last.compatible)

  // Hold the first request on a real socket while a release and reactivation
  // happen. The release must go out next, before the new lease.
  let directory = "/tmp/nbt-\(UUID().uuidString.prefix(8))"
  try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/focus.sock"
  let listener = socket(AF_UNIX, SOCK_STREAM, 0)
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8CString)
  withUnsafeMutablePointer(to: &address.sun_path) { field in
    field.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
      for (index, byte) in bytes.enumerated() { destination[index] = byte }
    }
  }
  let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  check("test socket binds", bound == 0 && listen(listener, 3) == 0)
  let firstReceived = DispatchSemaphore(value: 0)
  let unblock = DispatchSemaphore(value: 0)
  let lock = NSLock()
  var operations: [String] = []
  DispatchQueue.global().async {
    for index in 0..<3 {
      let fd = accept(listener, nil, nil)
      guard fd >= 0 else { return }
      var data = [UInt8](repeating: 0, count: 4096)
      let length = read(fd, &data, data.count)
      let request = try! BridgeValue.parse(String(decoding: data.prefix(max(0, length)), as: UTF8.self))
      lock.lock()
      operations.append(request["op"]!.stringValue!)
      lock.unlock()
      if index == 0 {
        firstReceived.signal()
        _ = unblock.wait(timeout: .now() + 3)
      }
      let response = reply.serialized() + "\n"
      _ = response.withCString { write(fd, $0, strlen($0)) }
      close(fd)
    }
  }
  let live = FocusBridgeClient(focusDir: directory)
  live.tick(active: true)
  check("first claim reaches the socket", firstReceived.wait(timeout: .now() + 2) == .success)
  live.release()
  live.tick(active: true)
  unblock.signal()
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    lock.lock()
    let released = operations.count >= 2
    lock.unlock()
    if released { break }
  }
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  live.tick(active: true)
  let finish = Date().addingTimeInterval(2)
  while Date() < finish && !live.claimed {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }
  lock.lock()
  let observed = operations
  lock.unlock()
  check("stale completion drains release before reactivated claim", observed == ["claim", "release", "claim"])
  check("old queued release cannot cancel reacquired lease", live.claimed)
  close(listener)

  // A menu pick while a renew is in flight queues, then drains in order
  // with the serialized session id and owner, exactly once each.

  /// Binds a private listener; the caller closes the returned fd.
  /// Returns (directory, listener fd, bindSucceeded).
  func bindDaemon(_ name: String) -> (String, Int32, Bool) {
    let directory = "/tmp/\(name)-\(UUID().uuidString.prefix(8))"
    try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = directory + "/focus.sock"
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    withUnsafeMutablePointer(to: &address.sun_path) { field in
      field.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
        for (index, byte) in pathBytes.enumerated() { destination[index] = byte }
      }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return (directory, listener, bound == 0)
  }

  func sessionJSON(_ id: Int) -> String {
    "{\"id\":\(id),\"goal\":\"Deep Work\",\"state\":\"running\","
      + "\"startedAt\":\"2026-10-07T00:00:00Z\",\"plannedEnd\":\"2026-10-07T00:25:00Z\","
      + "\"remainingSeconds\":1500,\"pausedSeconds\":0,\"calendarTitle\":\"\","
      + "\"extendOptions\":[300,600,900,1500],\"pauseStopsClock\":true}"
  }
  func statusBody(_ claimed: Bool, _ id: Int) -> String {
    "{\"ok\":true,\"bridgeVersion\":1,\"display\":\"notch\",\"claimed\":\(claimed),"
      + "\"ttlSeconds\":3,\"session\":\(sessionJSON(id))}"
  }

  /// One request per connection, driven by an immutable script fixed
  /// before the server starts: reply, hold-then-reply, or hold-then-close
  /// (a silent transport failure). Requests are recorded under a lock and
  /// read back only through a snapshot.
  final class ScriptedDaemon {
    enum Step {
      case reply(String)
      case hold(String)
      case holdThenClose
    }

    let listener: Int32
    private let script: [Step]
    private let lock = NSLock()
    private var requests: [BridgeValue] = []
    private var stop = false
    private let served = DispatchSemaphore(value: 0)
    /// Test code signals this to release a held reply.
    let hold = DispatchSemaphore(value: 0)
    private(set) var bound = false

    init(listener: Int32, script: [Step]) {
      self.listener = listener
      self.script = script
      bound = listen(listener, 8) == 0
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    func all() -> [BridgeValue] { lock.lock(); defer { lock.unlock() }; return requests }

    func serve() {
      defer { served.signal() }
      guard bound else { return }
      var index = 0
      while true {
        let fd = accept(listener, nil, nil)
        lock.lock(); let done = stop; lock.unlock()
        if done { if fd >= 0 { Darwin.close(fd) }; return }
        if fd < 0 { continue }
        handle(fd, index: index)
        index += 1
      }
    }

    private func handle(_ fd: Int32, index: Int) {
      defer { Darwin.close(fd) }
      var timeout = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var yes: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
      var bytes = [UInt8]()
      var chunk = [UInt8](repeating: 0, count: 4096)
      let deadline = Date().addingTimeInterval(2)
      while !bytes.contains(0x0A), bytes.count < 4096, Date() < deadline {
        let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, min($0.count, 4096 - bytes.count), 0) }
        guard n > 0 else { return }
        bytes.append(contentsOf: chunk.prefix(n))
      }
      guard let newline = bytes.firstIndex(of: 0x0A) else { return }
      guard let request = try? BridgeValue.parse(
        String(decoding: bytes.prefix(newline), as: UTF8.self))
      else { return }
      lock.lock(); requests.append(request); lock.unlock()

      guard index < script.count else { return }
      var body: String?
      switch script[index] {
      case .reply(let text):
        body = text
      case .hold(let text):
        _ = hold.wait(timeout: .now() + 3)
        body = text
      case .holdThenClose:
        _ = hold.wait(timeout: .now() + 3)
      }
      guard let body else { return }
      (body + "\n").withCString { pointer in
        var offset = 0
        let size = strlen(pointer)
        while offset < size {
          let sent = send(fd, pointer + offset, size - offset, 0)
          guard sent > 0 else { return }
          offset += sent
        }
      }
    }

    /// Stops the server: the accept loop exits once the listener is gone.
    /// Returns false if it did not exit inside the bound.
    @discardableResult
    func closeOwned() -> Bool {
      lock.lock(); stop = true; lock.unlock()
      Darwin.shutdown(listener, SHUT_RDWR)
      Darwin.close(listener)
      hold.signal()
      return served.wait(timeout: .now() + 2) == .success
    }
  }

  do {
    // Scripted replies, one per request index, fixed before serving.
    let refusal3 = "{\"ok\":false,\"bridgeVersion\":1,\"error\":\"session 3 is not the current session\"}"
    let releaseAck = "{\"ok\":true,\"bridgeVersion\":1,\"claimed\":false,\"session\":null}"
    let incompatible = "{\"ok\":false,\"error\":\"unknown command: notchBridge\"}"
    let script: [ScriptedDaemon.Step] = [
      .reply(statusBody(true, 3)),    // 0 claim
      .hold(statusBody(true, 4)),     // 1 held renew
      .reply(refusal3),               // 2 queued pauseFor refused (stale id)
      .reply(refusal3),               // 3 queued extend refused
      .hold(statusBody(true, 4)),     // 4 held claim
      .reply(releaseAck),             // 5 release
      .reply(statusBody(true, 4)),    // 6 new claim
      .reply(statusBody(true, 4)),    // 7 extend for id 4 accepted
      .holdThenClose,                 // 8 held renew dies mid-request
      .reply(statusBody(true, 4)),    // 9 claim back
      .hold(incompatible),            // 10 held renew answers incompatible
    ]
    let (directory, listener, boundOK) = bindDaemon("nba")
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let daemon = ScriptedDaemon(listener: listener, script: script)
    check("queue test socket binds and listens", boundOK && daemon.bound)
    DispatchQueue.global().async { daemon.serve() }

    let client = FocusBridgeClient(focusDir: directory)
    var actionProblems: [String] = []
    var statusEvents = 0
    client.onActionProblem = { actionProblems.append($0) }
    client.onStatus = { _ in statusEvents += 1 }

    func pump(until condition: () -> Bool, _ seconds: TimeInterval = 2) {
      let deadline = Date().addingTimeInterval(seconds)
      while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    client.tick(active: true)
    pump { client.claimed }
    check("queue test: claim lands", client.claimed && client.last.session?.id == 3)

    guard let session3 = client.last.session else {
      check("queue test: session 3 snapshot present", false, "claim reply had no session")
      check("queue test: the fake daemon exited", daemon.closeOwned())
      return
    }
    client.tick(active: true)  // the held renew
    pump { daemon.count == 2 }
    client.action("pauseFor", session: session3, seconds: 300)
    client.action("extend", session: session3, seconds: 600)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check("queue test: nothing sent while the renew is in flight", daemon.count == 2, "\(daemon.count)")
    daemon.hold.signal()
    pump { daemon.count == 4 }
    pump { actionProblems.count == 2 }
    let seen = daemon.all()
    if seen.count == 4, let first = seen.last(where: { $0["action"]?.stringValue == "pauseFor" }),
      let second = seen.last(where: { $0["action"]?.stringValue == "extend" }),
      seen[2] == first, seen[3] == second
    {
      check("queue test: actions drain in FIFO order with the original ids, exactly once",
        first["seconds"]?.intValue == 300 && first["sessionId"]?.intValue == 3
          && first["owner"]?.stringValue == client.owner
          && second["seconds"]?.intValue == 600 && second["sessionId"]?.intValue == 3
          && second["owner"]?.stringValue == client.owner,
        "\(seen)")
    } else {
      check("queue test: actions drain in FIFO order with the original ids, exactly once", false,
        "\(seen.count) requests reached the daemon")
    }
    check("queue test: the backend's stale-id refusals surface", actionProblems.count == 2
      && actionProblems.allSatisfy { $0.contains("session 3") }, "\(actionProblems)")
    check("queue test: the known refusals cleared the stale snapshot",
      client.last.session == nil && client.last.compatible)

    // A release behind a held claim kills the queued action; only the
    // release goes out, then a fresh claim and an id-4 action work.
    client.tick(active: true)
    pump { daemon.count == 5 }
    client.action("pause", session: session3, seconds: nil)
    client.release()
    daemon.hold.signal()
    pump { daemon.count == 6 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let afterRelease = daemon.all()
    check("queue test: release follows the held claim and the queued pause never leaves",
      afterRelease.count == 6 && afterRelease[5]["op"]?.stringValue == "release",
      "\(afterRelease.map { $0["op"]?.stringValue ?? $0["action"]?.stringValue ?? "?" })")
    let eventsBeforeClaim = statusEvents
    client.tick(active: true)
    pump { statusEvents > eventsBeforeClaim && client.claimed }
    check("queue test: the new claim's snapshot is id 4", client.last.session?.id == 4)
    if let session4 = client.last.session {
      let eventsBeforeExtend = statusEvents
      client.action("extend", session: session4, seconds: 600)
      pump { statusEvents > eventsBeforeExtend }
      let tail = daemon.all().last
      check("queue test: a fresh action for the new session works",
        tail?["action"]?.stringValue == "extend" && tail?["sessionId"]?.intValue == 4
          && tail?["seconds"]?.intValue == 600 && daemon.count == 8,
        "\(tail?.serialized() ?? "")")
    } else {
      check("queue test: a fresh action for the new session works", false, "no session after claim")
    }

    // A held renew that dies silently is a transport failure: the queued
    // actions are cancelled with a visible problem and never leave.
    client.tick(active: true)
    pump { daemon.count == 9 }
    if let current = client.last.session {
      client.action("pause", session: current, seconds: nil)
      client.action("extend", session: current, seconds: 900)
    }
    let problemsBefore = actionProblems.count
    daemon.hold.signal()
    pump { actionProblems.count > problemsBefore }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("queue test: a dead socket clears the queued actions with a problem",
      daemon.count == 9 && actionProblems.count > problemsBefore && !client.last.present,
      "\(daemon.count) requests, \(actionProblems)")

    // Reclaim, then a held renew that answers with an incompatible reply:
    // same clearing, and the daemon marks the bridge degraded.
    let eventsBeforeClaim2 = statusEvents
    client.tick(active: true)
    pump { statusEvents > eventsBeforeClaim2 && client.claimed }
    client.tick(active: true)
    pump { daemon.count == 11 }
    if let current = client.last.session {
      client.action("pause", session: current, seconds: nil)
      client.action("extend", session: current, seconds: 300)
    }
    let problemsBefore2 = actionProblems.count
    daemon.hold.signal()
    pump { !client.last.compatible || actionProblems.count > problemsBefore2 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("queue test: an incompatible reply clears the queued actions with a problem",
      daemon.count == 11 && !client.last.compatible && actionProblems.count > problemsBefore2,
      "\(daemon.count) requests, \(actionProblems)")
    check("queue test: the fake daemon exited", daemon.closeOwned())
  }
}
