import Foundation
import Testing

/// Where the card's lifecycle work is allowed to hang.
///
/// `KeepAwakeCardFlow`'s own tests prove the transitions are right. They
/// cannot prove the view attaches them to the right thing, and that is where
/// the bug was: the transitions were fine and `.onDisappear` was on a *face*.
/// A face disappears whenever the other face replaces it, so pressing Lid
/// closed opened the length question and the handler on the face it was
/// pressed from closed it again in the same frame.
///
/// An earlier version of this suite only counted the modifiers. The reviewer
/// defeated it in one move: he deleted the handler from `body` and added one
/// to a face. The count stayed at one and every assertion passed. Counting
/// says how many there are, not what they are attached to — so these find the
/// `body` block by matching its braces and ask whether the handler is inside
/// it.
///
/// Reading the source is a blunt instrument. It is also the only thing that
/// can see this: every rendered card and every measured height is identical
/// whether the handler is on the card or on a face, because by the time
/// anything is drawn the question has already been closed again.
@Suite("The Keep Awake card's lifecycle work hangs off the card")
struct KeepAwakeCardLifecycleTests {

    static var cardSource: String {
        get throws {
            // From this file to the card, through the package root. Fragile to
            // a move, and loudly so: a missing file throws rather than passing
            // on an empty string.
            let here = URL(fileURLWithPath: #filePath)
            let root = here.deletingLastPathComponent()  // LedgeUITests
                .deletingLastPathComponent()             // Tests
                .deletingLastPathComponent()             // package root
            return try String(
                contentsOf: root.appending(path: "Sources/LedgeUI/Cards/KeepAwakeCardView.swift"),
                encoding: .utf8
            )
        }
    }

    /// The text of `public var body`, from its opening brace to the brace that
    /// closes it.
    ///
    /// Brace matching rather than a line count, because the point is the
    /// *scope*: a modifier two lines below the end of `body` is on something
    /// else entirely, and that difference is the whole bug.
    static func bodyBlock(of source: String) throws -> String {
        guard let declaration = source.range(of: "public var body: some View {") else {
            Issue.record("the card has no `body` — this suite is reading the wrong file")
            return ""
        }
        var depth = 0
        var index = source.index(before: declaration.upperBound)  // the opening brace
        var started = false
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1; started = true }
            if character == "}" {
                depth -= 1
                if started, depth == 0 {
                    return String(source[declaration.upperBound...index])
                }
            }
            index = source.index(after: index)
        }
        Issue.record("`body`'s braces never balanced")
        return ""
    }

    /// The source with its comment lines taken out.
    ///
    /// Every check here is about what the card *does*, and a comment saying
    /// why it deliberately does not do something is not the card doing it —
    /// the first version of the focus test failed on its own explanation.
    static func code(in source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("The only onDisappear is the card's own, inside body")
    func theDisappearanceIsTheCards() throws {
        let source = try Self.cardSource
        let body = try Self.bodyBlock(of: source)
        #expect(Self.count(".onDisappear", in: body) == 1, """
            `body` does not carry the card's `.onDisappear`. A face is not a \
            lifecycle: the resting face disappears when the question replaces \
            it, and the question disappears when it is answered.
            """)
        #expect(Self.count(".onDisappear", in: source) == 1, """
            There is an `.onDisappear` outside `body`. Whatever it does, it \
            runs on a face swap.
            """)
    }

    @Test("The only reset is the card's own, inside body")
    func theResetIsTheCards() throws {
        let source = try Self.cardSource
        let body = try Self.bodyBlock(of: source)
        #expect(Self.count("cardWentAway()", in: body) == 1,
                "`cardWentAway()` is the card's reset and must be called where the card ends")
        #expect(Self.count("cardWentAway()", in: source) == 1,
                "a second caller of `cardWentAway()` is a face pretending to be the card")
    }

    @Test("The lid reading is refreshed from the card, not from a face")
    func theRefreshIsTheCards() throws {
        // Same trap, quieter: a `.task` on a face is cancelled and restarted
        // every time the other face takes over, so the question's arrival
        // would cancel the very read the press is waiting on.
        let source = try Self.cardSource
        let body = try Self.bodyBlock(of: source)
        // Every form of it, and all of them in `body`. Counting one exact
        // spelling let `.task(id:)` in through the side door; what the rule
        // is about is where the work hangs, not how it is written.
        let inBody = Self.count(".task", in: body)
        #expect(inBody >= 1, "the card's read must hang off the card")
        #expect(Self.count(".task", in: source) == inBody,
                "a `.task` outside `body` is work a face swap restarts")
    }

    @Test("Nothing in the card keeps the question's state outside the flow")
    func noBackDoor() throws {
        // `isAsking` and `showsLidNote` are `private(set)`, so this cannot
        // happen through the value — but a `@State` flag of the same name
        // beside it would bring the whole bug back wearing different letters.
        // The transitions are the only way in.
        let source = try Self.cardSource
        #expect(!source.contains("@State private var isAsking"),
                "the question's state belongs to KeepAwakeCardFlow, where it is tested")
        #expect(!source.contains("@State private var lidNote"),
                "the lid sentence's state belongs to KeepAwakeCardFlow, where it is tested")
    }

    @Test("body is unconditional, so its lifecycle is the card's")
    func bodyIsUnconditional() throws {
        // The reviewer beat the two tests above twice. The second time, by
        // leaving one `.onDisappear` inside `body` and attaching it to a
        // branch that is itself conditional: every count holds, every scope
        // check holds, and the handler still fires on a face swap because the
        // thing it is attached to is a thing that disappears.
        //
        // So this asks the stronger question. `body` must be one unbranching
        // chain of modifiers on one view. Where a face is chosen is `content`,
        // one level down, and nothing with a lifecycle hangs off it.
        let body = try Self.bodyBlock(of: Self.cardSource)
        // View branching only. A `?` was on this list and caught `try?`
        // inside the card's own `.task`, which branches nothing and has no
        // face to disappear with — a guard that fires on the shape of the
        // code rather than on the thing it is about.
        // `.id(` belongs here too. It branches nothing and re-identifies
        // everything: giving `body`'s subtree a new identity on a face swap
        // tears the old one down, which runs the disappearance handler just
        // as surely as a branch would. The reviewer beat the first three
        // versions of this suite; that was his fourth move.
        for branch in ["if ", "switch ", "ForEach", ".id("] {
            #expect(!body.contains(branch), """
                `body` contains \(branch). A modifier on a branch runs when \
                that branch goes, and a face going is not the card going — \
                which is the bug this suite exists for, in its third costume.
                """)
        }
    }

    @Test("Nothing makes a stop take focus on its own")
    func noAutomaticFocus() throws {
        // `.focusable()` on the stops made something take focus the instant a
        // card was drawn, so every card opened showing a preview of a press
        // nobody had made. A Button is focusable when the user asks for it;
        // saying so unconditionally is what hijacked the resting sentence.
        //
        // Source, not behaviour: the rendered card is identical either way
        // until something actually mounts and focuses it, which is why the
        // test that was supposed to catch this could not.
        #expect(!Self.code(in: try Self.cardSource).contains(".focusable()"),
                "a stop that takes focus by itself shows a preview nobody asked for")
    }

    @Test("The brace matcher actually finds body, and would notice it moving")
    func theMatcherWorks() throws {
        // A scope test that silently matched the whole file would pass
        // everything above while checking nothing. This is the control.
        let source = try Self.cardSource
        let body = try Self.bodyBlock(of: source)
        #expect(!body.isEmpty)
        #expect(body.count < source.count / 2,
                "the matched block is most of the file — the braces did not balance where expected")
        #expect(body.contains("content"), "`body` should still be drawing `content`")
        #expect(!body.contains("private func switchRow"),
                "the match ran past the end of `body` into the card's other members")
    }
}
