import Foundation
import LedgeCore
import os
import Testing
@testable import LedgeSystem

/// Writing notes down, and getting them back.
///
/// Every test gets its own directory — never the real Application Support, the
/// same rule the device catalogue's tests follow.
@Suite("Notes, on disk")
struct NotesStoreTests {

    private func scratch() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-notes-tests/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A note survives being written and read back")
    func roundTrip() async {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 100 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("hello\nworld"))
        await store.flush()

        let fresh = NotesStore(directory: dir, now: { 200 })
        let read = await fresh.body(note.id)
        #expect(read?.plainText == "hello\nworld")
    }

    @Test("The first line is the title and the rest is the preview")
    func titleAndPreview() async {
        let store = NotesStore(directory: scratch(), now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("Shopping\nmilk\neggs"))
        let body = await store.body(note.id)
        #expect(body?.title == "Shopping")
        #expect(body?.preview == "milk eggs")
    }

    @Test("A note with only a first line has no preview")
    func noPreview() async {
        let store = NotesStore(directory: scratch(), now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("just this"))
        let body = await store.body(note.id)
        #expect(body?.title == "just this")
        #expect(body?.preview == "")
    }

    /// Bold and italic survive the trip, and store as Foundation's own integer
    /// rather than anything SwiftUI-shaped.
    @Test("Formatting survives being written and read back")
    func formattingRoundTrips() async {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        var text = AttributedString("the quick brown fox")
        let range = text.range(of: "quick")!
        text[range].inlinePresentationIntent = .stronglyEmphasized
        await store.update(note.id, text: text)
        await store.flush()

        let read = await NotesStore(directory: dir, now: { 2 }).body(note.id)
        let bolded = read?.text.runs.first { $0.inlinePresentationIntent != nil }
        #expect(bolded != nil, "the bold run did not survive")
        #expect(read?.plainText == "the quick brown fox")
    }

    @Test("The list is newest first")
    func newestFirst() async {
        // Boxed: a captured `var` is not sendable, and the store's clock
        // crosses into the actor.
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(100))
        let store = NotesStore(directory: scratch(), now: { clock.withLock { $0 } })
        let first = await store.create()
        await store.update(first.id, text: AttributedString("first"))
        clock.withLock { $0 = 200 }
        let second = await store.create()
        await store.update(second.id, text: AttributedString("second"))

        let list = await store.list()
        #expect(list.first?.id == second.id)
        #expect(list.count == 2)
    }

    /// The whole point of one file per note: typing in one must not rewrite
    /// the others. The device catalogue's mistake, not repeated.
    @Test("Editing one note does not rewrite another")
    func oneFilePerNote() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let a = await store.create()
        let b = await store.create()
        await store.update(a.id, text: AttributedString("a"))
        await store.update(b.id, text: AttributedString("b"))
        await store.flush()

        let bURL = dir.appendingPathComponent("\(b.id).json")
        let before = try FileManager.default.attributesOfItem(atPath: bURL.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(1100))

        await store.update(a.id, text: AttributedString("a changed"))
        await store.flush()

        let after = try FileManager.default.attributesOfItem(atPath: bURL.path)[.modificationDate] as? Date
        #expect(before == after, "editing one note rewrote another's file")
    }

    /// An edit that cancels itself out must not buy a write.
    @Test("Writing the same text twice touches the disk once")
    func dirtyCheck() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("stable"))
        await store.flush()

        let url = dir.appendingPathComponent("\(note.id).json")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(1100))

        // Identical text: `update` short-circuits, so nothing is even marked.
        await store.update(note.id, text: AttributedString("stable"))
        await store.flush()

        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == after, "an edit that changed nothing still wrote")
    }

    @Test("Deleting sets the file aside rather than destroying it")
    func deleteIsRecoverable() async {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("precious"))
        await store.flush()
        await store.delete(note.id)

        let list = await store.list()
        #expect(list.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(note.id).json").path) == false)

        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains("deleted") } ?? []
        #expect(aside.count == 1, "the note was destroyed rather than set aside")
    }

    /// Opening a note and closing it without typing leaves nothing behind.
    @Test("An untouched new note is discarded")
    func emptyNoteIsDiscarded() async {
        let store = NotesStore(directory: scratch(), now: { 1 })
        let note = await store.create()
        await store.discardIfEmpty(note.id)
        #expect(await store.list().isEmpty)
    }

    @Test("A note with text in it is never discarded")
    func writtenNoteSurvivesDiscard() async {
        let store = NotesStore(directory: scratch(), now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("something"))
        await store.discardIfEmpty(note.id)
        #expect(await store.list().count == 1)
    }

    /// A damaged file must cost the user that note, not every note.
    @Test("A corrupt note is set aside and the rest still load")
    func corruptNoteIsQuarantined() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let good = await store.create()
        await store.update(good.id, text: AttributedString("fine"))
        let bad = await store.create()
        await store.update(bad.id, text: AttributedString("doomed"))
        await store.flush()

        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("\(bad.id).json"))

        let fresh = NotesStore(directory: dir, now: { 2 })
        #expect(await fresh.body(bad.id) == nil)
        #expect(await fresh.body(good.id)?.plainText == "fine")
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains("unreadable") } ?? []
        #expect(aside.count == 1)
    }

    /// A note from a newer Ledge is not guessed at.
    @Test("A note from a later version is refused rather than downgraded")
    func futureVersionRefused() async throws {
        let dir = scratch()
        let id = UUID().uuidString
        let payload = """
        {"version": 99, "id": "\(id)", "text": "hello", "createdAt": 1, "editedAt": 1}
        """
        try Data(payload.utf8).write(to: dir.appendingPathComponent("\(id).json"))

        let store = NotesStore(directory: dir, now: { 1 })
        #expect(await store.body(id) == nil)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains("later-version") } ?? []
        #expect(aside.count == 1, "a note from the future was read anyway")
    }

    /// A corrupt index must not take the notes with it.
    /// A damaged index must cost the user the index, not the notes. Every note
    /// is still sitting in the folder; the index is only a cache of them.
    @Test("A corrupt index is rebuilt from the notes on disk")
    func corruptIndexIsRebuilt() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("precious research"))
        await store.flush()

        try Data("nonsense".utf8).write(to: dir.appendingPathComponent("index.json"))

        let fresh = NotesStore(directory: dir, now: { 2 })
        let list = await fresh.list()
        #expect(list.count == 1, "a damaged index hid an intact note")
        #expect(list.first?.title == "precious research")
    }

    /// The index is written on a longer debounce than the notes are, so a
    /// crash in between leaves a note saved and unlisted.
    @Test("A note saved before the index was written still appears")
    func noteWithoutIndexIsFound() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("survived the crash"))
        await store.flush()
        // The index never made it — exactly what a crash at the wrong moment
        // leaves behind.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("index.json"))

        let fresh = NotesStore(directory: dir, now: { 2 })
        #expect(await fresh.list().count == 1, "a note on disk was invisible")
    }

    /// The window stays open when Escape returns focus, so the note it is
    /// pointed at can be discarded while the user is still looking at it.
    @Test("A note typed into after it was discarded is not thrown away")
    func typingAfterDiscard() async {
        let store = NotesStore(directory: scratch(), now: { 1 })
        let note = await store.create()
        await store.discardIfEmpty(note.id)
        await store.update(note.id, text: AttributedString("the note"))
        await store.flush()
        #expect(await store.list().count == 1, "every keystroke went nowhere")
        #expect(await store.body(note.id)?.plainText == "the note")
    }

    /// An emptied note is not kept on the card — but it is not destroyed
    /// either. The file is set aside, which is what makes dropping it safe.
    @Test("A note emptied out is dropped from the card, not destroyed")
    func clearedNoteIsSetAside() async {
        let dir = scratch()
        let box = OSAllocatedUnfairLock(initialState: TimeInterval(100))
        let store = NotesStore(directory: dir, now: { box.withLock { $0 } })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("a year of research"))
        await store.flush()
        box.withLock { $0 = 200 }
        await store.update(note.id, text: AttributedString(""))
        await store.discardIfEmpty(note.id)

        #expect(await store.list().isEmpty, "an empty note was left on the card")
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains("discarded") } ?? []
        #expect(aside.count == 1, "the note was destroyed rather than set aside")
    }

    /// The case the user actually complained about: type something, change
    /// your mind, delete it, close the window.
    @Test("Typing then deleting everything leaves no note behind")
    func typedThenEmptiedIsDropped() async {
        // A moving clock, so `editedAt` genuinely leaves `createdAt` behind —
        // with a frozen one this passes whether or not the rule is right.
        let box = OSAllocatedUnfairLock(initialState: TimeInterval(100))
        let store = NotesStore(directory: scratch(), now: { box.withLock { $0 } })
        let note = await store.create()
        box.withLock { $0 = 150 }
        await store.update(note.id, text: AttributedString("draft"))
        await store.update(note.id, text: AttributedString("   \n  "))
        await store.discardIfEmpty(note.id)
        #expect(await store.list().isEmpty, "whitespace is not content")
    }

    /// A discarded note that *had* been written is set aside, not unlinked.
    @Test("Discarding sets a written file aside rather than destroying it")
    func discardIsRecoverable() async {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        // Typed into, so there is a file at all. A note that was never typed
        // into is never written, which is the rule the test below pins.
        await store.update(note.id, text: AttributedString("something"))
        await store.flush()
        await store.discardIfEmpty(note.id)
        // It is not empty any more, so nothing is discarded — and that is
        // right: `discardIfEmpty` is for a blank, not for writing.
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(note.id).json").path
        ), "a note with words in it was thrown away by a discard")

        // Now one that really is empty and really was written: the window
        // flushes a blank on its way out, and a file from an older build is
        // on the disk either way.
        let blank = await store.create()
        await store.update(blank.id, text: AttributedString("x"))
        await store.update(blank.id, text: AttributedString(""))
        await store.flush()
        await store.discardIfEmpty(blank.id)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains("discarded") } ?? []
        #expect(aside.count == 1, "a written blank was unlinked rather than set aside")
    }

    /// The rule the owner asked for: an Untitled note nobody typed into must
    /// never be saved at all.
    @Test("A note that was never typed into never reaches the disk")
    func anEmptyNoteIsNeverWritten() async throws {
        // `create` used to mark the note dirty and schedule both writes, with
        // a comment saying that was deliberate. The result was a collection
        // filling with Untitled blanks: every press of New note that was then
        // thought better of left a file behind, and All Notes opened on one.
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.flush()
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(note.id).json").path
        ), "an empty note was written")

        // And it is still openable and listable in this session, because it is
        // the note the window has just put a cursor in.
        #expect(await store.body(note.id) != nil)
        #expect(await store.list().contains { $0.id == note.id })

        // The first word is what makes it a note.
        await store.update(note.id, text: AttributedString("the first word"))
        await store.flush()
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(note.id).json").path
        ), "a note that was typed into did not reach the disk")
    }

    /// The summary travels in every payload and into the index, so it must
    /// not carry the whole note.
    @Test("The preview is a preview, not the entire note")
    func previewIsBounded() async {
        let store = NotesStore(directory: scratch(), now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("title\n" + String(repeating: "x", count: 9000)))
        let body = await store.body(note.id)
        #expect((body?.preview.count ?? 0) <= 120, "the whole note is being carried in the summary")
        #expect(body?.plainText.count ?? 0 > 9000, "the note itself was truncated")
    }

    /// A field added later must not make every note written before it
    /// unreadable — the lesson the device catalogue records in its own comments.
    @Test("A note missing newer fields still loads")
    func lenientDecode() async throws {
        let dir = scratch()
        let id = UUID().uuidString
        try Data("""
        {"id": "\(id)", "text": "bare minimum"}
        """.utf8).write(to: dir.appendingPathComponent("\(id).json"))

        let store = NotesStore(directory: dir, now: { 1 })
        let body = await store.body(id)
        #expect(body?.plainText == "bare minimum")
        #expect(body?.version == NoteBody.currentVersion)
    }

    @Test("Flushing writes everything outstanding")
    func flushDrains() async {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("unsaved"))
        #expect(await store.pendingWriteCountForTesting > 0)
        await store.flush()
        #expect(await store.pendingWriteCountForTesting == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(note.id).json").path))
    }
}

@Suite("Duplicating and sweeping")
struct NotesDuplicateAndSweepTests {

    private func store() -> NotesStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-notes-tests/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return NotesStore(directory: url, now: { 1 })
    }

    @Test("A copy is its own note, not a version of the original")
    func duplicate() async {
        let store = store()
        let original = await store.create()
        await store.update(original.id, text: AttributedString("Elma\nikinci satır"))
        guard let copy = await store.duplicate(original.id) else {
            return #expect(Bool(false), "nothing came back")
        }
        #expect(copy.id != original.id)
        // The title is numbered so the two are tellable apart in a list; the
        // body is not touched.
        #expect(String(copy.text.characters) == "Elma (1)\nikinci satır")
        // Editing the copy must not reach back into what it came from.
        await store.update(copy.id, text: AttributedString("Armut"))
        let after = await store.body(original.id)
        #expect(after.map { String($0.text.characters) } == "Elma\nikinci satır")
        #expect(await store.list().count == 2)
    }

    @Test("Duplicating something that is gone returns nothing")
    func duplicateMissing() async {
        let store = store()
        #expect(await store.duplicate("no-such-note") == nil)
    }

    @Test("Blanks left behind by a kill are swept at launch, and only blanks")
    func sweep() async {
        // The case this exists for: `discardIfEmpty` runs when a window closes,
        // and nothing closes a window when the process dies under it.
        let store = store()
        let written = await store.create()
        await store.update(written.id, text: AttributedString("bu kalmalı"))
        let blank = await store.create()
        let spaces = await store.create()
        await store.update(spaces.id, text: AttributedString("   \n  "))
        await store.flush()

        #expect(await store.discardEmpties() == 2)
        let left = await store.list()
        #expect(left.count == 1)
        #expect(left.first?.id == written.id)
        #expect(await store.body(blank.id) == nil)
        #expect(await store.body(spaces.id) == nil)
        // Nothing left to do on a second pass.
        #expect(await store.discardEmpties() == 0)
    }
}

@Suite("Numbering a copy")
struct NotesNumberingTests {

    private func title(_ text: AttributedString) -> String {
        String(text.characters).split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    @Test("A copy takes the first number nobody else has")
    func numbering() {
        let note = AttributedString("Groceries\nmilk")
        #expect(title(NotesStore.numbered(note, avoiding: [])) == "Groceries (1)")
        #expect(title(NotesStore.numbered(note, avoiding: ["Groceries"])) == "Groceries (1)")
        #expect(title(NotesStore.numbered(note, avoiding: ["Groceries", "Groceries (1)"])) == "Groceries (2)")
        // Gaps are filled rather than skipped past.
        #expect(title(NotesStore.numbered(note, avoiding: ["Groceries (1)", "Groceries (3)"])) == "Groceries (2)")
    }

    @Test("Copying a copy gives (2), never (1) (1)")
    func copyOfCopy() {
        let copy = AttributedString("Groceries (1)\nmilk")
        let again = NotesStore.numbered(copy, avoiding: ["Groceries", "Groceries (1)"])
        #expect(title(again) == "Groceries (2)")
    }

    @Test("Only the first line is numbered, and the rest is untouched")
    func firstLineOnly() {
        let note = AttributedString("Plan\nstep one\nstep two")
        let copy = NotesStore.numbered(note, avoiding: [])
        #expect(String(copy.characters) == "Plan (1)\nstep one\nstep two")
    }

    @Test("A note with nothing to call it is left alone")
    func untitled() {
        // A bare "(1)" is not a better name than no name.
        #expect(String(NotesStore.numbered(AttributedString(""), avoiding: []).characters) == "")
        #expect(String(NotesStore.numbered(AttributedString("   \nbody"), avoiding: []).characters) == "   \nbody")
    }

    @Test("Numbers that are part of the name are not mistaken for a count")
    func parentheses() {
        let note = AttributedString("Invoice (draft)")
        #expect(title(NotesStore.numbered(note, avoiding: [])) == "Invoice (draft) (1)")
    }

    @Test("A bold title stays bold once it is numbered")
    func keepsFormatting() {
        var note = AttributedString("Plan")
        note.inlinePresentationIntent = .stronglyEmphasized
        note += AttributedString("\nbody")
        let copy = NotesStore.numbered(note, avoiding: [])
        let suffix = copy.runs.first { String(copy.characters[$0.range]).contains("(1)") }
        #expect(suffix?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }
}

@Suite("Never keeping a blank")
struct NotesBlankTests {

    private func store() -> NotesStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-notes-tests/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return NotesStore(directory: url, now: { 1 })
    }

    @Test("Leaving a blank note for another one does not keep the blank")
    func swapping() async {
        // What the window does when ⌘N is pressed on an untouched note: write
        // what is there, flush, then discard it if it was nothing.
        let store = store()
        let blank = await store.create()
        await store.update(blank.id, text: AttributedString(""))
        await store.flush()
        await store.discardIfEmpty(blank.id)

        let second = await store.create()
        await store.update(second.id, text: AttributedString("kept"))
        await store.flush()

        let left = await store.list()
        #expect(left.count == 1)
        #expect(left.first?.id == second.id)
    }

    @Test("A last write of nothing does not bring a note back")
    func noResurrection() async {
        // A window closing writes its note out one more time. If that note was
        // just discarded or deleted, that write must not recreate it.
        let store = store()
        let note = await store.create()
        await store.discardIfEmpty(note.id)
        #expect(await store.list().isEmpty)

        await store.update(note.id, text: AttributedString(""))
        await store.update(note.id, text: AttributedString("   \n "))
        await store.flush()
        #expect(await store.list().isEmpty)
    }

    @Test("A real edit to a note that has gone still brings it back")
    func writingStillRevives() async {
        // The protection is against blanks, not against somebody's writing.
        let store = store()
        let note = await store.create()
        await store.delete(note.id)
        await store.update(note.id, text: AttributedString("typed after it went"))
        await store.flush()
        #expect(await store.list().count == 1)
        let revived = await store.body(note.id)
        #expect(revived.map { String($0.text.characters) } == "typed after it went")
    }
}

/// The index is what the card reads at launch, so it has to change when a
/// note is created, retitled or given a new preview.
@Suite("The notes index")
struct NotesIndexTests {

    private func scratch() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-notes-tests/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func indexed(_ dir: URL) -> [String: NoteSummary] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let list = try? JSONDecoder().decode([NoteSummary].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    @Test("A new note is in the index once it has words in it")
    func newNoteReachesIndex() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("Shopping\nmilk"))
        await store.flush()
        try #require(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(note.id).json").path),
                     "the note itself was written")
        #expect(indexed(dir)[note.id]?.title == "Shopping")
        #expect(indexed(dir)[note.id]?.preview == "milk")
    }

    @Test("A new note nobody typed in stays out of the index")
    func blankStaysOutOfIndex() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let kept = await store.create()
        await store.update(kept.id, text: AttributedString("kept"))
        let scrap = await store.create()
        await store.update(scrap.id, text: AttributedString("scrap"))
        await store.delete(scrap.id)
        await store.flush()
        try #require(indexed(dir)[kept.id] != nil, "an index has been written")

        let blank = await store.create()
        await store.flush()
        #expect(indexed(dir)[blank.id] == nil)
    }

    @Test("A retitled note keeps its new title on the card after a relaunch")
    func retitleSurvivesRelaunch() async throws {
        let dir = scratch()
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(100))
        let store = NotesStore(directory: dir, now: { clock.withLock { $0 } })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("Old title\nold body"))
        // A delete writes the index whatever else does, so there is one to
        // go stale.
        let scrap = await store.create()
        await store.update(scrap.id, text: AttributedString("scrap"))
        await store.delete(scrap.id)
        await store.flush()
        try #require(indexed(dir)[note.id]?.title == "Old title", "the index lists the note by its old title")

        clock.withLock { $0 = 200 }
        await store.update(note.id, text: AttributedString("New title\nnew body"))
        await store.flush()
        try #require(await store.list().first?.title == "New title", "in session the card says the new title")

        let relaunched = NotesStore(directory: dir, now: { 300 })
        let summary = await relaunched.list().first { $0.id == note.id }
        #expect(summary?.title == "New title")
        #expect(summary?.preview == "new body")
    }

    @Test("A change under the title reaches the card's preview after a relaunch")
    func previewSurvivesRelaunch() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.update(note.id, text: AttributedString("Same title\nold body"))
        await store.flush()
        try #require(indexed(dir)[note.id]?.preview == "old body", "the index lists the old preview")

        await store.update(note.id, text: AttributedString("Same title\nnew body"))
        await store.flush()
        let relaunched = NotesStore(directory: dir, now: { 2 })
        #expect(await relaunched.list().first?.preview == "new body")
    }

    @Test("An index left stale by an older build is corrected by the next edit")
    func staleIndexHealsOnEdit() async throws {
        let dir = scratch()
        let first = NotesStore(directory: dir, now: { 1 })
        let note = await first.create()
        let long = "New title\n" + String(repeating: "word ", count: 40)
        await first.update(note.id, text: AttributedString(long))
        await first.flush()
        // What 1.2.1 left behind: the note retitled, the index never told.
        let stale = [NoteSummary(id: note.id, title: "Old title", preview: "old", editedAt: 1)]
        try JSONEncoder().encode(stale).write(to: dir.appendingPathComponent("index.json"))

        let relaunched = NotesStore(directory: dir, now: { 2 })
        try #require(await relaunched.list().first?.title == "Old title", "the card starts from the stale index")
        // An edit past the end of the preview: neither the title nor the
        // preview moves, so only comparing with the index can catch it.
        await relaunched.update(note.id, text: AttributedString(long + "more"))
        await relaunched.flush()
        #expect(indexed(dir)[note.id]?.title == "New title")
    }

    /// What 1.2.1 can leave on disk: a note that says "Current title" listed
    /// in the index as "Old title", and a second note, listed as newer, whose
    /// preview alone is out of date.
    private func staleFolder() throws -> (dir: URL, stale: String, other: String) {
        let dir = scratch()
        let stale = NoteBody(id: UUID().uuidString, text: AttributedString("Current title\ncurrent body"),
                             createdAt: 1, editedAt: 30)
        let other = NoteBody(id: UUID().uuidString, text: AttributedString("Other\nbody"),
                             createdAt: 1, editedAt: 20)
        for note in [stale, other] {
            try JSONEncoder().encode(note).write(to: dir.appendingPathComponent("\(note.id).json"))
        }
        let index = [NoteSummary(id: stale.id, title: "Old title", preview: "old body", editedAt: 10),
                     NoteSummary(id: other.id, title: "Other", preview: "old", editedAt: 20)]
        try JSONEncoder().encode(index).write(to: dir.appendingPathComponent("index.json"))
        return (dir, stale.id, other.id)
    }

    private func file(_ dir: URL, _ id: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent("\(id).json"))
    }

    @Test("Opening a note listed under an old title and closing it untouched corrects the card for good")
    func openWithoutEditHealsStaleIndex() async throws {
        let (dir, stale, other) = try staleFolder()
        let bytes = file(dir, stale)
        let store = NotesStore(directory: dir, now: { 99 })
        try #require(await store.list().map(\.title) == ["Other", "Old title"],
                     "the card starts from the stale index")

        // Open, then the window's close flush: the same text back, and a flush.
        let body = try #require(await store.body(stale))
        await store.update(stale, text: body.text)
        await store.flush()

        let relaunched = NotesStore(directory: dir, now: { 100 })
        let list = await relaunched.list()
        #expect(list.map(\.title) == ["Other", "Current title"])
        #expect(list.map(\.id) == [other, stale])
        #expect(list.first { $0.id == stale }?.editedAt == 10)
        #expect(list.first { $0.id == stale }?.preview == "current body")
        #expect(file(dir, stale) == bytes)
    }

    @Test("After launch the card's titles are checked against notes nobody has opened")
    func launchPassHealsUnopenedNotes() async throws {
        let (dir, stale, other) = try staleFolder()
        let bytes = file(dir, stale)
        let store = NotesStore(directory: dir, now: { 99 })
        try #require(await store.list().first { $0.id == stale }?.title == "Old title",
                     "the card starts from the stale index")

        let told = OSAllocatedUnfairLock(initialState: 0)
        await store.setOnChange { told.withLock { $0 += 1 } }

        await store.reconcileIndex()
        #expect(await store.list().map(\.title) == ["Other", "Current title"])
        #expect(told.withLock { $0 } > 0, "the card was told")
        await store.flush()

        let relaunched = NotesStore(directory: dir, now: { 100 })
        let list = await relaunched.list()
        #expect(list.map(\.title) == ["Other", "Current title"])
        #expect(list.map(\.id) == [other, stale])
        #expect(list.first { $0.id == other }?.preview == "body")
        #expect(list.first { $0.id == stale }?.editedAt == 10)
        #expect(file(dir, stale) == bytes)
    }

    @Test("The launch check leaves alone a note already being written in")
    func launchPassSkipsHeldNote() async throws {
        let (dir, stale, _) = try staleFolder()
        let store = NotesStore(directory: dir, now: { 99 })
        _ = await store.body(stale)
        await store.update(stale, text: AttributedString("Typed title\nunsaved"))
        try #require(await store.list().first { $0.id == stale }?.title == "Typed title",
                     "the edit is in the listing and not yet on disk")

        await store.reconcileIndex()
        #expect(await store.list().first { $0.id == stale }?.title == "Typed title")
    }

    @Test("The launch check tells the card once, however many notes it corrects")
    func launchPassTellsCardOnce() async throws {
        let dir = scratch()
        var index: [NoteSummary] = []
        for n in 0 ..< 50 {
            let note = NoteBody(id: UUID().uuidString, text: AttributedString("Current \(n)\nbody"),
                                createdAt: 1, editedAt: TimeInterval(n))
            try JSONEncoder().encode(note).write(to: dir.appendingPathComponent("\(note.id).json"))
            index.append(NoteSummary(id: note.id, title: "Old \(n)", preview: "body", editedAt: TimeInterval(n)))
        }
        try JSONEncoder().encode(index).write(to: dir.appendingPathComponent("index.json"))
        let store = NotesStore(directory: dir, now: { 99 })
        try #require(await store.list().allSatisfy { $0.title.hasPrefix("Old") }, "all fifty start stale")
        let told = OSAllocatedUnfairLock(initialState: 0)
        await store.setOnChange { told.withLock { $0 += 1 } }

        await store.reconcileIndex()
        try #require(await store.list().allSatisfy { $0.title.hasPrefix("Current") }, "all fifty were corrected")
        #expect(told.withLock { $0 } == 1)

        await store.reconcileIndex()
        #expect(told.withLock { $0 } == 1, "a pass that corrects nothing says nothing")
    }

    @Test("Opening a stale note tells the card straight away")
    func openTellsCardAtOnce() async throws {
        let (dir, stale, _) = try staleFolder()
        let store = NotesStore(directory: dir, now: { 99 })
        try #require(await store.list().first { $0.id == stale }?.title == "Old title",
                     "the card starts from the stale index")
        let told = OSAllocatedUnfairLock(initialState: 0)
        await store.setOnChange { told.withLock { $0 += 1 } }

        _ = await store.body(stale)
        #expect(told.withLock { $0 } == 1)
    }
}
