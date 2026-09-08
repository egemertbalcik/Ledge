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

    /// How often the fallback path re-asks the system regardless of events.
    /// One ~21 ms round trip at this cadence is background noise; it exists so
    /// a missed event costs a slow update rather than a dead card.
    /// How often the fallback asks the system whether a Focus is on.
    ///
    /// This is the *only* signal for anyone without Full Disk Access, because
    /// the database whose changes would wake us is unreadable without it — so
    /// it is also the card's entire latency. Thirty seconds meant a Focus card
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

    private let file: FileFocusSource
    private let status: FocusStatusReader

    private var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var backstop: Task<Void, Never>?
    private var probe: Task<Void, Never>?

    /// The last answer from the system, for the fallback path. Nil means "no
    /// Focus", and the snapshot is deliberately generic: without the database
    /// there is no name to show.
    private var fallbackFocused = false

    /// What the fallback path reports while a Focus is on. macOS's own icon for
    /// the generic case, and a name that promises nothing it cannot deliver.
    nonisolated static let genericFocus = FocusSnapshot(
        identifier: "com.apple.focus.unknown",
        name: "Focus",
        symbolName: "moon.fill"
    )

    public init(file: FileFocusSource = FileFocusSource(), status: FocusStatusReader = FocusStatusReader()) {
        self.file = file
        self.status = status
    }

    /// Whether *anything* can be reported: the database, or the system's
    /// on/off answer. False means the Focus card has no way to exist and the
    /// Permissions pane should say so.
    public var isReadable: Bool {
        file.isReadable || status.isAuthorized
    }

    public func current() -> FocusSnapshot? {
        primeIfNeeded()
        return Self.resolve(
            fileSnapshot: file.isReadable ? file.current() : nil,
            fileReadable: file.isReadable,
            statusFocused: fallbackFocused
        )
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
        fileSnapshot: FocusSnapshot?,
        fileReadable: Bool,
        statusFocused: Bool
    ) -> FocusSnapshot? {
        if fileReadable { return fileSnapshot }
        return statusFocused ? genericFocus : nil
    }

    public func startWatching(_ onChange: @escaping () -> Void) {
        stopWatching()
        self.onChange = onChange

        // The database path watches itself, and keeps retrying so a grant that
        // arrives later upgrades this source without a relaunch.
        file.startWatching { [weak self] in self?.onChange?() }

        // The fallback runs alongside rather than instead: Full Disk Access can
        // be revoked at any moment, and the system's answer costs nothing to
        // keep current.
        startFallbackWatching()
        refresh()
    }

    public func stopWatching() {
        file.stopWatching()
        onChange = nil
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
        guard !hasPrimed, !file.isReadable, status.isAuthorized else { return }
        hasPrimed = true
        fallbackFocused = status.isFocused() ?? false
    }

    /// Re-asks the system out of band — on wake, and when the screens light.
    public func refresh() {
        guard !file.isReadable, status.isAuthorized else { return }
        guard probe == nil else { return }
        probe = Task { [weak self] in
            // The read is a slow XPC round trip; keep it off the main actor.
            let focused = await Task.detached(priority: .utility) { [status = self?.status] in
                status?.isFocused() ?? false
            }.value
            guard let self, !Task.isCancelled else { return }
            self.probe = nil
            guard focused != self.fallbackFocused else { return }
            self.fallbackFocused = focused
            Self.log.debug("focus (system): \(focused ? "on" : "off", privacy: .public)")
            if DebugSwitches.tracing("focus") {
                Self.log.notice("""
                    focus: now \(focused ? "on" : "off", privacy: .public) — \
                    noticed by \(self.lastWake, privacy: .public)
                    """)
            }
            self.onChange?()
        }
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
