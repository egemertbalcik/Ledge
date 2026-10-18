import Foundation
import LedgeCore
import LedgeProviders
import LedgeUI
import Testing

@testable import LedgeShell

/// A provider the test drives by hand.
private final class Pump: ActivityProvider {
    let identifier: String
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    init(identifier: String) { self.identifier = identifier }

    func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { self.continuation = $0 }
    }

    func stop() { continuation?.finish(); continuation = nil }

    func publish(_ activity: Activity) { continuation?.yield(.publish(activity)) }
    func retract(_ id: ActivityID) { continuation?.yield(.retract(id)) }
}

/// What the shell is told about the track resting in the ears.
///
/// The pure `MediaLinger` tests call `nowResting` themselves, so they cannot
/// see whether anything ever calls it. This drives the real
/// `ActivityCoordinator` and wires its resting callback to a real
/// `MediaLinger` with the shell's own branch rule, which is where the wiring
/// was missing.
@Suite("A new song becomes a resting fact")
@MainActor
struct RestingTrackTests {

    private static let spotify = "com.spotify.client"
    private static let full: TimeInterval = 120

    /// `LedgeCoordinator.mediaKey`, which is private to the shell.
    private func mediaKey(_ activity: Activity?) -> String? {
        guard let activity, case .nowPlaying(let payload) = activity.payload else { return nil }
        return "\(activity.id.source)|\(payload.itemKey ?? payload.title)"
    }

    private func song(_ key: String, playing: Bool) -> Activity {
        Activity(
            id: ActivityID(kind: .nowPlaying, source: Self.spotify),
            createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(
                title: key,
                artist: "Murda",
                isPlaying: playing,
                sourceName: "Spotify",
                itemKey: "spotify:track:\(key)"
            ))
        )
    }

    /// Drives the coordinator and reports what the linger made of each pause.
    @MainActor
    private final class Harness {
        let presentation = NotchPresentation()
        let activities: ActivityCoordinator
        let pump = Pump(identifier: "nowplaying")
        var linger = MediaLinger()
        /// Every verdict the shell's branch rule reached, in order, so a test
        /// can prove the callback arrived before asserting what it decided.
        var verdicts: [MediaLinger.Verdict] = []
        var callbacks = 0
        var clock: TimeInterval = 1_000

        init(_ key: @escaping (Activity?) -> String?, full: TimeInterval) {
            let preferences = Preferences(store: MemoryPreferenceStore())
            preferences.hasCompletedOnboarding = true
            activities = ActivityCoordinator(
                presentation: presentation,
                preferences: preferences,
                isPermitted: { _ in true }
            )
            activities.onNowPlayingChanged = { [weak self] present, playing, _ in
                guard let self else { return }
                self.callbacks += 1
                // The shell's three branches, as `wireRestingContent` has them.
                if !present {
                    self.linger.nothingRests(now: self.clock)
                } else if playing {
                    self.linger.nowResting(key(self.presentation.nowPlaying))
                } else {
                    self.verdicts.append(self.linger.paused(
                        key(self.presentation.nowPlaying), full: full, now: self.clock
                    ))
                }
            }
            activities.register(ProviderRegistration(
                id: "nowplaying",
                displayName: "Now Playing",
                kind: .nowPlaying,
                permission: nil,
                make: { [pump] in pump }
            ))
            activities.startEnabled()
            // start() is what wires the hub's change callback; startEnabled()
            // only starts the providers. The app calls both.
            activities.start()
        }

        var providerRuns: Bool { activities.isProviderRunning("nowplaying") }

        /// The coordinator consumes the provider's stream on its own task, so
        /// a yield alone does not prove delivery. Waits for something the
        /// delivery actually produces rather than for a guessed interval.
        @discardableResult
        func settle(until arrived: () -> Bool = { true }) async -> Bool {
            for _ in 0 ..< 200 {
                if arrived() { return true }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return arrived()
        }

        /// The shell has been told something it had not been told before.
        func settleForCallback(after count: Int) async -> Bool {
            await settle(until: { self.callbacks > count })
        }
    }

    @Test("Pausing the song that was playing keeps it in the ears")
    func theFirstSongKeepsItsStay() async {
        let harness = Harness(mediaKey, full: Self.full)
        #expect(harness.providerRuns)
        harness.pump.publish(song("A", playing: true))
        let playingArrived = await harness.settleForCallback(after: 0)
        let playingCount = harness.callbacks
        harness.pump.publish(song("A", playing: false))
        let pauseArrived = await harness.settleForCallback(after: playingCount)

        // Prove the shell was told something before asking what it decided.
        #expect(playingArrived)
        #expect(pauseArrived)
        #expect(harness.verdicts == [.stays(Self.full)])
    }

    /// The reported bug: one song follows another inside the same player, and
    /// pausing the second one emptied the island at once.
    @Test("Pausing the song that came next keeps it in the ears too")
    func theSecondSongKeepsItsStay() async {
        let harness = Harness(mediaKey, full: Self.full)
        harness.pump.publish(song("A", playing: true))
        let first = await harness.settleForCallback(after: 0)
        let afterA = harness.callbacks
        harness.pump.publish(song("B", playing: true))
        // The whole bug: this second song must itself become a resting fact.
        let second = await harness.settleForCallback(after: afterA)
        let afterB = harness.callbacks
        harness.pump.publish(song("B", playing: false))
        let paused = await harness.settleForCallback(after: afterB)

        #expect(first)
        #expect(second)
        #expect(paused)
        #expect(harness.presentation.nowPlaying.map { mediaKey($0) } == "\(Self.spotify)|spotify:track:B")
        #expect(harness.verdicts == [.stays(Self.full)])
    }

    /// The reason the comparison is on the track's identity and not its
    /// payload: Now Playing republishes every second as the position moves.
    @Test("A moving position is not a new song")
    func elapsedTimeIsNotAChange() async {
        let harness = Harness(mediaKey, full: Self.full)
        harness.pump.publish(song("A", playing: true))
        #expect(await harness.settleForCallback(after: 0))
        let afterFirst = harness.callbacks

        // The same song, republished the way the provider does every second.
        for _ in 0 ..< 5 {
            harness.pump.publish(song("A", playing: true))
            await harness.settle(until: { false })
        }
        #expect(afterFirst > 0)
        #expect(harness.callbacks == afterFirst)
    }

    /// A paused track that is republished must not have its deadline reset —
    /// the stay belongs to the pause, not to each republish of the card.
    @Test("A paused song's stay runs down rather than restarting")
    func theStayDoesNotRestart() async {
        let harness = Harness(mediaKey, full: Self.full)
        harness.pump.publish(song("A", playing: true))
        #expect(await harness.settleForCallback(after: 0))
        let afterPlaying = harness.callbacks
        harness.pump.publish(song("A", playing: false))
        #expect(await harness.settleForCallback(after: afterPlaying))

        // Forty seconds later the card is republished while still paused.
        harness.clock += 40
        harness.pump.publish(song("A", playing: false))
        await harness.settle(until: { false })

        #expect(harness.verdicts.first == .stays(Self.full))
        if harness.verdicts.count > 1 {
            #expect(harness.verdicts[1] == .stays(Self.full - 40))
        }
    }
}

/// The clock behind Keep Awake's short stay in the ears.
/// A clock the coordinator can read from its initialiser.
@MainActor
private final class ClockBox {
    var now: TimeInterval = 1_000
}

/// What a running hold tells the shell — which is now nothing about resting.
///
/// It used to be "present, not playing": the only shape the shell reads as
/// paused music. Every hold went down the paused-track branch, which asked
/// the linger about a track that did not exist and was granted two minutes
/// for it — the island held open with nothing in its ears.
@Suite("A Keep Awake hold is announced, not rested")
@MainActor
struct KeepAwakeWindowTests {

    @MainActor
    private final class Harness {
        let presentation = NotchPresentation()
        let activities: ActivityCoordinator
        let pump = Pump(identifier: "keepawake")
        private let clockBox: ClockBox
        var restingFacts: [(present: Bool, playing: Bool)] = []
        var starts: [Activity] = []
        var syncs = 0

        init() {
            let preferences = Preferences(store: MemoryPreferenceStore())
            preferences.hasCompletedOnboarding = true
            let clock = ClockBox()
            self.clockBox = clock
            activities = ActivityCoordinator(
                presentation: presentation,
                preferences: preferences,
                isPermitted: { _ in true },
                now: { clock.now }
            )
            activities.onNowPlayingChanged = { [weak self] present, playing, _ in
                self?.restingFacts.append((present, playing))
            }
            activities.onKeepAwakeStarted = { [weak self] activity in
                self?.starts.append(activity)
            }
            activities.register(ProviderRegistration(
                id: "keepawake",
                displayName: "Keep Awake",
                kind: .keepAwake,
                permission: nil,
                make: { [pump] in pump }
            ))
            activities.startEnabled()
            activities.start()
        }

        func hold(_ phase: KeepAwakePayload.Phase, remaining: TimeInterval = 3_600) -> Activity {
            Activity(
                id: ActivityID(kind: .keepAwake, source: "session"),
                createdAt: 0,
                payload: .keepAwake(KeepAwakePayload(phase: phase, remaining: remaining))
            )
        }

        /// Waits for the queue to have actually taken a publication, proven
        /// by the presentation reflecting it rather than by an interval.
        @discardableResult
        func settle(until arrived: () -> Bool) async -> Bool {
            for _ in 0 ..< 200 {
                if arrived() { return true }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return arrived()
        }

        var holdIsRunning: Bool { presentation.liveKeepAwake != nil }
    }

    @Test("A running hold never claims the island as something resting")
    func aHoldIsNotPresent() async {
        let harness = Harness()
        harness.pump.publish(harness.hold(.ready))
        #expect(await harness.settle(until: { harness.presentation.keepAwakeSession != nil }))
        harness.pump.publish(harness.hold(.running))
        #expect(await harness.settle(until: { harness.holdIsRunning }))

        // Whatever the shell was told, it was never "present".
        #expect(harness.restingFacts.allSatisfy { !$0.present })
    }

    @Test("Starting a hold is announced once")
    func theStartIsAnnounced() async {
        let harness = Harness()
        harness.pump.publish(harness.hold(.ready))
        #expect(await harness.settle(until: { harness.presentation.keepAwakeSession != nil }))
        harness.pump.publish(harness.hold(.running))
        #expect(await harness.settle(until: { !harness.starts.isEmpty }))

        // The once-a-second republishes of a running hold are not new starts.
        for left in stride(from: 3_590.0, through: 3_550, by: -10) {
            harness.pump.publish(harness.hold(.running, remaining: left))
            await harness.settle(until: { false })
        }
        #expect(harness.starts.count == 1)
    }

    /// A hold already running when it is first seen is a relaunch, and its
    /// own arrival — marked `resumed` — speaks for it.
    @Test("A hold already running when first seen is not a new start")
    func anInheritedHoldIsNotAStart() async {
        let harness = Harness()
        harness.pump.publish(harness.hold(.running))
        #expect(await harness.settle(until: { harness.holdIsRunning }))
        await harness.settle(until: { false })
        #expect(harness.starts.isEmpty)
    }

    @Test("Stopping and starting again is a second start")
    func aSecondHoldIsAnnouncedToo() async {
        let harness = Harness()
        harness.pump.publish(harness.hold(.ready))
        #expect(await harness.settle(until: { harness.presentation.keepAwakeSession != nil }))
        harness.pump.publish(harness.hold(.running))
        #expect(await harness.settle(until: { harness.starts.count == 1 }))
        harness.pump.publish(harness.hold(.ready))
        #expect(await harness.settle(until: { !harness.holdIsRunning }))
        harness.pump.publish(harness.hold(.running))
        #expect(await harness.settle(until: { harness.starts.count == 2 }))
    }
}
