import Foundation
import Synchronization
import Testing

@testable import LedgeSystem

@MainActor
private final class NoFolder: FocusSource {
    var isReadable: Bool { false }
    func current() -> FocusSnapshot? { nil }
    func reading() -> FocusReading { .unintelligible }
    func startWatching(_ onChange: @escaping () -> Void) {}
    func stopWatching() {}
}

/// The Focus-status permission check, counted by the thread it ran on.
private final class PermissionCheck: Sendable {
    private let state = Mutex((granted: true, onMain: 0, offMain: 0))

    func callAsFunction() -> Bool {
        state.withLock {
            if Thread.isMainThread { $0.onMain += 1 } else { $0.offMain += 1 }
            return $0.granted
        }
    }

    func set(granted: Bool) { state.withLock { $0.granted = granted } }
    var onMain: Int { state.withLock { $0.onMain } }
    var offMain: Int { state.withLock { $0.offMain } }
}

@Suite("The Focus permission check stays off the main thread", .timeLimit(.minutes(10)))
@MainActor
struct FocusPermissionCheckTests {

    @Test("Refreshing and reading do not ask for the permission on the main thread")
    func checkRunsOffMain() async throws {
        let check = PermissionCheck()
        let source = SystemFocusSource(
            file: NoFolder(), checkAuthorization: { check() }, readStatus: { false }
        )
        // Asked once, when the source is built. Not watching, so no backstop
        // tick can add a check of its own while this counts.
        try #require(check.onMain == 1)
        defer { source.stopWatching() }

        for _ in 0..<5 {
            source.refresh()
            _ = source.current()
            _ = source.isReadable
        }
        await source.settled()
        try #require(check.offMain > 0, "the permission was asked again")

        #expect(check.onMain == 1, "asked \(check.onMain) times on the main thread")
        // One check for the whole burst, and none after it while nothing moved.
        // A chance for a stray one to land, which a late one can only make
        // this miss.
        try await Task.sleep(for: .milliseconds(200))
        #expect(check.offMain == 1, "asked \(check.offMain) times off the main thread")
    }

    @Test("Losing the permission is still noticed and still clears a Focus")
    func revocationStillNoticed() async throws {
        let check = PermissionCheck()
        let source = SystemFocusSource(
            file: NoFolder(), checkAuthorization: { check() }, readStatus: { true }
        )
        try #require(source.current() == SystemFocusSource.genericFocus)
        var notes = 0
        _ = source.addObserver { notes += 1 }
        defer { source.stopWatching() }
        // Nothing is out yet; whatever is, is waited for, and stays quiet.
        await source.settled()
        try #require(notes == 0)

        check.set(granted: false)
        source.refresh()
        await source.settled()
        try #require(notes > 0, "the loss was noticed")

        #expect(source.current() == nil)
        #expect(!source.isReadable)
    }

    @Test("A permission granted later is picked up without a relaunch")
    func grantStillNoticed() async throws {
        let check = PermissionCheck()
        check.set(granted: false)
        let source = SystemFocusSource(
            file: NoFolder(), checkAuthorization: { check() }, readStatus: { true }
        )
        var notes = 0
        source.startWatching { notes += 1 }
        defer { source.stopWatching() }
        try #require(source.current() == nil)
        // The startup recheck read "refused" and must be out of the way, or
        // the refresh below would find it still running and ask nothing.
        await source.settled()

        check.set(granted: true)
        source.refresh()
        await source.settled()
        try #require(notes > 0, "the grant was noticed")

        #expect(source.current() == SystemFocusSource.genericFocus)
    }
}
