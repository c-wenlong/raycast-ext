import Foundation

// MARK: - Loopback block page server
//
// A tiny HTTP/1.1 server on 127.0.0.1 and a random free port that serves the
// block page and takes the Snooze form (PLAN.md "Blocking"). BSD sockets like
// the daemon's own unix socket: an accept thread, one request per connection,
// each handled on a global queue and closed after the response.
//
//   GET  /blocked?host=&redirect=&token=   200 block page (400 without host)
//   POST /snooze  host=&token=&redirect=   303 to redirect (http/https only, else /blank) or 403
//   GET  /snooze                           403
//   GET  /blank                            200 empty dark page
//   GET  /health                           200 "ok"
//   anything else                          404 (405 for a known path with the wrong method)
//
// Requests over 16 KB, malformed ones and a Host header other than this
// server's own origin (DNS rebinding) get 400; reading gives up after 5 s.

/// One parsed request.
struct BlockRequest: Equatable {
  var method: String
  var path: String
  var query: [String: String]
  var headers: [String: String]  // lowercased names
  var body: Data
}

/// One response, rendered by `BlockServer.serialize`.
struct BlockResponse: Equatable {
  var status: Int
  var headers: [(String, String)]
  var body: Data

  static func == (a: BlockResponse, b: BlockResponse) -> Bool {
    a.status == b.status && a.body == b.body && a.headers.map { "\($0.0): \($0.1)" } == b.headers.map { "\($0.0): \($0.1)" }
  }

  static func html(_ status: Int, _ page: String) -> BlockResponse {
    BlockResponse(status: status, headers: [("Content-Type", "text/html; charset=utf-8")], body: Data(page.utf8))
  }

  static func text(_ status: Int, _ text: String) -> BlockResponse {
    BlockResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(text.utf8))
  }

  static func redirect(_ location: String) -> BlockResponse {
    BlockResponse(status: 303, headers: [("Location", location), ("Content-Type", "text/plain; charset=utf-8")], body: Data())
  }
}

final class BlockServer {
  static let maxRequest = 16 * 1024
  static let readTimeout: TimeInterval = 5
  static let maxConnections = 32

  /// Characters left as they are in a query value: `urlQueryAllowed` minus
  /// the ones that would end or change a value (`& = + ? / #`) and `%`.
  static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/#%"))

  private let log: (String) -> Void
  private let lock = NSLock()
  private weak var _policy: BlockPolicy?
  private var listener: Int32 = -1
  private var _port: UInt16?
  private let slots = DispatchSemaphore(value: BlockServer.maxConnections)

  init(log: @escaping (String) -> Void) {
    self.log = log
  }

  /// Who answers `snooze` and supplies the session line; held weakly (the engine owns the blocker).
  var policy: BlockPolicy? {
    get { lock.lock(); defer { lock.unlock() }; return _policy }
    set { lock.lock(); _policy = newValue; lock.unlock() }
  }

  /// The bound port, or nil before `start` (or after `shutdown`).
  var port: UInt16? {
    lock.lock(); defer { lock.unlock() }
    return _port
  }

  /// "http://127.0.0.1:<port>", the origin every block page lives on.
  var origin: String { "http://127.0.0.1:\(port ?? 0)" }

  // MARK: Lifecycle

  /// Binds 127.0.0.1 on a free port and starts accepting. Does nothing when already up.
  func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard _port == nil else { return }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BlockServerError("socket() failed: errno \(errno)") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(fd, 16) == 0 else {
      let code = errno
      close(fd)
      throw BlockServerError("could not listen on 127.0.0.1: errno \(code)")
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    listener = fd
    _port = UInt16(bigEndian: actual.sin_port)
    signal(SIGPIPE, SIG_IGN)
    let thread = Thread { [weak self] in self?.acceptLoop(fd) }
    thread.name = "focus.block-server"
    thread.start()
    log("block page server on 127.0.0.1:\(_port!)")
  }

  /// Stops accepting (tests; the daemon keeps the server for its lifetime).
  func shutdown() {
    lock.lock()
    let fd = listener
    listener = -1
    _port = nil
    lock.unlock()
    if fd >= 0 {
      Darwin.shutdown(fd, SHUT_RDWR)
      close(fd)
    }
  }

  private func acceptLoop(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 {
        if errno == EINTR || errno == ECONNABORTED { continue }
        lock.lock()
        let stillOpen = listener == fd
        lock.unlock()
        if !stillOpen { return }
        usleep(10_000)
        continue
      }
      guard slots.wait(timeout: .now()) == .success else {
        close(client)
        continue
      }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        defer { self?.slots.signal() }
        guard let self else {
          close(client)
          return
        }
        self.serve(client)
      }
    }
  }

  // MARK: Connection

  private func serve(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: Int(Self.readTimeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let response: BlockResponse
    var unread = false
    switch Self.readRequest(fd, deadline: Date().addingTimeInterval(Self.readTimeout)) {
    case .request(let data):
      switch Self.parse(data) {
      case .success(let request): response = handle(request)
      case .failure(let problem):
        log("block page: bad request (\(problem.message))")
        response = .html(400, BlockPage.plain("Bad request"))
      }
    case .tooLarge:
      log("block page: request over \(Self.maxRequest) bytes refused")
      response = .html(400, BlockPage.plain("Request too large"))
      unread = true
    case .timedOut, .closed:
      close(fd)
      return
    }
    Self.send(fd, Self.serialize(response))
    if unread { Self.drain(fd) }
    close(fd)
  }

  enum ReadOutcome: Equatable { case request(Data), tooLarge, timedOut, closed }

  /// Reads one request: the head up to the blank line, then `Content-Length` bytes of body.
  static func readRequest(_ fd: Int32, deadline: Date) -> ReadOutcome {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let separator = Data("\r\n\r\n".utf8)
    var needed: Int?  // total bytes once the head is known
    while true {
      if let needed, data.count >= needed { return .request(data.prefix(needed)) }
      if needed == nil, let range = data.range(of: separator) {
        let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        let length = max(0, contentLength(head) ?? 0)
        let total = range.upperBound + length
        if total > maxRequest { return .tooLarge }
        needed = total
        continue
      }
      if data.count > maxRequest { return .tooLarge }
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { return .timedOut }
      var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&poller, 1, Int32(min(remaining * 1000, 5000).rounded(.up)))
      if ready < 0 && errno == EINTR { continue }
      guard ready > 0 else { return .timedOut }
      let count = recv(fd, &buffer, buffer.count, 0)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return data.isEmpty ? .closed : .request(data) }
      data.append(contentsOf: buffer[0..<count])
    }
  }

  /// Content-Length from a request head; nil when absent. A bad value reads
  /// as absent here and is refused by `parse`.
  private static func contentLength(_ head: String) -> Int? {
    for line in head.components(separatedBy: "\r\n").dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
        return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
      }
    }
    return nil
  }

  /// After refusing an oversized request: stop sending, then read a little so
  /// the close does not reset the connection before the 400 arrives.
  private static func drain(_ fd: Int32) {
    Darwin.shutdown(fd, SHUT_WR)
    var buffer = [UInt8](repeating: 0, count: 4096)
    var total = 0
    let deadline = Date().addingTimeInterval(1)
    while total < 256 * 1024, deadline.timeIntervalSinceNow > 0 {
      var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&poller, 1, 200) > 0 else { break }
      let count = recv(fd, &buffer, buffer.count, 0)
      guard count > 0 else { break }
      total += count
    }
  }

  private static func send(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard var pointer = raw.baseAddress else { return }
      var left = raw.count
      while left > 0 {
        let sent = Darwin.send(fd, pointer, left, 0)
        if sent < 0 && errno == EINTR { continue }
        guard sent > 0 else { return }
        pointer += sent
        left -= sent
      }
    }
  }

  // MARK: Parsing

  struct ParseProblem: Error, Equatable { var message: String }

  /// Parses a complete request (head and body). Pure, for the tests.
  static func parse(_ data: Data) -> Result<BlockRequest, ParseProblem> {
    guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return .failure(ParseProblem(message: "no blank line")) }
    guard let head = String(data: data[..<split.lowerBound], encoding: .utf8) else {
      return .failure(ParseProblem(message: "head is not UTF-8"))
    }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
    guard requestLine.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(requestLine[2]),
      !requestLine[0].isEmpty, requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
      requestLine[1].hasPrefix("/")
    else { return .failure(ParseProblem(message: "bad request line")) }

    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
        return .failure(ParseProblem(message: "bad header line"))
      }
      let name = line[..<colon].lowercased()
      guard !name.contains(" ") else { return .failure(ParseProblem(message: "bad header name")) }
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if name == "content-length", headers[name] != nil { return .failure(ParseProblem(message: "two Content-Length headers")) }
      headers[name] = value
    }
    if headers["transfer-encoding"] != nil { return .failure(ParseProblem(message: "Transfer-Encoding is not supported")) }
    var length = 0
    if let value = headers["content-length"] {
      guard !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let parsed = Int(value) else {
        return .failure(ParseProblem(message: "bad Content-Length"))
      }
      length = parsed
    }
    let body = data[split.upperBound...]
    guard body.count >= length else { return .failure(ParseProblem(message: "body shorter than Content-Length")) }

    let target = String(requestLine[1])
    let path: String
    let query: [String: String]
    if let mark = target.firstIndex(of: "?") {
      path = String(target[..<mark])
      query = parseForm(String(target[target.index(after: mark)...]))
    } else {
      path = target
      query = [:]
    }
    return .success(BlockRequest(
      method: String(requestLine[0]), path: path, query: query, headers: headers, body: Data(body.prefix(length))))
  }

  /// `a=1&b=%20x+y` → ["a": "1", "b": " x y"]: form and query decoding
  /// (`+` is a space). The first of a repeated key wins; an undecodable value is dropped.
  static func parseForm(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let decode = { (s: Substring) in s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
      guard let key = decode(parts[0]), let value = decode(parts.count > 1 ? parts[1] : "") else { continue }
      if out[key] == nil { out[key] = value }
    }
    return out
  }

  /// Percent-encodes one query value (see `queryValueAllowed`).
  static func encodeQueryValue(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
  }

  /// The block page URL a tab is sent to. Each component is encoded as a query value.
  func pageURL(host: String, redirect: String, token: String) -> URL {
    Self.pageURL(origin: origin, host: host, redirect: redirect, token: token)
  }

  static func pageURL(origin: String, host: String, redirect: String, token: String) -> URL {
    let query = [("host", host), ("redirect", redirect), ("token", token)]
      .map { "\($0.0)=\(encodeQueryValue($0.1))" }.joined(separator: "&")
    return URL(string: "\(origin)/blocked?\(query)")!
  }

  /// The redirect to follow after a snooze: an absolute http or https URL
  /// with a host, re-serialised by Foundation; nil for anything else.
  static func safeRedirect(_ text: String) -> String? {
    guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return nil }
    let out = url.absoluteString
    guard !out.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == " " }) else { return nil }
    return out
  }

  // MARK: Routing

  /// Answers one parsed request. Runs on a connection's queue.
  func handle(_ request: BlockRequest) -> BlockResponse {
    guard let port, Self.hostHeaderIsOurs(request.headers["host"], port: port) else {
      log("block page: refused a request for host \"\(Self.forLog(request.headers["host"] ?? ""))\"")
      return .html(400, BlockPage.plain("Bad request"))
    }
    switch request.path {
    case "/blocked":
      guard request.method == "GET" else { return methodNotAllowed("GET") }
      guard let host = request.query["host"], !host.isEmpty else { return .html(400, BlockPage.plain("Missing host")) }
      let policy = self.policy
      return .html(200, BlockPage.render(
        host: host, redirect: request.query["redirect"] ?? "", token: request.query["token"] ?? "",
        snoozeSeconds: policy?.snoozeSeconds ?? 180, session: policy?.sessionView))
    case "/snooze":
      guard request.method == "POST" else {
        log("block page: refused \(request.method) /snooze")
        return .html(403, BlockPage.notAllowed())
      }
      return snooze(request)
    case "/blank":
      guard request.method == "GET" else { return methodNotAllowed("GET") }
      return .html(200, BlockPage.blank())
    case "/health":
      guard request.method == "GET" else { return methodNotAllowed("GET") }
      return .text(200, "ok")
    default:
      return .html(404, BlockPage.plain("Not found"))
    }
  }

  private func snooze(_ request: BlockRequest) -> BlockResponse {
    if let origin = request.headers["origin"], origin != "null", origin != self.origin,
      origin != "http://localhost:\(port ?? 0)"
    {
      log("block page: refused a snooze posted from \(Self.forLog(origin))")
      return .html(403, BlockPage.notAllowed())
    }
    let form = Self.parseForm(String(decoding: request.body, as: UTF8.self))
    let host = form["host"] ?? ""
    let token = form["token"] ?? ""
    guard !host.isEmpty, !token.isEmpty, let policy = self.policy, policy.snooze(host: host, token: token) else {
      log("block page: refused a snooze for \(host.isEmpty ? "(no host)" : Self.forLog(host))\(token.isEmpty ? " without a token" : "")")
      return .html(403, BlockPage.notAllowed())
    }
    return .redirect(Self.safeRedirect(form["redirect"] ?? "") ?? "/blank")
  }

  private func methodNotAllowed(_ allow: String) -> BlockResponse {
    var response = BlockResponse.html(405, BlockPage.plain("Method not allowed"))
    response.headers.append(("Allow", allow))
    return response
  }

  /// A request-supplied value made safe for one log line: control characters
  /// escaped, at most 200 characters.
  static func forLog(_ text: String) -> String {
    let flat = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "\\u{\(String($0.value, radix: 16))}" : String($0) }
      .joined()
    return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
  }

  /// DNS rebinding guard: the Host header must name this server itself.
  static func hostHeaderIsOurs(_ value: String?, port: UInt16) -> Bool {
    guard let value = value?.lowercased() else { return false }
    return value == "127.0.0.1:\(port)" || value == "localhost:\(port)"
  }

  // MARK: Writing

  static let reasons = [
    200: "OK", 303: "See Other", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
  ]

  /// Status line, headers (with the fixed security headers) and body.
  static func serialize(_ response: BlockResponse) -> Data {
    var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Status")\r\n"
    let fixed: [(String, String)] = [
      ("Content-Length", String(response.body.count)),
      ("Connection", "close"),
      ("Cache-Control", "no-store"),
      ("Referrer-Policy", "no-referrer"),
      ("X-Content-Type-Options", "nosniff"),
      ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"),
    ]
    for (name, value) in response.headers + fixed {
      head += "\(name): \(value)\r\n"
    }
    head += "\r\n"
    return Data(head.utf8) + response.body
  }
}

struct BlockServerError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}
