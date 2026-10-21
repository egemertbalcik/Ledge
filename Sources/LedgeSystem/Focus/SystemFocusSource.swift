import CoreServices
import Foundation
import LedgeCore
import os

/// The Focus source the app actually uses: the database when it can be read,
/// the system's own answer when it cannot.
///
/// The database gives the mode's name and symbol but needs Full Disk Access —
/// which macOS will not prompt for, so on most Macs it is simply absent and the
/// Focus card never appeared at all. `INFocusStatusCenter` needs only an
/// ordinary permission and answers the question that matters most: is a Focus
/// on. This class prefers the richer source and falls back to the reliable one,
/// so the card works on a Mac where nothing was granted by hand.
///
/// Change detection follows the same split. With the database readable the
/// existing directory watcher fires instantly. Without it, the daemon's writes
/// still show up as filesystem events even though their contents do not — TCC
/// withholds the bytes, not the fact that something changed — so an FSEvents
/// stream is the trigger, and a slow timer is the backstop for the day that
/// stops being true.
@MainActor
public final class SystemFocusSource: FocusSource {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "focus")

    /// How often the fallback asks the system whether a Focus is on.
    ///
    /// This is the *only* signal for anyone who has not given Ledge the Focus
    /// folder, because the database whose changes would wake us cannot be read
    /// without it — so it is also the card's entire latency. Thirty seconds meant a Focus card
    /// that arrived long after the switch was flipped, which reads as the app
    /// being asleep. The read is a ~21 ms XPC round trip on a background task;
    /// four seconds of that is a fraction of a percent of one core, and it is
    /// what makes the card feel connected to the switch.
    private static let backstopInterval: TimeInterval = 4

    /// What last prompted a reading — the filesystem event or the timer.
    /// Only ever read by the trace: which of the two is doing the work is the
    /// difference between a Focus card that follows the switch and one that
    /// arrives up to half a minute late.
    fileprivate var lastWake = "startup"

    private let file: any FocusSource
    private let statusAuthorized: @MainActor () -> Bool
    /// Asks again whether status may be read, and calls back if that moved.
    private let recheckAuthorization: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let readStatus: @Sendable () -> Bool?
    private let recheckFileAccess: @MainActor () -> Void

    private var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var backstop: Task<Void, Never>?
    private var probe: Task<Void, Never>?
    /// The held permission check, when this source owns one. Kept only so
    /// `settled()` can wait on it.
    private var authorization: FocusAuthorization?

    /// The last usable answer from the system, for the fallback path. An
    /// unknown or unauthorized reading clears it. Without the database
    /// there is no name to show.
    private var fallbackFocused = false

    /// What the fallback path reports while a Focus is on. macOS's own icon for
    /// the generic case, and a name that promises nothing it cannot deliver.
    nonisolated static let genericFocus = FocusSnapshot(
        identifier: "com.apple.focus.unknown",
        name: "Focus",
        symbolName: "moon.fill"
    )

    public convenience init(file: FileFocusSource = FileFocusSource(), status: FocusStatusReader = FocusStatusReader()) {
        self.init(
            file: file,
            checkAuthorization: { status.isAuthorized },
            readStatus: { status.isFocused() },
            recheckFileAccess: { file.recheckAccess() }
        )
    }

    /// The shipped wiring: the permission check is held, and asked again only
    /// off the main thread.
    init(
        file: any FocusSource,
        checkAuthorization: @escaping @Sendable () -> Bool,
        readStatus: @escaping @Sendable () -> Bool?,
        recheckFileAccess: @escaping @MainActor () -> Void = {}
    ) {
        let authorization = FocusAuthorization(check: checkAuthorization)
        self.authorization = authorization
        self.file = file
        self.statusAuthorized = { authorization.isAuthorized }
        self.recheckAuthorization = { authorization.recheck(then: $0) }
        self.readStatus = readStatus
        self.recheckFileAccess = recheckFileAccess
    }

    /// Injects readings without requiring a particular macOS permission state.
    init(
        file: any FocusSource,
        statusAuthorized: @escaping @MainActor () -> Bool,
        readStatus: @escaping @Sendable () -> Bool?
    ) {
        self.file = file
        self.statusAuthorized = statusAuthorized
        self.recheckAuthorization = { _ in }
        self.readStatus = readStatus
        self.recheckFileAccess = {}
    }

    /// Whether *anything* can be reported: the database, or the system's
    /// on/off answer. False means the Focus card has no way to exist and the
    /// Permissions pane should say so.
    public var isReadable: Bool {
        file.isReadable || statusAuthorized()
    }

    public func current() -> FocusSnapshot? {
        primeIfNeeded()
        return Self.resolve(
            file: fileReading(),
            statusFocused: statusAuthorized() && fallbackFocused
        )
    }

    private func fileReading() -> FocusReading {
        file.isReadable ? file.reading() : .unintelligible
    }

    public func reading() -> FocusReading {
        current().map(FocusReading.on) ?? .off
    }

    /// Which answer wins, as a pure rule so it can be tested without a Mac in
    /// a particular permission state:
    ///
    /// - The database, when it can be read: the real name and symbol.
    /// - Otherwise the system's on/off answer, as a nameless Focus.
    /// - Nil when nothing is on, or when nothing may be read at all.
    ///
    /// Note the database wins even when it says *no* Focus: it is the more
    /// precise source, and disagreement means the cached fallback is stale.
    nonisolated static func resolve(
        file: FocusReading,
        statusFocused: Bool
    ) -> FocusSnapshot? {
        switch file {
        case .on(let snapshot):
            return snapshot
        case .off:
            // Authoritative. The database is the precise source, so its "no"
            // beats a fallback still holding a Focus that has ended.
            return nil
        case .unintelligible:
            // Unreadable, or readable in a shape this version does not know.
            // Either way this source knows nothing, and the public API is the
            // only one left that might.
            return statusFocused ? genericFocus : nil
        }
    }

    /// Everyone listening, by token. Plural because the Focus answer has two
    /// consumers — the card, and the rule that keeps the notch quiet during a
    /// Focus — and giving them a source each meant two watchers asking macOS
    /// the same question a millisecond apart, getting different answers, and
    /// announcing changes against each other's state.
    private var observers: [UUID: () -> Void] = [:]

    /// Adds a listener without disturbing the others.
    public func addObserver(_ onChange: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = onChange
        if observers.count == 1 && self.onChange == nil { beginWatching() }
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func notifyObservers() {
        onChange?()
        for observer in observers.values { observer() }
    }

    public func startWatching(_ onChange: @escaping () -> Void) {
        stopWatching()
        self.onChange = onChange
        beginWatching()
    }

    private func beginWatching() {

        // The database path watches itself, and keeps retrying so access that
        // arrives later upgrades this source without a relaunch.
        file.startWatching { [weak self] in self?.notifyObservers() }

        // The fallback runs alongside rather than instead: Full Disk Access can
        // be revoked at any moment, and the system's answer costs nothing to
        // keep current.
        startFallbackWatching()
        refresh()
    }

    /// The user has just given (or withdrawn) access to the database folder.
    /// Re-reads at once instead of waiting for a backoff or a timer tick.
    public func accessChanged() {
        recheckFileAccess()
        refresh()
        notifyObservers()
    }

    public func stopWatching() {
        file.stopWatching()
        onChange = nil
        observers.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        hasPrimed = false
        backstop?.cancel()
        backstop = nil
        probe?.cancel()
        probe = nil
        fallbackFocused = false
    }

    isolated deinit {
        // The event stream holds an *unretained* pointer back to this object,
        // so a source released without `stopWatching()` would leave the stream
        // running and the next filesystem event would call into freed memory.
        // The same door `MediaKeyInterceptor` closes for its event tap.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        backstop?.cancel()
        probe?.cancel()
    }

    /// Whether the fallback has ever been read. The provider takes its
    /// baseline from `current()` *before* watching starts, and an asynchronous
    /// first answer would arrive after that — turning "a Focus was already on
    /// when Ledge launched" into news it is not. One blocking read, once.
    private var hasPrimed = false

    private func primeIfNeeded() {
        guard !hasPrimed, !file.isReadable, statusAuthorized() else { return }
        hasPrimed = true
        fallbackFocused = readStatus() ?? false
    }

    /// Re-asks the system out of band — on wake, and when the screens light.
    public func refresh() {
        // Answered with what was last known; a change comes back through here.
        recheckAuthorization { [weak self] in self?.refresh() }
        guard statusAuthorized() else {
            invalidateFallback()
            return
        }
        // While the database answers, the fallback is not kept current, so it
        // is not kept at all. Held, it outlived the Focus it described and
        // spoke for it again the moment the file stopped answering.
        guard fileReading() == .unintelligible else {
            // Quietly: the file's answer is what is showing, so nothing an
            // observer can see has changed. Unprimed, so a folder that stops
            // answering takes one fresh reading rather than saying "off" until
            // the next probe. A probe still out is caught where it stores.
            hasPrimed = false
            fallbackFocused = false
            return
        }
        guard probe == nil else { return }
        probe = Task { [weak self] in
            guard let self else { return }
            // Keep this probe registered through confirmation, so another
            // refresh cannot start a competing reading in the meantime.
            defer { if !Task.isCancelled { self.probe = nil } }
            let focused = await Task.detached(priority: .utility) { [readStatus = self.readStatus] in
                readStatus()
            }.value
            guard !Task.isCancelled else { return }
            guard self.statusAuthorized(), let focused else {
                self.invalidateFallback()
                return
            }
            guard focused != self.fallbackFocused else { return }
            // Confirm changes because consecutive system readings can disagree.
            let confirmed = await Task.detached(priority: .utility) { [readStatus = self.readStatus] in
                try? await Task.sleep(for: .milliseconds(200))
                return readStatus()
            }.value
            guard !Task.isCancelled else { return }
            guard self.statusAuthorized(), let confirmed else {
                self.invalidateFallback()
                return
            }
            guard confirmed == focused else { return }
            // Asked before the database became readable, answered after: the
            // file speaks now, and a reading kept from here would go stale.
            guard self.fileReading() == .unintelligible else { return }
            self.fallbackFocused = focused
            Self.log.debug("focus (system): \(focused ? "on" : "off", privacy: .public)")
            if DebugSwitches.tracing("focus") {
                Self.log.notice("""
                    focus: now \(focused ? "on" : "off", privacy: .public) — \
                    noticed by \(self.lastWake, privacy: .public)
                    """)
            }
            self.notifyObservers()
        }
    }

    /// Returns once the permission recheck and the status probe in flight have
    /// finished, including a probe that a finishing recheck starts.
    ///
    /// For tests. Polling for their effect against a count of short sleeps ran
    /// out whenever the full suite held the main thread for longer than the
    /// count allowed: the probe was fine, it had not been given a turn yet.
    func settled() async {
        while true {
            let check = authorization?.work
            let probe = self.probe
            await check?.value
            await probe?.value
            if authorization?.work == check, self.probe == probe { return }
        }
    }

    private func invalidateFallback() {
        probe?.cancel()
        probe = nil
        hasPrimed = false
        let wasFocused = fallbackFocused
        fallbackFocused = false
        if wasFocused { notifyObservers() }
    }

    // MARK: - Fallback watching

    private func startFallbackWatching() {
        startEventStream()

        backstop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.backstopInterval))
                guard let self, !Task.isCancelled else { return }
                self.lastWake = "the \(Int(Self.backstopInterval))s timer"
                self.refresh()
            }
        }
    }

    /// An FSEvents stream over the Focus database. Its *contents* are behind
    /// Full Disk Access, but the event that something changed is not, so this
    /// is a free wake-up for the expensive read below it.
    private func startEventStream() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true).path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let source = Unmanaged<SystemFocusSource>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                source.lastWake = "filesystem event"
                source.refresh()
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            Self.log.notice("focus: no filesystem event stream — falling back to the timer alone")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }
}

/// Whether Focus status may be read, as last checked.
///
/// The check is itself an XPC round trip to the Focus daemon, as slow as the
/// reading it guards (~20 ms), and it was asked on the main thread by every
/// `current()` and every refresh — every four seconds, for everyone. Held
/// here, it is asked once when the source is built, where the launch baseline
/// already takes one blocking reading, and from then on only off the main
/// thread.
@MainActor
final class FocusAuthorization {

    private(set) var isAuthorized: Bool
    private let check: @Sendable () -> Bool
    private var checking = false
    /// The latest recheck, for `SystemFocusSource.settled()`.
    private(set) var work: Task<Void, Never>?

    init(check: @escaping @Sendable () -> Bool) {
        self.check = check
        isAuthorized = check()
    }

    /// Asks again off the main thread. `changed` runs, on the main actor, only
    /// when the answer moved.
    func recheck(then changed: @escaping @MainActor () -> Void) {
        guard !checking else { return }
        checking = true
        work = Task { [weak self, check] in
            let now = await Task.detached(priority: .utility) { check() }.value
            guard let self else { return }
            self.checking = false
            guard now != self.isAuthorized else { return }
            self.isAuthorized = now
            changed()
        }
    }
}
