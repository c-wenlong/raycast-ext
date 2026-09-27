// The built-in blocking categories (PLAN.md "Blocking" table) and how a
// profile named in config resolves to the apps and hosts a session blocks.
// Pure Foundation.

import Foundation

struct BlockCategory: Equatable {
  var id: String
  var title: String
  /// Bundle ids.
  var apps: [String]
  /// Host suffixes, normalized ("youtube.com" also covers "m.youtube.com").
  var hosts: [String]
}

enum Categories {
  static let social = BlockCategory(
    id: "social", title: "Social", apps: [],
    hosts: [
      "instagram.com", "x.com", "twitter.com", "threads.net", "threads.com", "reddit.com", "tiktok.com",
      "facebook.com", "linkedin.com",
    ])

  static let messaging = BlockCategory(
    id: "messaging", title: "Messaging",
    apps: [
      "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.hnc.Discord",
      "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.facebook.archon",
    ],
    hosts: ["web.whatsapp.com", "web.telegram.org", "discord.com", "slack.com", "messenger.com"])

  static let gaming = BlockCategory(
    id: "gaming", title: "Gaming",
    apps: ["com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher", "net.battle.app"],
    hosts: ["chess.com", "lichess.org", "steampowered.com", "steamcommunity.com", "epicgames.com"])

  static let entertainment = BlockCategory(
    id: "entertainment", title: "Entertainment", apps: ["com.apple.TV"],
    hosts: ["youtube.com", "youtu.be", "netflix.com", "twitch.tv", "disneyplus.com", "open.spotify.com"])

  static let news = BlockCategory(
    id: "news", title: "News", apps: ["com.apple.news"],
    hosts: [
      "news.ycombinator.com", "bbc.com", "bbc.co.uk", "cnn.com", "straitstimes.com", "channelnewsasia.com",
    ])

  static let shopping = BlockCategory(
    id: "shopping", title: "Shopping", apps: [],
    hosts: ["amazon.com", "amazon.sg", "shopee.sg", "lazada.sg", "carousell.sg"])

  /// In PLAN's order; all of them are on in the built-in default profile.
  static let all: [BlockCategory] = [social, messaging, gaming, entertainment, news, shopping]

  static let byId: [String: BlockCategory] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// A profile name resolved for one session.
struct ResolvedProfile: Equatable {
  var profile: BlockProfile
  /// Set when the requested name was unknown and "default" was used instead.
  var fallbackFrom: String?
}

extension ProfileSpec {
  /// The effective sets: the union of the categories' apps and hosts plus the profile's own.
  func blockProfile(named name: String) -> BlockProfile {
    var apps = Set(self.apps)
    var hosts = Set(self.hosts.compactMap(Matching.normalizeHost))
    for id in categories {
      guard let category = Categories.byId[id] else { continue }
      apps.formUnion(category.apps)
      hosts.formUnion(category.hosts.compactMap(Matching.normalizeHost))
    }
    return BlockProfile(name: name, mode: mode, apps: apps, hosts: hosts)
  }
}

extension FocusConfig {
  /// The profile a session named `name` blocks with. An unknown name falls
  /// back to "default" (config's own, else the built-in one) and says so.
  func resolveProfile(named name: String) -> ResolvedProfile {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let spec = profiles[trimmed] {
      return ResolvedProfile(profile: spec.blockProfile(named: trimmed), fallbackFrom: nil)
    }
    let fallback = profiles["default"] ?? .builtInDefault
    return ResolvedProfile(profile: fallback.blockProfile(named: "default"), fallbackFrom: trimmed)
  }
}
