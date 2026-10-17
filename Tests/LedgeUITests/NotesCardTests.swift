import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// What the notes card shows, and what it refuses to do while somebody is
/// pointing at it.
@Suite("The notes card")
@MainActor
struct NotesCardTests {

    private let clock = Date(timeIntervalSince1970: 1_792_000_000)

    private func note(_ id: String, _ title: String = "A note",
                      ago: TimeInterval = 600, preview: String = "") -> NoteSummary {
        NoteSummary(id: id, title: title, preview: preview,
                    editedAt: clock.timeIntervalSince1970 - ago)
    }

    private func card(_ notes: [NoteSummary], open: String? = nil,
                      opening: String? = nil, openingIsSlow: Bool = false,
                      failed: NoteSummary? = nil) -> NotesCardView {
        NotesCardView(
            payload: NotesPayload(notes: notes, openNoteID: open),
            now: { clock },
            opening: opening,
            openingIsSlow: openingIsSlow,
            failed: failed
        )
    }

    private func drawn(_ view: some View, width: CGFloat = 275) -> CGSize? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 2
        return renderer.nsImage?.size
    }

    // MARK: - What is shown

    @Test("The card shows five notes and turns the rest into a count")
    func fiveAndACount() {
        let many = (0 ..< 312).map { note("n\($0)", "Note \($0)") }
        let view = card(many)
        #expect(view.shown.count == 5)
        #expect(view.hidden == 307)
        #expect(NotesCopy.allNotes(312) == "All 312 notes")
    }

    @Test("With nothing hidden there is no door to open")
    func noDoorWhenNothingIsHidden() {
        // The count used to be text that named notes the card could not
        // reach. It is the way in now, so it must not appear when there is
        // nowhere to go.
        #expect(card((0 ..< 5).map { note("n\($0)") }).hidden == 0)
        #expect(card([note("a")]).hidden == 0)
    }

    @Test("The card is the same size at twelve notes and at three hundred")
    func heightDoesNotGrowWithTheCollection() {
        guard let twelve = drawn(card((0 ..< 12).map { note("n\($0)", "Note \($0)") })),
              let many = drawn(card((0 ..< 312).map { note("n\($0)", "Note \($0)") }))
        else { Issue.record("both must draw"); return }
        #expect(twelve.height == many.height,
                "the card grew with a collection it is not trying to hold")
    }

    @Test("Every face draws at the widths the island gives it")
    func drawsEverywhere() {
        let faces: [NotesCardView] = [
            card([]),
            card([note("a", "Only one", preview: "with a line of its own")]),
            card((0 ..< 12).map { note("n\($0)", "Note \($0)") }),
            card((0 ..< 12).map { note("n\($0)", "Note \($0)") }, open: "n2"),
            card([note("u", "", preview: "no first line yet")] + (0 ..< 4).map { note("n\($0)") }),
            card((0 ..< 12).map { note("n\($0)") }, failed: note("n1", "Gone"))
        ]
        for face in faces {
            for width in [231, 260, 275, 283, 320] as [CGFloat] {
                guard let size = drawn(face, width: width) else {
                    Issue.record("a face would not draw at \(width)")
                    continue
                }
                #expect(size.height > 0)
                #expect(size.height <= 300 * 2, "the card must stay under the 300pt cap")
            }
        }
    }

    // MARK: - The time column

    @Test("The time column is a time, Open, or Opening…")
    func whatTheTrailingColumnSays() {
        let a = note("a", "A", ago: 2 * 3600)
        let view = card([a], open: "a")
        #expect(view.trailing(for: a) == .open, "the note the window has open says so")

        let plain = card([a])
        #expect(plain.trailing(for: a) == .when("2h"))

        // Opening only once the wait has lasted. Before that the column still
        // reads as a time: a word that flashes and vanishes is a fault.
        #expect(card([a], opening: "a").trailing(for: a) == .when("2h"))
        #expect(card([a], opening: "a", openingIsSlow: true).trailing(for: a) == .opening)
    }

    @Test("Open and Opening are marked; a time is not")
    func onlyNewsIsMarked() {
        // The amber is the window's mark for the note it has open. A date is
        // not news and must not wear it.
        #expect(NoteRowTrailing.open.isMarked)
        #expect(NoteRowTrailing.opening.isMarked)
        #expect(!NoteRowTrailing.when("2h").isMarked)
        #expect(!NoteRowTrailing.when("Yesterday").isMarked)
    }

    // MARK: - The order, under a pointer

    @Test("The order is the payload's when nobody is pointing at the card")
    func orderFollowsThePayload() {
        let notes = [note("a", "A"), note("b", "B"), note("c", "C")]
        #expect(card(notes).ordered.map(\.id) == ["a", "b", "c"])
    }

    @Test("A note that moves while the pointer is on the card does not jump")
    func theOrderIsHeldUnderTheHand() {
        // A note edited in the window moves to the top on the next publish,
        // and the publish arrives while somebody's pointer is over the row
        // that is about to move. The list is held still and catches up when
        // the pointer leaves.
        // "c" was edited and the provider now lists it first, while the card
        // is holding the order it had when the pointer arrived.
        let shuffled = NotesPayload(
            notes: [note("c", "C"), note("a", "A"), note("b", "B")]
        )
        let held = NotesCardView(payload: shuffled, now: { clock },
                                 frozenOrder: ["a", "b", "c"])
        #expect(held.ordered.map(\.id) == ["a", "b", "c"],
                "the row under the pointer moved out from under it")

        let released = NotesCardView(payload: shuffled, now: { clock })
        #expect(released.ordered.map(\.id) == ["c", "a", "b"],
                "the order must catch up once the pointer has gone")
    }

    @Test("A note made while the order is held joins the end, and a deleted one drops out")
    func arrivalsAndDeparturesUnderTheHand() {
        let view = NotesCardView(
            payload: NotesPayload(notes: [note("new", "New"), note("a", "A")]),
            now: { clock },
            frozenOrder: ["a", "b"]
        )
        // "b" is gone and "new" has arrived: held order first, then arrivals,
        // and nothing invented.
        #expect(view.ordered.map(\.id) == ["a", "new"])
    }
}
