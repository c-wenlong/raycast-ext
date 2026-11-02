import Foundation

// MARK: - Block page HTML
//
// The page a blocked tab is sent to, modelled on Raycast Focus's block page
// (the user's screenshot, 2026-09-27): a black canvas with a soft lighter centre,
// a round icon, "<host> has been blocked", one flat bordered "Snooze for N
// minutes" button and a grey footer near the bottom. Pure string building so
// the test harness can check it without a server.
//
// Rules (PLAN.md "Blocking"): every interpolated value is HTML-escaped; the
// redirect only ever lands in a hidden form field; there is no JavaScript at
// all (the server's Content-Security-Policy forbids it too), the form posts
// to /snooze and the server answers with a redirect.

enum BlockPage {
  /// Markdown.accent / SheetStyle.accent as CSS: the helper's one highlight colour.
  static let accent = "#E85C54"

  /// Escapes `& < > " '` so a value is inert in text and in quoted attributes.
  static func escape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for character in text {
      switch character {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case "'": out += "&#39;"
      default: out.append(character)
      }
    }
    return out
  }

  /// "Snooze for 3 minutes", "Snooze for 1 minute", "Snooze for 45 seconds",
  /// "Snooze for 1 minute 30 seconds". Never a fixed "3": it follows config.
  static func snoozeLabel(seconds: Int) -> String {
    let seconds = max(1, seconds)
    func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
    if seconds < 60 { return "Snooze for " + unit(seconds, "second") }
    let minutes = seconds / 60
    let rest = seconds % 60
    return "Snooze for " + unit(minutes, "minute") + (rest == 0 ? "" : " " + unit(rest, "second"))
  }

  /// "44:40", "1:02:05": the menu bar's clock format.
  static func clock(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let (h, m, r) = (s / 3600, (s % 3600) / 60, s % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%02d:%02d", m, r)
  }

  /// "Deep Work · 44:40 left", "Deep Work · paused", "Deep Work · time's up";
  /// nil with no session. Unescaped: `render` escapes it.
  static func sessionLine(_ view: SessionView?) -> String? {
    guard let view else { return nil }
    let goal = view.goal.trimmingCharacters(in: .whitespacesAndNewlines)
    let status: String
    switch view.state {
    case "paused": status = "paused"
    case "ending": status = "time's up"
    default: status = "\(clock(view.remainingSeconds)) left"
    }
    return goal.isEmpty ? status.prefix(1).uppercased() + status.dropFirst() : "\(goal) · \(status)"
  }

  /// The block page for `host`. `redirect` and `token` go back to the server
  /// in the Snooze form; `token` is only echoed, never checked here.
  static func render(host: String, redirect: String, token: String, snoozeSeconds: Int, session: SessionView?) -> String {
    let line = sessionLine(session).map { "\n    <p class=\"session\">\(escape($0))</p>" } ?? ""
    return page(title: "Blocked by Focus", body: """
      <main>
        \(icon)
        <h1>\(escape(host)) has been blocked</h1>\(line)
        <form method="post" action="/snooze">
          <input type="hidden" name="host" value="\(escape(host))">
          <input type="hidden" name="token" value="\(escape(token))">
          <input type="hidden" name="redirect" value="\(escape(redirect))">
          <button type="submit">\(snoozeIcon)<span>\(escape(snoozeLabel(seconds: snoozeSeconds)))</span></button>
        </form>
      </main>
      <footer>End your focus session to access this page</footer>
      """)
  }

  /// Answer to a refused snooze (wrong token, a GET, a session that ended).
  static func notAllowed() -> String {
    page(title: "Not allowed", body: """
      <main>
        \(icon)
        <h1>Not allowed</h1>
        <p class="session">This snooze is not valid for the current focus session.</p>
      </main>
      """)
  }

  /// Where a snooze with an unusable redirect lands: the canvas and nothing else.
  static func blank() -> String { page(title: "Focus", body: "") }

  /// A small plain page for 400 and 404 answers.
  static func plain(_ message: String) -> String {
    page(title: "Focus", body: "<main><p class=\"session\">\(escape(message))</p></main>")
  }

  // MARK: Pieces

  /// A ring with a gap and a centre dot on a faint accent disc: a target, drawn inline so no asset is fetched.
  static let icon = """
    <svg class="icon" width="56" height="56" viewBox="0 0 56 56" aria-hidden="true">
          <circle cx="28" cy="28" r="28" fill="\(accent)" fill-opacity="0.16"/>
          <circle cx="28" cy="28" r="15" fill="none" stroke="\(accent)" stroke-width="4" stroke-linecap="round" stroke-dasharray="80 14.25" transform="rotate(-60 28 28)"/>
          <circle cx="28" cy="28" r="4.5" fill="\(accent)"/>
        </svg>
    """

  /// A clock with a return arrow, like the glyph on Raycast's Snooze button.
  static let snoozeIcon = """
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M15.2 9a6.2 6.2 0 1 1-2.1-4.65"/><path d="M13.4 1.9v2.8h-2.8"/><path d="M9 5.6V9l2.2 1.4"/></svg>
    """

  static let style = """
    :root { color-scheme: dark; }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html { height: 100%; background: #000; }
    body {
      min-height: 100%;
      background: radial-gradient(ellipse 58% 52% at 50% 46%, #161616 0%, #0f0f0f 38%, #0b0b0b 62%, #000 100%) fixed;
      color: rgba(255, 255, 255, 0.9);
      font: 15px/1.4 -apple-system, system-ui, BlinkMacSystemFont, "SF Pro Text", Helvetica, sans-serif;
      -webkit-font-smoothing: antialiased;
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      padding: 48px 24px 140px; text-align: center;
    }
    main { display: flex; flex-direction: column; align-items: center; max-width: 660px; }
    .icon { display: block; width: 56px; height: 56px; margin-bottom: 24px; }
    h1 { font-size: 28px; font-weight: 600; line-height: 1.32; letter-spacing: 0.005em; color: rgba(255, 255, 255, 0.88); overflow-wrap: anywhere; }
    .session { margin-top: 10px; font-size: 14px; color: rgba(255, 255, 255, 0.42); overflow-wrap: anywhere; }
    form { margin-top: 36px; }
    button {
      display: inline-flex; align-items: center; gap: 10px;
      font: inherit; font-size: 15px; font-weight: 500; color: rgba(255, 255, 255, 0.9);
      background: rgba(255, 255, 255, 0.06); border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 8px;
      padding: 10px 18px 10px 16px; cursor: pointer;
    }
    button:hover { background: rgba(255, 255, 255, 0.1); border-color: rgba(255, 255, 255, 0.16); }
    button:active { background: rgba(255, 255, 255, 0.14); }
    button:focus-visible { outline: 2px solid \(accent); outline-offset: 3px; }
    button svg { flex: none; opacity: 0.85; }
    footer { position: fixed; left: 0; right: 0; bottom: 64px; padding: 0 24px; font-size: 15px; color: rgba(255, 255, 255, 0.38); }
    """

  static func page(title: String, body: String) -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <meta name="color-scheme" content="dark">
    <title>\(escape(title))</title>
    <style>
    \(style)
    </style>
    </head>
    <body>
    \(body)
    </body>
    </html>

    """
  }
}
