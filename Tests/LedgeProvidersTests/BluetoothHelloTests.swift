import Foundation
import LedgeCore
import os
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// A Bluetooth source a test drives by hand.
@MainActor
private final class HandBluetooth: BluetoothDeviceSource {
    var onConnect: ((BluetoothDeviceSnapshot) -> Void)?
    var onDisconnect: ((String) -> Void)?
    /// What a read of the paired list answers with.
    var listed: [BluetoothDeviceSnapshot] = []
    private(set) var reads = 0
    var isAvailable: Bool { true }

    func pairedDevices() async -> PairedListReading? {
        reads += 1
        return PairedListReading(devices: listed, readAt: Date())
    }

    func startWatching(
        onConnect: @escaping (BluetoothDeviceSnapshot) -> Void,
        onDisconnect: @escaping (String) -> Void
    ) {
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    func stopWatching() {}
}

private final class Observed: DeviceObservationSink, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { state.withLock { $0 } }
    func submit(_ observation: DeviceObservation) { state.withLock { $0 += 1 } }
}

/// The connection cards a provider published.
@MainActor
private final class Heard {
    /// The battery levels each hello carried, in the order they were told.
    var hellos: [[String: Double]] = []
    var goodbyes = 0
    /// How long each card said it would live.
    var helloLives: [TimeInterval?] = []
    var goodbyeLives: [TimeInterval?] = []
}

/// "Connected" and "Disconnected" are told once each and only when they are
/// news: not late, not twice, not lost to a blip and not for a device that
/// was gone before it was ever announced.
@Suite("Saying a device came or went")
@MainActor
struct BluetoothHelloTests {

    private let address = "80:AF:19:40:F9:B6"

    private func device(_ levels: [String: Double] = [:], isApple: Bool) -> BluetoothDeviceSnapshot {
        BluetoothDeviceSnapshot(
            name: "Test Device", address: address, isConnected: true,
            batteryLevels: levels, symbolName: isApple ? "airpods.pro" : "hifispeaker", isApple: isApple
        )
    }

    /// Runs a provider through `body` and reports what it said.
    ///
    /// It listens until `done`, not for a fixed time. A busy machine can
    /// stretch a 100 ms wait into seconds. A test that slept "long enough"
    /// failed there for no fault of the code. `thenListen` is a
    /// short extra for the tests that check something was *not* told twice;
    /// under load it can miss a late second telling, never invent one.
    private func heard(
        source: HandBluetooth = HandBluetooth(),
        sink: Observed? = nil,
        grace: TimeInterval = 0.15,
        steps: [Int] = [40, 80, 120],
        remembered: Set<String>? = nil,
        until done: @MainActor (Heard) -> Bool,
        thenListen extra: Duration = .milliseconds(300),
        limit: Duration = .seconds(20),
        _ body: @MainActor (HandBluetooth) async -> Void
    ) async -> Heard {
        let recalled = OSAllocatedUnfairLock(initialState: false)
        let provider = BluetoothProvider(
            source: source, observations: sink, flapGrace: grace, lateLevelSteps: steps,
            levelReporters: remembered.map { known -> @Sendable () async -> Set<String> in
                { @Sendable in
                    recalled.withLock { $0 = true }
                    return known
                }
            })
        let stream = provider.start()
        let heard = Heard()
        let reader = Task { @MainActor in
            for await event in stream {
                guard case .publish(let activity) = event, case .device(let payload) = activity.payload,
                      payload.announcesConnection else { continue }
                if payload.isConnected == true {
                    heard.hellos.append(payload.batteryLevels)
                    heard.helloLives.append(activity.expiresAfter)
                } else {
                    heard.goodbyes += 1
                    heard.goodbyeLives.append(activity.expiresAfter)
                }
            }
        }
        // The startup read of the paired list has to be out of the way first.
        var began = ContinuousClock.now
        while source.reads == 0, ContinuousClock.now - began < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(20))
        if remembered != nil {
            // What earlier runs remembered has to be in hand before the connect.
            while !recalled.withLock({ $0 }), ContinuousClock.now - began < limit { await Task.yield() }
            #expect(recalled.withLock { $0 }, "the provider asked what earlier runs remembered")
            for _ in 0..<50 { await Task.yield() }
        }
        await body(source)
        began = ContinuousClock.now
        while !done(heard), ContinuousClock.now - began < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: extra)
        provider.stop()
        await reader.value
        return heard
    }

    /// A speaker or a mouse never reports a battery. Waiting for one made
    /// every such device say "Connected" two seconds late.
    @Test("A device with no battery to wait for says hello at once")
    func noLevelsToWaitFor() async {
        // A wait so long that a hello which sat through it would never be
        // heard here: it arrives only if it was said without waiting.
        let result = await heard(
            steps: [120_000], until: { !$0.hellos.isEmpty }, limit: .seconds(8)
        ) { source in
            source.onConnect?(self.device(isApple: false))
        }
        #expect(result.hellos.count == 1)
    }

    /// Headphones from another maker that do report a battery. Nothing in
    /// this run has seen their levels yet. An earlier run has, which is
    /// enough to wait for them. Without it they said hello bare on their
    /// first connect after every launch.
    @Test("Headphones remembered as reporting a battery are waited for on their first connect")
    func rememberedReporterIsWaitedFor() async {
        let source = HandBluetooth()
        let levels = ["Battery": 0.7]
        let result = await heard(
            source: source, steps: [60, 120, 180],
            // Lower case, as the catalogue keeps addresses.
            remembered: [address.lowercased()],
            until: { !$0.hellos.isEmpty }
        ) { source in
            source.onConnect?(self.device(isApple: false))
            source.listed = [self.device(levels, isApple: false)]
        }
        #expect(result.hellos == [levels])
    }

    @Test("Earbuds whose levels arrive a moment later say hello once, with them")
    func waitsForLevels() async {
        let source = HandBluetooth()
        let result = await heard(source: source, steps: [60, 120, 180], until: { !$0.hellos.isEmpty }) { source in
            source.onConnect?(self.device(isApple: true))
            source.listed = [self.device(["Left": 0.8, "Right": 0.7], isApple: true)]
        }
        #expect(result.hellos.count == 1)
        #expect(result.hellos.first == ["Left": 0.8, "Right": 0.7])
    }

    @Test("Earbuds whose levels never come still say hello, bare, when the wait ends")
    func waitEndsWithoutLevels() async {
        let source = HandBluetooth()
        var readsAtConnect = 0
        let result = await heard(source: source, until: { !$0.hellos.isEmpty }) { source in
            readsAtConnect = source.reads
            source.onConnect?(self.device(isApple: true))
        }
        #expect(result.hellos.count == 1)
        #expect(result.hellos.first?.isEmpty == true)
        #expect(source.reads > readsAtConnect, "it looked for levels before giving up, so this was the wait ending")
    }

    /// The wait gave up when it saw the disconnect. The reconnect was then
    /// treated as link churn and kept quiet: no hello at all.
    ///
    /// The first wait here cannot finish inside the test, however slow the
    /// machine: it looks every 50 ms for ten seconds and finds no levels. The
    /// levels only exist after the reconnect, so a hello that carries them
    /// can only have come from the wait the reconnect started.
    @Test("A link blip while the hello waits does not lose the hello")
    func blipDuringTheWait() async {
        let levels = ["Left": 0.6, "Right": 0.5]
        let result = await heard(
            grace: 60, steps: Array(stride(from: 50, through: 10_000, by: 50)),
            until: { !$0.hellos.isEmpty }
        ) { source in
            source.onConnect?(self.device(isApple: true))
            try? await Task.sleep(for: .milliseconds(90))
            source.onDisconnect?(self.address)
            try? await Task.sleep(for: .milliseconds(90))
            source.onConnect?(self.device(isApple: true))
            source.listed = [self.device(levels, isApple: true)]
        }
        #expect(result.hellos == [levels])
        #expect(result.goodbyes == 0)
    }

    /// The sound output card stays quiet for a few seconds after a connect so
    /// that the hello tells the arrival alone. A hello said late, after a
    /// blip, needs those seconds counted from the reconnect.
    @Test("A hello owed after a blip keeps the sound output card quiet from the reconnect")
    func blipRenewsTheQuietWindow() async {
        let source = HandBluetooth()
        var clock: TimeInterval = 50_000
        let provider = BluetoothProvider(
            source: source, now: { clock }, flapGrace: 60, lateLevelSteps: [120_000])
        let recent = RecentConnections()
        provider.recentConnections = recent
        let stream = provider.start()
        let name = "Blip Window Buds"
        let buds = BluetoothDeviceSnapshot(
            name: name, address: address, isConnected: true,
            batteryLevels: [:], symbolName: "airpods.pro", isApple: true)

        source.onConnect?(buds)
        #expect(recent.connectedRecently(name, now: 50_001), "noted at the first connect")
        clock = 50_010
        #expect(!recent.connectedRecently(name, now: 50_011), "and that window has closed")
        source.onDisconnect?(address)
        source.onConnect?(buds)
        #expect(recent.connectedRecently(name, now: 50_011))

        provider.stop()
        for await _ in stream {}
    }

    /// Gone and back before the wait looks again: the old wait and the new
    /// one must not both tell the same connection.
    @Test("A blip between two looks says hello once, not twice")
    func blipBetweenLooks() async {
        let result = await heard(
            grace: 60, steps: [300, 600], until: { !$0.hellos.isEmpty }, thenListen: .milliseconds(900)
        ) { source in
            // No pause between them: all three land before the first look.
            source.onConnect?(self.device(isApple: true))
            source.onDisconnect?(self.address)
            source.onConnect?(self.device(isApple: true))
        }
        #expect(result.hellos.count == 1)
        #expect(result.goodbyes == 0)
    }

    @Test("A device that leaves before it was ever announced leaves without a card")
    func goneBeforeHello() async {
        let sink = Observed()
        // The departure is observed at the moment the goodbye would be told,
        // so two observations mean that moment has come and gone.
        let result = await heard(
            sink: sink, grace: 0.15, steps: [120_000], until: { _ in sink.count >= 2 }
        ) { source in
            source.onConnect?(self.device(isApple: true))
            source.onDisconnect?(self.address)
        }
        #expect(sink.count == 2, "the connection and the departure are still observed")
        #expect(result.hellos.isEmpty)
        #expect(result.goodbyes == 0, "Disconnected for something that never said Connected")
    }

    @Test("A device that said hello and then leaves says goodbye")
    func goodbyeAfterHello() async {
        let result = await heard(grace: 0.15, until: { $0.goodbyes > 0 }) { source in
            source.onConnect?(self.device(["Battery": 0.5], isApple: false))
            source.onDisconnect?(self.address)
        }
        #expect(result.hellos.count == 1)
        #expect(result.goodbyes == 1)
    }

    /// The card lived four seconds and a peek may wait eight for the stage. A
    /// hello that waited longer than that was dropped when its turn came.
    /// Sound moving to the same device is kept quiet and macOS's own card is
    /// moved out of sight, so nothing told the arrival at all.
    @Test("A hello's card lives longer than a peek may wait for the stage")
    func helloOutlivesTheWait() async {
        let result = await heard(grace: 0.15, until: { $0.goodbyes > 0 }) { source in
            source.onConnect?(self.device(["Battery": 0.5], isApple: false))
            source.onDisconnect?(self.address)
        }
        #expect(result.helloLives == [BluetoothProvider.helloLifetime])
        #expect(BluetoothProvider.helloLifetime > PendingPeek.longestWait)
        #expect(result.goodbyeLives == [BluetoothProvider.lifetime], "a goodbye is as short as it was")
    }

    /// Connected before Ledge started, so it never said hello here. Its
    /// goodbye is still news.
    @Test("A device that was already connected at launch still says goodbye")
    func seededDeviceSaysGoodbye() async {
        let source = HandBluetooth()
        source.listed = [device(["Battery": 0.5], isApple: false)]
        let result = await heard(source: source, grace: 0.15, until: { $0.goodbyes > 0 }) { source in
            source.onDisconnect?(self.address)
        }
        #expect(result.hellos.isEmpty, "it was there all along")
        #expect(result.goodbyes == 1)
    }
}
