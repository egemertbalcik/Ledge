import Testing

@testable import LedgeSystem

@Suite("Bluetooth authorization fallback")
@MainActor
struct BluetoothAuthorizationTests {
    @Test("Without a grant, availability and device reads use no native Bluetooth operations")
    func fallbackAvoidsNativeAccess() async {
        let probe = BluetoothAccessProbe()
        let source = probe.makeSource()

        #expect(source.isAvailable)
        source.startWatching(onConnect: { _ in }, onDisconnect: { _ in })
        let devices = await source.connectedDevices()
        source.stopWatching()

        #expect(devices == [probe.headphones])
        #expect(probe.profileReads == 1)
        #expect(probe.controllerReads == 0)
        #expect(probe.pairedReads == 0)
        #expect(probe.registrations == 0)
    }

    @Test("A later grant enables native reads and watching, and revocation restores fallback")
    func permissionTransitions() async {
        let probe = BluetoothAccessProbe()
        let source = probe.makeSource()
        source.startWatching(onConnect: { _ in }, onDisconnect: { _ in })
        #expect(probe.registrations == 0)

        probe.authorized = true
        #expect(source.isAvailable)
        source.startWatching(onConnect: { _ in }, onDisconnect: { _ in })
        #expect(await source.connectedDevices() == [probe.headphones])
        #expect(probe.controllerReads == 1)
        #expect(probe.pairedReads == 2)
        #expect(probe.registrations == 1)

        probe.authorized = false
        #expect(source.isAvailable)
        source.startWatching(onConnect: { _ in }, onDisconnect: { _ in })
        #expect(await source.connectedDevices() == [probe.headphones])
        source.stopWatching()
        #expect(probe.controllerReads == 1)
        #expect(probe.pairedReads == 2)
        #expect(probe.registrations == 1)
        #expect(probe.profileReads == 2)
    }

    @Test("Revocation during profiler enrichment prevents the subsequent native read")
    func rechecksAfterProfilerRead() async {
        let probe = BluetoothAccessProbe()
        probe.authorized = true
        probe.revokeDuringProfile = true
        let source = probe.makeSource()

        #expect(await source.connectedDevices() == [probe.headphones])
        #expect(probe.profileReads == 1)
        #expect(!probe.authorized)
        #expect(probe.pairedReads == 0)
    }
}

@MainActor
private final class BluetoothAccessProbe {
    var authorized = false
    var revokeDuringProfile = false
    var controllerReads = 0
    var pairedReads = 0
    var registrations = 0
    var profileReads = 0

    let headphones = BluetoothDeviceSnapshot(
        name: "Test headphones", address: "AA:BB:CC:11:22:33",
        batteryLevels: ["Battery": 0.15]
    )

    func makeSource() -> IOBluetoothDeviceSource {
        IOBluetoothDeviceSource(
            mayAccessNative: { self.authorized },
            controllerAddress: {
                self.controllerReads += 1
                return "AA:BB:CC:00:00:00"
            },
            readPairedDevices: {
                self.pairedReads += 1
                return []
            },
            registerConnect: { _ in
                self.registrations += 1
                return nil
            },
            profileDevices: {
                self.profileReads += 1
                if self.revokeDuringProfile { self.authorized = false }
                let disconnected = BluetoothDeviceSnapshot(
                    name: "Disconnected speaker", address: "DD:EE:FF:11:22:33",
                    isConnected: false
                )
                return [
                    self.headphones.address: self.headphones,
                    disconnected.address: disconnected,
                ]
            }
        )
    }
}
