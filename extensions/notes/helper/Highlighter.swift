import AppKit
import Foundation

// MARK: - Code block syntax highlighting
//
// A small regex tokenizer. Each language is an ordered list of rules
// (comments and strings first, so they win over keywords) compiled into one
// alternation, so a block is scanned once, left to right. Identifiers are
// then looked up in the language's keyword and type sets. Only
// `.foregroundColor` is touched; Markdown.apply has already set the font.

enum Highlighter {
  enum Kind {
    case comment, string, number, keyword, type, removed, word
  }

  struct Language {
    var rules: [(String, Kind)]
    var keywords: Set<String> = []
    var types: Set<String> = []
    /// Treat Capitalised identifiers as types (Swift, Rust, Java...).
    var capitalizedTypes = false
    /// Match keywords ignoring case (SQL).
    var caseInsensitive = false
  }

  static func highlight(_ storage: NSTextStorage, body: NSRange, language: String) {
    guard body.length > 0, NSMaxRange(body) <= storage.length else { return }
    let text = (storage.string as NSString).substring(with: body)
    var id = canonical(language)
    if id == nil, !plainNames.contains(language.lowercased()) { id = guess(text) }
    guard let id, let lang = languages[id], let scanner = compiled(id, lang) else { return }

    let ns = text as NSString
    for match in scanner.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      guard match.range.length > 0,
        let index = scanner.ruleGroups.firstIndex(where: { match.range(at: $0).location != NSNotFound })
      else { continue }
      var resolved = lang.rules[index].1
      if resolved == .word {
        let word = ns.substring(with: match.range)
        let key = lang.caseInsensitive ? word.lowercased() : word
        if lang.keywords.contains(key) {
          resolved = .keyword
        } else if lang.types.contains(key) {
          resolved = .type
        } else if lang.capitalizedTypes, let first = word.unicodeScalars.first,
          CharacterSet.uppercaseLetters.contains(first), word.count > 1 {
          resolved = .type
        } else {
          continue
        }
      }
      let range = NSRange(location: body.location + match.range.location, length: match.range.length)
      storage.addAttribute(.foregroundColor, value: color(resolved), range: range)
    }
  }

  // MARK: Colours
  //
  // Each keeps 4.5:1 against the code card in its appearance (tested in
  // test/text-view).

  private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let c = isDark ? dark : light
      return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }
  }

  static let keywordColor = dynamic(dark: (0.93, 0.55, 0.29), light: (0.68, 0.30, 0.04))
  static let stringColor = dynamic(dark: (0.60, 0.80, 0.50), light: (0.18, 0.47, 0.15))
  static let numberColor = dynamic(dark: (0.55, 0.75, 0.95), light: (0.13, 0.42, 0.78))
  static let typeColor = dynamic(dark: (0.76, 0.62, 0.95), light: (0.50, 0.30, 0.78))
  static let removedColor = dynamic(dark: (0.95, 0.45, 0.45), light: (0.78, 0.18, 0.18))

  private static func color(_ kind: Kind) -> NSColor {
    switch kind {
    case .comment: return .secondaryLabelColor
    case .string: return stringColor
    case .number: return numberColor
    case .keyword: return keywordColor
    case .type: return typeColor
    case .removed: return removedColor
    case .word: return .labelColor
    }
  }

  // MARK: Language lookup

  /// Fence words that mean "no highlighting at all".
  private static let plainNames: Set<String> = ["plain", "text", "txt", "plaintext", "none", "nohighlight"]

  private static let aliases: [String: String] = [
    "py": "python", "python3": "python", "py3": "python",
    "js": "javascript", "mjs": "javascript", "cjs": "javascript", "node": "javascript",
    "ts": "typescript", "tsx": "typescript", "jsx": "typescript", "mts": "typescript",
    "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash", "shellscript": "bash", "fish": "bash",
    "jsonc": "json", "json5": "json",
    "golang": "go",
    "rs": "rust",
    "h": "c",
    "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
    "cs": "csharp", "c#": "csharp",
    "kt": "kotlin", "kts": "kotlin",
    "rb": "ruby",
    "objc": "objectivec", "objective-c": "objectivec", "m": "objectivec", "mm": "objectivec",
    "pl": "perl", "pm": "perl",
    "rscript": "r",
    "psql": "sql", "mysql": "sql", "sqlite": "sql", "postgres": "sql", "postgresql": "sql",
    "htm": "html", "xml": "html", "svg": "html", "xhtml": "html", "vue": "html",
    "scss": "css", "less": "css", "sass": "css",
    "yml": "yaml",
    "md": "markdown", "mdx": "markdown",
    "patch": "diff",
  ]

  private static func canonical(_ language: String) -> String? {
    let key = language.lowercased()
    if languages[key] != nil { return key }
    return aliases[key]
  }

  /// Cheap signals for an unlabelled (or unknown) block; falls back to
  /// strings and numbers only.
  static func guess(_ body: String) -> String {
    let sample = body.count > 2000 ? String(body.prefix(2000)) : body
    func has(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> Bool {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
      return regex.firstMatch(in: sample, range: NSRange(location: 0, length: (sample as NSString).length)) != nil
    }
    let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
    if has(#"\A\s*#!.*\b(?:ba|z|fi)?sh\b"#) { return "bash" }
    if has(#"\A\s*#!.*python"#) { return "python" }
    if has(#"\A\s*#!.*node"#) { return "javascript" }
    if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && has(#""[^"\n]*"\s*:"#) { return "json" }
    if has(#"^(?:diff --git|@@ .* @@)"#) { return "diff" }
    if has(#"^\s*<(?:!DOCTYPE|html|div|span|p|a|body|head|svg|\?xml)\b"#, [.anchorsMatchLines, .caseInsensitive]) { return "html" }
    if has(#"^\s*(?:SELECT|INSERT INTO|CREATE TABLE|UPDATE|DELETE FROM)\b"#, [.anchorsMatchLines, .caseInsensitive]) { return "sql" }
    if has(#"^\s*(?:def |class |import |from \w+ import )"#) && has(#":[ \t]*$"#) { return "python" }
    if has(#"^\s*\$ "#) { return "bash" }
    if has(#"^package \w+"#) || (has(#":="#) && has(#"\bfunc "#)) { return "go" }
    if has(#"\bfn \w+"#) || has(#"\blet mut "#) { return "rust" }
    if has(#"\bfunction\b|^\s*const |=>|\bconsole\."#) { return "javascript" }
    if has(#"\bfunc \w+|^\s*(?:let|var|guard|import (?:Foundation|SwiftUI|AppKit|UIKit))\b"#) { return "swift" }
    if has(#"^\s*(?:def |import |print\()"#) { return "python" }
    return "fallback"
  }

  // MARK: Compiled regex cache

  /// One language's rules joined into a single alternation, plus the capture
  /// group that starts each rule (a rule may hold groups of its own).
  private struct Scanner {
    let regex: NSRegularExpression
    let ruleGroups: [Int]
  }

  private static var cache: [String: Scanner] = [:]

  private static func compiled(_ id: String, _ lang: Language) -> Scanner? {
    if let hit = cache[id] { return hit }
    var groups: [Int] = []
    var next = 1
    for (pattern, _) in lang.rules {
      groups.append(next)
      next += 1 + ((try? NSRegularExpression(pattern: pattern))?.numberOfCaptureGroups ?? 0)
    }
    let pattern = lang.rules.map { "(\($0.0))" }.joined(separator: "|")
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
    let scanner = Scanner(regex: regex, ruleGroups: groups)
    cache[id] = scanner
    return scanner
  }

  // MARK: Shared patterns

  private static let slash = #"//[^\n]*"#
  private static let hash = #"#[^\n]*"#
  private static let cBlock = #"/\*[\s\S]*?(?:\*/|\z)"#
  private static let dq = #""(?:[^"\\\n]|\\.)*"?"#
  private static let sq = #"'(?:[^'\\\n]|\\.)*'?"#
  private static let bt = #"`(?:[^`\\]|\\[\s\S])*`?"#
  private static let tripleDQ = #""""[\s\S]*?(?:"""|\z)"#
  private static let tripleSQ = #"'''[\s\S]*?(?:'''|\z)"#
  private static let charLit = #"'(?:\\.|[^'\\\n])'"#
  private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[a-zA-Z]*\b"#
  private static let ident = #"[A-Za-z_]\w*"#
  private static let identDollar = #"[A-Za-z_$][\w$]*"#
  private static let annotation = #"@[A-Za-z_][\w.]*"#

  private static func words(_ list: String) -> Set<String> {
    Set(list.split(separator: " ").map(String.init))
  }

  /// C-family: // and /* */ comments, "..." strings, 'c' characters.
  private static func cFamily(keywords: String, types: String = "", strings: [String] = [dq, charLit],
                              extra: [(String, Kind)] = [], capitalized: Bool = true, ident: String = ident) -> Language {
    var rules: [(String, Kind)] = [(slash, .comment), (cBlock, .comment)]
    rules += strings.map { ($0, .string) }
    rules += extra
    rules += [(number, .number), (ident, .word)]
    return Language(rules: rules, keywords: words(keywords), types: words(types), capitalizedTypes: capitalized)
  }

  private static let jsKeywords = "break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield async await null undefined true false get set"
  private static let jsBuiltins = "console Object Array String Number Boolean Promise Map Set JSON Math Date Error RegExp Symbol window document require module process globalThis"
  private static let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL"
  private static let cTypes = "size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t uintptr_t FILE"
  private static let preprocessor: [(String, Kind)] = [
    (#"(?<=include)[ \t]*<[^>\n]*>"#, .string),
    (#"^[ \t]*#[ \t]*\w+"#, .keyword),
  ]

  // MARK: Languages

  static let languages: [String: Language] = [
    "fallback": Language(rules: [(dq, .string), (sq, .string), (number, .number)]),

    "python": Language(
      rules: [(hash, .comment), (tripleDQ, .string), (tripleSQ, .string), (dq, .string), (sq, .string),
              (annotation, .type), (number, .number), (ident, .word)],
      keywords: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
      types: words("self cls print len range int str float list dict set tuple bool bytes type object super open enumerate zip map filter sorted reversed min max sum any all isinstance Exception ValueError TypeError KeyError")),

    "javascript": cFamily(keywords: jsKeywords, types: jsBuiltins, strings: [bt, dq, sq], capitalized: false, ident: identDollar),

    "typescript": cFamily(
      keywords: jsKeywords + " interface type enum implements private public protected readonly declare namespace abstract as is keyof infer never unknown any satisfies",
      types: jsBuiltins + " string number boolean void object symbol bigint", strings: [bt, dq, sq], ident: identDollar),

    "swift": cFamily(
      keywords: "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public rethrows static struct subscript typealias var break case continue default defer do else fallthrough for guard if in repeat return switch where while as catch false is nil super self Self throw throws true try await async actor some any lazy weak unowned override final mutating nonmutating convenience required dynamic get set willSet didSet indirect",
      strings: [tripleDQ, dq], extra: [(#"[@#][A-Za-z_]\w*"#, .keyword)]),

    "bash": Language(
      rules: [(#"(?<![\w$#])#[^\n]*"#, .comment), (dq, .string), (#"'[^'\n]*'?"#, .string),
              (#"\$(?:\{[^}\n]*\}?|[A-Za-z_]\w*|[0-9#?@*$!-])"#, .type), (number, .number), (ident, .word)],
      keywords: words("if then else elif fi case esac for while until do done in function return exit local export readonly declare unset shift break continue source alias set"),
      types: words("echo cd pwd ls cat grep sed awk printf read test mkdir rm cp mv chmod chown sudo git npm npx node python3 curl brew make touch find xargs")),

    "json": Language(
      rules: [(slash, .comment), (cBlock, .comment), (#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, .type), (dq, .string),
              (#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, .number), (ident, .word)],
      keywords: words("true false null")),

    "go": cFamily(
      keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false iota",
      types: "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any append cap close copy delete len make new panic print println recover",
      strings: [#"`[^`]*`?"#, dq, charLit], capitalized: false),

    "rust": cFamily(
      keywords: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while",
      types: "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str",
      extra: [(#"'[A-Za-z_]\w*\b(?!')"#, .type), (#"\b[A-Za-z_]\w*!"#, .keyword), (#"#!?\[[^\]\n]*\]"#, .type)]),

    "c": cFamily(keywords: cKeywords, types: cTypes, extra: preprocessor, capitalized: false),

    "cpp": cFamily(
      keywords: cKeywords + " class namespace template typename public private protected virtual override final new delete this throw try catch using nullptr constexpr decltype explicit friend operator mutable noexcept static_cast dynamic_cast reinterpret_cast const_cast co_await co_return co_yield concept requires",
      types: cTypes + " std string vector map unordered_map set unique_ptr shared_ptr optional", extra: preprocessor),

    "objectivec": cFamily(
      keywords: cKeywords + " self super nil Nil YES NO id instancetype nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull",
      types: cTypes + " BOOL NSInteger NSUInteger CGFloat SEL",
      strings: [#"@?"(?:[^"\\\n]|\\.)*"?"#, charLit], extra: preprocessor + [(#"@[A-Za-z_]\w*"#, .keyword)]),

    "csharp": cFamily(
      keywords: "abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using var virtual void volatile while async await get set value record init yield",
      strings: [#"@"(?:[^"]|"")*"?"#, dq, charLit], extra: [(#"^[ \t]*#[ \t]*\w+"#, .keyword)]),

    "java": cFamily(
      keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var record sealed permits yield",
      strings: [tripleDQ, dq, charLit], extra: [(annotation, .type)]),

    "kotlin": cFamily(
      keywords: "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor finally get import init set where abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg",
      strings: [tripleDQ, dq, charLit], extra: [(annotation, .type)]),

    "ruby": Language(
      rules: [(#"^=begin[\s\S]*?(?:^=end|\z)"#, .comment), (hash, .comment), (dq, .string), (sq, .string),
              (#"(?<![:\w]):[A-Za-z_]\w*[?!]?"#, .type), (#"@@?[A-Za-z_]\w*"#, .type), (number, .number), (ident, .word)],
      keywords: words("BEGIN END alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer puts private protected public lambda proc"),
      capitalizedTypes: true),

    "php": Language(
      rules: [(slash, .comment), (hash, .comment), (cBlock, .comment), (dq, .string), (sq, .string),
              (#"<\?php|\?>"#, .keyword), (#"\$[A-Za-z_]\w*"#, .type), (number, .number), (ident, .word)],
      keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new null or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false self parent"),
      capitalizedTypes: true),

    "perl": Language(
      rules: [(hash, .comment), (dq, .string), (sq, .string), (#"[$@%][A-Za-z_]\w*"#, .type), (number, .number), (ident, .word)],
      keywords: words("my our local sub if elsif else unless while until for foreach do last next redo return use no require package print say die warn eval defined undef and or not eq ne lt gt le ge cmp qw")),

    "r": Language(
      rules: [(hash, .comment), (dq, .string), (sq, .string), (number, .number), (#"[A-Za-z_.][\w.]*"#, .word)],
      keywords: words("if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA NA_integer_ NA_real_ NA_character_ return library require"),
      types: words("c list vector data.frame matrix factor print paste paste0 length sum mean")),

    "sql": Language(
      rules: [(#"--[^\n]*"#, .comment), (cBlock, .comment), (#"'(?:[^']|'')*'?"#, .string), (number, .number), (ident, .word)],
      keywords: words("select from where and or not insert into values update set delete create table drop alter add column index primary key foreign references join inner left right outer full cross on as group by order having limit offset distinct union all case when then else end is null like ilike in between exists default unique constraint view with returning begin commit rollback transaction if cascade asc desc true false"),
      types: words("int integer bigint smallint varchar char text boolean bool date time timestamp timestamptz numeric decimal real float double serial bigserial uuid json jsonb blob count sum avg min max coalesce now"),
      caseInsensitive: true),

    "html": Language(
      rules: [(#"<!--[\s\S]*?(?:-->|\z)"#, .comment), (#"<![A-Za-z][^>\n]*>?"#, .comment),
              (#"</?[A-Za-z][\w:.-]*"#, .keyword), (#"/?>"#, .keyword),
              (#"(?<==)"[^"\n]*"?|(?<==)'[^'\n]*'?"#, .string), (#"\b[\w:-]+(?==)"#, .type), (#"&#?\w+;"#, .number)]),

    "css": Language(
      rules: [(cBlock, .comment), (slash, .comment), (dq, .string), (sq, .string),
              (#"@[\w-]+|!important"#, .keyword), (#"#[0-9a-fA-F]{3,8}\b"#, .number),
              (#"^[ \t]*[\w-]+(?=[ \t]*:[^{\n]*$)"#, .keyword), (#"[.#][A-Za-z_-][\w-]*"#, .type),
              (#"(?<![\w-])-?\d*\.?\d+(?:[a-zA-Z]+|%)?"#, .number)]),

    "yaml": Language(
      rules: [(#"(?<!\S)#[^\n]*"#, .comment), (#"^(?:---|\.\.\.)[ \t]*$"#, .keyword), (dq, .string), (sq, .string),
              (#"^[ \t]*(?:- +)?[^\s:#'"-][^:\n]*?(?=:(?:[ \t]|$))"#, .keyword), (#"[&*][\w-]+"#, .type),
              (number, .number), (ident, .word)],
      types: words("true false null yes no on off True False Null")),

    "toml": Language(
      rules: [(hash, .comment), (#"^[ \t]*\[\[?[^\]\n]*\]\]?"#, .type), (#"^[ \t]*[\w.\-"']+(?=[ \t]*=)"#, .keyword),
              (tripleDQ, .string), (tripleSQ, .string), (dq, .string), (#"'[^'\n]*'?"#, .string),
              (number, .number), (ident, .word)],
      types: words("true false inf nan")),

    "markdown": Language(
      rules: [(#"^#{1,6}[ \t][^\n]*"#, .keyword), (#"^>[^\n]*"#, .comment), (#"`[^`\n]+`"#, .string),
              (#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .type), (#"^[ \t]*(?:[-*+]|\d+\.)(?=[ \t])"#, .number),
              (#"\[[^\]\n]*\]\([^)\n]*\)"#, .number)]),

    "diff": Language(
      rules: [(#"^(?:diff |index |\+\+\+ |--- )[^\n]*"#, .comment), (#"^@@[^\n]*"#, .type),
              (#"^\+[^\n]*"#, .string), (#"^-[^\n]*"#, .removed)]),
  ]
}
