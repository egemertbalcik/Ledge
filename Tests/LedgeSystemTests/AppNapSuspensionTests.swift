import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// Another application's preferences, as a test can see them.
///
/// Never the real ones. Every test here would otherwise change settings on the
/// machine it runs on, in apps that have nothing to do with Ledge, and leave
/// them changed when it failed.
private final class FakePreferences: @unchecked Sendable, AppNapPreferencing {

    private let lock = NSLock()
    private var values: [String: Bool] = [:]
    private var unreadable: Set<String> = []
    private var unwritable: Set<String> = []
    private var uncertain: Set<String> = []
    private var writeLog: [(id: String, value: Bool?)] = []

    init(_ values: [String: Bool] = [:]) { self.values = values }

    var writes: [(id: String, value: Bool?)] { lock.withLock { writeLog } }
    func value(_ id: String) -> Bool? { lock.withLock { values[id] } }
    func has(_ id: String) -> Bool { lock.withLock { values[id] != nil } }

    func cannotRead(_ id: String) { lock.withLock { _ = unreadable.insert(id) } }
    /// Nothing is attempted — the honest refusal, which only the domain check
    /// can actually produce in the real one.
    func cannotWrite(_ id: String) { lock.withLock { _ = unwritable.insert(id) } }
    func canWriteAgain(_ id: String) { lock.withLock { unwritable.remove(id) } }

    /// The real shape of a failure: the value changes and *then* the flush
    /// fails. A fake that refuses before mutating cannot reproduce the case
    /// that loses somebody's setting.
    func flushFails(_ id: String) { lock.withLock { _ = uncertain.insert(id) } }
    func flushWorksAgain(_ id: String) { lock.withLock { uncertain.remove(id) } }

    func read(_ bundleID: String) -> Bool?? {
        lock.withLock {
            if unreadable.contains(bundleID) { return nil }
            return .some(values[bundleID])
        }
    }

    func write(_ value: Bool?, to bundleID: String) -> PreferenceWrite {
        lock.withLock {
            guard !unwritable.contains(bundleID) else { return .refused }
            writeLog.append((bundleID, value))
            if let value { values[bundleID] = value } else { values[bundleID] = nil }
            return uncertain.contains(bundleID) ? .uncertain : .written
        }
    }
}

private actor FakeJournal: AppNapJournaling {
    private var entries: [String: AppNapOverride] = [:]
    private var refusing: Set<String> = []
    private var holding: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var reached: CheckedContinuation<Void, Never>?

    /// Holds the next `record` open. The whole point of the race is what else
    /// runs while a journal call is in the air, and a journal that always
    /// answers at once cannot reach it.
    func holdNextRecord() { holdNext = true }

    /// Returns once a held `record` has actually arrived.
    func whenRecordReached() async {
        await withCheckedContinuation { continuation in
            if holding != nil { continuation.resume() } else { reached = continuation }
        }
    }

    func releaseRecord() {
        holding?.resume()
        holding = nil
    }

    /// How many times the journal has been drained.
    ///
    /// The test needs to know that `end` has actually run, not merely that a
    /// Task for it was created — a `Task { }` is a request to start, and
    /// releasing the held record before it starts tests nothing at all. That
    /// is how three mutations survived the first version of this.
    private var drains = 0
    var drainCount: Int { drains }

    func seed(_ entry: AppNapOverride) { entries[entry.bundleID] = entry }
    func refuse(_ id: String) { refusing.insert(id) }
    var ids: [String] { entries.keys.sorted() }

    func outstanding() -> [AppNapOverride] {
        drains += 1
        return entries.values.sorted { $0.bundleID < $1.bundleID }
    }

    func record(_ entry: AppNapOverride) async -> Bool {
        guard !refusing.contains(entry.bundleID) else { return false }
        if entries[entry.bundleID] == nil { entries[entry.bundleID] = entry }
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                holding = continuation
                reached?.resume()
                reached = nil
            }
        }
        return true
    }

    func clear(_ bundleID: String) { entries[bundleID] = nil }
}

/// Turning App Nap off for the agents is the only thing Ledge does that
/// changes another application's settings. The user has no way of noticing it
/// was left behind, so every test here is about it never being left behind.
@Suite("Turning App Nap off for the agents")
struct AppNapSuspensionTests {

    private let roster = AgentRoster(["com.a", "com.b"])

    private func rig(_ preferences: FakePreferences) -> (AppNapSuspension, FakeJournal) {
        let journal = FakeJournal()
        return (AppNapSuspension(preferences: preferences, journal: journal), journal)
    }

    @Test("Every roster app is written, and remembered as it was")
    func writesAndRemembers() async {
        let prefs = FakePreferences(["com.a": false])
        let (suspension, journal) = rig(prefs)
        let changed = await suspension.begin(roster)

        #expect(changed == ["com.a", "com.b"])
        #expect(prefs.value("com.a") == true)
        #expect(prefs.value("com.b") == true)
        #expect(await journal.ids == ["com.a", "com.b"])
    }

    /// A key that was absent is restored by removing it, not by writing
    /// `false`. Anything else leaves a trace of Ledge in somebody else's
    /// preferences forever, for a setting they never chose.
    @Test("An absent key comes back absent, not false")
    func absentComesBackAbsent() async {
        let prefs = FakePreferences(["com.a": false])
        let (suspension, journal) = rig(prefs)
        await suspension.begin(roster)
        await suspension.end()

        #expect(prefs.value("com.a") == false, "a false the user had was not put back")
        #expect(!prefs.has("com.b"), "a key that never existed was left behind as false")
        #expect(await journal.ids.isEmpty)
    }

    /// The record exists before the write it describes, or the write does not
    /// happen. A change with no record is a change nothing can undo.
    @Test("An app that cannot be journalled is not touched")
    func noJournalNoWrite() async {
        let prefs = FakePreferences()
        let journal = FakeJournal()
        await journal.refuse("com.a")
        let suspension = AppNapSuspension(preferences: prefs, journal: journal)

        let changed = await suspension.begin(roster)
        #expect(changed == ["com.b"])
        #expect(!prefs.has("com.a"), "an unjournalled app was written to anyway")
        #expect(prefs.value("com.b") == true)
    }

    /// Only when nothing was attempted. That is the one case where dropping
    /// the record is knowledge rather than a guess.
    @Test("A write that was never attempted leaves no record to undo")
    func refusedWriteDropsItsRecord() async {
        let prefs = FakePreferences()
        prefs.cannotWrite("com.a")
        let (suspension, journal) = rig(prefs)

        let changed = await suspension.begin(roster)
        #expect(changed == ["com.b"])
        #expect(await journal.ids == ["com.b"], "a record was kept for a write that never happened")
    }

    /// The real setter mutates the cache and *then* flushes, so a failed flush
    /// is not proof the value is unchanged — it may already have changed, and
    /// may still reach disk. An earlier version of this treated that as
    /// "nothing happened" and dropped the only record that could undo it.
    @Test("A write whose flush failed keeps its record")
    func uncertainWriteKeepsItsRecord() async {
        let prefs = FakePreferences()
        prefs.flushFails("com.a")
        let (suspension, journal) = rig(prefs)

        let changed = await suspension.begin(roster)
        #expect(changed == ["com.a", "com.b"], "an app that may have changed was not reported")
        #expect(await journal.ids == ["com.a", "com.b"],
                "the only record that could undo an uncertain write was dropped")
        #expect(prefs.value("com.a") == true, "the value did change, which is the whole point")
    }

    /// Same rule on the way out, for the same reason.
    @Test("A restore whose flush failed keeps its record and tries again")
    func uncertainRestoreKeepsTrying() async {
        let prefs = FakePreferences()
        let (suspension, journal) = rig(prefs)
        await suspension.begin(roster)

        prefs.flushFails("com.a")
        await suspension.end()
        #expect(await journal.ids == ["com.a"], "an unconfirmed restore cleared its record")

        prefs.flushWorksAgain("com.a")
        await suspension.end()
        #expect(await journal.ids.isEmpty)
    }

    /// A record dropped on a failed restore is another application left
    /// changed forever, with nothing left that knows it was.
    @Test("A restore that fails keeps its record and tries again")
    func failedRestoreKeepsTrying() async {
        let prefs = FakePreferences()
        let (suspension, journal) = rig(prefs)
        await suspension.begin(roster)

        prefs.cannotWrite("com.a")
        await suspension.end()
        #expect(await journal.ids == ["com.a"], "the record was dropped on a failed restore")
        #expect(prefs.value("com.a") == true, "still changed, as it should be")

        prefs.canWriteAgain("com.a")
        await suspension.end()
        #expect(await journal.ids.isEmpty)
        #expect(!prefs.has("com.a"))
    }

    /// What a crash looks like: the journal survived, the process did not.
    @Test("A journal left by a crash is put back at the next start")
    func recoversFromACrash() async {
        let prefs = FakePreferences(["com.z": true])
        let journal = FakeJournal()
        await journal.seed(AppNapOverride(bundleID: "com.z", previous: nil))
        let suspension = AppNapSuspension(preferences: prefs, journal: journal)

        await suspension.begin(roster)
        #expect(!prefs.has("com.z"), "a crash's leftover was never put back")
        #expect(await journal.ids == ["com.a", "com.b"])
    }

    /// The app's current value after a crash is whatever the *previous run*
    /// wrote, not what the user chose. Letting a second run overwrite the
    /// record would bake that in and the user's own setting would be gone.
    @Test("A record from an unfinished run is never overwritten by the current reading")
    func theOlderRecordIsTheTrueOne() async {
        let prefs = FakePreferences(["com.a": true])
        let journal = FakeJournal()
        // The previous run found `false` and wrote `true`; then it died.
        await journal.seed(AppNapOverride(bundleID: "com.a", previous: false))
        let suspension = AppNapSuspension(preferences: prefs, journal: journal)

        await suspension.begin(AgentRoster(["com.a"]))
        await suspension.end()
        #expect(prefs.value("com.a") == false,
                "the user's own setting was lost to a second run's reading")
    }

    /// Writing `true` over the user's own `true` and deleting it afterwards
    /// would take away a setting they chose.
    @Test("An app already set to true is never touched")
    func alreadyTrueIsLeftAlone() async {
        let prefs = FakePreferences(["com.a": true, "com.b": true])
        let (suspension, journal) = rig(prefs)

        #expect(await suspension.begin(roster).isEmpty)
        #expect(prefs.writes.isEmpty, "an app that was already right was written to")
        #expect(await journal.ids.isEmpty)
    }

    /// A value nobody could read is a value nobody could put back.
    @Test("An unreadable preference is never written")
    func unreadableIsNeverWritten() async {
        let prefs = FakePreferences()
        prefs.cannotRead("com.a")
        let (suspension, _) = rig(prefs)

        #expect(await suspension.begin(roster) == ["com.b"])
        #expect(!prefs.has("com.a"))
    }

    /// An actor is not a lock, so `begin` and `end` really did interleave at
    /// every journal call — and a round number local to this type could not
    /// fix it, because the damage happens at the journal, where a cancelled
    /// begin's clear cannot tell its own record from the replacement's.
    ///
    /// So they do not interleave at all now: an end asked for while a begin is
    /// still in the air waits for it and then undoes it. This test holds a
    /// begin open, asks for an end, and checks that the end did *not* run
    /// early — and that what it eventually leaves behind is nothing.
    @Test("An End asked for during a Begin waits, and still leaves nothing behind")
    func endWaitsForBeginAndUndoesIt() async throws {
        let prefs = FakePreferences()
        let journal = FakeJournal()
        let suspension = AppNapSuspension(preferences: prefs, journal: journal)

        await journal.holdNextRecord()
        let beginning = Task { await suspension.begin(AgentRoster(["com.a"])) }
        await journal.whenRecordReached()
        let beforeEnd = await journal.drainCount

        // Waited for the end to actually join the queue, not for a while to
        // pass. An end that was never scheduled looks exactly like an end that
        // is waiting its turn, and the earlier version of this could not tell
        // them apart — it inferred admission from eighty milliseconds of
        // nothing happening.
        let admitted = Admissions()
        await suspension.setOnAdmission { admitted.saw($0) }
        let ending = Task { await suspension.end() }
        for _ in 0 ..< 400 where !admitted.contains("end") {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(admitted.contains("end"), "the end was never asked for")
        #expect(await journal.drainCount == beforeEnd,
                "the end ran while a begin was still in the air")

        await journal.releaseRecord()
        _ = await beginning.value
        await ending.value

        #expect(await journal.ids.isEmpty, "a record outlived the end that should have drained it")
        #expect(prefs.value("com.a") != true,
                "an application was left with App Nap disabled after the session ended")
    }

    /// The case a round number could not cover: a *replacement* session. A
    /// stale begin must not clear the new session's undo record, and a stale
    /// end must not restore over the setting the new session asked for.
    @Test("A replacement session keeps its setting and its record")
    func replacementSessionSurvives() async throws {
        let prefs = FakePreferences()
        let journal = FakeJournal()
        let suspension = AppNapSuspension(preferences: prefs, journal: journal)

        await journal.holdNextRecord()
        let first = Task { await suspension.begin(AgentRoster(["com.a"])) }
        await journal.whenRecordReached()

        // Both are asked for in a known order — two Tasks created in sequence
        // prove nothing about which of them reaches the queue first, and the
        // whole point of this test is the order.
        let admitted = Admissions()
        await suspension.setOnAdmission { admitted.saw($0) }
        let stop = Task { await suspension.end() }
        for _ in 0 ..< 400 where !admitted.contains("end") {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(admitted.contains("end"), "the end was never asked for")

        let second = Task { await suspension.begin(AgentRoster(["com.a"])) }
        for _ in 0 ..< 400 where !admitted.contains("begin") {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(admitted.contains("begin"), "the replacement was never asked for")

        await journal.releaseRecord()
        _ = await first.value
        await stop.value
        _ = await second.value

        #expect(prefs.value("com.a") == true,
                "the running session lost the setting it asked for")
        #expect(await journal.ids == ["com.a"],
                "the running session lost the record that could undo it")

        await suspension.end()
        #expect(prefs.value("com.a") != true)
        #expect(await journal.ids.isEmpty)
    }

    @Test("Ending with nothing outstanding changes nothing")
    func endingIdle() async {
        let prefs = FakePreferences()
        let (suspension, _) = rig(prefs)
        await suspension.end()
        #expect(prefs.writes.isEmpty)
    }
}

/// Finding the browsers, without anybody's actual browsers being open.
@Suite("Running Chromium browsers")
struct RunningChromiumTests {

    private let both = ChromiumOcclusion.flags.joined(separator: " ")

    @Test("A browser started with both flags is reported protected")
    func protectedIsSeen() {
        let found = RunningChromium.browsers(
            running: [(id: "com.google.Chrome", name: "Chrome", pid: 42)],
            commandLine: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome \(self.both)" }
        )
        #expect(found.map(\.isProtected) == [true])
        #expect(found.first?.name == "Chrome")
    }

    @Test("A browser started without them is reported unprotected")
    func unprotectedIsSeen() {
        let found = RunningChromium.browsers(
            running: [(id: "com.google.Chrome", name: "Chrome", pid: 42)],
            commandLine: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }
        )
        #expect(found.map(\.isProtected) == [false])
    }

    /// Being wrong this way costs one unnecessary suggestion. Being wrong the
    /// other way costs an agent that silently stops with nobody told.
    @Test("A command line nobody could read is reported unprotected")
    func unreadableIsUnprotected() {
        let found = RunningChromium.browsers(
            running: [(id: "com.google.Chrome", name: "Chrome", pid: 42)],
            commandLine: { _ in nil }
        )
        #expect(found.map(\.isProtected) == [false])
    }

    /// Without `-ww` the command line comes back cut to the terminal width, so
    /// a flag that is there reads as missing and a browser that is fine is
    /// reported broken.
    @Test("The command line is asked for in full")
    func asksForTheWholeLine() {
        var asked: [String] = []
        _ = RunningChromium.commandLine(of: 42, run: { _, arguments in
            asked = arguments
            return ""
        })
        #expect(asked.contains("-ww"), "a truncated command line would read as unprotected")
        #expect(asked.contains("42"))
    }

    @Test("Every running browser is reported, each on its own")
    func eachBrowserSeparately() {
        let found = RunningChromium.browsers(
            running: [(id: "com.google.Chrome", name: "Chrome", pid: 1),
                      (id: "company.thebrowser.Browser", name: "Arc", pid: 2)],
            commandLine: { pid in pid == 1 ? "/x \(self.both)" : "/y" }
        )
        #expect(found.map(\.bundleID) == ["com.google.Chrome", "company.thebrowser.Browser"])
        #expect(found.map(\.isProtected) == [true, false])
    }
}

/// The switch and the roster are read at the moment of use, not captured, so
/// changing either mid-session does what the user expects without them having
/// to restart one.
/// Where the preferences are read matters, and it is now provable rather than
/// inferred. Reading them first meant awaiting the main actor *before* the
/// suspension knew the operation existed, so an end completing during that hop
/// could not be told about a begin that had not arrived yet — the old begin
/// resumed afterwards and turned App Nap off for a session that was over.
@Suite("When the preferences are read")
struct AppNapAdmissionOrderTests {

    @Test("The operation joins the queue before the switch is read")
    func admittedBeforeReading() async throws {
        let prefs = FakePreferences()
        let journal = FakeJournal()
        let suspension = AppNapSuspension(preferences: prefs, journal: journal)

        let events = Admissions()
        await suspension.setOnAdmission { events.saw("admitted:\($0)") }
        let nap = RosterAppNap(
            suspension: suspension,
            wanted: { events.saw("read-switch"); return true },
            roster: { events.saw("read-roster"); return AgentRoster(["com.a"]) }
        )

        await nap.beginIfWanted()

        let order = events.order
        let admitted = try #require(order.firstIndex { $0.hasPrefix("admitted:") },
                                    "the operation never joined the queue")
        let read = try #require(order.firstIndex(of: "read-switch"),
                                "the switch was never read")
        #expect(admitted < read,
                "the preferences were read before the operation joined the queue: \(order)")
    }
}

@Suite("Whether App Nap is touched at all")
struct RosterAppNapTests {

    private func rig(wanted: @escaping @Sendable () -> Bool,
                     roster: @escaping @Sendable () -> AgentRoster = { AgentRoster(["com.a"]) })
    -> (RosterAppNap, FakePreferences, FakeJournal) {
        let prefs = FakePreferences()
        let journal = FakeJournal()
        let nap = RosterAppNap(
            suspension: AppNapSuspension(preferences: prefs, journal: journal),
            wanted: wanted, roster: roster
        )
        return (nap, prefs, journal)
    }

    @Test("Nothing is written unless the user asked for it")
    func offMeansUntouched() async {
        let (nap, prefs, journal) = rig(wanted: { false })
        await nap.beginIfWanted()
        #expect(prefs.writes.isEmpty, "another app's preferences were written unasked")
        #expect(await journal.ids.isEmpty)
    }

    @Test("With the switch on, the roster is written")
    func onMeansWritten() async {
        let (nap, prefs, journal) = rig(wanted: { true })
        await nap.beginIfWanted()
        #expect(prefs.value("com.a") == true)
        #expect(await journal.ids == ["com.a"])
    }

    /// Turning the switch off is a reason to undo, not a reason to forget.
    /// Skipping the restore would leave the apps from the last session carrying
    /// a setting Ledge wrote and nothing would ever put it back.
    @Test("Turning the switch off still puts back what an earlier run changed")
    func turningItOffRestores() async {
        let prefs = FakePreferences()
        let journal = FakeJournal()
        await journal.seed(AppNapOverride(bundleID: "com.z", previous: nil))
        prefs.cannotRead("")  // no-op; the point is the seeded journal
        let wants = Wants(false)
        let nap = RosterAppNap(
            suspension: AppNapSuspension(preferences: prefs, journal: journal),
            wanted: { wants.value }, roster: { AgentRoster(["com.a"]) }
        )

        await nap.beginIfWanted()
        #expect(await journal.ids.isEmpty, "a leftover was kept because the switch was off")
        #expect(prefs.writes.map(\.id) == ["com.z"])
    }

    /// Read each time, not captured: a user who turns it on mid-session should
    /// not have to end and restart one.
    @Test("The switch is read every time it is asked")
    func readEachTime() async {
        let wants = Wants(false)
        let prefs = FakePreferences()
        let journal = FakeJournal()
        let nap = RosterAppNap(
            suspension: AppNapSuspension(preferences: prefs, journal: journal),
            wanted: { wants.value }, roster: { AgentRoster(["com.a"]) }
        )

        await nap.beginIfWanted()
        #expect(!prefs.has("com.a"))

        wants.value = true
        await nap.beginIfWanted()
        #expect(prefs.value("com.a") == true, "the switch was captured, not read")
    }
}

/// A switch a test can flip from a Sendable closure.
private final class Wants: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}


/// The journal on disk.
///
/// A file that cannot be read *this time* — a transient failure, a half-written
/// file from a crash — was taken as "no entries", and the next record then
/// wrote a journal containing only the new entry over a perfectly good one.
/// Every application the old journal named was left changed with nothing that
/// knew it.
@Suite("The App Nap journal on disk", .serialized)
struct FileAppNapJournalTests {

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-app-nap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("What is written comes back")
    func roundTrip() async {
        let url = directory().appendingPathComponent("app-nap.json")
        let journal = FileAppNapJournal(url: url)
        #expect(await journal.record(AppNapOverride(bundleID: "com.a", previous: false)))
        #expect(await journal.record(AppNapOverride(bundleID: "com.b", previous: nil)))

        let reopened = FileAppNapJournal(url: url)
        let back = await reopened.outstanding()
        #expect(back.map(\.bundleID) == ["com.a", "com.b"])
        #expect(back.first?.previous == false)
        #expect(back.last?.previous == nil, "an absent key came back as something else")
    }

    @Test("An absent journal is simply empty, and can be written to")
    func absentIsEmpty() async {
        let journal = FileAppNapJournal(url: directory().appendingPathComponent("app-nap.json"))
        #expect(await journal.outstanding().isEmpty)
        #expect(await journal.record(AppNapOverride(bundleID: "com.a", previous: nil)))
    }

    /// The dangerous case. A directory where the file should be cannot be read
    /// as data and cannot be moved aside either, which is as close as a test
    /// can get to a disk that will not answer.
    @Test("A journal that cannot be read is never written over")
    func unreadableIsNeverOverwritten() async {
        let url = directory().appendingPathComponent("app-nap.json")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let journal = FileAppNapJournal(url: url)
        #expect(await journal.outstanding().isEmpty, "an unreadable journal has nothing to report")
        #expect(!(await journal.record(AppNapOverride(bundleID: "com.a", previous: nil))),
                "a record was accepted into a journal nobody could read")
        // And the write must not have happened: the caller is told no so that
        // it does not touch the application at all.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the unreadable thing was replaced")
    }

    /// The case that loses data: the file cannot be read, but the directory
    /// around it is perfectly writable, so an atomic write would replace it
    /// without a murmur and every application the old journal named would be
    /// left changed with nothing that knew it.
    @Test("A journal that cannot be read is kept, and nothing is recorded into it")
    func unreadableFileIsKept() async throws {
        let url = directory().appendingPathComponent("app-nap.json")
        let existing = try JSONEncoder().encode([AppNapOverride(bundleID: "com.old", previous: false)])
        try existing.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let journal = FileAppNapJournal(url: url)
        #expect(await journal.outstanding().isEmpty, "an unreadable journal has nothing to report")
        #expect(!(await journal.record(AppNapOverride(bundleID: "com.new", previous: nil))),
                "a record was accepted into a journal nobody could read")

        // The old one is still there, bytes intact, waiting for a read that works.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == existing, "the unreadable journal was written over")
    }

    /// Readable bytes that are not a journal. Set aside rather than deleted,
    /// so whatever it named can still be recovered by hand.
    @Test("A journal that makes no sense is set aside, not deleted")
    func nonsenseIsSetAside() async {
        let url = directory().appendingPathComponent("app-nap.json")
        try? Data("not json at all".utf8).write(to: url)

        let journal = FileAppNapJournal(url: url)
        #expect(await journal.outstanding().isEmpty)
        let siblings = (try? FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)) ?? []
        #expect(siblings.contains { $0.contains("unreadable") },
                "the file was deleted rather than kept")
        #expect(await journal.record(AppNapOverride(bundleID: "com.a", previous: nil)),
                "a journal set aside leaves a usable one behind")
    }
}


/// A second bad journal must not destroy the first one's remains — those
/// bytes may be the only account left of what another application's
/// preference used to be.
extension FileAppNapJournalTests {

    @Test("A second journal that makes no sense does not destroy the first one's remains")
    func quarantineIsNotDestructive() async throws {
        let folder = directory()
        let url = folder.appendingPathComponent("app-nap.json")

        try Data("first nonsense".utf8).write(to: url)
        _ = await FileAppNapJournal(url: url).outstanding()

        try Data("second nonsense".utf8).write(to: url)
        _ = await FileAppNapJournal(url: url).outstanding()

        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains("unreadable") }
        #expect(aside.count == 2, "a later quarantine destroyed an earlier one: kept \(aside)")
    }
}


/// What has joined the suspension's queue, from any thread.
private final class Admissions: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func saw(_ name: String) { lock.withLock { seen.append(name) } }
    func contains(_ name: String) -> Bool { lock.withLock { seen.contains(name) } }
    var order: [String] { lock.withLock { seen } }
}

/// Absence has to be read, not assumed.
///
/// `fileExists` answers false for a journal whose directory cannot be read —
/// the file is sitting right there — and "absent" is the one answer that
/// authorises writing a new journal over the top.
extension FileAppNapJournalTests {

    @Test("A journal inside an unreadable directory is not called absent")
    func unreadableDirectoryIsNotAbsence() async throws {
        let folder = directory()
        let url = folder.appendingPathComponent("app-nap.json")
        let existing = try JSONEncoder().encode([AppNapOverride(bundleID: "com.old", previous: false)])
        try existing.write(to: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: folder.path) }

        let journal = FileAppNapJournal(url: url)
        #expect(await journal.outstanding().isEmpty, "nothing can be reported from a journal nobody can read")
        #expect(!(await journal.record(AppNapOverride(bundleID: "com.new", previous: nil))),
                "a record was accepted into a journal that could not be read")

        // The dangerous path, and the reason this matters: the *same* journal
        // carries on living. If the unreadable moment was remembered as "no
        // entries", then once the directory is readable again this instance
        // will happily write a journal containing only the new record over the
        // top of a perfectly good one, and every application the old one named
        // is left changed with nothing that knows it.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(await journal.record(AppNapOverride(bundleID: "com.new", previous: nil)),
                "the journal never became usable again")
        let back = await journal.outstanding().map(\.bundleID)
        #expect(back.contains("com.old"),
                "the old journal was written over by an instance that had called it absent")
        #expect(back.contains("com.new"))

        let reopened = FileAppNapJournal(url: url)
        #expect(await reopened.outstanding().map(\.bundleID).contains("com.old"),
                "the journal on disk lost what it named")
    }
}
