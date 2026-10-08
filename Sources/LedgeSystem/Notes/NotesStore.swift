import Foundation
import LedgeCore
import os

/// A note's body, as it is written down.
///
/// The text is an `AttributedString` carrying nothing but `inlinePresentationIntent`
/// — bold and italic and no more. That attribute is Foundation's own and encodes
/// as a plain integer (`{"NSInlinePresentationIntent":2}`), so a note written
/// today stays readable by a Ledge built against a later SDK. A SwiftUI font
/// attribute would have encoded as an internal blob, which is not something to
/// put on a user's disk.
public struct NoteBody: Equatable, Sendable, Codable {

    /// Bumped when the shape of this file changes. A file from a *later*
    /// version is quarantined rather than guessed at, the same way the device
    /// catalogue refuses to downgrade.
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var text: AttributedString
    public var createdAt: TimeInterval
    public var editedAt: TimeInterval

    public init(
        id: String,
        text: AttributedString = AttributedString(""),
        createdAt: TimeInterval,
        editedAt: TimeInterval
    ) {
        self.version = Self.currentVersion
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.editedAt = editedAt
    }

    /// The note as characters, with every attribute dropped.
    public var plainText: String { String(text.characters) }

    /// The first line, which is the only title a note has.
    public var title: String {
        plainText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Everything after the first line, flattened to one run for the tile.
    public var preview: String {
        let parts = plainText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return "" }
        // Truncated here, deliberately. The summary travels in every payload the
        // card publishes and is written into the index, and the tile draws two
        // lines of it — carrying the user's whole note through both to render
        // sixty characters would put their prose in fixture files and make the
        // queue diff it on every keystroke.
        return String(
            parts[1]
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(120)
        )
    }

    public var summary: NoteSummary {
        NoteSummary(id: id, title: title, preview: preview, editedAt: editedAt)
    }

    /// Whether this note has nothing in it, so closing the window can drop it
    /// rather than leaving an untitled blank behind.
    public var isEmpty: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, text, createdAt, editedAt
    }

    /// Hand-written, and lenient about everything except identity.
    ///
    /// A synthesised decoder demands every key, so adding a field later would
    /// make every note written before it unreadable — and an unreadable note
    /// is a note the user lost. Only `id` is required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(AttributedString.self, forKey: .text) ?? AttributedString("")
        createdAt = try c.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
        editedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .editedAt) ?? createdAt
    }
}

/// Where the notes live.
///
/// An actor, so no filesystem work happens on the main actor — the shelf keeps
/// its paths in `UserDefaults` and gets away with it because a path is short
/// and changes rarely. A note changes on every keystroke and has no length
/// limit, and writing a growing string into the defaults domain re-serialises
/// the whole plist through `cfprefsd` each time.
///
/// **One file per note.** The device catalogue writes its entire contents —
/// every record and all of their history — on every change, which turned a
/// battery reading into a rewrite of everything. A note is the same shape of
/// mistake waiting to happen, only worse, because the trigger is a keystroke.
/// Here a keystroke rewrites one note; the index changes only when a note is
/// created, deleted, or retitled.
public actor NotesStore {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "notes")

    /// How long typing has to pause before the body is written down.
    private static let bodyIdleDebounce = Duration.milliseconds(1_500)

    /// The longest a change may go unwritten while somebody keeps typing.
    ///
    /// An idle debounce alone is not enough: write uninterrupted for two
    /// minutes and nothing has reached the disk at all. The ceiling bounds
    /// what a crash can cost to a few seconds, without fsyncing per keystroke.
    private static let bodyMaximumDelay = Duration.seconds(10)

    /// The index changes far less often than a body, so it can wait longer.
    private static let indexDebounce = Duration.seconds(5)

    /// Sorted keys, so two encodings of the same note are the same bytes.
    /// Without it the dictionary order varies within a single process and the
    /// "has anything changed?" check below misses about three times in four.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private let directory: URL
    private let now: @Sendable () -> TimeInterval

    private var summaries: [String: NoteSummary] = [:]
    private var bodies: [String: NoteBody] = [:]
    private var loaded = false

    /// Notes whose file no longer matches what is in memory.
    private var dirtyBodies: Set<String> = []
    private var indexDirty = false

    /// The exact bytes last written for each note, so an edit that changes
    /// nothing — a cursor move, a reformat that cancelled out — does not buy a
    /// write. The catalogue skips this check and re-serialises for observations
    /// that stored nothing new.
    private var lastWritten: [String: Data] = [:]
    private var lastWrittenIndex: Data?

    private var bodyWrite: Task<Void, Never>?
    private var indexWrite: Task<Void, Never>?
    /// When the oldest unwritten body change happened, for the ceiling above.
    private var oldestDirtyAt: ContinuousClock.Instant?

    /// Told whenever the list the card draws has changed.
    public var onChange: (@Sendable () -> Void)?

    public init(
        directory: URL? = nil,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.now = now
    }

    public func setOnChange(_ handler: (@Sendable () -> Void)?) {
        onChange = handler
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ledge/Notes", isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func bodyURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    // MARK: - Reading

    /// Reads the index once. Bodies are read lazily, when a note is opened:
    /// a hundred notes is a hundred files, and the card only needs their
    /// titles.
    public func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: indexURL) {
            do {
                let list = try JSONDecoder().decode([NoteSummary].self, from: data)
                for summary in list { summaries[summary.id] = summary }
                lastWrittenIndex = data
            } catch {
                quarantine(indexURL, reason: "unreadable")
                Self.log.error("notes index unreadable — set aside, rebuilding from the notes themselves")
            }
        }
        adoptNotesMissingFromIndex()
    }

    /// Takes in any note on disk the index does not mention.
    ///
    /// The index is a cache, not the record. It is written on a longer debounce
    /// than the notes are, so a crash in between leaves a note saved and
    /// unlisted — and a damaged index would otherwise hide every note at once,
    /// with all of them sitting intact in the folder. Reading the directory
    /// costs one scan at launch and makes both of those recoverable.
    private func adoptNotesMissingFromIndex() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id != "index" else { continue }
            // Anything set aside carries its reason in the name, and a note
            // that was quarantined is not one to bring back by itself.
            guard !id.contains("-") || UUID(uuidString: id) != nil else { continue }
            guard summaries[id] == nil else { continue }
            guard let data = try? Data(contentsOf: url),
                  let note = try? JSONDecoder().decode(NoteBody.self, from: data),
                  note.version <= NoteBody.currentVersion
            else { continue }
            summaries[id] = note.summary
            lastWritten[id] = data
            indexDirty = true
            Self.log.notice("found a note the index did not list — restored")
        }
        if indexDirty { scheduleIndexWrite() }
    }

    /// Newest first, which is the order the card draws and the only order
    /// there is. Nothing here is sortable by the user, deliberately.
    public func list() -> [NoteSummary] {
        load()
        return summaries.values.sorted { $0.editedAt > $1.editedAt }
    }

    public func body(_ id: String) -> NoteBody? {
        load()
        if let held = bodies[id] { return held }
        guard let data = try? Data(contentsOf: bodyURL(id)) else { return nil }
        do {
            let note = try JSONDecoder().decode(NoteBody.self, from: data)
            guard note.version <= NoteBody.currentVersion else {
                // Written by a later Ledge. Guessing at a shape we do not know
                // would lose whatever the newer field held, so it is set aside
                // intact and the note reads as missing rather than as damaged.
                quarantine(bodyURL(id), reason: "from-a-later-version")
                Self.log.error("note is from a later version — set aside")
                return nil
            }
            bodies[id] = note
            lastWritten[id] = data
            return note
        } catch {
            quarantine(bodyURL(id), reason: "unreadable")
            Self.log.error("note unreadable — set aside")
            return nil
        }
    }

    // MARK: - Writing

    @discardableResult
    public func create() -> NoteBody {
        load()
        let stamp = now()
        let note = NoteBody(id: UUID().uuidString, createdAt: stamp, editedAt: stamp)
        bodies[note.id] = note
        summaries[note.id] = note.summary
        dirtyBodies.insert(note.id)
        indexDirty = true
        if oldestDirtyAt == nil { oldestDirtyAt = ContinuousClock.now }
        // Scheduled, not merely marked: without these a note created and never
        // typed into reached the disk only if some later edit happened to flush
        // it.
        scheduleBodyWrite()
        scheduleIndexWrite()
        noteChanged()
        return note
    }

    /// Takes an edit. Called on every keystroke's worth of change, so it does
    /// no work beyond remembering what changed.
    public func update(_ id: String, text: AttributedString) {
        load()
        // A note that is no longer there, being typed into, is somebody's
        // writing about to go nowhere — the window can still be open on a note
        // that was discarded on a lost focus or deleted from the card. Bring it
        // back rather than dropping every keystroke on the floor in silence.
        guard var note = body(id) ?? revive(id) else { return }
        guard note.text != text else { return }
        note.text = text
        note.editedAt = now()

        let before = note.summary
        bodies[id] = note
        summaries[id] = note.summary
        dirtyBodies.insert(id)
        if before.title != note.title || before.preview != note.preview {
            indexDirty = true
        }
        if oldestDirtyAt == nil { oldestDirtyAt = ContinuousClock.now }
        scheduleBodyWrite()
        scheduleIndexWrite()
        noteChanged()
    }

    /// Removes a note for good.
    ///
    /// The file is moved aside rather than unlinked. Everything else in this
    /// app can be done again — a note cannot, and "recoverable" is one of the
    /// rules this is built to.
    public func delete(_ id: String) {
        load()
        summaries.removeValue(forKey: id)
        bodies.removeValue(forKey: id)
        lastWritten.removeValue(forKey: id)
        dirtyBodies.remove(id)
        indexDirty = true
        quarantine(bodyURL(id), reason: "deleted")
        scheduleIndexWrite()
        noteChanged()
    }

    /// Drops a note only if nothing was ever typed into it, so closing a note
    /// the user opened and thought better of leaves nothing behind.
    /// Drops a note only if nothing was ever typed into it, so closing a note
    /// the user opened and thought better of leaves nothing behind.
    ///
    /// An empty note is never kept — not one that was opened and never typed
    /// into, and not one that was emptied out. A card full of blank tiles is
    /// the app making a mess on the user's behalf.
    ///
    /// What makes that safe is the file being *set aside* rather than unlinked,
    /// exactly as `delete` does. An earlier version tried to protect a note
    /// cleared for rewriting by refusing to discard anything whose `editedAt`
    /// had moved past its `createdAt` — which kept every blank the user had
    /// ever typed into and then emptied. The quarantine is the protection;
    /// the guard was the wrong one.
    ///
    /// - Returns: whether the note was discarded, so the caller can stop
    ///   writing into an id that no longer exists.
    @discardableResult
    public func discardIfEmpty(_ id: String) -> Bool {
        load()
        guard let note = body(id), note.isEmpty else { return false }
        summaries.removeValue(forKey: id)
        bodies.removeValue(forKey: id)
        lastWritten.removeValue(forKey: id)
        dirtyBodies.remove(id)
        indexDirty = true
        quarantine(bodyURL(id), reason: "discarded")
        scheduleIndexWrite()
        noteChanged()
        return true
    }

    /// Re-creates a note that was discarded or deleted while its window was
    /// still open, keeping the id so the window and the card stay in step.
    private func revive(_ id: String) -> NoteBody? {
        guard summaries[id] == nil else { return nil }
        let stamp = now()
        let note = NoteBody(id: id, createdAt: stamp, editedAt: stamp)
        bodies[id] = note
        summaries[id] = note.summary
        indexDirty = true
        Self.log.notice("a note was written to after it had gone — brought back")
        return note
    }

    private func noteChanged() {
        onChange?()
    }

    private func scheduleBodyWrite() {
        bodyWrite?.cancel()
        let overdue = oldestDirtyAt.map { ContinuousClock.now - $0 >= Self.bodyMaximumDelay } ?? false
        if overdue {
            writeDirtyBodies()
            return
        }
        bodyWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.bodyIdleDebounce)
            guard !Task.isCancelled else { return }
            await self?.writeDirtyBodies()
        }
    }

    private func scheduleIndexWrite() {
        guard indexDirty else { return }
        indexWrite?.cancel()
        indexWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.indexDebounce)
            guard !Task.isCancelled else { return }
            await self?.writeIndex()
        }
    }

    private func writeDirtyBodies() {
        let ids = dirtyBodies
        dirtyBodies.removeAll()
        oldestDirtyAt = nil
        for id in ids {
            guard let note = bodies[id] else { continue }
            guard let data = try? Self.encoder().encode(note) else { continue }
            // Nothing actually changed on disk — skip the write rather than
            // re-serialising for an edit that cancelled itself out.
            guard data != lastWritten[id] else { continue }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Atomic: a crash halfway through must leave the previous note
                // intact, not a half-written file that gets set aside on the
                // next launch.
                try data.write(to: bodyURL(id), options: .atomic)
                lastWritten[id] = data
            } catch {
                // Put it back: an unwritten change is still unwritten, and the
                // next flush must try again rather than believe it is saved.
                dirtyBodies.insert(id)
                if oldestDirtyAt == nil { oldestDirtyAt = ContinuousClock.now }
                Self.log.error("could not write a note: \(error.localizedDescription, privacy: .public)")
            }
        }
        // A disk that was full, a volume not yet unlocked: the note is still
        // only in memory, and nothing else will come along to write it if the
        // user has stopped typing.
        if !dirtyBodies.isEmpty { scheduleBodyWrite() }
    }

    private func writeIndex() {
        guard indexDirty else { return }
        let list = summaries.values.sorted { $0.editedAt > $1.editedAt }
        guard let data = try? Self.encoder().encode(list) else { return }
        guard data != lastWrittenIndex else { indexDirty = false; return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: indexURL, options: .atomic)
            lastWrittenIndex = data
            indexDirty = false
        } catch {
            Self.log.error("could not write the notes index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Everything outstanding, now.
    ///
    /// Called when the window closes, when it stops being the key window, when
    /// the app resigns active, and from the shutdown barrier. Losing a note is
    /// unrecoverable in a way nothing else in this app is, so every one of
    /// those is a reason to stop waiting for the debounce.
    public func flush() {
        bodyWrite?.cancel()
        bodyWrite = nil
        indexWrite?.cancel()
        indexWrite = nil
        writeDirtyBodies()
        writeIndex()
    }

    /// Moves a file aside instead of deleting it, stamped with why.
    private func quarantine(_ url: URL, reason: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingPathExtension()
            .appendingPathExtension("\(reason)-\(stamp)")
            .appendingPathExtension("json")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    /// Tests: how many notes are waiting to be written.
    public var pendingWriteCountForTesting: Int { dirtyBodies.count }
}
