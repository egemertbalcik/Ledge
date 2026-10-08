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

    /// A discarded note is set aside like a deleted one, not unlinked.
    @Test("Discarding sets the file aside rather than destroying it")
    func discardIsRecoverable() async {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.flush()
        await store.discardIfEmpty(note.id)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains("discarded") } ?? []
        #expect(aside.count == 1)
    }

    /// A note that was created and never typed into must still reach the disk.
    @Test("Creating a note schedules it to be written")
    func createSchedulesAWrite() async throws {
        let dir = scratch()
        let store = NotesStore(directory: dir, now: { 1 })
        let note = await store.create()
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(note.id).json").path))
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
