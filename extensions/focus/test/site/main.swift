// Checks of the site half of blocking: the block page HTML, the loopback
// server over real sockets, URL encoding, host extraction and the tab
// watcher over a fake browser. Run with scripts/test-site.sh. No Core, no
// real browser: the only child process is osascript running a script that
// sends no Apple events.
//
// `--demo [seconds] [bundle,bundle|none]` instead starts the real server and
// watcher with a fake policy that blocks example.com (in Chrome and Dia by
// default), prints the port and a sample page URL, and keeps running for the
// live check in SITE.md.

import AppKit
import Foundation

var failures = 0
var passes = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  " + detail()))
  if ok { passes += 1 } else { failures += 1 }
}

// MARK: Fakes

final class FakePolicy: BlockPolicy {
  private let lock = NSLock()
  private var _session: SessionView?
  private var _token: String
  private var _blocked: Set<String>
  private var _snoozed: Set<String> = []
  private(set) var snoozes: [String] = []
  private(set) var refusedSnoozes = 0
  private(set) var recorded: [String] = []
  var snoozeSeconds: Int
  var browsers: [String]

  init(blocked: Set<String>, token: String = "tok-123", snoozeSeconds: Int = 180, browsers: [String] = [], session: SessionView? = nil) {
    _blocked = blocked
    _token = token
    self.snoozeSeconds = snoozeSeconds
    self.browsers = browsers
    _session = session
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var sessionView: SessionView? {
    get { locked { _session } }
    set { locked { _session = newValue } }
  }
  var token: String {
    get { locked { _token } }
    set { locked { _token = newValue } }
  }
  var recordedHosts: [String] { locked { recorded } }
  var grantedSnoozes: [String] { locked { snoozes } }

  func isBlocked(host: String) -> Bool {
    locked {
      guard !_token.isEmpty, !_snoozed.contains(host) else { return false }
      return _blocked.contains { host == $0 || host.hasSuffix("." + $0) }
    }
  }

  func snooze(host: String, token: String) -> Bool {
    locked {
      guard !_token.isEmpty, token == _token else {
        refusedSnoozes += 1
        return false
      }
      _snoozed.insert(host)
      snoozes.append(host)
      return true
    }
  }

  func recordBlocked(host: String) {
    locked { recorded.append(host) }
  }
}

final class Logs {
  private let lock = NSLock()
  private var lines: [String] = []
  func add(_ line: String) {
    lock.lock()
    lines.append(line)
    lock.unlock()
  }
  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
  func count(_ fragment: String) -> Int { all.filter { $0.contains(fragment) }.count }
}

func session(goal: String = "Deep Work", state: String = "running", remaining: Int = 2680) -> SessionView {
  let now = Date()
  return SessionView(
    id: 1, goal: goal, state: state, startedAt: now.addingTimeInterval(-600), plannedEnd: now.addingTimeInterval(TimeInterval(remaining)),
    remainingSeconds: remaining, pausedSeconds: 0, calendarTitle: "Work", extendOptions: [300])
}

// MARK: Demo mode

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--demo" {
  let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 60 : 60
  let policy = FakePolicy(
    blocked: ["example.com"], token: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
    browsers: arguments.count > 2 ? arguments[2].split(separator: ",").map(String.init).filter { $0 != "none" }
      : ["com.google.Chrome", "company.thebrowser.dia"],
    session: session())
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm:ss.SSS"
  let blocker = makeSiteBlocker(log: { print("[\(formatter.string(from: Date()))] \($0)"); fflush(stdout) })
  blocker.start(policy: policy)
  let service = blocker as! SiteBlockerService
  print("port \(service.server.port ?? 0)")
  print("page \(service.server.pageURL(host: "instagram.com", redirect: "https://www.instagram.com/", token: policy.token))")
  fflush(stdout)
  let app = NSApplication.shared
  app.setActivationPolicy(.prohibited)
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print("recorded \(policy.recordedHosts)")
    print("snoozed \(policy.grantedSnoozes)")
    exit(0)
  }
  app.run()
}

// MARK: Permission probe

check("probe: exit 0 is granted", BrowserWatch.probeVerdict(ScriptResult(status: 0, output: "Google Chrome\n", error: "")) == BrowserWatch.granted)
check("probe: -1743 is denied", BrowserWatch.probeVerdict(ScriptResult(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Google Chrome. (-1743)")) == BrowserWatch.denied)
check("probe: -600 passes through", BrowserWatch.probeVerdict(ScriptResult(status: 1, output: "", error: "execution error: Google Chrome got an error: Application isn't running. (-600)")) == BrowserWatch.notRunning)
check("probe: a killed script counts as not running", BrowserWatch.probeVerdict(ScriptResult(status: 15, output: "", error: "")) == BrowserWatch.notRunning)
check("probe: the probe is the tab read with a long timeout", BrowserWatch.probeScript("com.google.Chrome") == BrowserWatch.readScript("com.google.Chrome").replacingOccurrences(of: "with timeout of 3 seconds", with: "with timeout of 900 seconds"))
check("probe: the probe still reads the active tab", BrowserWatch.probeScript("com.google.Chrome").contains("URL of active tab of front window"))
check("probe: no window still means consent was given", BrowserWatch.probeVerdict(ScriptResult(status: 1, output: "", error: "execution error: Google Chrome got an error: Can’t get window 1. Invalid index. (-1719)")) == BrowserWatch.granted)
check("probe: a pending prompt (-1712) is passed through, not cached", BrowserWatch.probeVerdict(ScriptResult(status: 1, output: "", error: "execution error: Google Chrome got an error: AppleEvent timed out. (-1712)")) == -1712)

// MARK: Page

let hostile = "<img src=x onerror=alert(1)>.evil.com"
let hostilePage = BlockPage.render(
  host: hostile, redirect: "\"><script>alert(1)</script>", token: "a\"b'c<d>&e", snoozeSeconds: 180,
  session: session(goal: "<b>Goal</b> & 'more'"))
check("page: hostile host escaped", hostilePage.contains("&lt;img src=x onerror=alert(1)&gt;.evil.com has been blocked"))
check("page: no raw <img", !hostilePage.contains("<img"))
check("page: no <script> at all", !hostilePage.lowercased().contains("<script"))
check("page: redirect escaped in the hidden field", hostilePage.contains("name=\"redirect\" value=\"&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;\""))
check("page: token escaped in the hidden field", hostilePage.contains("name=\"token\" value=\"a&quot;b&#39;c&lt;d&gt;&amp;e\""))
check("page: goal escaped", hostilePage.contains("&lt;b&gt;Goal&lt;/b&gt; &amp; &#39;more&#39; · 44:40 left"))
check("page: host escaped in the hidden field too", hostilePage.contains("name=\"host\" value=\"&lt;img src=x onerror=alert(1)&gt;.evil.com\""))
// With every quoted attribute value emptied, no tag may carry an on* handler.
let tagsOnly = hostilePage.replacingOccurrences(of: "\"[^\"]*\"", with: "\"\"", options: .regularExpression)
check("page: no event handler attributes", tagsOnly.range(of: "<[^>]*\\son[a-z]+=", options: .regularExpression) == nil)
check("page: form posts to /snooze", hostilePage.contains("<form method=\"post\" action=\"/snooze\">"))
check("page: title", hostilePage.contains("<title>Blocked by Focus</title>"))
check("page: footer", hostilePage.contains("End your focus session to access this page"))
check("escape: all five", BlockPage.escape("&<>\"'x") == "&amp;&lt;&gt;&quot;&#39;x", BlockPage.escape("&<>\"'x"))
check("escape: unicode kept", BlockPage.escape("日本.jp") == "日本.jp")

check("label: 180 s", BlockPage.snoozeLabel(seconds: 180) == "Snooze for 3 minutes", BlockPage.snoozeLabel(seconds: 180))
check("label: 45 s", BlockPage.snoozeLabel(seconds: 45) == "Snooze for 45 seconds", BlockPage.snoozeLabel(seconds: 45))
check("label: 600 s", BlockPage.snoozeLabel(seconds: 600) == "Snooze for 10 minutes", BlockPage.snoozeLabel(seconds: 600))
check("label: 60 s", BlockPage.snoozeLabel(seconds: 60) == "Snooze for 1 minute", BlockPage.snoozeLabel(seconds: 60))
check("label: 1 s", BlockPage.snoozeLabel(seconds: 1) == "Snooze for 1 second", BlockPage.snoozeLabel(seconds: 1))
check("label: 90 s", BlockPage.snoozeLabel(seconds: 90) == "Snooze for 1 minute 30 seconds", BlockPage.snoozeLabel(seconds: 90))
for (seconds, label) in [(180, "Snooze for 3 minutes"), (45, "Snooze for 45 seconds"), (600, "Snooze for 10 minutes")] {
  let page = BlockPage.render(host: "x.com", redirect: "", token: "t", snoozeSeconds: seconds, session: nil)
  check("page: button reads \(label)", page.contains("<span>\(label)</span></button>"))
}

let plainPage = BlockPage.render(host: "youtube.com", redirect: "https://youtube.com/", token: "t", snoozeSeconds: 180, session: nil)
check("page: no session line when idle", !plainPage.contains("class=\"session\""))
check("session line: running", BlockPage.sessionLine(session()) == "Deep Work · 44:40 left", BlockPage.sessionLine(session()) ?? "nil")
check("session line: over an hour", BlockPage.sessionLine(session(remaining: 3725)) == "Deep Work · 1:02:05 left")
check("session line: paused", BlockPage.sessionLine(session(state: "paused")) == "Deep Work · paused")
check("session line: ending", BlockPage.sessionLine(session(state: "ending", remaining: 0)) == "Deep Work · time's up")
check("session line: empty goal", BlockPage.sessionLine(session(goal: " ")) == "44:40 left")
check("session line: nil", BlockPage.sessionLine(nil) == nil)
for page in [hostilePage, plainPage, BlockPage.notAllowed(), BlockPage.blank(), BlockPage.plain("<x>")] {
  check("no script and no external URL in \(page.count)-byte page",
    !page.lowercased().contains("<script") && !page.contains("src=\"http") && !page.contains("href=") && !page.contains("url("))
}

// MARK: URL encoding

for (host, redirect) in [
  ("youtube.com", "https://www.youtube.com/watch?v=abc&t=10#frag"),
  ("a&b=c.com", "https://x.com/a b?q=1&r=2+3#x"),
  ("日本.jp", "https://日本.jp/パス?クエリ=値#断片"),
  ("per%cent", "https://x.com/?a=%20&b=%zz/?#"),
  ("[::1]", "http://[::1]:8080/p?x=y"),
] {
  let url = BlockServer.pageURL(origin: "http://127.0.0.1:4242", host: host, redirect: redirect, token: "t&k=n#1 +")
  let query = url.absoluteString.components(separatedBy: "?").dropFirst().joined(separator: "?")
  let back = BlockServer.parseForm(query)
  check("pageURL round trip: \(host)", back == ["host": host, "redirect": redirect, "token": "t&k=n#1 +"], "\(back)")
  check("pageURL: one ? and two & for \(host)",
    url.absoluteString.filter { $0 == "?" }.count == 1 && url.absoluteString.filter { $0 == "&" }.count == 2
      && !url.absoluteString.contains("#") && !url.absoluteString.contains(" "), url.absoluteString)
  check("pageURL: path /blocked for \(host)", url.path == "/blocked" && url.host == "127.0.0.1" && url.port == 4242)
}
check("parseForm: + is a space", BlockServer.parseForm("a=1+2&b=%2B") == ["a": "1 2", "b": "+"])
check("parseForm: first key wins, empty value kept", BlockServer.parseForm("a=1&a=2&b=&c") == ["a": "1", "b": "", "c": ""])

check("safeRedirect: https", BlockServer.safeRedirect("https://youtube.com/watch?v=1") == "https://youtube.com/watch?v=1")
check("safeRedirect: HTTP upper", BlockServer.safeRedirect("HTTP://x.com/") != nil)
check("safeRedirect: javascript", BlockServer.safeRedirect("javascript:alert(1)") == nil)
check("safeRedirect: data", BlockServer.safeRedirect("data:text/html,<b>x</b>") == nil)
check("safeRedirect: relative", BlockServer.safeRedirect("//evil.com/x") == nil && BlockServer.safeRedirect("/snooze") == nil)
check("safeRedirect: no host", BlockServer.safeRedirect("http://") == nil && BlockServer.safeRedirect("https:///x") == nil)
check("safeRedirect: header injection", BlockServer.safeRedirect("https://x.com/\r\nSet-Cookie: a=b") == nil)
check("safeRedirect: ftp", BlockServer.safeRedirect("ftp://x.com/") == nil)
check("safeRedirect: empty", BlockServer.safeRedirect("") == nil)
if let unicode = BlockServer.safeRedirect("https://example.com/パス?q=値") {
  check("safeRedirect: non-ASCII comes out ASCII", unicode.allSatisfy(\.isASCII), unicode)
} else {
  check("safeRedirect: non-ASCII path accepted", false)
}

// MARK: Request parsing

func parsed(_ text: String) -> BlockRequest? { try? BlockServer.parse(Data(text.utf8)).get() }
let get = parsed("GET /blocked?host=a.com&x=%20 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nX-Thing:  v \r\n\r\n")
check("parse: GET", get?.method == "GET" && get?.path == "/blocked" && get?.query == ["host": "a.com", "x": " "])
check("parse: headers lowercased and trimmed", get?.headers["x-thing"] == "v" && get?.headers["host"] == "127.0.0.1:1")
let post = parsed("POST /snooze HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhost=")
check("parse: POST body", post.map { String(decoding: $0.body, as: UTF8.self) } == "host=")
check("parse: bad request line", parsed("HELLO\r\n\r\n") == nil && parsed("GET x HTTP/1.1\r\n\r\n") == nil)
check("parse: bad version", parsed("GET / HTTP/2\r\n\r\n") == nil)
check("parse: lowercase method", parsed("get / HTTP/1.1\r\n\r\n") == nil)
check("parse: short body", parsed("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc") == nil)
check("parse: bad content length", parsed("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == nil)
check("parse: two content lengths", parsed("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na") == nil)
check("parse: chunked refused", parsed("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == nil)
check("parse: folded header refused", parsed("GET / HTTP/1.1\r\n X: y\r\n\r\n") == nil)
check("host header: ours", BlockServer.hostHeaderIsOurs("127.0.0.1:80", port: 80) && BlockServer.hostHeaderIsOurs("LOCALHOST:80", port: 80))
check("host header: rebinding refused", !BlockServer.hostHeaderIsOurs("evil.com:80", port: 80) && !BlockServer.hostHeaderIsOurs(nil, port: 80)
  && !BlockServer.hostHeaderIsOurs("127.0.0.1:81", port: 80))
check("forLog: control characters escaped", BlockServer.forLog("a\nb\u{1b}") == "a\\u{a}b\\u{1b}", BlockServer.forLog("a\nb\u{1b}"))

// MARK: Server over sockets

struct HTTPReply {
  var status: Int
  var headers: [String: String]
  var body: String
}

/// Sends raw bytes to the server and reads until it closes.
func exchange(_ port: UInt16, _ raw: Data, readTimeout: Int = 8) -> HTTPReply? {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  var on: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  var timeout = timeval(tv_sec: readTimeout, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard connected == 0 else { return nil }
  raw.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let sent = send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
      if sent <= 0 { break }
      offset += sent
    }
  }
  var data = Data()
  var chunk = [UInt8](repeating: 0, count: 8192)
  while true {
    let count = recv(fd, &chunk, chunk.count, 0)
    if count <= 0 { break }
    data.append(contentsOf: chunk[0..<count])
  }
  guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
  let head = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
  let parts = head[0].split(separator: " ")
  guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
  var headers: [String: String] = [:]
  for line in head.dropFirst() {
    if let colon = line.firstIndex(of: ":") {
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
  }
  return HTTPReply(status: status, headers: headers, body: String(decoding: data[split.upperBound...], as: UTF8.self))
}

let serverLogs = Logs()
let server = BlockServer(log: serverLogs.add)
let policy = FakePolicy(blocked: ["youtube.com"], snoozeSeconds: 45, session: session())
server.policy = policy
do { try server.start() } catch { check("server starts", false, "\(error)") }
let port = server.port ?? 0
check("server: bound to a port", port > 0)
try? server.start()
check("server: second start keeps the port", server.port == port)

func request(_ method: String, _ target: String, headers: [String: String] = [:], body: String = "") -> HTTPReply? {
  var head = "\(method) \(target) HTTP/1.1\r\n"
  var all = ["Host": "127.0.0.1:\(port)"]
  all.merge(headers) { $1 }
  if !body.isEmpty || method == "POST" { all["Content-Length"] = String(body.utf8.count) }
  for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
  return exchange(port, Data((head + "\r\n" + body).utf8))
}

func form(_ values: [(String, String)]) -> String {
  values.map { "\($0.0)=\(BlockServer.encodeQueryValue($0.1))" }.joined(separator: "&")
}

let health = request("GET", "/health")
check("GET /health: 200 ok", health?.status == 200 && health?.body == "ok", "\(String(describing: health))")
check("responses close the connection", health?.headers["connection"] == "close")

let pageURL = server.pageURL(host: hostile, redirect: "https://youtube.com/watch?v=1&t=2", token: "tok-123")
check("pageURL: our origin", pageURL.absoluteString.hasPrefix("http://127.0.0.1:\(port)/blocked?host="), pageURL.absoluteString)
let target = pageURL.absoluteString.replacingOccurrences(of: "http://127.0.0.1:\(port)", with: "")
let blockedReply = request("GET", target)
check("GET /blocked: 200", blockedReply?.status == 200, "\(String(describing: blockedReply?.status))")
check("GET /blocked: html", blockedReply?.headers["content-type"] == "text/html; charset=utf-8")
check("GET /blocked: host escaped", blockedReply?.body.contains("&lt;img src=x onerror=alert(1)&gt;.evil.com has been blocked") == true)
check("GET /blocked: no raw markup from the host", blockedReply?.body.contains("<img") == false)
check("GET /blocked: label from policy (45 s)", blockedReply?.body.contains("Snooze for 45 seconds") == true)
check("GET /blocked: session line", blockedReply?.body.contains("Deep Work · 44:") == true)
check("GET /blocked: redirect in the form",
  blockedReply?.body.contains("name=\"redirect\" value=\"https://youtube.com/watch?v=1&amp;t=2\"") == true)
check("GET /blocked: CSP forbids scripts", blockedReply?.headers["content-security-policy"]?.contains("default-src 'none'") == true)
check("GET /blocked: no-store, no-referrer, nosniff",
  blockedReply?.headers["cache-control"] == "no-store" && blockedReply?.headers["referrer-policy"] == "no-referrer"
    && blockedReply?.headers["x-content-type-options"] == "nosniff")
check("GET /blocked without host: 400", request("GET", "/blocked?redirect=x&token=y")?.status == 400)
check("GET /blocked with empty host: 400", request("GET", "/blocked?host=")?.status == 400)
check("GET /blocked from another Host (rebinding): 400",
  request("GET", "/blocked?host=a.com", headers: ["Host": "evil.example:\(port)"])?.status == 400)
check("GET /blocked via localhost: 200", request("GET", "/blocked?host=a.com", headers: ["Host": "localhost:\(port)"])?.status == 200)
check("POST /blocked: 405", request("POST", "/blocked?host=a.com")?.status == 405)

let snoozed = request("POST", "/snooze", headers: ["Content-Type": "application/x-www-form-urlencoded", "Origin": "null"],
  body: form([("host", "youtube.com"), ("token", "tok-123"), ("redirect", "https://youtube.com/watch?v=1&t=2#c")]))
check("POST /snooze right token: 303", snoozed?.status == 303, "\(String(describing: snoozed?.status))")
check("POST /snooze: Location is the redirect", snoozed?.headers["location"] == "https://youtube.com/watch?v=1&t=2#c",
  snoozed?.headers["location"] ?? "nil")
check("POST /snooze: policy granted the snooze", policy.grantedSnoozes == ["youtube.com"], "\(policy.grantedSnoozes)")
check("snoozed host no longer blocked", !policy.isBlocked(host: "youtube.com"))

let wrong = request("POST", "/snooze", body: form([("host", "x.youtube.com"), ("token", "nope"), ("redirect", "https://x.youtube.com/")]))
check("POST /snooze wrong token: 403", wrong?.status == 403 && wrong?.body.contains("Not allowed") == true)
check("wrong token: no snooze granted", policy.grantedSnoozes == ["youtube.com"])
check("wrong token: refusal logged", serverLogs.count("refused a snooze for x.youtube.com") == 1, "\(serverLogs.all)")
check("POST /snooze without token: 403", request("POST", "/snooze", body: form([("host", "a.com")]))?.status == 403)
check("POST /snooze with no body: 403", request("POST", "/snooze")?.status == 403)
check("GET /snooze: 403", request("GET", "/snooze?host=a.com&token=tok-123")?.status == 403)
check("GET /snooze: nothing granted", policy.grantedSnoozes == ["youtube.com"])
check("GET /snooze: refusal logged", serverLogs.count("refused GET /snooze") == 1)
let crossSite = request("POST", "/snooze", headers: ["Origin": "https://evil.example"],
  body: form([("host", "b.com"), ("token", "tok-123"), ("redirect", "https://b.com/")]))
check("POST /snooze from another origin: 403", crossSite?.status == 403)
let scripted = request("POST", "/snooze", body: form([("host", "c.com"), ("token", "tok-123"), ("redirect", "javascript:alert(1)")]))
check("POST /snooze javascript: redirect → 303 /blank", scripted?.status == 303 && scripted?.headers["location"] == "/blank",
  "\(String(describing: scripted?.status)) \(scripted?.headers["location"] ?? "nil")")
let noRedirect = request("POST", "/snooze", body: form([("host", "d.com"), ("token", "tok-123")]))
check("POST /snooze without redirect → /blank", noRedirect?.headers["location"] == "/blank")
let blank = request("GET", "/blank")
check("GET /blank: 200 dark page", blank?.status == 200 && blank?.body.contains("background") == true)
policy.token = ""
check("POST /snooze after the session ended: 403",
  request("POST", "/snooze", body: form([("host", "e.com"), ("token", "tok-123")]))?.status == 403)
policy.token = "tok-123"

check("GET /nope: 404", request("GET", "/nope")?.status == 404)
check("GET /: 404", request("GET", "/")?.status == 404)
check("POST /health: 405", request("POST", "/health")?.status == 405)
check("malformed request: 400", exchange(port, Data("HELLO WORLD\r\n\r\n".utf8))?.status == 400)
check("missing Host: 400", exchange(port, Data("GET /health HTTP/1.1\r\n\r\n".utf8))?.status == 400)
let bigHead = "GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Pad: \(String(repeating: "a", count: 20_000))\r\n\r\n"
check("oversized head: 400", exchange(port, Data(bigHead.utf8))?.status == 400)
let bigBody = "POST /snooze HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 20000\r\n\r\n" + String(repeating: "b", count: 20_000)
check("oversized body: 400", exchange(port, Data(bigBody.utf8))?.status == 400)
let hugeLength = "POST /snooze HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 9223372036854775807\r\n\r\nx"
check("Content-Length of Int.max: 400, no overflow", exchange(port, Data(hugeLength.utf8))?.status == 400)
check("server still answers after it", request("GET", "/health")?.status == 200)
check("oversized: logged", serverLogs.count("over 16384 bytes") == 3, "\(serverLogs.all)")

// Parallel clients all get answers.
let group = DispatchGroup()
let okLock = NSLock()
var okCount = 0
for _ in 0..<24 {
  group.enter()
  DispatchQueue.global().async {
    if request("GET", "/health")?.status == 200 {
      okLock.lock()
      okCount += 1
      okLock.unlock()
    }
    group.leave()
  }
}
group.wait()
check("24 parallel requests answered", okCount == 24, "\(okCount)")

// A client that stalls mid-request is dropped after the 5 s read timeout.
let stallStart = Date()
let stalled = exchange(port, Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n".utf8), readTimeout: 10)
let stallTime = Date().timeIntervalSince(stallStart)
check("stalled request closed after ~5 s", stalled == nil && stallTime >= 4.5 && stallTime < 7, "\(stallTime) s")

// MARK: Host extraction

let hostCases: [(String, String?)] = [
  ("https://WWW.YouTube.com:443/watch?v=1", "www.youtube.com"),
  ("http://user:pass@Evil.com:8080/x", "evil.com"),
  ("http://youtube.com@evil.com/", "evil.com"),
  ("http://[::1]:8080/", "::1"),
  ("https://[2001:DB8::1]/p", "2001:db8::1"),
  ("https://example.com./", "example.com"),
  ("HTTPS://X.COM", "x.com"),
  ("  https://x.com/  ", "x.com"),
  ("chrome://newtab/", nil),
  ("file:///Users/x/a.html", nil),
  ("about:blank", nil),
  ("javascript:alert(1)", nil),
  ("data:text/html,hi", nil),
  ("view-source:https://x.com", nil),
  ("missing value", nil),
  ("", nil),
  ("https://", nil),
]
for (url, expected) in hostCases {
  let got = BrowserWatch.host(of: url)
  check("host(of: \(url)) = \(expected ?? "nil")", got == expected, got ?? "nil")
}
check("never blocked: loopback", ["localhost", "127.0.0.1", "::1", "app.localhost"].allSatisfy(BrowserWatch.neverBlocked))
check("never blocked: not others", !BrowserWatch.neverBlocked("localhost.evil.com") && !BrowserWatch.neverBlocked("youtube.com"))
check("bundle id: valid", BrowserWatch.isBundleID("com.google.Chrome") && BrowserWatch.isBundleID("company.thebrowser.dia"))
check("bundle id: script injection refused", !BrowserWatch.isBundleID("x\" then do shell script \"id") && !BrowserWatch.isBundleID(""))
check("scripts name the bundle and take URLs as arguments",
  BrowserWatch.readScript("com.google.Chrome").contains("application id \"com.google.Chrome\"")
    && BrowserWatch.redirectScript("com.google.Chrome").contains("item 2 of argv"))
check("errorNumber", ScriptResult(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Google Chrome. (-1743)\n").errorNumber == -1743)
check("errorNumber: none", ScriptResult(status: 1, output: "", error: "boom").errorNumber == nil)

// osascript itself, with no Apple events: arguments arrive untouched, errors carry their number.
let echoed = BrowserWatch.osascript("on run argv\nreturn item 1 of argv\nend run", ["https://x.com/?a=1&b=\"q\" 'r' #f"])
check("osascript: argument round trip", echoed.status == 0 && echoed.output == "https://x.com/?a=1&b=\"q\" 'r' #f\n", "\(echoed)")
let erred = BrowserWatch.osascript("error \"no\" number -1743", [])
check("osascript: error number parsed", erred.status != 0 && erred.errorNumber == -1743, "\(erred)")

// MARK: Watcher over a fake browser

let chrome = "com.google.Chrome"
let dia = "company.thebrowser.dia"

/// Browsers as the scripts see them: one active tab URL each.
final class FakeBrowsers {
  private let lock = NSLock()
  var tabs: [String: String] = [:]
  var running: Set<String> = []
  var permissions: [String: Int32] = [:]
  var askAnswer: [String: Int32] = [:]
  var asks: [String] = []
  var reads: [String: Int] = [:]
  var failWith: [String: String] = [:]  // bundle → stderr
  var ignoreSets = false  // the browser "does not navigate"
  var moveBeforeSet: String?  // the tab changes between read and write
  var promptOpen: DispatchSemaphore?  // an ask waits on this, like the real prompt
  var checks: [String: Int] = [:]  // no-prompt permission checks per bundle
  var sets = 0  // redirects written

  func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  func run(_ source: String, _ args: [String]) -> ScriptResult {
    locked {
      guard let bundle = [chrome, dia].first(where: { source.contains("application id \"\($0)\"") }) else {
        return ScriptResult(status: 1, output: "", error: "unknown target")
      }
      if let error = failWith[bundle] { return ScriptResult(status: 1, output: "", error: error) }
      if source.contains("set URL of theTab") {
        if let moved = moveBeforeSet {
          tabs[bundle] = moved
          moveBeforeSet = nil
        }
        guard tabs[bundle] == args[0] else { return ScriptResult(status: 0, output: "moved\n", error: "") }
        sets += 1
        if !ignoreSets { tabs[bundle] = args[1] }
        return ScriptResult(status: 0, output: "ok\n", error: "")
      }
      reads[bundle, default: 0] += 1
      return ScriptResult(status: 0, output: (tabs[bundle] ?? "") + "\n", error: "")
    }
  }

  func permission(_ bundle: String, _ ask: Bool) -> Int32 {
    if ask {
      let prompt = locked { () -> DispatchSemaphore? in
        asks.append(bundle)
        return promptOpen
      }
      prompt?.wait()  // the user has not answered yet
    }
    return locked {
      if !ask { checks[bundle, default: 0] += 1 }
      if ask {
        let answer = askAnswer[bundle] ?? BrowserWatch.granted
        permissions[bundle] = answer
        return answer
      }
      return permissions[bundle] ?? BrowserWatch.granted
    }
  }
}

let browsers = FakeBrowsers()
let watchLogs = Logs()
var now = Date(timeIntervalSince1970: 1_790_000_000)
let origin = "http://127.0.0.1:\(port)"
let watch = BrowserWatch(
  log: watchLogs.add,
  page: { host, redirect, token in BlockServer.pageURL(origin: origin, host: host, redirect: redirect, token: token) },
  isOwnPage: { $0.hasPrefix(origin + "/") },
  runner: browsers.run, permission: browsers.permission, isRunning: { bundle in browsers.locked { browsers.running.contains(bundle) } },
  clock: { now }, interval: 3600)
let watchPolicy = FakePolicy(blocked: ["example.com", "youtube.com"], browsers: [chrome, dia, chrome], session: session())

browsers.running = [chrome]
browsers.tabs = [chrome: "https://www.example.com/page?x=1#top", dia: "https://youtube.com/"]
watch.passAndWait()
check("watch: nothing before start", browsers.reads.isEmpty && watchPolicy.recordedHosts.isEmpty)
watch.start(policy: watchPolicy)
watch.passAndWait()
let sentTo = browsers.tabs[chrome] ?? ""
check("watch: blocked tab sent to the block page", sentTo.hasPrefix(origin + "/blocked?host=www.example.com&redirect="), sentTo)
let sentQuery = BlockServer.parseForm(sentTo.components(separatedBy: "?").dropFirst().joined(separator: "?"))
check("watch: page carries the original URL and the token",
  sentQuery["redirect"] == "https://www.example.com/page?x=1#top" && sentQuery["token"] == "tok-123", "\(sentQuery)")
check("watch: attempt recorded once", watchPolicy.recordedHosts == ["www.example.com"], "\(watchPolicy.recordedHosts)")
check("watch: Dia not running, not asked", browsers.reads[dia] == nil)
check("watch: duplicate bundle polled once per pass", (browsers.reads[chrome] ?? 0) <= 2, "\(browsers.reads)")
for _ in 0..<3 { watch.passAndWait() }
check("watch: block page not re-recorded", watchPolicy.recordedHosts == ["www.example.com"], "\(watchPolicy.recordedHosts)")

browsers.locked { browsers.tabs[chrome] = "https://www.example.com/page?x=1#top" }  // Back
now += 10
watch.passAndWait()
check("watch: coming back is a new attempt", watchPolicy.recordedHosts == ["www.example.com", "www.example.com"])

browsers.locked { browsers.tabs[chrome] = "https://github.com/" }
watch.passAndWait()
check("watch: other hosts untouched", browsers.tabs[chrome] == "https://github.com/")
browsers.locked { browsers.tabs[chrome] = "http://localhost:3000/example.com" }
watch.passAndWait()
check("watch: localhost untouched", browsers.tabs[chrome] == "http://localhost:3000/example.com")
browsers.locked { browsers.tabs[chrome] = "chrome://settings/?example.com" }
watch.passAndWait()
check("watch: non-http untouched", browsers.tabs[chrome] == "chrome://settings/?example.com")

// The tab does not navigate: the same URL within the settle time is not a new attempt; later it is.
browsers.locked {
  browsers.ignoreSets = true
  browsers.tabs[chrome] = "https://youtube.com/watch?v=9"
}
let before = watchPolicy.recordedHosts.count
let setsBefore = browsers.locked { browsers.sets }
watch.passAndWait()
watch.passAndWait()
check("watch: settling navigation not re-recorded", watchPolicy.recordedHosts.count == before + 1)
check("watch: but the tab is sent again", browsers.locked { browsers.sets } == setsBefore + 2)
now += BrowserWatch.settle + 1
watch.passAndWait()
check("watch: after the settle time it counts again", watchPolicy.recordedHosts.count == before + 2)
browsers.locked { browsers.ignoreSets = false }

// The tab changes between the read and the write.
browsers.locked {
  browsers.tabs[chrome] = "https://example.com/a"
  browsers.moveBeforeSet = "https://github.com/b"
}
let beforeMove = watchPolicy.recordedHosts.count
now += 10
watch.passAndWait()
check("watch: tab moved meanwhile, left alone and not recorded",
  browsers.tabs[chrome] == "https://github.com/b" && watchPolicy.recordedHosts.count == beforeMove)

// Dia running but denied: logged once, Chrome still blocked.
browsers.locked {
  browsers.running = [chrome, dia]
  browsers.permissions[dia] = BrowserWatch.denied
  browsers.tabs[chrome] = "https://example.com/x"
}
now += 10
for _ in 0..<3 { watch.passAndWait() }
check("watch: denied browser logged once", watchLogs.count("\(dia): Automation permission denied") == 1, "\(watchLogs.all)")
check("watch: denied browser not scripted", browsers.reads[dia] == nil)
check("watch: other browser still blocked", browsers.tabs[chrome]?.hasPrefix(origin + "/blocked") == true)

// Dia never asked: one prompt on the side queue, which the user answers later;
// meanwhile Dia is not checked (the check would wait on the prompt) and Chrome is still polled.
browsers.locked {
  browsers.permissions[dia] = BrowserWatch.notAsked
  browsers.askAnswer[dia] = BrowserWatch.granted
  browsers.promptOpen = DispatchSemaphore(value: 0)
  browsers.tabs[chrome] = "https://example.com/while-asking"
}
now += 10
watch.passAndWait()
Thread.sleep(forTimeInterval: 0.1)
let checksBefore = browsers.locked { browsers.checks[dia] ?? 0 }
watch.passAndWait()
watch.passAndWait()
check("watch: no permission check while the prompt is up", browsers.locked { browsers.checks[dia] ?? 0 } == checksBefore)
check("watch: other browser polled while the prompt is up", browsers.tabs[chrome]?.hasPrefix(origin + "/blocked") == true)
browsers.promptOpen?.signal()
Thread.sleep(forTimeInterval: 0.3)
watch.passAndWait()
check("watch: prompt asked once", browsers.asks == [dia], "\(browsers.asks)")
check("watch: after the grant Dia is redirected", browsers.tabs[dia]?.hasPrefix(origin + "/blocked?host=youtube.com") == true,
  browsers.tabs[dia] ?? "nil")

// Script errors: -1743 logged once; a missing window is quiet.
browsers.locked {
  browsers.failWith[chrome] = "execution error: Not authorized to send Apple events to Google Chrome. (-1743)"
  browsers.failWith[dia] = "execution error: Can't get window 1. Invalid index. (-1728)"
}
let logCount = watchLogs.all.count
for _ in 0..<3 { watch.passAndWait() }
check("watch: -1743 from a script logged once", watchLogs.count("\(chrome): Automation permission denied") == 1, "\(watchLogs.all)")
check("watch: -1728 not logged", watchLogs.all.count == logCount + 1, "\(watchLogs.all.suffix(3))")
browsers.locked { browsers.failWith = [:] }
watch.passAndWait()
check("watch: recovery logged", watchLogs.count("\(chrome): reading tabs again") == 1)

// Idle (no token) and stopped: no scripts at all.
let readsBefore = browsers.locked { browsers.reads }
watchPolicy.token = ""
watch.passAndWait()
check("watch: no session, no scripts", browsers.locked { browsers.reads } == readsBefore)
watchPolicy.token = "tok-123"
watch.stop()
watch.pollNow()
watch.passAndWait()
check("watch: stopped, no scripts", browsers.locked { browsers.reads } == readsBefore)
check("watch: stopped", !watch.isStarted)

// Both browsers never asked: both prompts start without waiting on each other.
let twoPrompts = FakeBrowsers()
twoPrompts.running = [chrome, dia]
twoPrompts.permissions = [chrome: BrowserWatch.notAsked, dia: BrowserWatch.notAsked]
twoPrompts.promptOpen = DispatchSemaphore(value: 0)
let twoWatch = BrowserWatch(
  log: { _ in }, page: { _, _, _ in nil }, isOwnPage: { _ in false }, runner: twoPrompts.run,
  permission: twoPrompts.permission, isRunning: { _ in true }, interval: 3600)
let twoPolicy = FakePolicy(blocked: ["example.com"], browsers: [chrome, dia])  // held: the watcher keeps it weakly
twoWatch.start(policy: twoPolicy)
twoWatch.passAndWait()
Thread.sleep(forTimeInterval: 0.3)
check("watch: two prompts asked side by side", Set(twoPrompts.locked { twoPrompts.asks }) == [chrome, dia],
  "\(twoPrompts.locked { twoPrompts.asks })")
twoPrompts.promptOpen?.signal()
twoPrompts.promptOpen?.signal()
twoWatch.stop()

// MARK: SiteBlocker composition

let composedLogs = Logs()
let composed = SiteBlockerService(log: composedLogs.add) { server in
  BrowserWatch(
    log: composedLogs.add,
    page: { server.port == nil ? nil : server.pageURL(host: $0, redirect: $1, token: $2) },
    isOwnPage: { $0.hasPrefix(server.origin + "/") },
    runner: browsers.run, permission: browsers.permission, isRunning: { _ in false }, interval: 3600)
}
check("blocker: server down before start", composed.server.port == nil)
let composedPolicy = FakePolicy(blocked: ["example.com"])
composed.start(policy: composedPolicy)
let firstPort = composed.server.port
check("blocker: start brings the server up", firstPort != nil)
check("blocker: watcher started", composed.watch.isStarted)
composed.stop()
check("blocker: stop stops polling", !composed.watch.isStarted)
check("blocker: server stays up after stop", composed.server.port == firstPort)
composed.start(policy: composedPolicy)
check("blocker: restart keeps the same port", composed.server.port == firstPort)
check("blocker: page served after restart",
  exchange(firstPort ?? 0, Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(firstPort ?? 0)\r\n\r\n".utf8))?.status == 200)
composed.stop()
composed.server.shutdown()
server.shutdown()
check("server: shutdown frees the port", server.port == nil)

print(failures == 0 ? "all passed (\(passes) checks)" : "\(failures) failed, \(passes) passed")
exit(failures == 0 ? 0 : 1)
