import Foundation
import LedgeCore
import Testing

/// Two players sounding at once, and which one the notch follows.
@Suite("Handing the notch between players")
struct CrossAppHandoverTests {

    private let spotify = "com.spotify.client"
    private let music = "com.apple.Music"
    private let chrome = "com.google.Chrome"
    private let safari = "com.apple.Safari"

    private func isApp(_ bundleID: String) -> Bool {
        bundleID == "com.spotify.client" || bundleID == "com.apple.Music"
    }

    private func handsOver(
        _ handover: inout CrossAppHandover,
        from held: String,
        to newcomer: String,
        playing: Bool = true,
        at now: TimeInterval
    ) -> Bool {
        handover.handsOver(
            from: held, to: newcomer, newcomerIsPlaying: playing, at: now, isApp: isApp
        )
    }

    @Test("A page never takes the notch from a playing app")
    func autoplayIsRefused() {
        var handover = CrossAppHandover()
        for second in stride(from: 0.0, through: 30.0, by: 1.0) {
            #expect(handsOver(&handover, from: spotify, to: chrome, at: 1_000 + second) == false)
        }
    }

    @Test("An app takes the notch from a page, after it has kept playing")
    func appTakesOverFromAPage() {
        var handover = CrossAppHandover()
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_000) == false, "one sighting is not enough")
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_001) == false)
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_000 + CrossAppHandover.corroboration))
    }

    @Test("One page yields to another, on the same terms")
    func pageYieldsToPage() {
        var handover = CrossAppHandover()
        #expect(handsOver(&handover, from: chrome, to: safari, at: 1_000) == false)
        #expect(handsOver(&handover, from: chrome, to: safari, at: 1_003))
    }

    @Test("One app yields to another, on the same terms")
    func appYieldsToApp() {
        var handover = CrossAppHandover()
        #expect(handsOver(&handover, from: spotify, to: music, at: 1_000) == false)
        #expect(handsOver(&handover, from: spotify, to: music, at: 1_003))
    }

    @Test("A newcomer that is not playing is not a newcomer")
    func pausedNewcomerIsIgnored() {
        var handover = CrossAppHandover()
        #expect(handsOver(&handover, from: chrome, to: spotify, playing: false, at: 1_000) == false)
        // And it does not count towards the corroboration either: the clock
        // starts when it actually starts playing.
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_003) == false)
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_006))
    }

    @Test("A newcomer that gives up loses its progress")
    func aFlickeringChallengerStartsOver() {
        var handover = CrossAppHandover()
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_000) == false)
        // It stops for a moment — the argument is over.
        #expect(handsOver(&handover, from: chrome, to: spotify, playing: false, at: 1_001) == false)
        // Back again: the two and a half seconds start from here, not from
        // the first sighting.
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_002) == false)
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_004) == false)
        #expect(handsOver(&handover, from: chrome, to: spotify, at: 1_005))
    }
}
