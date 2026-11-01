import Foundation

/// What the badge rule knows about one keyboard input source: the three
/// things Text Input Sources reports for it, and nothing that needs TIS to
/// run — so the rule can be tested against a table.
public struct KeyboardSourceFacts: Equatable, Sendable {
    /// `kTISPropertyInputSourceID`: "com.apple.keylayout.Turkish-QWERTY-PC".
    public var id: String
    /// What the input menu calls it: "Turkish Q".
    public var name: String
    /// `kTISPropertyInputSourceLanguages`, the source's own language first.
    public var languages: [String]

    public init(id: String, name: String, languages: [String]) {
        self.id = id
        self.name = name
        self.languages = languages
    }
}

/// The short code the ears show for a keyboard input source.
///
/// The code has one job: to read differently for each source the user
/// switches *between*. The language tag alone failed it exactly where it
/// mattered — Turkish Q and Turkish F were both TR, ABC and Dvorak both EN,
/// Hiragana and Katakana both JA — so a switch flashed a badge saying nothing
/// had changed, and Dvorak, Turkish F and Zhuyin type nothing like their
/// neighbours. So the code is worked out over the sources the user has
/// *enabled*, the only ones a switch can land on, in four steps:
///
/// 1. **The language, when that is enough.** The primary subtag of the first
///    language, uppercased whole: two letters for a two-letter tag (TR, EN),
///    three for a three-letter one (CHR, HAW, YUE) — cut to two, Cherokee read
///    as Chamorro's CH. A source with no language takes the initials of its
///    words that have letters in them; the dash in "Pinyin – Simplified" is
///    not a word. One language reads as its country instead: Ukrainian is UA,
///    because UK is what everyone reads as Britain, and Britain is GB here.
///    A code no other enabled source has is the badge, which is why the
///    owner's Turkish Q and ABC still read TR and EN.
/// 2. **A name of its own, among sources sharing a language.** What people
///    already call these by: Dvorak DV, Colemak CO, Pinyin PY, Zhuyin ZY,
///    Wubi WB, Shuangpin SP, Cangjie CJ, Sucheng SC; the kana modes by
///    Apple's own menu-bar glyphs — Hiragana あ, Katakana ア, half-width ｱ,
///    full-width romaji Ａ, Romaji A; and the national Latin layouts by the
///    code on their flag — U.S. US, British GB, Australian
///    AU, Canadian CA, Irish IE, Austrian AT, Swiss CH, Brazilian BR — with
///    the English ABC layouts as ABC. Matched on the source id, which unlike
///    the name reads the same in every language macOS runs in.
/// 3. **Otherwise, what the names add.** Among sources still sharing a code,
///    the words all their names have in common are set aside, and each adds
///    the first letter or digit of what it has left — a word no other source
///    in the group has, when it has one, because that is the word that tells
///    it apart: Turkish Q and Turkish F read TRQ and TRF, 2-Set and 3-Set
///    Korean KO2 and KO3, the two Pinyins PYS and PYT. One with no word left
///    keeps the code — it is the one the others are being told apart from —
///    so Russian beside Russian – PC reads RU and RUP, Dvorak beside
///    Dvorak – Left-Handed DV and DVL. A code over two characters gives up
///    its last one for the letter (Cherokee – Nation is CHN), because nothing
///    is ever longer than three.
/// 4. **A letter that is still free.** If that letter is taken, the first
///    letter of its other words, then any letter or digit in them — all of
///    it from the words only it has before any from the words it shares, so
///    3-Set Korean (390) beside 3-Set Korean reads KO9 — then a digit. Two
///    sources whose names differ never share a code.
///
/// The code depends on the enabled set by design: Turkish Q is TR on its own
/// and TRQ the moment Turkish F is added, because only then is there
/// something to tell it from. Sources with the very same name get the same
/// code — macOS offers nothing that tells the two Hiragana modes apart in the
/// menu either, and the card's title could not say which was which.
public enum KeyboardBadge {

    /// The ears give the code a fixed slot. A code that would not fit is
    /// shortened, never the ear widened.
    public static let maxLength = 3

    /// The code for every source in `sources`, keyed by source id.
    ///
    /// Order-independent: the same set gives the same codes however TIS
    /// happens to list it.
    public static func codes(for sources: [KeyboardSourceFacts]) -> [String: String] {
        var seen = Set<String>()
        let sources = sources.filter { seen.insert($0.id).inserted }
        var codes = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, language(of: $0)) })

        // 2. Only where a language is shared: a lone Dvorak is plain EN.
        for group in sharing(sources, codes) {
            for source in group {
                if let own = ownName(of: source) { codes[source.id] = own }
            }
        }
        // 3 and 4, over whatever still collides — including a name of its own
        // that met another source's language code (Dvorak's DV is Dhivehi's).
        for group in sharing(sources, codes) {
            separate(group, codes: &codes)
        }
        return codes
    }

    /// The code for `source` among the enabled sources, whether or not it is
    /// one of them: a source macOS selected on its own still needs a code
    /// none of the enabled ones holds.
    public static func code(for source: KeyboardSourceFacts, among enabled: [KeyboardSourceFacts]) -> String {
        codes(for: [source] + enabled)[source.id] ?? language(of: source)
    }

    // MARK: - Step 1

    /// The language as a code, or the name's initials when there is none.
    static func language(of source: KeyboardSourceFacts) -> String {
        if let first = source.languages.first {
            // "en-GB", "zh-Hans" and "bs_Cyrl" all reduce to the leading subtag.
            let subtag = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if (2...maxLength).contains(subtag.count), subtag.allSatisfy(\.isLetter) {
                return languagesReadAsCountries[subtag.lowercased()] ?? subtag.uppercased()
            }
        }
        return initials(of: source.name)
    }

    /// Language codes that read as another country's: UK is Britain to
    /// everyone, and beside GB a Ukrainian badge said the wrong thing.
    private static let languagesReadAsCountries: [String: String] = ["uk": "UA"]

    /// Two initials, from words with letters in them only. Split on spaces
    /// alone, "Pinyin – Simplified" counted its dash as a word and read "P–".
    static func initials(of name: String) -> String {
        let initials = name.split(whereSeparator: \.isWhitespace)
            .compactMap { $0.first(where: \.isLetter) }
        return initials.prefix(2).map(upper).joined()
    }

    // MARK: - Step 2

    /// Matched on the last part of the id: "com.apple.inputmethod.TCIM.Zhuyin"
    /// and the same mode in another vendor's method alike.
    private static let ownNames: [String: String] = [
        "itabc": "PY", "pinyin": "PY",
        "zhuyin": "ZY", "zhuyineten": "ZY",
        "wbx": "WB", "wubi": "WB",
        "shuangpin": "SP",
        "cangjie": "CJ",
        "jianyi": "SC", "sucheng": "SC",
        "japanese": "あ", "hiragana": "あ",
        "katakana": "ア",
        "halfwidthkana": "ｱ",
        "fullwidthroman": "Ａ",
        "roman": "A",
        // The national Latin layouts, by the country on the flag macOS shows
        // for them. ENA beside ENB said nothing at a glance, and ENA meant ABC
        // on one Mac and Australian on the next.
        "us": "US", "usinternational-pc": "US",
        // The English ABCs only. ABC – QWERTZ and ABC – AZERTY are German and
        // French layouts: given "ABC" too, they took it in their own language
        // group while ABC itself, alone in English, read EN — the badges the
        // wrong way round for anyone with both. They fall to step 3.
        "abc": "ABC", "abc-india": "ABC", "usextended": "ABC",
        "british": "GB", "british-pc": "GB",
        "australian": "AU",
        "canadian": "CA", "canadian-csa": "CA", "canadianfrench-pc": "CA",
        "irish": "IE",
        "newzealand": "NZ",
        "austrian": "AT",
        "swissgerman": "CH", "swissfrench": "CH",
        "belgian": "BE",
        "latinamerican": "LA",
    ]

    /// Layouts with a name of their own come in families — Dvorak – Left-Handed,
    /// Dvorak – QWERTY ⌘, a third-party Colemak-DH, Brazilian – ABNT2 — so
    /// these match on how the last part of the id begins. Exact matches
    /// above, because "roman" begins "Romanian", "us" begins half the
    /// alphabet, and "abc" begins layouts of other languages.
    private static let ownFamilies: [(prefix: String, code: String)] = [
        ("dvorak", "DV"), ("colemak", "CO"), ("brazilian", "BR"),
    ]

    static func ownName(of source: KeyboardSourceFacts) -> String? {
        let last = (source.id.split(separator: ".").last.map(String.init) ?? source.id).lowercased()
        if let own = ownNames[last] { return own }
        return ownFamilies.first { last.hasPrefix($0.prefix) }?.code
    }

    // MARK: - Steps 3 and 4

    /// Sources sharing a code while their names differ, one group per code,
    /// in code order so the outcome never depends on the order of the list.
    private static func sharing(
        _ sources: [KeyboardSourceFacts], _ codes: [String: String]
    ) -> [[KeyboardSourceFacts]] {
        let byCode: [String: [KeyboardSourceFacts]] = Dictionary(grouping: sources) { source in
            codes[source.id] ?? ""
        }
        return byCode.keys.sorted().compactMap { code -> [KeyboardSourceFacts]? in
            guard let group = byCode[code], Set(group.map(\.name)).count > 1 else { return nil }
            return group
        }
    }

    /// Tells apart sources that share a code, by what their names add.
    private static func separate(_ group: [KeyboardSourceFacts], codes: inout [String: String]) {
        guard let stem = group.first.flatMap({ codes[$0.id] }) else { return }
        // Same name, same code: they are handled as one.
        let names = Set(group.map(\.name)).sorted()
        let words = Dictionary(uniqueKeysWithValues: names.map { ($0, Self.words(of: $0)) })
        let shared = names.dropFirst().reduce(Set(words[names[0]] ?? [])) {
            $0.intersection(words[$1] ?? [])
        }
        let base = stem.count < maxLength ? stem : String(stem.prefix(maxLength - 1))
        var taken = Set(codes.values)

        for name in names {
            let own = (words[name] ?? []).filter { !shared.contains($0) }
            // Nothing beyond the shared words: the one the others are told
            // apart from keeps the code.
            guard !own.isEmpty else { continue }
            // Everything from the words only it has before anything from the
            // words it shares: "(390)" is what sets 3-Set Korean (390) apart,
            // while its "3-Set" is 3-Set Korean's too.
            let alone = own.filter { word in
                !names.contains { $0 != name && (words[$0] ?? []).contains(word) }
            }
            let rest = own.filter { !alone.contains($0) }
            let candidates = [alone, rest].flatMap { words in
                words.compactMap { $0.first(where: isMark) } + words.flatMap { $0.filter(isMark) }
            }
            let digits: [Character] = ["2", "3", "4", "5", "6", "7", "8", "9"]
            guard let code = (candidates + digits).lazy
                .map({ base + upper($0) })
                .first(where: { !taken.contains($0) })
            else { continue }
            taken.insert(code)
            for source in group where source.name == name { codes[source.id] = code }
        }
    }

    /// Words that carry a letter or a digit — "2-Set" does, the dash between
    /// words and a "⌘" do not.
    private static func words(of name: String) -> [String] {
        name.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.contains(where: isMark) }
    }

    private static func isMark(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Uppercased when that stays one character: "ß" would become "SS" and
    /// push a code past the slot.
    private static func upper(_ character: Character) -> String {
        let upper = String(character).uppercased()
        return upper.count == 1 ? upper : String(character)
    }
}
