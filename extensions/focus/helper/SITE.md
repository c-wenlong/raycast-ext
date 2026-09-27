# Site blocking: block page server and tab watcher

For HELPER.md (step 3, site half): `BlockPage.swift` (HTML, pure), `BlockServer.swift` (loopback
HTTP), `BrowserWatch.swift` (AppleScript), `SiteBlocking.swift` (factory), `Blocking.swift` (interface).

## Wiring

- `engine.siteBlocker = makeSiteBlocker(log: log)` in `main.swift`. The engine calls
  `start(policy: self)` when blocking turns on, `pollNow()` right after, `stop()` when it turns off.
- The server starts on the first `start` and stays up; `stop` only stops polling. Policy held weakly.
- `Info.plist` needs `NSAppleEventsUsageDescription` (for example "Focus reads the address of the
  front tab in Chrome and Dia to block distracting sites."), or macOS may refuse the Automation
  prompt for focus-daemon.

## HTTP (127.0.0.1, random port, one request per connection)

| Request | Answer |
|---|---|
| `GET /blocked?host=&redirect=&token=` | 200 block page; 400 without `host`. `token` is only echoed into the form. |
| `POST /snooze` form `host, token, redirect` | `policy.snooze` true: 303 to `redirect` if it is an absolute http(s) URL with a host, else 303 `/blank`. False, no token, or an `Origin` other than ours or `null`: 403 "Not allowed". |
| `GET /snooze` (any non-POST) | 403 |
| `GET /blank` | 200 empty dark page |
| `GET /health` | 200 `ok` |
| other | 404; a known path with the wrong method 405 |

- Every request must carry `Host: 127.0.0.1:<port>` (or `localhost:<port>`), else 400 (DNS rebinding).
- Over 16 KB, malformed, chunked, or two `Content-Length`: 400. Reading gives up after 5 s. At most
  32 connections at once. Refusals are logged (request values escaped, cut at 200 characters).
- Every response: `Connection: close`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`,
  `X-Content-Type-Options: nosniff`, and a CSP of `default-src 'none'; style-src 'unsafe-inline'`
  (no script can run; the page has none). Chrome sends `Origin: null` on the Snooze POST because of
  the referrer policy, so `null` is accepted; the token is the real check.
- Page URLs: each value percent-encoded with `urlQueryAllowed` minus `& = + ? / # %`; the server
  decodes `+` as a space. Every value written into HTML is escaped (`& < > " '`).

## Tab watcher

- Every 2 s while started (a `DispatchSourceTimer` on its own queue), and at once on `start` and
  `pollNow`. Skips everything when `policy.token` is "". For each bundle id in `policy.browsers`
  (validated as letters, digits, dots, hyphens) that is running: read the active tab URL of the
  front window, take the host (lowercased, no port, brackets or trailing dot), skip non-http(s),
  loopback names and the block page itself, and if `isBlocked(host:)` set the tab to the block
  page (only if it still shows the URL read) and call `recordBlocked(host:)`.
- A tab showing the block page is never recorded again. Going Back to the site is a new attempt.
  The same URL read again within 4 s of a redirect is sent again but not recorded again.
- AppleScript runs in `/usr/bin/osascript` (killed after 6 s), not `NSAppleScript`, which is
  main-thread only and could stall the menu bar for up to two minutes on a hung browser. URLs go
  in as arguments, never into the script source.
- Automation permission: `AEDeterminePermissionToAutomateTarget` without prompting first. Not asked
  yet: one prompt per browser, each on its own thread; that browser is skipped until it is answered (TCC makes even the
  silent check wait while a prompt is up) and the others keep being polled. Denied (-1743) and
  other script errors are logged once per browser until it works again; -1728 (no window) is quiet.

## Tests

`scripts/test-site.sh` (the lead adds `test-site` to package.json): page escaping and labels, URL
round trips, parsing, HTTP over a real listener with a fake policy, host extraction, osascript
argument passing, and the watcher over a fake browser. `scripts/test-site.sh --demo 60` runs the
real server and watcher blocking example.com in Chrome and Dia for a live check.
