import Foundation
import Testing

@testable import LedgeSystem

/// The badge the ears show for an input source, worked out over the enabled
/// sources.
///
/// The fixtures are what Text Input Sources reports on macOS 26 — id, name
/// and the first language — read off a real Mac with every source listed.
/// The old rule cut the first language to two letters, so every source of one
/// language read the same: Turkish Q and F were both TR, ABC and Dvorak both
/// EN, and a switch between them flashed a badge that said nothing changed.
@Suite("Keyboard badge")
struct KeyboardBadgeTests {

    private static func source(_ id: String, _ name: String, _ language: String) -> KeyboardSourceFacts {
        KeyboardSourceFacts(id: id, name: name, languages: [language])
    }

    static let turkishQ = source("com.apple.keylayout.Turkish-QWERTY-PC", "Turkish Q", "tr")
    static let turkishF = source("com.apple.keylayout.Turkish-Standard", "Turkish F", "tr")
    static let turkishQLegacy = source("com.apple.keylayout.Turkish-QWERTY", "Turkish Q – Legacy", "tr")
    static let turkishFLegacy = source("com.apple.keylayout.Turkish", "Turkish F – Legacy", "tr")
    static let abc = source("com.apple.keylayout.ABC", "ABC", "en")
    static let us = source("com.apple.keylayout.US", "U.S.", "en")
    static let usInternational = source(
        "com.apple.keylayout.USInternational-PC", "U.S. International – PC", "en")
    static let british = source("com.apple.keylayout.British", "British", "en")
    static let britishPC = source("com.apple.keylayout.British-PC", "British – PC", "en")
    static let australian = source("com.apple.keylayout.Australian", "Australian", "en")
    static let canadian = source("com.apple.keylayout.Canadian", "Canadian", "en")
    static let irish = source("com.apple.keylayout.Irish", "Irish", "en")
    static let german = source("com.apple.keylayout.German", "German", "de")
    static let austrian = source("com.apple.keylayout.Austrian", "Austrian", "de")
    static let swissGerman = source("com.apple.keylayout.SwissGerman", "Swiss German", "de")
    static let abcQWERTZ = source("com.apple.keylayout.ABC-QWERTZ", "ABC – QWERTZ", "de")
    static let french = source("com.apple.keylayout.French", "French", "fr")
    static let abcAZERTY = source("com.apple.keylayout.ABC-AZERTY", "ABC – AZERTY", "fr")
    static let abcIndia = source("com.apple.keylayout.ABC-India", "ABC – India", "en")
    static let ukrainian = source("com.apple.keylayout.Ukrainian-PC", "Ukrainian", "uk")
    static let dvorak = source("com.apple.keylayout.Dvorak", "Dvorak", "en")
    static let dvorakLeft = source("com.apple.keylayout.Dvorak-Left", "Dvorak – Left-Handed", "en")
    static let colemak = source("com.apple.keylayout.Colemak", "Colemak", "en")
    static let pinyin = source("com.apple.inputmethod.SCIM.ITABC", "Pinyin – Simplified", "zh-Hans")
    static let wubi = source("com.apple.inputmethod.SCIM.WBX", "Wubi – Simplified", "zh-Hans")
    static let pinyinTraditional = source(
        "com.apple.inputmethod.TCIM.Pinyin", "Pinyin – Traditional", "zh-Hant")
    static let zhuyin = source("com.apple.inputmethod.TCIM.Zhuyin", "Zhuyin – Traditional", "zh-Hant")
    static let hiragana = source(
        "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "Hiragana", "ja")
    static let katakana = source(
        "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese.Katakana", "Katakana", "ja")
    static let romaji = source("com.apple.inputmethod.Kotoeri.RomajiTyping.Roman", "Romaji", "en")
    static let korean2 = source("com.apple.inputmethod.Korean.2SetKorean", "2-Set Korean", "ko")
    static let korean3 = source("com.apple.inputmethod.Korean.3SetKorean", "3-Set Korean", "ko")
    static let korean390 = source("com.apple.inputmethod.Korean.390Sebulshik", "3-Set Korean (390)", "ko")
    static let russian = source("com.apple.keylayout.Russian", "Russian", "ru")
    static let russianPC = source("com.apple.keylayout.RussianWin", "Russian – PC", "ru")
    static let cherokee = source("com.apple.keylayout.Cherokee-Nation", "Cherokee – Nation", "chr")
    static let cherokeeQWERTY = source("com.apple.keylayout.Cherokee-QWERTY", "Cherokee – QWERTY", "chr")
    static let hawaiian = source("com.apple.keylayout.Hawaiian", "Hawaiian", "haw")
    static let cantonese = source("com.apple.inputmethod.TYIM.Phonetic", "Phonetic – Cantonese", "yue-Hant")
    static let dhivehi = source("com.apple.keylayout.Dhivehi-QWERTY", "Dhivehi", "dv")

    static let everything: [KeyboardSourceFacts] = [
        turkishQ, turkishF, turkishQLegacy, turkishFLegacy, abc, us, usInternational, british, britishPC,
        australian, canadian, irish, german, austrian, swissGerman, abcQWERTZ, french, abcAZERTY,
        abcIndia, ukrainian, dvorak,
        dvorakLeft, colemak, pinyin, wubi, pinyinTraditional, zhuyin, hiragana, katakana, romaji,
        korean2, korean3, korean390, russian, russianPC, cherokee, cherokeeQWERTY, hawaiian,
        cantonese, dhivehi,
    ]

    /// The codes for an enabled set, by name.
    private func badges(_ enabled: [KeyboardSourceFacts]) -> [String: String] {
        let codes = KeyboardBadge.codes(for: enabled)
        return Dictionary(uniqueKeysWithValues: enabled.map { ($0.name, codes[$0.id] ?? "–") })
    }

    /// Proves a fixture really is the case under test: the sources share a
    /// language, which is what made the old badge useless.
    private func requireShared(_ sources: KeyboardSourceFacts...) throws {
        let languages = Set(sources.map(KeyboardBadge.language(of:)))
        try #require(languages.count == 1, "fixture does not share a language: \(languages)")
    }

    @Test("The owner's Turkish Q and ABC still read TR and EN")
    func theOwnersPair() {
        #expect(badges([Self.turkishQ, Self.abc]) == ["Turkish Q": "TR", "ABC": "EN"])
    }

    @Test("Turkish Q and Turkish F are told apart by the letter their names add")
    func turkishQAndF() throws {
        try requireShared(Self.turkishQ, Self.turkishF)
        #expect(badges([Self.turkishQ, Self.turkishF]) == ["Turkish Q": "TRQ", "Turkish F": "TRF"])
        // A third language beside them changes nothing for it.
        #expect(badges([Self.turkishQ, Self.turkishF, Self.abc])["ABC"] == "EN")
        // Q's letter is taken by Turkish Q, so the legacy layout takes the
        // first letter of its next word.
        #expect(badges([Self.turkishQ, Self.turkishF, Self.turkishQLegacy])
            == ["Turkish Q": "TRQ", "Turkish F": "TRF", "Turkish Q – Legacy": "TRL"])
    }

    @Test("A letter already taken gives way to the next one, then to a digit")
    func aFreeLetter() throws {
        // All four Turkish layouts: both legacy ones want L, and the second
        // has only the letters of its own words left.
        try requireShared(Self.turkishQ, Self.turkishF, Self.turkishQLegacy, Self.turkishFLegacy)
        #expect(badges([Self.turkishQ, Self.turkishF, Self.turkishQLegacy, Self.turkishFLegacy]) == [
            "Turkish F": "TRF", "Turkish F – Legacy": "TRL",
            "Turkish Q": "TRQ", "Turkish Q – Legacy": "TRE",
        ])
        // A name whose every letter is taken: only a digit is left.
        let mein = ["Mein", "Mein B", "Mein B B"].map {
            KeyboardSourceFacts(id: "org.example.keylayout.\($0)", name: $0, languages: ["de"])
        }
        #expect(badges(mein) == ["Mein": "DE", "Mein B": "DEB", "Mein B B": "DE2"])
    }

    @Test("English layouts read by a name of their own")
    func theEnglishFamily() throws {
        try requireShared(Self.abc, Self.dvorak, Self.colemak, Self.us, Self.british)
        #expect(badges([Self.abc, Self.dvorak]) == ["ABC": "ABC", "Dvorak": "DV"])
        #expect(badges([Self.abc, Self.colemak]) == ["ABC": "ABC", "Colemak": "CO"])
        #expect(badges([Self.abc, Self.dvorak, Self.dvorakLeft])
            == ["ABC": "ABC", "Dvorak": "DV", "Dvorak – Left-Handed": "DVL"])
        // Two of one family: what the names add, as anywhere else.
        #expect(badges([Self.us, Self.usInternational])
            == ["U.S.": "US", "U.S. International – PC": "USI"])
        #expect(badges([Self.british, Self.britishPC]) == ["British": "GB", "British – PC": "GBP"])
        // One without a name of its own keeps the language.
        let workman = KeyboardSourceFacts(id: "org.example.keylayout.Workman", name: "Workman", languages: ["en"])
        #expect(badges([workman, Self.dvorak]) == ["Workman": "EN", "Dvorak": "DV"])
    }

    @Test("National layouts read by the country on their flag")
    func nationalLayouts() throws {
        try requireShared(Self.abc, Self.us, Self.british, Self.australian, Self.canadian, Self.irish)
        // ENA beside ENB said nothing, and ENA was ABC on one Mac and
        // Australian on the next.
        #expect(badges([Self.abc, Self.british]) == ["ABC": "ABC", "British": "GB"])
        #expect(badges([Self.abc, Self.us]) == ["ABC": "ABC", "U.S.": "US"])
        #expect(badges([Self.us, Self.british, Self.australian, Self.canadian, Self.irish])
            == ["U.S.": "US", "British": "GB", "Australian": "AU", "Canadian": "CA", "Irish": "IE"])
        try requireShared(Self.german, Self.austrian, Self.swissGerman, Self.abcQWERTZ)
        #expect(badges([Self.german, Self.abcQWERTZ, Self.swissGerman, Self.austrian])
            == ["German": "DEG", "ABC – QWERTZ": "DEA", "Swiss German": "CH", "Austrian": "AT"])
    }

    @Test("Ukrainian reads UA, so nothing beside GB reads as Britain")
    func ukrainianIsUA() throws {
        try #require(Self.ukrainian.languages.first == "uk")
        #expect(badges([Self.british, Self.us, Self.ukrainian])
            == ["British": "GB", "U.S.": "US", "Ukrainian": "UA"])
        // Its own language, not a name of its own: alone, too.
        #expect(badges([Self.ukrainian, Self.abc]) == ["Ukrainian": "UA", "ABC": "EN"])
    }

    @Test("ABC is ABC only in English; the German and French ABCs are told apart by step 3")
    func abcVariantsOfOtherLanguages() throws {
        // Matched by how the id began, ABC – QWERTZ took "ABC" in the German
        // group while ABC itself, alone in English, read EN: the wrong way
        // round. Here ABC is alone in its language, so it reads EN, and the
        // variant reads as what it is, a German or French layout.
        try #require(KeyboardBadge.language(of: Self.abcQWERTZ) != KeyboardBadge.language(of: Self.abc))
        #expect(badges([Self.abc, Self.abcQWERTZ, Self.german])
            == ["ABC": "EN", "ABC – QWERTZ": "DEA", "German": "DEG"])
        #expect(badges([Self.abc, Self.abcAZERTY, Self.french])
            == ["ABC": "EN", "ABC – AZERTY": "FRA", "French": "FRF"])
        // ABC – India is English, and an ABC.
        try requireShared(Self.abc, Self.abcIndia, Self.british)
        #expect(badges([Self.abc, Self.abcIndia]) == ["ABC": "ABC", "ABC – India": "ABI"])
        #expect(badges([Self.abcIndia, Self.british]) == ["ABC – India": "ABC", "British": "GB"])
    }

    @Test("A name of its own needs a shared language: the owner's ABC stays EN")
    func ownNamesOnlyWhenShared() {
        #expect(badges([Self.abc]) == ["ABC": "EN"])
        #expect(badges([Self.british, Self.turkishQ]) == ["British": "EN", "Turkish Q": "TR"])
    }

    @Test("Japanese modes read as Apple's own kana glyphs")
    func japaneseKana() throws {
        try requireShared(Self.hiragana, Self.katakana)
        #expect(badges([Self.hiragana, Self.katakana, Self.romaji, Self.abc])
            == ["Hiragana": "あ", "Katakana": "ア", "Romaji": "A", "ABC": "ABC"])
        // Alone in their languages, Hiragana and Romaji need nothing more.
        #expect(badges([Self.hiragana, Self.romaji]) == ["Hiragana": "JA", "Romaji": "EN"])
    }

    @Test("Chinese methods read by their short names")
    func chineseMethods() throws {
        try requireShared(Self.pinyin, Self.zhuyin, Self.wubi)
        #expect(badges([Self.pinyin, Self.zhuyin]) == ["Pinyin – Simplified": "PY", "Zhuyin – Traditional": "ZY"])
        #expect(badges([Self.pinyin, Self.wubi, Self.abc])
            == ["Pinyin – Simplified": "PY", "Wubi – Simplified": "WB", "ABC": "EN"])
        // The same method twice: what the names add tells them apart.
        #expect(badges([Self.pinyin, Self.pinyinTraditional])
            == ["Pinyin – Simplified": "PYS", "Pinyin – Traditional": "PYT"])
    }

    @Test("Korean sets read by their number")
    func koreanSets() throws {
        try requireShared(Self.korean2, Self.korean3)
        #expect(badges([Self.korean2, Self.korean3]) == ["2-Set Korean": "KO2", "3-Set Korean": "KO3"])
        // "(390)" is the word only it has, so its letter comes from there —
        // "3" is taken, then "9" — before any from the "3-Set" it shares.
        #expect(badges([Self.korean2, Self.korean3, Self.korean390])
            == ["2-Set Korean": "KO2", "3-Set Korean": "KO3", "3-Set Korean (390)": "KO9"])
    }

    @Test("Russian beside Russian – PC: the plain one keeps the plain code")
    func thePlainOneKeepsIt() throws {
        try requireShared(Self.russian, Self.russianPC)
        #expect(badges([Self.russian, Self.russianPC, Self.abc])
            == ["Russian": "RU", "Russian – PC": "RUP", "ABC": "EN"])
    }

    @Test("Three-letter languages keep all three letters, and never grow past them")
    func threeLetterLanguages() throws {
        try #require(Self.cherokee.languages.first?.count == 3)
        // Cut to two these were CH, HA and YU — real codes of other languages.
        #expect(badges([Self.cherokee, Self.hawaiian, Self.cantonese, Self.abc])
            == ["Cherokee – Nation": "CHR", "Hawaiian": "HAW", "Phonetic – Cantonese": "YUE", "ABC": "EN"])
        // Told apart, they give up the third letter rather than reach four.
        #expect(badges([Self.cherokee, Self.cherokeeQWERTY])
            == ["Cherokee – Nation": "CHN", "Cherokee – QWERTY": "CHQ"])
    }

    @Test("Initials come from words with letters in them, not from a dash")
    func initialsSkipTheDash() throws {
        let name = "Pinyin – Simplified"
        // The fixture has to hold a word with no letter in it.
        try #require(name.split(separator: " ").contains { !$0.contains(where: \.isLetter) })
        #expect(KeyboardBadge.initials(of: name) == "PS")
        // Through the rule, for a source that reports no language at all…
        let untagged = KeyboardSourceFacts(id: "org.example.keylayout.Stroke", name: "Stroke – Simplified", languages: [])
        #expect(KeyboardBadge.codes(for: [untagged])[untagged.id] == "SS")
        // …and for the empty tag Unicode Hex Input reports.
        let hex = KeyboardSourceFacts(id: "com.apple.keylayout.UnicodeHexInput", name: "Unicode Hex Input", languages: [""])
        #expect(KeyboardBadge.codes(for: [hex, Self.abc])[hex.id] == "UH")
    }

    @Test("A letter whose capital is two letters stays as it is")
    func uppercaseNeverGrows() throws {
        // "ß".uppercased() is "SS": taken as the added letter, a code would
        // reach four characters.
        try #require("ß".uppercased().count == 2)
        #expect(KeyboardBadge.initials(of: "ßa ßb") == "ßß")
        let plain = KeyboardSourceFacts(id: "org.example.keylayout.Mein", name: "Mein", languages: ["de"])
        let other = KeyboardSourceFacts(id: "org.example.keylayout.MeinS", name: "Mein ßtrich", languages: ["de"])
        let codes = KeyboardBadge.codes(for: [plain, other])
        #expect(codes[other.id] == "DEß")
        #expect(codes[plain.id] == "DE")
    }

    @Test("A source alone in its language reads the plain language, whatever it is called")
    func aSingleSource() {
        #expect(badges([Self.turkishF]) == ["Turkish F": "TR"])
        #expect(badges([Self.dvorak]) == ["Dvorak": "EN"])
        #expect(badges([Self.zhuyin, Self.turkishQ]) == ["Zhuyin – Traditional": "ZH", "Turkish Q": "TR"])
    }

    @Test("Codes follow the enabled set as it changes, and stay unique in every one")
    func uniqueAsSetsChange() throws {
        // Adding Turkish F is what gives Turkish Q something to be told from;
        // removing it gives the plain code back.
        var enabled = [Self.turkishQ, Self.abc]
        #expect(badges(enabled)["Turkish Q"] == "TR")
        enabled.append(Self.turkishF)
        #expect(badges(enabled)["Turkish Q"] == "TRQ")
        enabled.removeAll { $0 == Self.turkishF }
        #expect(badges(enabled)["Turkish Q"] == "TR")

        // Every pair, every growing prefix, and the whole table at once.
        var sets: [[KeyboardSourceFacts]] = []
        for (i, a) in Self.everything.enumerated() {
            for b in Self.everything[(i + 1)...] { sets.append([a, b]) }
            sets.append(Array(Self.everything[...i]))
        }
        try #require(sets.count > Self.everything.count * 2)
        for set in sets {
            let codes = KeyboardBadge.codes(for: set)
            #expect(Set(set.map(\.id)) == Set(codes.keys))
            for source in set {
                let code = try #require(codes[source.id])
                #expect(!code.isEmpty && code.count <= KeyboardBadge.maxLength, "\(source.name): \(code)")
            }
            let names = Dictionary(grouping: set) { codes[$0.id] ?? "" }.mapValues { Set($0.map(\.name)) }
            for (code, shared) in names {
                #expect(shared.count == 1, "\(code) is shared by \(shared.sorted())")
            }
        }
    }

    @Test("A name of its own that is another language's code is still told apart")
    func borrowedCodeMeetsALanguage() throws {
        // Dvorak's DV is Dhivehi's language code.
        try #require(KeyboardBadge.ownName(of: Self.dvorak) == KeyboardBadge.language(of: Self.dhivehi))
        let codes = badges([Self.abc, Self.dvorak, Self.dhivehi])
        #expect(Set(codes.values).count == 3)
    }

    @Test("The order TIS lists the sources in changes nothing")
    func orderIndependent() {
        let forwards = KeyboardBadge.codes(for: Self.everything)
        let backwards = KeyboardBadge.codes(for: Self.everything.reversed())
        let shuffled = KeyboardBadge.codes(for: Self.everything.sorted { $0.name.count < $1.name.count })
        #expect(forwards == backwards)
        #expect(forwards == shuffled)
    }

    @Test("A source not on the enabled list gets a code none of them holds")
    func aSourceMacOSPicked() throws {
        let enabled = [Self.abc, Self.dvorak]
        let enabledCodes = Set(KeyboardBadge.codes(for: enabled).values)
        try #require(enabledCodes == ["ABC", "DV"])
        let code = KeyboardBadge.code(for: Self.romaji, among: enabled)
        #expect(!enabledCodes.contains(code))
        #expect(code.count <= KeyboardBadge.maxLength)
        // And one that is on the list gets the code it has there.
        #expect(KeyboardBadge.code(for: Self.abc, among: enabled) == "ABC")
    }
}
