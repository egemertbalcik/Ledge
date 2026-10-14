import Foundation
import LedgeCore
import os

/// Reading and writing `NSAppSleepDisabled` in another application's
/// preferences.
///
/// This is the one thing Ledge does that reaches outside itself and changes
/// another app's settings, which is why it is opt-in, why the roster is short
/// and visible, and why every write is journalled before it happens. A user who
/// uninstalls Ledge should find nothing of it left in anybody else's
/// preferences.
///
/// A protocol first, because every test here would otherwise write to a real
/// preference domain on the machine it runs on.
public protocol AppNapPreferencing: Sendable {
    /// The key in that app's current-user, any-host domain — the one
    /// `defaults write <bundle> NSAppSleepDisabled -bool YES` writes.
    ///
    /// Three answers, all different: `.some(.some(value))` is a key holding a
    /// boolean, `.some(nil)` is no key, and `nil` is a domain that could not be
    /// read or a key holding something that is not a boolean. The last is not a
    /// failure to report loudly — it is a reason not to touch the app at all,
    /// because a value that cannot be put back exactly is a value not worth
    /// overwriting.
    func read(_ bundleID: String) -> Bool??
    /// Sets the key, or removes it when nil.
    func write(_ value: Bool?, to bundleID: String) -> PreferenceWrite
}

/// What a write to another application's preferences actually settled.
///
/// Three answers, because the real one is not a boolean. `CFPreferencesSetValue`
/// mutates the in-process cache and *then* `CFPreferencesSynchronize` tries to
/// flush it; a failed flush therefore means the value may already have changed
/// and may still reach disk. Treating that as "nothing happened" — which this
/// did, and which a test of ours enshrined — throws away the only record that
/// could ever put it back.
public enum PreferenceWrite: Sendable, Equatable {
    /// It landed.
    case written
    /// Nothing was attempted, so nothing changed. Only safe to answer before
    /// touching anything.
    case refused
    /// It may have changed. The record stays.
    case uncertain
}

/// The real one, over CFPreferences.
public struct SystemAppNapPreferences: AppNapPreferencing {

    private static let key = "NSAppSleepDisabled"
    private static let log = Logger(subsystem: "com.egemert.ledge", category: "app-nap")

    public init() {}

    public func read(_ bundleID: String) -> Bool?? {
        // Checked again here rather than trusted from the caller. This
        // function is the last thing between a bad id and
        // `kCFPreferencesAnyApplication`-shaped damage, and it costs nothing.
        guard AgentRoster.isWritableDomain(bundleID) else { return nil }
        guard let raw = CFPreferencesCopyValue(
            Self.key as CFString, bundleID as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) else {
            return .some(nil)
        }
        guard let number = raw as? NSNumber, CFGetTypeID(raw) == CFBooleanGetTypeID() else {
            // Somebody has put something else under this key. Putting it back
            // afterwards would mean knowing what it was, and a preference
            // Ledge cannot describe is a preference Ledge should not replace.
            Self.log.notice("app nap: \(bundleID, privacy: .public) holds a non-boolean; left alone")
            return nil
        }
        return .some(number.boolValue)
    }

    public func write(_ value: Bool?, to bundleID: String) -> PreferenceWrite {
        // Before anything is touched, so this is the one honest `.refused`.
        guard AgentRoster.isWritableDomain(bundleID) else { return .refused }
        CFPreferencesSetValue(
            Self.key as CFString,
            value.map { $0 as CFBoolean },
            bundleID as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        // Past this line nothing can honestly say the value is unchanged: the
        // cache has already taken it, and a failed flush may still reach disk
        // later or be read by that app from the cache in the meantime.
        let settled = CFPreferencesSynchronize(
            bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        if !settled {
            Self.log.error("app nap: \(bundleID, privacy: .public) would not flush; treating the write as uncertain")
        }
        return settled ? .written : .uncertain
    }
}

/// Turns App Nap off for the roster while a session runs, and puts every
/// preference back exactly as it was.
///
/// The ordering is the whole of it: a journal entry exists before the write
/// that it describes, and it is cleared only after the write that undoes it has
/// succeeded. Anything else and a crash leaves another application's settings
/// changed with no record saying so — which, unlike a dark screen, the user has
/// no way of even noticing, let alone fixing.
public actor AppNapSuspension {

    private let preferences: AppNapPreferencing
    private let journal: AppNapJournaling
    private static let log = Logger(subsystem: "com.egemert.ledge", category: "app-nap")

    /// The work still to be done, in the order it was asked for.
    ///
    /// An actor is not a lock. `begin` suspends at every journal call, and
    /// anything arriving in one of those gaps runs to completion first — so a
    /// `begin` and an `end` genuinely interleave, and so do two of either.
    ///
    /// A round number was the first attempt and it was not enough: it is a
    /// check *local to this type*, and the damage happens at the journal,
    /// where a cancelled begin's `clear` cannot tell its own record from the
    /// replacement's, and a stale end's restore writes an old value over a
    /// live session's. Ownership would have to reach every call.
    ///
    /// So nothing interleaves instead. Each operation waits for the one
    /// before it and the whole apply/restore pipeline is serial — which is
    /// what the ordering was always supposed to be, said once rather than
    /// defended at every await.
    private var tail: Task<Void, Never>?

    /// Told each time an operation joins the queue.
    ///
    /// Only a test sets this, and it is the difference between a test that
    /// proves the ordering and one that guesses at it: without it the only way
    /// to know an `end` had been asked for was to wait a while and see nothing
    /// happen, which is also what an `end` that was never scheduled looks
    /// like. Joining the queue is the moment the order is decided, so it is
    /// the moment worth observing.
    private var onAdmission: (@Sendable (String) -> Void)?

    /// For tests only.
    func setOnAdmission(_ observer: @escaping @Sendable (String) -> Void) {
        onAdmission = observer
    }

    /// Runs `work` after everything already asked for, and not before.
    private func serially(_ named: String,
                          _ work: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let mine = Task {
            await previous?.value
            await work()
        }
        tail = mine
        onAdmission?(named)
        await mine.value
    }

    public init(preferences: AppNapPreferencing = SystemAppNapPreferences(),
                journal: AppNapJournaling) {
        self.preferences = preferences
        self.journal = journal
    }

    /// Turns App Nap off across the roster.
    ///
    /// Returns the apps it actually changed. An app it could not journal is an
    /// app it does not touch — never the other way round.
    /// Turns App Nap off across the roster, if the user has asked for it.
    ///
    /// The switch and the roster are read *inside* the serialized operation,
    /// not before it. Reading them first meant awaiting the main actor before
    /// this type knew the operation existed — and an `end` completing during
    /// that hop could not be told about a begin that had not arrived yet.
    public func beginIfWanted(wanted: @escaping @MainActor @Sendable () -> Bool,
                              roster: @escaping @MainActor @Sendable () -> AgentRoster) async {
        await serially("beginIfWanted") { [weak self] in
            guard let self else { return }
            guard await wanted() else {
                // Not merely skipped: anything an earlier run left behind is
                // still put back. Turning the setting off is a reason to undo,
                // not a reason to forget.
                await self.drain()
                return
            }
            await self.apply(await roster())
        }
    }

    @discardableResult
    public func begin(_ roster: AgentRoster) async -> [String] {
        // The answer travels in a box rather than a captured var: the work
        // runs in a detached task so the chain can own it, and a var captured
        // across that boundary is not something Swift will let us mutate.
        let answer = ChangedApps()
        await serially("begin") { [weak self] in
            guard let self else { return }
            answer.set(await self.apply(roster))
        }
        return answer.value
    }

    @discardableResult
    private func apply(_ roster: AgentRoster) async -> [String] {
        // Whatever an earlier run left behind comes first. Writing a fresh
        // journal over an outstanding one would strand the apps it named.
        await drain()

        let planned = AppNapPlan.writes(for: roster) { preferences.read($0) }
        guard !planned.isEmpty else { return [] }

        var changed: [String] = []
        for entry in planned {
            guard await journal.record(entry) else {
                Self.log.error("app nap: could not journal \(entry.bundleID, privacy: .public); not touching it")
                continue
            }
            switch preferences.write(true, to: entry.bundleID) {
            case .written:
                changed.append(entry.bundleID)
            case .uncertain:
                // It may have landed. The record stays, and the next restore
                // puts the old value back over whatever is actually there —
                // which is right either way, because writing the value an app
                // already had costs nothing.
                changed.append(entry.bundleID)
            case .refused:
                // The only case where nothing was attempted, so the only case
                // where dropping the record is knowledge rather than a guess.
                await journal.clear(entry.bundleID)
            }
        }
        return changed
    }

    /// Puts every preference back. Safe to call when nothing is outstanding.
    public func end() async {
        await serially("end") { [weak self] in await self?.drain() }
    }

    /// Also the recovery path: a journal read at launch names exactly the apps
    /// a crash left changed.
    public func restoreOutstanding() async {
        await serially("restore") { [weak self] in await self?.drain() }
    }

    private func drain() async {
        for entry in await journal.outstanding() {
            switch preferences.write(entry.previous, to: entry.bundleID) {
            case .written:
                await journal.clear(entry.bundleID)
            case .uncertain, .refused:
                // Kept, and tried again next time. A record dropped on a
                // restore that may not have landed is another app left changed
                // forever with nothing left that knows it. Uncertain is kept
                // for the same reason it is kept on the way in: the next
                // attempt writing a value the app already has costs nothing,
                // and the alternative costs the user a setting.
                Self.log.error("app nap: \(entry.bundleID, privacy: .public) did not confirm the restore; keeping the record")
            }
        }
    }
}

/// Where the overrides are written down.
public protocol AppNapJournaling: Sendable {
    func outstanding() async -> [AppNapOverride]
    /// Returns false if the record did not land, which means the write it
    /// describes must not happen.
    func record(_ entry: AppNapOverride) async -> Bool
    func clear(_ bundleID: String) async
}

/// The real journal, beside the Keep Awake one.
public actor FileAppNapJournal: AppNapJournaling {

    private let url: URL
    private var entries: [String: AppNapOverride] = [:]
    private var loaded = false
    private static let log = Logger(subsystem: "com.egemert.ledge", category: "app-nap")

    public init(url: URL) {
        self.url = url
    }

    /// Reads the journal, and says whether it can be trusted.
    ///
    /// An unreadable file and an absent one are not the same thing, and
    /// treating them alike loses data: a file that cannot be read *this time*
    /// — a transient I/O failure, a half-written file from a crash — was taken
    /// as "no entries", and the next `record` then wrote a journal containing
    /// only the new entry, over the top of a perfectly good one. Every app the
    /// old journal named was left changed with nothing that knew it.
    ///
    /// So a failed read is remembered as a failure and retried, and nothing is
    /// written over a file nobody has managed to read.
    private func load() -> Bool {
        if loaded { return true }
        // Asked by reading, not by `fileExists`. A file whose directory cannot
        // be read does not exist as far as `fileExists` is concerned — it
        // answers false for a journal that is sitting right there — and
        // "absent" is the one answer that authorises writing a new one over
        // the top. A directory that is unreadable for a moment would then be
        // remembered as empty, and the first record afterwards would replace a
        // perfectly good journal with a single entry.
        //
        // Only the error that genuinely means "no such file" counts as absent.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // The ordinary case, and a real answer.
            loaded = true
            return true
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                                        && error.code == Int(ENOENT) {
            loaded = true
            return true
        } catch {
            Self.log.error("app nap: the journal could not be read (\(error.localizedDescription, privacy: .public)); not writing over it")
            return false
        }
        guard let stored = try? JSONDecoder().decode([AppNapOverride].self, from: data) else {
            // Understood as far as the bytes go, and not understood at all
            // beyond that. Set aside rather than deleted, so whatever it named
            // can still be recovered by hand.
            // A unique name, and nothing deleted to make room for it. The
            // fixed `.unreadable` name meant a second bad journal destroyed
            // the first one — which may have been the only remaining account
            // of what another application's preference used to be.
            // Second-resolution alone is not unique: two bad journals in the
            // same second collide, the move fails, and the second one is
            // simply left unquarantined. The date is for a human reading the
            // directory; the suffix is what makes it a different file.
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let unique = UUID().uuidString.prefix(8)
            let aside = url.appendingPathExtension("unreadable-\(stamp)-\(unique)")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
            } catch {
                // Still there, still unreadable, and still not written over.
                // Committing the empty state here would let the next record
                // replace the file this failed to preserve.
                Self.log.error("app nap: a journal that made no sense could not be set aside; leaving it alone")
                return false
            }
            Self.log.error("app nap: the journal made no sense; set aside at \(aside.lastPathComponent, privacy: .public)")
            loaded = true
            return true
        }
        entries = Dictionary(stored.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        loaded = true
        return true
    }

    private func flush() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Array(entries.values).sorted { $0.bundleID < $1.bundleID })
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Self.log.error("app nap: the journal would not write: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func outstanding() -> [AppNapOverride] {
        guard load() else { return [] }
        return Array(entries.values).sorted { $0.bundleID < $1.bundleID }
    }

    public func record(_ entry: AppNapOverride) -> Bool {
        // No write on an untrusted read. Returning false here is what stops
        // the caller touching the application at all, which is the point:
        // a journal nobody could read is a journal nobody could add to safely.
        guard load() else { return false }
        // An entry already here is from a run that did not finish. Its value is
        // the older and therefore the true one — the app's current setting is
        // whatever that run wrote, not what the user chose.
        guard entries[entry.bundleID] == nil else { return true }
        entries[entry.bundleID] = entry
        guard flush() else {
            entries[entry.bundleID] = nil
            return false
        }
        return true
    }

    public func clear(_ bundleID: String) {
        guard load() else { return }
        guard let removed = entries.removeValue(forKey: bundleID) else { return }
        if !flush() { entries[bundleID] = removed }
    }
}

/// What the provider needs of the App Nap work, and nothing more.
///
/// A protocol so `LedgeProviders` does not have to know whether the user has
/// asked for this at all — the answer lives with the preference, and a
/// provider that had to ask would need a preference store it has no business
/// holding.
public protocol AppNapSuspending: Sendable {
    /// Turns App Nap off across the roster, if the user has asked for it.
    func beginIfWanted() async
    func end() async
    func restoreOutstanding() async
}

/// The shipping one: reads the preference each time it is asked.
///
/// Read at the moment of use rather than captured, so a user who turns the
/// setting off mid-session is not still having their apps written to, and one
/// who turns it on does not have to restart a session for it.
public struct RosterAppNap: AppNapSuspending {

    private let suspension: AppNapSuspension
    // Main-actor closures, awaited rather than asserted into.
    //
    // These read the user's preferences, which live on the main actor, and
    // this type is nonisolated — so there is a real hop here whether or not
    // anybody writes one. `MainActor.assumeIsolated` does not perform it; it
    // asserts that it already happened, and traps when it has not. That
    // version shipped briefly and crashed the app on the path that starts the
    // mode, including when the feature was switched off, because the switch
    // still has to be read to find that out.
    private let wanted: @MainActor @Sendable () -> Bool
    private let roster: @MainActor @Sendable () -> AgentRoster

    public init(suspension: AppNapSuspension,
                wanted: @escaping @MainActor @Sendable () -> Bool,
                roster: @escaping @MainActor @Sendable () -> AgentRoster) {
        self.suspension = suspension
        self.wanted = wanted
        self.roster = roster
    }

    public func beginIfWanted() async {
        // Handed in, not read here. Reading them first meant awaiting the main
        // actor before the suspension knew this operation existed, and an end
        // completing during that hop could not be told about a begin that had
        // not arrived yet — so the old begin resumed afterwards and turned App
        // Nap off for a session that was over.
        await suspension.beginIfWanted(wanted: wanted, roster: roster)
    }

    public func end() async { await suspension.end() }
    public func restoreOutstanding() async { await suspension.restoreOutstanding() }
}


/// Where a serialized operation leaves its answer for the caller.
private final class ChangedApps: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func set(_ apps: [String]) { lock.withLock { stored = apps } }
    var value: [String] { lock.withLock { stored } }
}
