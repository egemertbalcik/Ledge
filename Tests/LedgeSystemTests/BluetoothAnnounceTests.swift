import Testing

@testable import LedgeSystem

/// The announce filter, pinned against the exact devices that leaked: every
/// Continuity device on the author's desk reports a Bluetooth class of 0, and
/// so does an LE keyboard — the name has to carry the decision.
@Suite("Bluetooth announceworthiness")
struct BluetoothAnnounceTests {

    @Test("Continuity devices are never announced, class 0 or not")
    func continuityFiltered() {
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Ege iPhone"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Ege Apple Watch"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Ege iPad"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Ege's MacBook Pro"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(
            name: "Mystery", minorType: "Smartphone"
        ))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(
            name: "Mystery", minorType: "Watch"
        ))
    }

    @Test("Audio gear, input devices and the unclassified rest still announce")
    func gearAnnounced() {
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(name: "Ege AirPods"))
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(name: "NuPhy Air60 V2-1"))
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(name: "DUALSHOCK 4 Wireless Controller"))
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(
            name: "27\" Smart Monitor M5", minorType: "Display"
        ))
    }
}

/// Non-Apple Continuity noise: LE-linked Android phones and smartwatches also
/// report class 0, so the name patterns carry the decision — and they must
/// spare audio gear that shares the brand word.
@Suite("Bluetooth announceworthiness, non-Apple")
struct BluetoothNonAppleAnnounceTests {

    @Test("Android phones and smartwatches stay quiet")
    func nonAppleContinuityFiltered() {
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Galaxy Watch4"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Galaxy S24 Ultra"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Pixel 9 Pro"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Xperia 5 IV"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Watch GT 3"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "Redmi Note 12"))
        #expect(!IOBluetoothDeviceSource.isAnnounceworthy(name: "OnePlus 12"))
    }

    @Test("Same-brand earbuds still announce")
    func nonAppleGearAnnounced() {
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(name: "Galaxy Buds2 Pro"))
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(name: "Pixel Buds Pro"))
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(name: "Galaxy Fit3"))
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(name: "Redmi Buds 4"))
        #expect(IOBluetoothDeviceSource.isAnnounceworthy(name: "OnePlus Buds Pro 2"))
    }
}
