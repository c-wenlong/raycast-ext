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
}
