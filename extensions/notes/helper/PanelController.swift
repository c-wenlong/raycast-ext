import AppKit
import Foundation

// MARK: - Controller

final class PanelController: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate {
  private var panel: NSPanel!
  private var textView: NoteTextView!
  private var notes: [Note] = []
  private var currentPath: String?
  /// The collapsed toggles (NoteTextView.collapsedToggleKeys) of each
  /// note shown since the helper started, so a note opens again as it was
  /// left. Never saved.
  private var collapsedToggles: [String: Set<String>] = [:]
  private var loadedText = ""
  private var saveTimer: Timer?
  private var watcher: DispatchSourceFileSystemObject?
  private var pendingCommand: String
  private var palette: ActionPalette!
  private var settings: SettingsController!
  private var zoomHUD: ZoomHUD!
  private var codeBlocks: CodeBlockOverlay!
  private var links: LinkController!
  private var titlebarChrome: TitlebarChrome!
  private var statusBar: StatusBar!
  private static let baseTextInset = NSSize(width: 18, height: 16)
  private static let zoomDefaultsKey = "notesPanelZoom"

  init(initialCommand: String) {
    pendingCommand = initialCommand
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    loadZoom()
    loadTheme()
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

    let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    let view = NSMenu(title: "View")
    let zoomIn = view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
    zoomIn.target = self
    let zoomInAlt = view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
    zoomInAlt.target = self
    zoomInAlt.isHidden = true
    let zoomOut = view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
    zoomOut.target = self
    let zoomReset = view.addItem(withTitle: "Actual Size", action: #selector(zoomReset(_:)), keyEquivalent: "0")
    zoomReset.target = self
    viewItem.submenu = view
    main.addItem(viewItem)

    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Window")
    let minimize = windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    minimize.target = nil
    windowItem.submenu = windowMenu
    main.addItem(windowItem)

    NSApp.mainMenu = main
  }

  // MARK: Zoom

  /// Reads the persisted zoom, applied before the first note loads.
  private func loadZoom() {
    let stored = CGFloat(UserDefaults.standard.double(forKey: Self.zoomDefaultsKey))
    Markdown.zoom = ZoomLevels.steps.contains(where: { abs($0 - stored) < 0.001 }) ? stored : ZoomLevels.default
  }

  @objc private func zoomIn(_ sender: Any?) {
    setZoom(ZoomLevels.next(after: Markdown.zoom))
  }

  @objc private func zoomOut(_ sender: Any?) {
    setZoom(ZoomLevels.previous(before: Markdown.zoom))
  }

  @objc private func zoomReset(_ sender: Any?) {
    setZoom(ZoomLevels.default)
  }

  private func setZoom(_ value: CGFloat) {
    Markdown.zoom = value
    UserDefaults.standard.set(Double(value), forKey: Self.zoomDefaultsKey)
    relayout()
    zoomHUD.show(text: "Zoomed to \(ZoomLevels.percentageString(for: value))")
  }

  /// Restyles the note and re-measures everything sized from its fonts
  /// (insets, code block controls), after a zoom or typeface change.
  private func relayout() {
    // The view's font first: setting it re-fonts the whole text, so the
    // restyle has to come after it or code loses its monospaced font.
    textView.font = Markdown.baseFont
    restyle()
    applyTextContainerInset()
    codeBlocks.update()
  }

  // MARK: Appearance and font

  /// Loads and applies both settings at launch, before the panel is
  /// built, so the first show already has them.
  private func loadTheme() {
    settings = SettingsController()
    settings.commandActions = Self.commandActions
    settings.onAppearance = { [weak self] value in
      guard let self else { return }
      self.restyle()
      self.textView.needsDisplay = true
      self.zoomHUD.show(text: value.announcement)
    }
    settings.onFont = { [weak self] value in
      self?.relayout()
      self?.zoomHUD.show(text: value.announcement)
    }
  }

  private func applyTextContainerInset() {
    textView.textContainerInset = NSSize(
      width: Self.baseTextInset.width * Markdown.zoom, height: Self.baseTextInset.height * Markdown.zoom)
    // Text scrolls under the translucent header and footer; the insets
    // only decide where the first and last lines rest when not scrolled.
    if let scroll = textView.enclosingScrollView {
      scroll.contentInsets = NSEdgeInsets(top: headerHeight, left: 0, bottom: StatusBar.reservedHeight, right: 0)
      scroll.scrollerInsets = NSEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
    }
  }

  /// Height of the title bar plus unified toolbar, which the content
  /// extends under. contentLayoutRect is not laid out yet while the panel
  /// is being built, so the known height is used until it is.
  private var headerHeight: CGFloat {
    guard let content = panel.contentView, panel.contentLayoutRect.height > 0,
      panel.contentLayoutRect.height < content.bounds.height
    else { return 52 }
    return content.bounds.height - panel.contentLayoutRect.height
  }

  private func buildPanel() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.contentMinSize = NSSize(width: 420, height: 240)
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
    scroll.automaticallyAdjustsContentInsets = false

    textView = NoteTextView(frame: scroll.bounds)
    textView.textContainer?.replaceLayoutManager(TaskBoxLayoutManager())
    textView.autoresizingMask = [.width]
    textView.isRichText = false
    textView.font = Markdown.baseFont
    textView.linkTextAttributes = [:]
    // Only a background for selections: the default also recolours the
    // text, which would reveal the characters hidden under boxes.
    textView.selectedTextAttributes = [.backgroundColor: Markdown.selection]
    textView.backgroundColor = Markdown.canvas
    panel.backgroundColor = Markdown.canvas
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.insertionPointColor = Markdown.accent
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.delegate = self
    textView.onRestyle = { [weak self] in self?.restyle() }
    textView.onCommand = { [weak self] command in
      self?.handle(command)
      return true
    }
    textView.noteLinkTargets = { [weak self] in self?.noteLinkTargets() ?? [] }
    textView.minSize = NSSize(width: 0, height: scroll.bounds.height)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true

    scroll.documentView = textView
    applyTextContainerInset()
    panel.contentView?.addSubview(scroll)
    codeBlocks = CodeBlockOverlay(textView: textView)
    links = LinkController(textView: textView)

    zoomHUD = ZoomHUD()
    zoomHUD.install(in: panel.contentView!)

    titlebarChrome = TitlebarChrome { [weak self] command in self?.handle(command) }
    titlebarChrome.install(in: panel)
    // Fades under the header and footer so text scrolling beneath them
    // dissolves instead of being clipped.
    let fadeColor = textView.backgroundColor
    let topFade = FadeOverlay(edge: .top)
    topFade.color = fadeColor
    topFade.install(in: panel.contentView!, height: headerHeight + 28)
    let bottomFade = FadeOverlay(edge: .bottom)
    bottomFade.color = fadeColor
    bottomFade.install(in: panel.contentView!, height: StatusBar.reservedHeight + 34)
    applyTextContainerInset()
    statusBar = StatusBar { [weak self] in self?.handle("format") }
    statusBar.install(in: panel.contentView!)

    palette = ActionPalette(actions: settings.paletteActions) { [weak self] command in
      self?.handle(command)
    }
    settings.palette = palette
  }

  private static let commandActions: [PaletteAction] = [
    PaletteAction(title: "New Note", keys: "⌘N", symbol: "plus", command: "new"),
    PaletteAction(title: "Open Today's Note", keys: "", symbol: "calendar", command: "today"),
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
    PaletteAction(title: "Zoom In", keys: "⌘+", symbol: "plus.magnifyingglass", command: "zoom-in"),
    PaletteAction(title: "Zoom Out", keys: "⌘-", symbol: "minus.magnifyingglass", command: "zoom-out"),
    PaletteAction(title: "Actual Size", keys: "⌘0", symbol: "1.magnifyingglass", command: "zoom-reset"),
    PaletteAction(title: "Minimize Window", keys: "⌘M", symbol: "minus.square", command: "minimize"),
    PaletteAction(title: "Formatting…", keys: "", symbol: "textformat", command: "format"),
  ]

  // MARK: Commands

  func handle(_ command: String) {
    switch command {
    case "toggle":
      // A miniaturized panel is not considered visible in the usual sense
      // (it's parked in the Dock), so treat it like "hidden": restore it
      // rather than trying to hide it again.
      panel.isVisible && !panel.isMiniaturized ? hide() : show()
    case "show":
      show()
    case "hide":
      hide()
    case "new":
      newNote()
      show()
    case "today":
      openToday()
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
      if palette.isVisible {
        palette.hide()
      } else {
        palette.show(over: panel)
      }
    case "format":
      palette.hide()
      if statusBar.isFormatBarVisible {
        statusBar.hideFormatBar()
      } else {
        statusBar.showFormatBar { [weak self] format in self?.applyFormat(format) }
      }
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
    case "zoom-in":
      zoomIn(nil)
    case "zoom-out":
      zoomOut(nil)
    case "zoom-reset":
      zoomReset(nil)
    case "minimize":
      panel.performMiniaturize(nil)
    default:
      if let format = FormatOptions.format(forCommand: command) {
        applyFormat(format)
      } else if settings.handle(command) {
        return
      } else if command.hasPrefix("open ") {
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
    if panel.isMiniaturized { panel.deminiaturize(nil) }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(textView)
  }

  private func hide() {
    palette.hide()
    codeBlocks.closePicker()
    links.close()
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
    migrateNamesIfNeeded()
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

  private func open(_ requested: String) {
    saveNow()
    refreshList()
    // A path from before the names were migrated (Browse Notes on the
    // first launch) opens the note under its new name.
    let path = existingNote(at: requested) ?? requested
    if !notes.contains(where: { $0.path == path }) {
      notes.insert(Note(path: path, modified: Date()), at: 0)
    }
    load(path)
  }

  /// Copies the open note. The heading gets " copy" appended and a
  /// generated filename follows that heading's slug (with an id of its
  /// own), so the title-driven rename on the next save leaves the copy's
  /// name alone.
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

    // The copy's title line (heading or not) gets " copy", so the two
    // notes read apart in the title bar and in Browse Notes.
    if let titleRange = Titles.titleLineRange(of: text) {
      let line = (text as NSString).substring(with: titleRange)
      let trimmed = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
      text = (text as NSString).replacingCharacters(in: titleRange, with: trimmed + " copy")
    }
    if let generated = NoteNames.parse(filename) {
      let slug = Titles.firstLine(of: text).map(slugify) ?? generated.slug
      copyName = NoteNames.filename(stamp: generated.stamp, id: freshID(in: directory), slug: slug)
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

  /// Moves the open note to the Trash (no confirmation: the Trash keeps
  /// it), then shows the newest remaining note.
  private func deleteNote() {
    guard let path = currentPath else { return }
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
    let path = uniquePath(for: NoteNames.filename(stamp: NoteNames.timestamp(), id: freshID(in: notesDir), slug: "untitled"))
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

  /// Today's daily note, `YYYY-MM-DD.md`, created on first use with the
  /// same date heading Browse Notes and Tasks write (createDailyIfMissing
  /// in src/lib/notes.ts). The create is exclusive, so a note the
  /// extension makes at the same moment is never overwritten.
  private func openToday() {
    saveNow()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let day = formatter.string(from: Date())
    let path = (notesDir as NSString).appendingPathComponent(day + ".md")
    if !diskFiles.fileExists(atPath: path) {
      guard createDailyNote(at: path, heading: "# \(day)\n\n") else {
        NSSound.beep()
        panel.title = "Cannot write to \(notesDir)"
        return
      }
      refreshList()
    }
    load(path)
  }

  /// Creates the daily note with `heading` so that it appears complete in
  /// one step and an existing note is never touched: the heading goes to
  /// a hidden temporary file (not `.md`, so Browse Notes ignores it) that
  /// is linked into place, or, where the filesystem has no hard links,
  /// into an exclusively created file. Returns false when nothing could
  /// be written; true when the note now exists, whoever made it.
  private func createDailyNote(at path: String, heading: String) -> Bool {
    try? diskFiles.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
    let temp = (notesDir as NSString).appendingPathComponent(".today-\(UUID().uuidString).tmp")
    defer { unlink(temp) }
    guard (try? heading.write(toFile: temp, atomically: false, encoding: .utf8)) != nil else { return false }
    if link(temp, path) == 0 { return true }
    if errno == EEXIST { return true }
    // No hard links here: create exclusively and write the heading whole.
    let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    if fd < 0 { return errno == EEXIST }
    defer { close(fd) }
    let bytes = Array(heading.utf8)
    let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    if written != bytes.count {
      unlink(path)
      return false
    }
    return true
  }

  // MARK: Loading and saving

  private func load(_ path: String) {
    rememberCollapsedToggles()
    currentPath = path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      // Not UTF-8 (or unreadable): show it read-only so nothing here can
      // overwrite or copy a file we cannot represent.
      loadedText = ""
      textView.string = ""
      textView.isEditable = false
      codeBlocks.update()
      watch(path)
      panel.title = "Cannot read \((path as NSString).lastPathComponent) as UTF-8"
      return
    }
    textView.isEditable = true
    loadedText = text
    // Setting the string resets the caret; keep relocation off for that,
    // then place the caret with relocation on (so it never rests on a
    // fence) but with fence edits off (so opening a note never changes it).
    textView.suppressFenceRelocation = true
    textView.string = text
    textView.suppressFenceRelocation = false
    textView.restoreCollapsedToggles(collapsedToggles[path] ?? [])
    restyle()
    textView.suppressFenceEdits = true
    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    textView.suppressFenceEdits = false
    textView.undoManager?.removeAllActions()
    textView.scrollToEndOfDocument(nil)
    codeBlocks.update()
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

  /// Generated filenames follow the note's first line (its title), as
  /// the Raycast extension does. Only the slug changes; the id stays, and
  /// links to the old name in the notes folder follow.
  private func renameToMatchTitleIfNeeded() {
    guard let path = currentPath, let titleText = Titles.firstLine(of: loadedText) else { return }
    let filename = (path as NSString).lastPathComponent
    let directory = (path as NSString).deletingLastPathComponent
    guard let next = NoteNames.renamed(filename, title: titleText, newID: { self.freshID(in: directory) }) else { return }
    let nextPath = uniquePath(for: next, in: directory)
    guard nextPath != path, (try? diskFiles.moveItem(atPath: path, toPath: nextPath)) != nil else { return }
    currentPath = nextPath
    if let index = notes.firstIndex(where: { $0.path == path }) {
      notes[index] = Note(path: nextPath, modified: Date())
    }
    watch(nextPath)
    rewriteLinks(after: [path: nextPath])
    updateTitle()
  }

  /// An id no generated name in `directory` carries yet.
  private func freshID(in directory: String) -> String {
    NoteNames.newID(avoiding: NoteNames.ids(in: (try? diskFiles.contentsOfDirectory(atPath: directory)) ?? []))
  }

  /// After the window renamed notes (`moves`, old path to new): every link
  /// to them in a note under the notes folder points at the new name
  /// (NoteNames.rewriteLinks: atomic writes, modification dates move on).
  /// The open note is rewritten in the window instead (one undo step) and
  /// saved the usual way.
  private func rewriteLinks(after moves: [String: String]) {
    guard !moves.isEmpty else { return }
    NoteNames.rewriteLinks(underRoot: notesDir, moves: moves, skipping: currentPath)
    rewriteOpenNoteLinks(moves)
  }

  private func rewriteOpenNoteLinks(_ moves: [String: String]) {
    guard !moves.isEmpty, let current = currentPath, textView.isEditable else { return }
    let text = textView.string
    if let updated = NoteNames.rewriteLinks(in: text, directory: (current as NSString).deletingLastPathComponent, moves: moves),
      let edit = NoteNames.edit(from: text, to: updated, caret: textView.selectedRange().location)
    {
      textView.apply(edit)
    }
  }

  /// The folder whose names are fully brought up to date (`migrateNames`).
  private var migratedFolder: String?

  /// Generated names from before ids get one (NoteNames.migrateFolder),
  /// with the renames logged in `.note-renames.json` and links to them
  /// rewritten. Only the notes folder itself is renamed in; daily and
  /// hand-named notes stay as they are. Until a run completes, every
  /// listing tries again; after that, once per folder per launch.
  private func migrateNamesIfNeeded() {
    guard migratedFolder != notesDir else { return }
    saveNow()
    let outcome = NoteNames.migrateFolder(notesDir, root: notesDir, openPath: currentPath)
    if let current = currentPath, let moved = outcome.renamed[current] {
      currentPath = moved
      watch(moved)
    }
    rewriteOpenNoteLinks(outcome.rewritten)
    if outcome.complete { migratedFolder = notesDir }
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
    let collapsed = textView.collapsedToggleKeys()
    loadedText = onDisk
    textView.string = onDisk
    textView.restoreCollapsedToggles(collapsed)
    restyle()
    let length = (onDisk as NSString).length
    textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    updateTitle()
  }

  /// Notes the open note's collapsed toggles before another replaces it.
  private func rememberCollapsedToggles() {
    guard let path = currentPath, textView.isEditable else { return }
    collapsedToggles[path] = textView.collapsedToggleKeys()
  }

  // MARK: Editing helpers

  func restyle() {
    guard let storage = textView.textStorage else { return }
    let selection = textView.selectedRange()
    Markdown.apply(to: storage)
    textView.setSelectedRange(selection)
    textView.typingAttributes = [.font: Markdown.baseFont, .foregroundColor: NSColor.labelColor]
    codeBlocks?.update()
    updateStatus()
  }

  /// Formatting picked from the "T" button or ⌘K: focus the note again,
  /// then make the same edit its key would.
  private func applyFormat(_ format: NoteTextView.Format) {
    guard textView.isEditable else {
      NSSound.beep()
      return
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(textView)
    textView.applyFormat(format)
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
    if url.scheme == Markdown.taskScheme {
      if let location = Int(url.lastPathComponent) { toggleTask(atBox: location) }
      return true
    }
    // A link to another note (`[Title](file.md)`) opens it here when the
    // note is in the notes folder, in its default app when it is not; one
    // to a note that is gone beeps rather than going to the browser.
    guard let target = NoteLinks.notePath(for: url, in: currentDirectory) else { return false }
    guard let path = existingNote(at: target) else {
      NSSound.beep()
      return true
    }
    if NoteLinks.opensInWindow(path, root: notesDir) {
      // After the click finishes, so the text is not swapped mid-tracking.
      DispatchQueue.main.async { [weak self] in
        self?.open(path)
        self?.show()
      }
    } else {
      NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    return true
  }

  /// The folder links in the open note are relative to.
  private var currentDirectory: String {
    currentPath.map { ($0 as NSString).deletingLastPathComponent } ?? notesDir
  }

  /// `path` when the file is there; otherwise the note the migration's
  /// rename log sends its name to, or the one note beside it carrying the
  /// same id (renamed since the link was written).
  private func existingNote(at path: String) -> String? {
    if diskFiles.fileExists(atPath: path) { return path }
    let directory = (path as NSString).deletingLastPathComponent
    let filename = (path as NSString).lastPathComponent
    // A name from before ids: where the migration's log says it went.
    if let log = NoteNames.renameLog(in: directory),
      let logged = NoteLinks.renamedByLog(filename, renames: log.renames, exists: {
        diskFiles.fileExists(atPath: (directory as NSString).appendingPathComponent($0))
      })
    {
      return (directory as NSString).appendingPathComponent(logged)
    }
    let names = (try? diskFiles.contentsOfDirectory(atPath: directory)) ?? []
    return NoteNames.parse(filename)?.id == nil ? nil
      : NoteLinks.noteWithSameID(as: filename, among: names).map { (directory as NSString).appendingPathComponent($0) }
  }

  private static func noteTitle(_ text: String, _ filename: String) -> String { title(of: text, filename: filename) }

  /// Titles the "[[" picker read, by path, with the modification date they
  /// were read at: an unchanged note is not read again.
  private var linkTitles: [String: (modified: Date, title: String)] = [:]

  /// The notes "[[" offers: every other note in the folder, most
  /// recently modified first, titled as the title bar titles them (from
  /// the first few KB of each file).
  private func noteLinkTargets() -> [NoteLinks.Target] {
    let directory = currentDirectory
    let notes = listNotes().filter { $0.path != currentPath }
    var titles: [String: (modified: Date, title: String)] = [:]
    let targets = notes.map { note -> NoteLinks.Target in
      let title: String
      if let cached = linkTitles[note.path], cached.modified == note.modified {
        title = cached.title
      } else {
        var head = NoteLinks.headText(atPath: note.path) ?? ""
        // A note whose first lines are all blank or fences past the limit.
        if Titles.firstLine(of: head) == nil, (head as NSString).length >= NoteLinks.headLimit - 4 {
          head = (try? String(contentsOfFile: note.path, encoding: .utf8)) ?? head
        }
        title = PanelController.noteTitle(head, note.filename)
      }
      titles[note.path] = (note.modified, title)
      return NoteLinks.Target(
        title: title, target: NoteLinks.linkTarget(for: note.path, from: directory), modified: note.modified)
    }
    linkTitles = titles
    return targets
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

  /// The title bar shows just the note's title (with • while unsaved);
  /// its position in the list goes to the bottom bar.
  private func updateTitle() {
    updateStatus()
    guard let path = currentPath else {
      panel.title = "Notes"
      return
    }
    guard textView.isEditable else { return }
    let noteTitle = title(of: textView.string, filename: (path as NSString).lastPathComponent)
    let unsaved = textView.string != loadedText ? " •" : ""
    panel.title = noteTitle + unsaved
  }

  private func updateStatus() {
    let position = currentIndex.map { "\($0 + 1)/\(notes.count)" }
    statusBar?.update(characters: textView.string.count, position: position)
  }
}
