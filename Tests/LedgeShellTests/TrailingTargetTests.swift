import LedgeCore
import Testing

@testable import LedgeShell

/// What a pointer on the trailing side opens: a readout showing in the
/// satellite first, then a running timer.
@Suite("What the trailing side opens")
@MainActor
struct TrailingTargetTests {

    private let readout = ActivityID(kind: .levels, source: "levels")
    private let timer = ActivityID(kind: .timer, source: "timer")

    private func target(_ zone: CompactZone?, readoutShown: Bool = false) -> ActivityID? {
        LedgeCoordinator.trailingTarget(
            zone: zone,
            transientShown: readoutShown, transient: readout, runningTimer: timer
        )
    }

    @Test("A readout first, then the timer")
    func asBefore() {
        #expect(target(.satellite, readoutShown: true) == readout)
        #expect(target(.trailing) == timer)
        #expect(target(.leading) == nil)
        #expect(target(nil) == nil)
    }
}
