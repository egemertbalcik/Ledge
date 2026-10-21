import Foundation
import Synchronization
import Testing

@testable import LedgeSystem

/// The real `Assertions.json` from a Mac on macOS 26.4 with no Focus on.
/// UUIDs and device identifiers replaced; structure and keys untouched. There
/// is no `storeAssertionRecords` key at all: macOS leaves it out when nothing
/// is on, and keeps only the invalidation records of the Focus that ended.
private let realOffAssertions = Data("""
{"data":[{"storeInvalidationRequestRecords":[{"invalidationRequestPredicate":{"invalidationPredicateType":"any"},"invalidationRequestReason":"user-changed-state","invalidationRequestUUID":"00000000-0000-0000-0000-000000000001","invalidationRequestSource":{"assertionClientIdentifier":"com.apple.controlcenter.dnd"},"invalidationRequestDateTimestamp":813590380.028252}],"storeInvalidationRecords":[{"invalidationAssertion":{"assertionUUID":"00000000-0000-0000-0000-000000000002","assertionSource":{"assertionClientIdentifier":"com.apple.focus.activity-manager","assertionSourceDeviceIdentifier":"00000000-0000-0000-0000-0000000000AA"},"assertionStartDateTimestamp":811225221.319631,"assertionDetails":{"assertionDetailsIdentifier":"com.apple.focus.activity-manager","assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default","assertionDetailsLifetime":{"assertionDetailsScheduleLifetimeScheduleIdentifier":"com.apple.donotdisturb.schedule.default","assertionDetailsLifetimeType":"schedule","assertionDetailsScheduleLifetimeBehavior":"expire-on-end"},"assertionDetailsReason":"user-action"}},"invalidationSource":{"assertionClientIdentifier":"com.apple.focus.activity-manager","assertionSourceDeviceIdentifier":"00000000-0000-0000-0000-0000000000AA"},"invalidationDateTimestamp":811225270.589058,"invalidationReason":"user-changed-state"},{"invalidationAssertion":{"assertionUUID":"00000000-0000-0000-0000-000000000003","assertionSource":{"assertionClientIdentifier":"com.apple.controlcenter.dnd"},"assertionStartDateTimestamp":813588630.028803,"assertionDetails":{"assertionDetailsIdentifier":"com.apple.controlcenter.dnd","assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default","assertionDetailsReason":"user-action"}},"invalidationSource":{"assertionClientIdentifier":"com.apple.controlcenter.dnd"},"invalidationDateTimestamp":813590380.028252,"invalidationReason":"user-changed-state"}]}],"header":{"version":8,"timestamp":813590380.031871}}
""".utf8)

/// The same file with Work on.
private let realOnAssertions = Data("""
{"data":[{"storeAssertionRecords":[{"assertionUUID":"00000000-0000-0000-0000-000000000004","assertionSource":{"assertionClientIdentifier":"com.apple.controlcenter.dnd"},"assertionStartDateTimestamp":813588630.028803,"assertionDetails":{"assertionDetailsIdentifier":"com.apple.controlcenter.dnd","assertionDetailsModeIdentifier":"com.apple.focus.work","assertionDetailsReason":"user-action"}}],"storeInvalidationRecords":[]}],"header":{"version":8,"timestamp":813590380.031871}}
""".utf8)

/// The database folder, read through the shipped parser rather than a flag.
@MainActor
private final class FocusFolder: FocusSource {
    var isReadable = false
    var bytes: Data?
    private var onChange: (() -> Void)?

    func current() -> FocusSnapshot? {
        if case .on(let snapshot) = reading() { return snapshot }
        return nil
    }

    func reading() -> FocusReading {
        guard isReadable else { return .unintelligible }
        switch FileFocusSource.assertions(from: bytes) {
        case .unintelligible: return .unintelligible
        case .inactive: return .off
        case .active(let identifier):
            let mode = FileFocusSource.builtInModes[identifier]
            return .on(FocusSnapshot(
                identifier: identifier,
                name: mode?.name ?? "Focus",
                symbolName: mode?.symbol ?? "moon.fill"
            ))
        }
    }

    /// macOS rewrote the file, and the directory watch fired.
    func write(_ data: Data) {
        bytes = data
        onChange?()
    }

    func startWatching(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    func stopWatching() { onChange = nil }
}

/// What the system says, shareable between a test and the source it drives.
private final class SystemAnswer: Sendable {
    private let value: Mutex<Bool?>
    init(_ value: Bool?) { self.value = Mutex(value) }
    func get() -> Bool? { value.withLock { $0 } }
    func set(_ new: Bool?) { value.withLock { $0 = new } }
}

@Suite("The real no-Focus file", .timeLimit(.minutes(10)))
@MainActor
struct FocusOffFileTests {

    @Test("The file macOS writes when no Focus is on reads as off")
    func realOffFileReadsAsOff() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: realOffAssertions) as? [String: Any])
        let first = try #require((root["data"] as? [[String: Any]])?.first)
        try #require(first["storeAssertionRecords"] == nil, "the fixture is the real off shape")
        try #require(FileFocusSource.assertions(from: realOnAssertions) == .active("com.apple.focus.work"))

        #expect(FileFocusSource.assertions(from: realOffAssertions) == .inactive)
        // Still not a licence to read any record-less file as off.
        #expect(FileFocusSource.assertions(from: Data(#"{"data":[{}]}"#.utf8)) == .unintelligible)
    }

    /// The folder is offered as the way to show the mode's name, so the
    /// natural moment to grant it is while a nameless Focus is on.
    @Test("Granting the folder during a Focus, then turning the Focus off, reads as off")
    func grantDuringFocusThenOff() async throws {
        let file = FocusFolder()
        let focused = Mutex<Bool?>(true)
        let source = SystemFocusSource(
            file: file, statusAuthorized: { true }, readStatus: { focused.withLock { $0 } }
        )
        var notes = 0
        source.startWatching { notes += 1 }
        defer { source.stopWatching() }
        try #require(source.current() == SystemFocusSource.genericFocus)
        // The startup probe lands with nothing new, as it long since has in
        // the app by the time anyone opens Settings. Waited on, not slept
        // through: a held main thread outlasts any fixed sleep.
        await source.settled()
        try #require(source.current() == SystemFocusSource.genericFocus)

        file.bytes = realOnAssertions
        file.isReadable = true
        source.accessChanged()
        try #require(source.current()?.identifier == "com.apple.focus.work")

        focused.withLock { $0 = false }
        file.write(realOffAssertions)
        try #require(notes >= 2, "the grant and the off write were both delivered")

        #expect(source.current() == nil, "still reports \(String(describing: source.current()))")
    }

    /// The folder granted while a Focus is on, so the system's reading of it
    /// was already held when the file started answering.
    private func grantedDuringFocus() async throws -> (SystemFocusSource, FocusFolder, SystemAnswer) {
        let file = FocusFolder()
        let focused = SystemAnswer(true)
        let source = SystemFocusSource(
            file: file, statusAuthorized: { true }, readStatus: { focused.get() }
        )
        source.startWatching {}
        try #require(source.current() == SystemFocusSource.genericFocus)
        // The startup probe lands, waited on rather than slept through.
        await source.settled()

        file.bytes = realOnAssertions
        file.isReadable = true
        source.accessChanged()
        try #require(source.current()?.identifier == "com.apple.focus.work")
        return (source, file, focused)
    }

    /// The Focus that was on when the folder arrived must not come back the
    /// moment the folder stops answering.
    @Test("A system reading from before the grant is not kept once the file answers")
    func fallbackDroppedOnceFileAnswers() async throws {
        let (source, file, focused) = try await grantedDuringFocus()
        defer { source.stopWatching() }

        // The Focus ends, and the folder stops answering before any probe has
        // had a chance to notice.
        focused.set(false)
        file.isReadable = false
        try #require(file.reading() == .unintelligible)

        #expect(source.current() == nil, "the old Focus spoke again: \(String(describing: source.current()))")
    }

    /// The same, with the folder still readable but in a shape this version
    /// does not know, where no blocking first reading is taken.
    @Test("A system reading from before the grant is not kept when the file turns unknown")
    func fallbackDroppedWhenFileTurnsUnknown() async throws {
        let (source, file, focused) = try await grantedDuringFocus()
        defer { source.stopWatching() }

        focused.set(false)
        file.bytes = Data(#"{"data":[{}]}"#.utf8)
        try #require(file.isReadable && file.reading() == .unintelligible)

        #expect(source.current() == nil, "the old Focus spoke again: \(String(describing: source.current()))")
    }

    /// And the other side: a Focus still on when the folder stops answering is
    /// read afresh, not reported as off until the next probe.
    @Test("A Focus still on when the folder stops answering is read afresh")
    func focusStillOnIsReadAfresh() async throws {
        let (source, file, _) = try await grantedDuringFocus()
        defer { source.stopWatching() }

        file.isReadable = false
        try #require(file.reading() == .unintelligible)

        #expect(source.current() == SystemFocusSource.genericFocus)
    }

    /// The fallback is dropped while the file answers, so it must still be
    /// kept while a readable file says nothing a reader can use — the schema
    /// change the parser's third answer exists for.
    @Test("A readable file in an unknown shape still lets the system's answer through")
    func unknownShapeKeepsFallbackLive() async throws {
        let file = FocusFolder()
        file.isReadable = true
        file.bytes = Data(#"{"data":[{}]}"#.utf8)
        let focused = SystemAnswer(false)
        let source = SystemFocusSource(
            file: file, statusAuthorized: { true }, readStatus: { focused.get() }
        )
        var notes = 0
        source.startWatching { notes += 1 }
        defer { source.stopWatching() }
        try #require(file.reading() == .unintelligible)
        try #require(source.current() == nil)
        // The startup probe read "off" and must be out of the way, or the
        // refresh below would find it still running and start nothing.
        await source.settled()

        focused.set(true)
        source.refresh()
        await source.settled()
        try #require(notes > 0, "the change was noticed")

        #expect(source.current() == SystemFocusSource.genericFocus)
    }

    /// A status probe already in flight when the folder becomes readable — by
    /// the ready-retry, with nobody calling `accessChanged` — lands after it.
    @Test("A status probe that lands after the folder became readable is not kept")
    func probeInFlightAcrossGrant() async throws {
        let file = FocusFolder()
        let focused = Mutex<Bool?>(false)
        let asked = Mutex(0)
        let answered = Mutex(0)
        let source = SystemFocusSource(
            file: file, statusAuthorized: { true },
            readStatus: {
                asked.withLock { $0 += 1 }
                Thread.sleep(forTimeInterval: 0.15)  // the XPC round trip
                answered.withLock { $0 += 1 }
                return focused.withLock { $0 }
            }
        )
        // Not watching: no startup probe or backstop tick to muddy the order,
        // and `refresh()` stands in for the filesystem event.
        defer { source.stopWatching() }
        try #require(source.current() == nil)

        // A Focus comes on; the filesystem event starts a probe. Nothing else
        // is out, so this one refresh starts it, and it is waited for until it
        // has actually asked, however long that takes.
        focused.withLock { $0 = true }
        let before = asked.withLock { $0 }
        source.refresh()
        while asked.withLock({ $0 }) == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(asked.withLock { $0 } > before, "a probe is out")

        // The folder becomes readable while that probe is out.
        file.bytes = realOnAssertions
        file.isReadable = true
        file.write(realOnAssertions)
        try #require(source.current()?.identifier == "com.apple.focus.work")
        // The probe and its confirmation land, and then its last step back on
        // the main actor. Both readings run at utility priority, which a
        // loaded full-suite run can hold back for longer than any deadline,
        // so this waits on the probe itself.
        await source.settled()
        try #require(answered.withLock { $0 } >= before + 2, "the probe and its confirmation both ran")

        focused.withLock { $0 = false }
        file.isReadable = false
        try #require(file.reading() == .unintelligible)

        #expect(source.current() == nil, "the late probe was kept: \(String(describing: source.current()))")
    }
}
