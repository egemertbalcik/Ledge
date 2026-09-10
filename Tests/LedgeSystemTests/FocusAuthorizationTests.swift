import Foundation
import Synchronization
import Testing

@testable import LedgeSystem

@MainActor
private final class FocusFileStub: FocusSource {
    var isReadable = false
    var snapshot: FocusSnapshot?
    func current() -> FocusSnapshot? { snapshot }
    func startWatching(_ onChange: @escaping () -> Void) {}
    func stopWatching() {}
}

@MainActor
private final class FocusAuthorizationStub {
    var authorized = true
}

@Suite("Focus authorization lifecycle")
@MainActor
struct FocusAuthorizationTests {
    @Test("Revocation clears the baseline and notifies quiet-mode observers")
    func revocationClearsAndNotifies() {
        let file = FocusFileStub()
        let authorization = FocusAuthorizationStub()
        let focused = Mutex(true)
        let source = SystemFocusSource(
            file: file,
            statusAuthorized: { authorization.authorized },
            readStatus: { focused.withLock { $0 } }
        )
        #expect(source.current() != nil)
        var notifications = 0
        var observedFocus: FocusSnapshot?
        _ = source.addObserver {
            notifications += 1
            observedFocus = source.current()
        }
        defer { source.stopWatching() }
        authorization.authorized = false
        // Even before the next refresh, an unauthorized cached value must not
        // answer an explicit query as though it were still a usable reading.
        #expect(source.current() == nil)
        source.refresh()
        #expect(notifications == 1)
        #expect(observedFocus == nil)
        #expect(!source.isReadable)
        source.refresh()
        #expect(notifications == 1, "unchanged loss should not repeatedly notify")

        // Regrant takes a fresh baseline, rather than reviving the old true.
        focused.withLock { $0 = false }
        authorization.authorized = true
        #expect(source.current() == nil)
    }

    @Test("An unknown status reading clears a previously active baseline")
    func unknownReadingClearsBaseline() async throws {
        let focused = Mutex<Bool?>(true)
        let source = SystemFocusSource(
            file: FocusFileStub(),
            statusAuthorized: { true },
            readStatus: { focused.withLock { $0 } }
        )
        #expect(source.current() != nil)
        var notifications = 0
        _ = source.addObserver { notifications += 1 }
        defer { source.stopWatching() }
        focused.withLock { $0 = nil }
        source.refresh()
        for _ in 0..<100 where notifications == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(notifications == 1)
        #expect(source.current() == nil)
    }

    @Test("Readable database remains authoritative after status access is lost")
    func fileSurvivesStatusRevocation() {
        let file = FocusFileStub()
        let authorization = FocusAuthorizationStub()
        let source = SystemFocusSource(
            file: file,
            statusAuthorized: { authorization.authorized },
            readStatus: { true }
        )
        #expect(source.current() != nil)
        file.isReadable = true
        file.snapshot = FocusSnapshot(identifier: "work", name: "Work", symbolName: "briefcase")
        authorization.authorized = false
        source.refresh()
        #expect(source.isReadable)
        #expect(source.current() == file.snapshot)
    }
}
