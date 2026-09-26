import AppKit
import Foundation

// MARK: - Controller

final class PanelController: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate {
  private var panel: NSPanel!
  private var textView: NoteTextView!
  private var notes: [Note] = []
  private var currentPath: String?
  private var loadedText = ""
  private var saveTimer: Timer?
  private var watcher: DispatchSourceFileSystemObject?
  private var pendingCommand: String
  private var palette: ActionPalette!

  init(initialCommand: String) {
    pendingCommand = initialCommand
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    buildPanel()
    handle(pendingCommand)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard saveNow() else {
      panel.title = "Could not save; quit cancelled"
      return .terminateCancel
    }
    return .terminateNow
  }

  /// Accessory apps start without a menu bar, and without one the Edit
  /// key equivalents (⌘Z, ⌘C, ⌘V, ⌘A...) have nothing to route to.
  private func installMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu()
    appItem.submenu?.addItem(withTitle: "Quit Notes Window", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    main.addItem(appItem)

    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    let find = edit.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
    find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    let next = edit.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
    next.tag = Int(NSFindPanelAction.next.rawValue)
    let previous = edit.addItem(withTitle: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
    previous.tag = Int(NSFindPanelAction.previous.rawValue)
    previous.keyEquivalentModifierMask = [.command, .shift]
    editItem.submenu = edit
    main.addItem(editItem)

    NSApp.mainMenu = main
  }

  private func buildPanel() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
      styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.setFrameAutosaveName("notes-panel")
    panel.delegate = self
    if panel.frame.origin == .zero { panel.center() }

    let scroll = NSScrollView(frame: panel.contentView!.bounds)
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false

    textView = NoteTextView(frame: scroll.bounds)
    textView.textContainer?.replaceLayoutManager(TaskBoxLayoutManager())
    textView.autoresizingMask = [.width]
    textView.isRichText = false
    textView.font = Markdown.baseFont
    textView.linkTextAttributes = [:]
    textView.isAutomaticLinkDetectionEnabled = false
    textView.textContainerInset = NSSize(width: 18, height: 16)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.delegate = self
    textView.onCommand = { [weak self] command in
      self?.handle(command)
      return true
    }
    textView.minSize = NSSize(width: 0, height: scroll.bounds.height)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true

    scroll.documentView = textView
    panel.contentView?.addSubview(scroll)

    palette = ActionPalette(actions: [
      PaletteAction(title: "New Note", keys: "⌘N", symbol: "plus", command: "new"),
      PaletteAction(title: "Duplicate Note", keys: "⌘D", symbol: "doc.on.doc", command: "duplicate"),
      PaletteAction(title: "Browse Notes", keys: "⌘P", symbol: "square.grid.2x2", command: "browse"),
      PaletteAction(title: "Previous Note", keys: "⌘[", symbol: "arrow.left.circle", command: "prev"),
      PaletteAction(title: "Next Note", keys: "⌘]", symbol: "arrow.right.circle", command: "next"),
      PaletteAction(title: "Toggle Task", keys: "⌘↩", symbol: "checkmark.circle", command: "toggle-task"),
      PaletteAction(title: "Find in Note", keys: "⌘F", symbol: "magnifyingglass", command: "find"),
      PaletteAction(title: "Copy Note", keys: "⇧⌘C", symbol: "doc.on.clipboard", command: "copy"),
      PaletteAction(title: "Reveal in Finder", keys: "", symbol: "folder", command: "reveal"),
      PaletteAction(title: "Delete Note", keys: "⌃X", symbol: "trash", command: "delete"),
      PaletteAction(title: "Hide Window", keys: "⎋", symbol: "eye.slash", command: "hide"),
    ]) { [weak self] command in
      self?.handle(command)
    }
  }

  // MARK: Commands

  func handle(_ command: String) {
    switch command {
    case "toggle":
      panel.isVisible ? hide() : show()
    case "show":
      show()
    case "hide":
      hide()
    case "new":
      newNote()
      show()
    case "prev":
      move(by: 1)
    case "next":
      move(by: -1)
    case "browse":
      hide()
      NSWorkspace.shared.open(URL(string: "raycast://extensions/c-wenlong/notes/browseNotes")!)
    case "toggle-task":
      toggleTaskOnCurrentLine()
    case "palette":
      palette.isVisible ? palette.hide() : palette.show(over: panel)
    case "duplicate":
      duplicateNote()
    case "find":
      let item = NSMenuItem()
      item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
      textView.performFindPanelAction(item)
    case "copy":
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(textView.string, forType: .string)
    case "reveal":
      if let path = currentPath {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }
    case "delete":
      deleteNote()
    default:
      if command.hasPrefix("open ") {
        let path = String(command.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        open(path)
        show()
      }
    }
  }

  private func show() {
    refreshList()
    if currentPath == nil {
      if let first = notes.first { load(first.path) } else { newNote() }
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(textView)
  }

  private func hide() {
    palette.hide()
    saveNow()
    panel.orderOut(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }

  // MARK: Note list and navigation

  /// Re-reads the folder so the order reflects the latest edits, keeping
  /// the open note selected even if it moved.
  private func refreshList() {
    notes = listNotes()
    if let current = currentPath, !notes.contains(where: { $0.path == current }) {
      currentPath = nil
      loadedText = ""
    }
    updateTitle()
  }

  private var currentIndex: Int? {
    guard let current = currentPath else { return nil }
    return notes.firstIndex(where: { $0.path == current })
  }

  private func move(by delta: Int) {
    saveNow()
    guard !notes.isEmpty else { return }
    let index = ((currentIndex ?? 0) + delta + notes.count) % notes.count
    load(notes[index].path)
  }

  private func open(_ path: String) {
    saveNow()
    refreshList()
    if !notes.contains(where: { $0.path == path }) {
      notes.insert(Note(path: path, modified: Date()), at: 0)
    }
    load(path)
  }

  /// Copies the open note. The heading gets " copy" appended and a
  /// generated filename follows that heading's slug, so the title-driven
  /// rename on the next save leaves the copy's name alone.
  private func duplicateNote() {
    saveNow()
    guard let path = currentPath, textView.isEditable else {
      NSSound.beep()
      return
    }
    let filename = (path as NSString).lastPathComponent
    let directory = (path as NSString).deletingLastPathComponent
    var text = loadedText
    var copyName = "\((filename as NSString).deletingPathExtension) copy.md"

    if let heading = headingPattern.firstMatch(in: text, range: fullRange(text)) {
      let headingRange = heading.range(at: 1)
      let copyTitle = (text as NSString).substring(with: headingRange) + " copy"
      text = (text as NSString).replacingCharacters(in: headingRange, with: copyTitle)
      if let match = generatedNamePattern.firstMatch(in: filename, range: fullRange(filename)) {
        let prefix = (filename as NSString).substring(with: match.range(at: 1))
        copyName = "\(prefix) - \(slugify(copyTitle)).md"
      }
    }

    let copyPath = uniquePath(for: copyName, in: directory)
    do {
      try text.write(toFile: copyPath, atomically: false, encoding: .utf8)
    } catch {
      NSSound.beep()
      return
    }
    refreshList()
    load(copyPath)
  }

  /// Moves the open note to the Trash after confirming, then shows the
  /// newest remaining note.
  private func deleteNote() {
    guard let path = currentPath else { return }
    let alert = NSAlert()
    alert.messageText = "Move note to Trash?"
    alert.informativeText = (path as NSString).lastPathComponent
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    saveNow()
    watcher?.cancel()
    watcher = nil
    do {
      try diskFiles.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    } catch {
      NSSound.beep()
      watch(path)
      return
    }
    currentPath = nil
    loadedText = ""
    refreshList()
    if let first = notes.first { load(first.path) } else { newNote() }
  }

  private func newNote() {
    saveNow()
    let path = uniquePath(for: "\(timestampPrefix()) - untitled.md")
    do {
      try diskFiles.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
      try "# \n".write(toFile: path, atomically: false, encoding: .utf8)
    } catch {
      NSSound.beep()
      panel.title = "Cannot write to \(notesDir)"
      return
    }
    refreshList()
    load(path)
    textView.setSelectedRange(NSRange(location: 2, length: 0))
  }

  // MARK: Loading and saving

  private func load(_ path: String) {
    currentPath = path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      // Not UTF-8 (or unreadable): show it read-only so nothing here can
      // overwrite or copy a file we cannot represent.
      loadedText = ""
      textView.string = ""
      textView.isEditable = false
      watch(path)
      panel.title = "Cannot read \((path as NSString).lastPathComponent) as UTF-8"
      return
    }
    textView.isEditable = true
    loadedText = text
    textView.string = text
    restyle()
    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    textView.undoManager?.removeAllActions()
    textView.scrollToEndOfDocument(nil)
    watch(path)
    updateTitle()
  }

  func textDidChange(_ notification: Notification) {
    restyle()
    saveTimer?.invalidate()
    saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
      self?.saveNow()
    }
    updateTitle()
  }

  /// Writes unsaved text. Returns false when the write failed, in which
  /// case the text stays dirty and the next save retries.
  @discardableResult
  private func saveNow() -> Bool {
    saveTimer?.invalidate()
    guard let path = currentPath, textView.isEditable else { return true }
    let text = textView.string
    guard text != loadedText else { return true }
    do {
      try text.write(toFile: path, atomically: false, encoding: .utf8)
      loadedText = text
      renameToMatchTitleIfNeeded()
      updateTitle()
      return true
    } catch {
      NSSound.beep()
      return false
    }
  }

  /// Generated filenames follow the heading, as the Raycast extension does.
  private func renameToMatchTitleIfNeeded() {
    guard let path = currentPath else { return }
    let filename = (path as NSString).lastPathComponent
    guard let match = generatedNamePattern.firstMatch(in: filename, range: fullRange(filename)),
      let heading = headingPattern.firstMatch(in: loadedText, range: fullRange(loadedText))
    else { return }
    let headingText = (loadedText as NSString).substring(with: heading.range(at: 1))
    let currentSlug = (filename as NSString).substring(with: match.range(at: 2))
    let nextSlug = slugify(headingText)
    guard !headingText.trimmingCharacters(in: .whitespaces).isEmpty, nextSlug != currentSlug else { return }
    let prefix = (filename as NSString).substring(with: match.range(at: 1))
    let nextPath = uniquePath(for: "\(prefix) - \(nextSlug).md", in: (path as NSString).deletingLastPathComponent)
    guard (try? diskFiles.moveItem(atPath: path, toPath: nextPath)) != nil else { return }
    currentPath = nextPath
    if let index = notes.firstIndex(where: { $0.path == path }) {
      notes[index] = Note(path: nextPath, modified: Date())
    }
    watch(nextPath)
    updateTitle()
  }

  /// Reloads when another program edits the open note and we have no
  /// unsaved changes of our own.
  private func watch(_ path: String) {
    watcher?.cancel()
    watcher = nil
    let fd = Darwin.open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      guard let self, self.currentPath == path else { return }
      if source.data.contains(.delete) || source.data.contains(.rename) {
        let unsaved = self.textView.string != self.loadedText
        if diskFiles.fileExists(atPath: path) {
          // Replaced in place (editors that save via rename): our fd points
          // at the old inode, so watch the new file and pick up its text.
          self.watch(path)
          if !unsaved { self.reloadFromDisk(path) }
          return
        }
        if unsaved {
          // Gone while we still hold edits: write them back rather than
          // dropping them, then keep editing the recreated file.
          do {
            try self.textView.string.write(toFile: path, atomically: false, encoding: .utf8)
            self.loadedText = self.textView.string
            self.watch(path)
          } catch {
            NSSound.beep()  // still dirty; the next save retries
          }
          self.updateTitle()
          return
        }
        self.currentPath = nil
        self.refreshList()
        if let first = self.notes.first { self.load(first.path) } else { self.newNote() }
        return
      }
      self.reloadFromDisk(path)
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    watcher = source
  }

  /// Takes the on-disk text when it changed and we have nothing unsaved.
  private func reloadFromDisk(_ path: String) {
    if !textView.isEditable {
      // Was undecodable; if it reads as UTF-8 now, open it for real.
      if (try? String(contentsOfFile: path, encoding: .utf8)) != nil { load(path) }
      return
    }
    let onDisk = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    guard onDisk != loadedText, textView.string == loadedText else { return }
    let selection = textView.selectedRange()
    loadedText = onDisk
    textView.string = onDisk
    restyle()
    let length = (onDisk as NSString).length
    textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    updateTitle()
  }

  // MARK: Editing helpers

  func restyle() {
    guard let storage = textView.textStorage else { return }
    let selection = textView.selectedRange()
    Markdown.apply(to: storage)
    textView.setSelectedRange(selection)
    textView.typingAttributes = [.font: Markdown.baseFont, .foregroundColor: NSColor.labelColor]
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url = link as? URL, url.scheme == Markdown.taskScheme,
      let location = Int(url.lastPathComponent)
    else { return false }
    toggleTask(atBox: location)
    return true
  }

  private func toggleTask(atBox location: Int) {
    let text = textView.string as NSString
    guard location + 3 <= text.length,
      text.substring(with: NSRange(location: location, length: 1)) == "["
    else { return }
    let markRange = NSRange(location: location + 1, length: 1)
    let mark = text.substring(with: markRange).lowercased() == "x" ? " " : "x"
    textView.insertText(mark, replacementRange: markRange)
  }

  private func toggleTaskOnCurrentLine() {
    let text = textView.string as NSString
    let lineRange = text.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
    let line = text.substring(with: lineRange)
    if let match = taskPattern.firstMatch(in: line, range: fullRange(line)) {
      let markRange = NSRange(location: lineRange.location + match.range(at: 2).location, length: 1)
      let mark = text.substring(with: markRange).lowercased() == "x" ? " " : "x"
      textView.insertText(mark, replacementRange: markRange)
    } else {
      let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
      let insertAt = NSRange(location: lineRange.location + indent.count, length: 0)
      textView.insertText("- [ ] ", replacementRange: insertAt)
    }
  }

  private func updateTitle() {
    guard let path = currentPath else {
      panel.title = "Notes"
      return
    }
    guard textView.isEditable else { return }
    let noteTitle = title(of: textView.string, filename: (path as NSString).lastPathComponent)
    let position = currentIndex.map { "\($0 + 1)/\(notes.count)" } ?? ""
    let unsaved = textView.string != loadedText ? " •" : ""
    panel.title = position.isEmpty ? noteTitle + unsaved : "\(noteTitle)\(unsaved)  ·  \(position)"
  }
}
