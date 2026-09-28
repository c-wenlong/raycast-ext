import Foundation

// MARK: - Site blocking
//
// Puts the loopback block page server and the browser tab watcher behind the
// `SiteBlocker` interface the engine drives (Blocking.swift). The server
// starts on the first `start` and stays up for the daemon's lifetime, so a
// block page left open in a tab can still answer after a pause or a finished
// session (with 403 once its token is dead); `stop` only stops polling.

/// The site half of blocking: the engine calls `start`, `stop` and `pollNow`.
final class SiteBlockerService: SiteBlocker {
  let server: BlockServer
  private(set) var watch: BrowserWatch!
  private let log: (String) -> Void
  private let lock = NSLock()

  init(log: @escaping (String) -> Void, watch makeWatch: ((BlockServer) -> BrowserWatch)? = nil) {
    self.log = log
    let server = BlockServer(log: log)
    self.server = server
    watch = makeWatch?(server) ?? BrowserWatch(
      log: log,
      page: { [weak server] host, redirect, token in
        guard let server, server.port != nil else { return nil }
        return server.pageURL(host: host, redirect: redirect, token: token)
      },
      isOwnPage: { [weak server] url in
        guard let server, server.port != nil else { return false }
        return url.hasPrefix(server.origin + "/")
      })
  }

  func start(policy: BlockPolicy) {
    lock.lock()
    server.policy = policy
    if server.port == nil {
      do {
        try server.start()
      } catch {
        log("block page server did not start: \(error); sites will not be blocked")
      }
    }
    lock.unlock()
    watch.start(policy: policy)
  }

  func stop() {
    watch.stop()
  }

  func pollNow() {
    watch.pollNow()
  }
}

/// The site blocker the daemon hands to the engine (`engine.siteBlocker = makeSiteBlocker(log: log)`).
func makeSiteBlocker(log: @escaping (String) -> Void) -> SiteBlocker {
  SiteBlockerService(log: log)
}
