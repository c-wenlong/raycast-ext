import AppKit
import Foundation

// MARK: - Appearance and font settings
//
// Window settings picked from the settings popover (or sent over the socket
// as `appearance-dark`, `font-serif`, ...) and remembered in UserDefaults
// next to the zoom: the appearance (follow the system, or force light or
// dark) and the note's typeface (the system sans serif, its serif design
// New York, or its monospaced design). Code spans and code blocks stay
// monospaced whichever typeface is picked.

/// The window's appearance. Forcing one sets `NSApp.appearance`, which
/// every window of the helper inherits: the panel and its child panels
/// (⌘K palette, slash menu, link bubble and editor, language picker),
/// menus and the find bar.
enum NoteAppearance: String, CaseIterable {
  case system, light, dark

  var title: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  var command: String { "appearance-" + rawValue }
  /// Shown in the zoom HUD's bubble after a change.
  var announcement: String { self == .system ? "System appearance" : "\(title) appearance" }
  var symbol: String {
    switch self {
    case .system: return "circle.lefthalf.filled"
    case .light: return "sun.max"
    case .dark: return "moon"
    }
  }

  /// nil follows the system.
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}

/// The note's typeface: one of the three designs of the system font, so
/// sizes, weights and metrics line up (all three have an 18pt line at
/// 15pt, so the 28pt pitch holds).
enum NoteFont: String, CaseIterable {
  case sans, serif, mono

  var title: String {
    switch self {
    case .sans: return "Sans Serif"
    case .serif: return "Serif"
    case .mono: return "Mono"
    }
  }

  var command: String { "font-" + rawValue }
  var announcement: String {
    switch self {
    case .sans: return "Sans serif font"
    case .serif: return "Serif font"
    case .mono: return "Mono font"
    }
  }
  var symbol: String {
    switch self {
    case .sans: return "textformat"
    case .serif: return "book"
    case .mono: return "chevron.left.forwardslash.chevron.right"
    }
  }

  /// Extra words the palette search matches.
  var keywords: String {
    switch self {
    case .sans: return "sans-serif system"
    case .serif: return "new york"
    case .mono: return "monospace monospaced"
    }
  }

  var design: NSFontDescriptor.SystemDesign {
    switch self {
    case .sans: return .default
    case .serif: return .serif
    case .mono: return .monospaced
    }
  }

  /// The system font at `size` and `weight` in this design; the plain
  /// system font if the design is missing.
  func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    let system = NSFont.systemFont(ofSize: size, weight: weight)
    guard self != .sans, let descriptor = system.fontDescriptor.withDesign(design),
      let font = NSFont(descriptor: descriptor, size: size)
    else { return system }
    return font
  }
}

enum NoteSettings {
  static let appearanceKey = "notesPanelAppearance"
  static let fontKey = "notesPanelFont"
  static let attachmentKey = "notesPanelAttachment"

  static func appearance(in defaults: UserDefaults = .standard) -> NoteAppearance {
    defaults.string(forKey: appearanceKey).flatMap(NoteAppearance.init(rawValue:)) ?? .system
  }

  static func font(in defaults: UserDefaults = .standard) -> NoteFont {
    defaults.string(forKey: fontKey).flatMap(NoteFont.init(rawValue:)) ?? .sans
  }

  static func attachment(in defaults: UserDefaults = .standard) -> NoteAttachment {
    defaults.string(forKey: attachmentKey).flatMap(NoteAttachment.init(rawValue:)) ?? .floating
  }

  static func save(_ appearance: NoteAppearance, in defaults: UserDefaults = .standard) {
    defaults.set(appearance.rawValue, forKey: appearanceKey)
  }

  static func save(_ font: NoteFont, in defaults: UserDefaults = .standard) {
    defaults.set(font.rawValue, forKey: fontKey)
  }

  static func save(_ attachment: NoteAttachment, in defaults: UserDefaults = .standard) {
    defaults.set(attachment.rawValue, forKey: attachmentKey)
  }

  enum Change: Equatable {
    case appearance(NoteAppearance)
    case font(NoteFont)
    case attachment(NoteAttachment)
  }

  /// The setting a command (`appearance-dark`, `font-serif`, `attachment-notch`, ...) picks.
  static func change(forCommand command: String) -> Change? {
    if let appearance = NoteAppearance.allCases.first(where: { $0.command == command }) { return .appearance(appearance) }
    if let font = NoteFont.allCases.first(where: { $0.command == command }) { return .font(font) }
    if let attachment = NoteAttachment.allCases.first(where: { $0.command == command }) { return .attachment(attachment) }
    return nil
  }


}

/// Loads, applies and saves settings from the popover or socket.
final class SettingsController {
  private let defaults: UserDefaults
  private(set) var appearance: NoteAppearance
  private(set) var attachment: NoteAttachment
  var onChange: () -> Void = {}
  /// Called after a change is applied: restyle, relayout, announce.
  var onAppearance: (NoteAppearance) -> Void = { _ in }
  var onFont: (NoteFont) -> Void = { _ in }
  /// Called after the attachment changes; the controller only persists it,
  /// the panel does the moving. It may refuse a change it cannot serve.
  var onAttachment: (NoteAttachment) -> Bool = { _ in true }

  /// Reads the stored settings and applies them (`NSApp.appearance`,
  /// `Markdown.font`); call before the panel is built.
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = NoteSettings.appearance(in: defaults)
    attachment = NoteSettings.attachment(in: defaults)
    Markdown.font = NoteSettings.font(in: defaults)
    NSApp.appearance = appearance.nsAppearance
  }

  /// Applies `command` if it is a setting command; false otherwise.
  @discardableResult
  func handle(_ command: String) -> Bool {
    guard let change = NoteSettings.change(forCommand: command) else { return false }
    switch change {
    case .appearance(let value):
      appearance = value
      NoteSettings.save(value, in: defaults)
      // Every window of the helper inherits the app's appearance.
      NSApp.appearance = value.nsAppearance
      onAppearance(value)
    case .font(let value):
      Markdown.font = value
      NoteSettings.save(value, in: defaults)
      onFont(value)
    case .attachment(let value):
      guard value != attachment else { break }
      // The panel moves first; refusing keeps the old attachment.
      guard onAttachment(value) else { return true }
      attachment = value
      NoteSettings.save(value, in: defaults)
    }
    onChange()
    return true
  }
}
