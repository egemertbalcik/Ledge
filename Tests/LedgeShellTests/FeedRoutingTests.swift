import LedgeCore
import Testing

@testable import LedgeShell

/// Where a device, a charger or a volume readout goes while something rests.
///
/// A feed sits in the ears all day. Treating it like music sent every volume
/// key and every AirPods arrival to a small satellite beside it for as long
/// as it was there, which changed far more than the feed.
@Suite("Readouts beside a resting feed")
@MainActor
struct FeedRoutingTests {

    private func beside(_ phase: NotchPhase, _ resting: ActivityKind?) -> Bool {
        LedgeCoordinator.satellitesBesideRest(phase: phase, resting: resting)
    }

    @Test("Music resting keeps its satellites")
    func musicKeepsSatellites() {
        #expect(beside(.companion, .nowPlaying))
        #expect(beside(.companion, .timer))
    }

    @Test("A feed resting alone gets the usual readout and peek")
    func feedGetsTheUsual() {
        #expect(!beside(.companion, .feeds))
    }

    @Test("Outside the companion nothing goes beside")
    func onlyBesideTheCompanion() {
        for phase in NotchPhase.allCases where phase != .companion {
            #expect(!beside(phase, .nowPlaying))
            #expect(!beside(phase, .feeds))
        }
    }
}
