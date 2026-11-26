import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

@MainActor
private final class FakeRoute: AudioRouteWatching {
    private var onChange: (@MainActor (String) -> Void)?
    private(set) var isWatching = false

    func startWatching(_ onChange: @escaping @MainActor (_ name: String) -> Void) {
        self.onChange = onChange
        isWatching = true
    }

    func stopWatching() {
        onChange = nil
        isWatching = false
    }

    func moveTo(_ name: String) { onChange?(name) }
}

/// Answers the Bluetooth reads a provider asks for and counts them.
///
/// The count goes up when a read starts. That is as good as "finished" only
/// because the answer comes back in the same turn and the provider acts on it
/// with no pause in between. Where the order of a read's return matters, use
/// `HeldLookups`.
@MainActor
private final class Lookups {
    private(set) var count = 0
    var answer: BluetoothDeviceSnapshot?
    init(_ answer: BluetoothDeviceSnapshot? = nil) { self.answer = answer }
    func read(_ name: String) -> BluetoothDeviceSnapshot? {
        count += 1
        return answer
    }
}

/// Bluetooth reads that stay out until the test answers each one by hand, so
/// a read can come back after a newer change, after its deadline or after the
/// provider has stopped.
@MainActor
private final class HeldLookups {
    private var out: [(name: String, answer: CheckedContinuation<BluetoothDeviceSnapshot?, Never>)] = []
    var waiting: Int { out.count }

    func read(_ name: String) async -> BluetoothDeviceSnapshot? {
        await withCheckedContinuation { out.append((name, $0)) }
    }

    /// Lets the provider's own tasks run until `count` reads are out.
    func wait(for count: Int) async {
        let began = ContinuousClock.now
        while out.count < count, ContinuousClock.now - began < .seconds(20) { await Task.yield() }
    }

    /// Answers the read for `name`, then lets the provider act on the answer.
    func answer(_ name: String, with device: BluetoothDeviceSnapshot?) async {
        guard let index = out.firstIndex(where: { $0.name == name }) else {
            Issue.record("no read is out for \(name)")
            return
        }
        out.remove(at: index).answer.resume(returning: device)
        // What the provider does with an answer happens in one turn of the
        // main actor. These yields are turns, not time.
        for _ in 0..<50 { await Task.yield() }
    }
}

/// The deadlines a provider asked for, held until the test lets them pass.
@MainActor
private final class Deadlines {
    private var waiting: [@MainActor () -> Void] = []
    var count: Int { waiting.count }
    func hold(_ work: @escaping @MainActor () -> Void) { waiting.append(work) }
    /// Every deadline asked for so far passes, oldest first.
    func pass() {
        let due = waiting
        waiting.removeAll()
        for work in due { work() }
    }
}

@Suite("Saying where sound just went")
@MainActor
struct AudioRouteProviderTests {

    /// Runs the provider through `body` and returns every card it published.
    ///
    /// Nothing here waits on a clock. The Bluetooth read is counted, so a
    /// test knows it ran; the deadline is the test's to pass; and stopping
    /// the provider ends the stream after everything already published, so
    /// reading it to the end sees all of it.
    private func cards(
        lookups: Lookups,
        now: TimeInterval,
        recent: RecentConnections = RecentConnections(),
        expectingReads reads: Int = 1,
        change body: @MainActor (FakeRoute) -> Void,
        afterTheRead then: @MainActor (Deadlines) -> Void = { $0.pass() }
    ) async -> [Activity] {
        let route = FakeRoute()
        let deadlines = Deadlines()
        let provider = AudioRouteProvider(
            source: route, now: { now },
            bluetoothDevice: { lookups.read($0) },
            afterDeadline: { deadlines.hold($0) }
        )
        // Its own memory of recent hellos, not the one the app shares: tests
        // run side by side and one clearing it would undo another's setup.
        provider.recentConnections = recent
        let stream = provider.start()
        body(route)
        // The read is made in a task of the provider's own; let it run.
        let began = ContinuousClock.now
        while lookups.count < reads, ContinuousClock.now - began < .seconds(20) {
            await Task.yield()
        }
        #expect(lookups.count == reads, "the Bluetooth read ran, so what follows is a decision and not a no-show")
        then(deadlines)
        provider.stop()
        var told: [Activity] = []
        for await event in stream {
            if case .publish(let activity) = event { told.append(activity) }
        }
        return told
    }

    private func names(_ cards: [Activity]) -> [String] {
        cards.compactMap { if case .device(let payload) = $0.payload { payload.name } else { nil } }
    }

    private func device(
        _ name: String, levels: [String: Double], symbol: String = "airpods.pro", isApple: Bool = true
    ) -> BluetoothDeviceSnapshot {
        BluetoothDeviceSnapshot(
            name: name, address: "80:AF:19:40:F9:B6", isConnected: true,
            batteryLevels: levels, symbolName: symbol, isApple: isApple
        )
    }

    @Test("A route change publishes a card that expires on its own")
    func routeChangeAnnounces() async {
        let told = await cards(lookups: Lookups(), now: 1_000, change: { $0.moveTo("AirPods Pro") })

        #expect(told.count == 1)
        #expect(told.first?.expiresAfter == AudioRouteProvider.lifetime,
                "a transient card that never expired would pile up")
        guard case .device(let payload)? = told.first?.payload else {
            Issue.record("expected a device card")
            return
        }
        #expect(payload.name == "AirPods Pro")
        #expect(payload.symbolName == "airpods.pro")
        // No Bluetooth device of that name: nothing to lend a ring.
        #expect(payload.batteryLevels.isEmpty)
    }

    @Test("Earbuds that stayed connected lend their battery, in one card")
    func stayedConnectedCarriesBattery() async {
        let buds = device("only and one", levels: ["Left": 0.9, "Right": 0.8, "Case": 0.5])
        let told = await cards(lookups: Lookups(buds), now: 5_000, change: { $0.moveTo("Only And One") })
        #expect(told.count == 1, "one card; the deadline passing afterwards adds none")
        guard case .device(let payload)? = told.first?.payload else {
            Issue.record("expected a device card")
            return
        }
        #expect(payload.batteryLevels == ["Left": 0.9, "Right": 0.8, "Case": 0.5])
        #expect(payload.symbolName == "airpods.pro")
    }

    /// Staying quiet for any Bluetooth device without levels took the card
    /// away from every speaker and headset that never reports a battery:
    /// sound moved to it and the notch said nothing.
    @Test("A connected Bluetooth output with no battery still gets its card")
    func outputWithoutLevelsIsTold() async {
        let speaker = device("Kitchen Speaker", levels: [:], symbol: "hifispeaker", isApple: false)
        var beforeTheDeadline = -1
        let told = await cards(
            lookups: Lookups(speaker), now: 6_000,
            change: { $0.moveTo("Kitchen Speaker") },
            afterTheRead: { deadlines in
                beforeTheDeadline = deadlines.count
                deadlines.pass()
            }
        )
        #expect(beforeTheDeadline == 1, "it was waiting on the deadline, not told at once")
        #expect(names(told) == ["Kitchen Speaker"])
        guard case .device(let payload)? = told.first?.payload else {
            Issue.record("expected a device card")
            return
        }
        #expect(payload.symbolName == "hifispeaker", "the device's own glyph, not one guessed from the name")
        #expect(payload.batteryLevels.isEmpty)
    }

    @Test("Earbuds whose hello arrives while the card waits leave the news to it")
    func helloDuringTheWaitKeepsItQuiet() async {
        let recent = RecentConnections()
        let told = await cards(
            lookups: Lookups(device("Arriving Buds", levels: [:])), now: 6_500, recent: recent,
            change: { $0.moveTo("Arriving Buds") },
            afterTheRead: { deadlines in
                // The read came back without levels; then the hello is heard,
                // and only then does the deadline pass.
                recent.noteConnected("Arriving Buds", at: 6_500)
                deadlines.pass()
            }
        )
        #expect(told.isEmpty)
    }

    @Test("A device that connected a moment ago is not told twice")
    func recentConnectionStaysQuiet() async {
        let recent = RecentConnections()
        recent.noteConnected("Fresh Buds", at: 7_000)
        let buds = device("Fresh Buds", levels: ["Left": 1, "Right": 1])
        let told = await cards(
            lookups: Lookups(buds), now: 7_001, recent: recent, change: { $0.moveTo("Fresh Buds") })
        #expect(told.isEmpty)
    }

    /// The quiet is for the one route a connection brings with it. Choosing
    /// the same device again a moment later is news.
    @Test("The quiet after a connection is used up by the first route to it")
    func quietIsUsedOnce() async {
        let recent = RecentConnections()
        recent.noteConnected("Fresh Buds", at: 7_100)
        let first = await cards(
            lookups: Lookups(), now: 7_101, recent: recent, change: { $0.moveTo("Fresh Buds") })
        #expect(first.isEmpty, "the route that came with the connection")
        #expect(!recent.connectedRecently("Fresh Buds", now: 7_101), "and the quiet is spent")
        let second = await cards(
            lookups: Lookups(), now: 7_102, recent: recent, change: { $0.moveTo("Fresh Buds") })
        #expect(names(second) == ["Fresh Buds"])
    }

    /// Connected A, sound to B, then back to A inside four seconds. The
    /// return was kept quiet as A's echo and the notch went on saying B.
    @Test("Sound going elsewhere ends the quiet, so the return is told")
    func anotherRouteEndsTheQuiet() async {
        let recent = RecentConnections()
        recent.noteConnected("Fresh Buds", at: 7_200)
        let away = await cards(
            lookups: Lookups(), now: 7_201, recent: recent, change: { $0.moveTo("MacBook Pro Speakers") })
        #expect(names(away) == ["MacBook Pro Speakers"])
        let back = await cards(
            lookups: Lookups(), now: 7_202, recent: recent, change: { $0.moveTo("Fresh Buds") })
        #expect(names(back) == ["Fresh Buds"])
    }

    /// Two sets of the same earbuds in one house. Nothing says which of them
    /// sound went to, so neither lends its battery.
    @Test("Two connected devices with one name lend no battery")
    func ambiguousNameMatchesNothing() {
        let one = device("AirPods Pro", levels: ["Left": 0.9])
        var two = device("airpods pro", levels: ["Left": 0.2])
        two.address = "80:AF:19:40:F9:B7"
        #expect(AudioRouteProvider.match("AirPods Pro", in: [one]) == one)
        #expect(AudioRouteProvider.match("AirPods Pro", in: [one, two]) == nil)
        #expect(AudioRouteProvider.match("AirPods Pro", in: []) == nil)
    }

    /// The first change's deadline used to fire whatever came after it: the
    /// notch said the new output and then, a moment later, the old one.
    @Test("Two quick changes tell only where sound ended up")
    func twoQuickChangesTellTheNewerOne() async {
        var held = -1
        let told = await cards(
            lookups: Lookups(), now: 8_000, expectingReads: 2,
            change: {
                $0.moveTo("MacBook Pro Speakers")
                $0.moveTo("Studio Display")
            },
            afterTheRead: { deadlines in
                held = deadlines.count
                deadlines.pass()
            }
        )
        #expect(held == 2, "both changes had a deadline and both passed")
        #expect(names(told) == ["Studio Display"])
    }

    /// Everything `provider` publishes from here on, readable after `stop()`.
    private func listen(to provider: AudioRouteProvider) -> Task<[Activity], Never> {
        let stream = provider.start()
        return Task { @MainActor in
            var told: [Activity] = []
            for await event in stream {
                if case .publish(let activity) = event { told.append(activity) }
            }
            return told
        }
    }

    private func glyph(_ activity: Activity?) -> String? {
        if case .device(let payload)? = activity?.payload { payload.symbolName } else { nil }
    }

    /// The older change's read comes back after the newer change has begun,
    /// carrying a device with no levels, while the newer read is still out.
    /// It must not be told. It must not leave its device behind either, for
    /// the newer change's deadline to pick up and wear as its glyph.
    @Test("A read that returns after a newer change is ignored")
    func olderReadReturnsLate() async {
        let route = FakeRoute()
        let lookups = HeldLookups()
        let deadlines = Deadlines()
        let provider = AudioRouteProvider(
            source: route, now: { 9_000 },
            bluetoothDevice: { await lookups.read($0) }, afterDeadline: { deadlines.hold($0) })
        let told = listen(to: provider)

        route.moveTo("Kitchen Speaker")
        route.moveTo("Studio Display")
        await lookups.wait(for: 2)
        #expect(lookups.waiting == 2, "both reads are out, so the order they return in is the test's")
        await lookups.answer(
            "Kitchen Speaker", with: device("Kitchen Speaker", levels: [:], symbol: "hifispeaker", isApple: false))
        // The newer change is told by its deadline, its own read still out.
        deadlines.pass()
        await lookups.answer("Studio Display", with: nil)
        provider.stop()

        let cards = await told.value
        #expect(names(cards) == ["Studio Display"])
        #expect(glyph(cards.first) == AudioDeviceSymbol.forName("Studio Display"))
        #expect(glyph(cards.first) != "hifispeaker", "the older change's device is not the newer one's")
    }

    /// A read that hangs must not hold the card for ever. When it does come
    /// back the change has been told and nothing more is said.
    @Test("A deadline that passes before the read returns tells the card bare, once")
    func deadlineBeatsTheRead() async {
        let route = FakeRoute()
        let lookups = HeldLookups()
        let deadlines = Deadlines()
        let provider = AudioRouteProvider(
            source: route, now: { 9_100 },
            bluetoothDevice: { await lookups.read($0) }, afterDeadline: { deadlines.hold($0) })
        let told = listen(to: provider)

        route.moveTo("Kitchen Speaker")
        await lookups.wait(for: 1)
        #expect(lookups.waiting == 1, "the read is still out when the deadline passes")
        deadlines.pass()
        await lookups.answer(
            "Kitchen Speaker", with: device("Kitchen Speaker", levels: ["Battery": 0.4], symbol: "airpods.pro"))
        provider.stop()

        let cards = await told.value
        #expect(names(cards) == ["Kitchen Speaker"])
        #expect(glyph(cards.first) == AudioDeviceSymbol.forName("Kitchen Speaker"),
                "told from the name alone: the device had not been read yet")
        guard case .device(let payload)? = cards.first?.payload else { return }
        #expect(payload.batteryLevels.isEmpty)
    }

    /// A change left over from before a stop has nothing to say to the run
    /// that starts afterwards.
    @Test("A change from before a stop is not told into the next run")
    func nothingCrossesAStop() async {
        let route = FakeRoute()
        let lookups = HeldLookups()
        let deadlines = Deadlines()
        let provider = AudioRouteProvider(
            source: route, now: { 9_200 },
            bluetoothDevice: { await lookups.read($0) }, afterDeadline: { deadlines.hold($0) })
        let first = listen(to: provider)

        route.moveTo("Kitchen Speaker")
        await lookups.wait(for: 1)
        #expect(lookups.waiting == 1 && deadlines.count == 1, "a read and a deadline are both still out")
        provider.stop()
        #expect(await first.value.isEmpty)
        // Ending a stream schedules one more stop of its own. Let that land
        // before starting again, or it would stop the second run instead.
        for _ in 0..<50 { await Task.yield() }

        let second = listen(to: provider)
        #expect(route.isWatching, "the second run is up, so anything told now would reach it")
        deadlines.pass()
        await lookups.answer("Kitchen Speaker", with: nil)
        provider.stop()
        #expect(await second.value.isEmpty)
    }

    /// It shares the device *kind* with the Bluetooth cards, so it needs its
    /// own source — otherwise a route change would quietly replace the card
    /// saying a device had just connected.
    @Test("It does not collide with the Bluetooth device cards")
    func ownsItsOwnActivity() {
        #expect(AudioRouteProvider.activityID.source == "audioroute")
        #expect(AudioRouteProvider.activityID.kind == .device)
    }

    @Test("Stopping the provider stops the watching")
    func stopReleasesTheListener() async {
        let route = FakeRoute()
        let provider = AudioRouteProvider(source: route, bluetoothDevice: { _ in nil })
        let stream = provider.start()
        #expect(route.isWatching, "it was watching, so stopping is what ends it")
        provider.stop()
        for await _ in stream {}
        #expect(route.isWatching == false)
    }

    @Test("Apple's own gear keeps its tinted glyph")
    func appleGearIsTinted() {
        #expect(AudioRouteProvider.readsAsApple("AirPods Pro"))
        #expect(AudioRouteProvider.readsAsApple("MacBook Pro Speakers"))
        #expect(AudioRouteProvider.readsAsApple("Scarlett 2i2") == false)
    }

    @Test("The glyph follows the device's name, since macOS gives no icon")
    func symbolsFollowNames() {
        #expect(AudioDeviceSymbol.forName("AirPods Max") == "airpodsmax")
        #expect(AudioDeviceSymbol.forName("MacBook Pro Speakers") == "laptopcomputer")
        #expect(AudioDeviceSymbol.forName("Studio Display") == "display")
        #expect(AudioDeviceSymbol.forName("Some Interface") == "hifispeaker.fill")
    }
}
