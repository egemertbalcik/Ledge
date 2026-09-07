import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

@MainActor
private final class FakeRadio: RadioPowerWatching {
    private var onChange: (@MainActor (Bool) -> Void)?
    private(set) var isWatching = false

    func startWatching(_ onChange: @escaping @MainActor (_ isOn: Bool) -> Void) {
        self.onChange = onChange
        isWatching = true
    }

    func stopWatching() {
        onChange = nil
        isWatching = false
    }

    func flip(_ isOn: Bool) { onChange?(isOn) }
}

@Suite("Bluetooth being switched on or off")
@MainActor
struct BluetoothPowerProviderTests {

    private func run(_ body: (FakeRadio) -> Void) async -> [Activity] {
        let fake = FakeRadio()
        let provider = BluetoothPowerProvider(source: fake, now: { 1_000 })
        let stream = provider.start()
        body(fake)
        provider.stop()
        var published: [Activity] = []
        for await event in stream {
            if case .publish(let activity) = event { published.append(activity) }
        }
        return published
    }

    /// Devices disconnect silently when it goes, and the first symptom is a
    /// keyboard that has stopped typing.
    @Test("Switching it off says so, and the card retires on its own")
    func bluetoothOff() async {
        let published = await run { $0.flip(false) }
        #expect(published.count == 1)
        #expect(published.first?.expiresAfter == BluetoothPowerProvider.lifetime)
        guard case .device(let payload)? = published.first?.payload else {
            Issue.record("expected a device card")
            return
        }
        #expect(payload.name == "Bluetooth")
        #expect(payload.statusText == "Off")
        // SF Symbols ships no Bluetooth glyph — the mark is a trademark — so
        // the app draws the rune and names it something no symbol answers to.
        // One rune, whichever way the switch went: the far ear carries the
        // state, so the glyph does not have to.
        #expect(payload.symbolName == LedgeSymbol.bluetooth)
        #expect(LedgeSymbol.isCustom(payload.symbolName))
    }

    @Test("Switching it back on says that too")
    func bluetoothOn() async {
        let published = await run { $0.flip(true) }
        guard case .device(let payload)? = published.first?.payload else {
            Issue.record("expected a device card")
            return
        }
        #expect(payload.statusText == "On")
        #expect(payload.symbolName == LedgeSymbol.bluetooth, "one rune, whichever way it went")
    }

    /// It shares the device kind with the connection cards and the route
    /// change, so it needs its own source or one would replace another.
    @Test("It owns its own activity")
    func ownsItsActivity() {
        #expect(BluetoothPowerProvider.activityID.source == "radio.bluetooth")
        #expect(BluetoothPowerProvider.activityID != AudioRouteProvider.activityID)
    }

    @Test("Stopping the provider stops the watching")
    func stopReleases() async {
        let fake = FakeRadio()
        let provider = BluetoothPowerProvider(source: fake)
        _ = provider.start()
        provider.stop()
        #expect(fake.isWatching == false)
    }
}
