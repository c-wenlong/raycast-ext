// Renders the real notes panel (controls, cards, boxes) to a PNG without
// touching the running instance: `npm run render-panel -- <note.md> <out.png> [caret] [command,command]` (either optional, any order).
// The window is moved off screen and its frame autosave is disabled first.

import AppKit

let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("--") }
guard args.count >= 2 else {
  FileHandle.standardError.write("usage: render-panel <note.md> <out.png> [caret]\n".data(using: .utf8)!)
  exit(2)
}
let notePath = (args[0] as NSString).expandingTildeInPath
notesDir = (notePath as NSString).deletingLastPathComponent
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// "hide" so nothing is created if the folder has no notes; "open" below shows the panel.
let controller = PanelController(initialCommand: "hide")
app.delegate = controller
controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.frame.width >= 300 }) else { exit(3) }
panel.setFrameAutosaveName("")
panel.setFrame(NSRect(x: -3000, y: -3000, width: 560, height: 480), display: false)
controller.handle("open \(notePath)")
panel.setFrameOrigin(NSPoint(x: -3000, y: -3000))
// Remaining arguments: an integer is the caret offset, anything else a
// comma-separated list of commands, in any order.
for extra in args.dropFirst(2) {
  if let caret = Int(extra), let textView = panel.contentView?.subviews.compactMap({ ($0 as? NSScrollView)?.documentView as? NSTextView }).first {
    textView.setSelectedRange(NSRange(location: caret, length: 0))
    textView.scrollRangeToVisible(textView.selectedRange())
  } else {
    for command in extra.split(separator: ",") { controller.handle(String(command)) }
  }
}
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
// The whole window frame (title bar included), not just the content view.
let view = panel.contentView!.superview ?? panel.contentView!
let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
print("rendered \(args[1])")
exit(0)
