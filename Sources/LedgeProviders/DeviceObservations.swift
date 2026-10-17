import Foundation
import LedgeCore
import LedgeSystem

/// Turns what the Bluetooth sources already saw into normalised observations.
///
/// Nothing here asks the hardware anything. Every function takes a snapshot a
/// provider was handed for its own reasons — a connect notification, the
/// existing ten-minute refresh, a proximity advertisement — and re-describes
/// it. Wiring the catalogue therefore costs no scan time and no extra query.
public enum DeviceObservations {

    /// A connected or refreshed Bluetooth device.
    ///
    /// `system_profiler` and IOBluetooth report a level and nothing else, so
    /// the charging state is `unknown` — and stays unknown rather than being
    /// guessed, which is what keeps charged alerts honestly unavailable for
    /// these devices.
    /// - Parameter cause: why this snapshot exists. A connect callback is the
    ///   only thing that may give a device attachment semantics; the startup
    ///   inventory and the periodic refresh establish a baseline quietly. See
    ///   `ObservationCause`.
    public static func fromBluetooth(
        _ device: BluetoothDeviceSnapshot,
        at observedAt: Date,
        cause: ObservationCause
    ) -> DeviceObservation {
        DeviceObservation(
            deviceID: .bluetooth(device.address),
            name: device.name,
            readings: device.batteryLevels.map { label, level in
                BatteryReading(
                    component: BatteryComponent(label: label),
                    level: level,
                    charging: .unknown,
                    observedAt: observedAt
                )
            },
            // A snapshot from the paired-device list states attachment.
            presence: device.isConnected ? .connected : .disconnected,
            observedAt: observedAt,
            symbolName: device.symbolName,
            isApple: device.isApple,
            cause: cause
        )
    }

    /// A device seen to detach. Carries no levels on purpose: the last known
    /// ones stay, and their age is what marks them.
    public static func disconnected(
        address: String,
        name: String,
        symbolName: String = "headphones",
        isApple: Bool = false,
        at observedAt: Date
    ) -> DeviceObservation {
        DeviceObservation(
            deviceID: .bluetooth(address), name: name, readings: [],
            presence: .disconnected, observedAt: observedAt,
            symbolName: symbolName, isApple: isApple,
            // A disconnect notification is a connection event like any other.
            cause: .connectionEvent
        )
    }

    /// Which paired device an advertisement belongs to, if any.
    ///
    /// The whole ownership question for proximity, in one testable place.
    /// Three ways to answer "nobody", and all three matter:
    ///
    /// - the paired list has not been read yet. Ownership cannot be
    ///   established by waiting, so an unanswered list is a reason to record
    ///   nothing — not a reason to record everything and sort it out later,
    ///   which is how seventeen strangers' earbuds got in;
    /// - the model id is not one Apple ships. Those records exist: `0xBA8F`
    ///   and friends are other Continuity traffic that decoded far enough to
    ///   look like a proximity message;
    /// - nothing paired claims the model, or more than one does.
    public static func owner(
        of proximity: AirPodsProximity,
        paired: PairedDeviceRegistry.Answer?
    ) -> PairedDevice? {
        guard let paired, AirPodsProximity.isKnownModel(proximity.model) else { return nil }
        return paired.airPodsOwner(ofModel: proximity.model)
    }

    /// An AirPods proximity advertisement, as readings for the paired device
    /// that broadcast it.
    ///
    /// These *do* carry charging evidence per component, which is why AirPods
    /// can support charged alerts and a plain Bluetooth accessory cannot. They
    /// are also the loudest thing on the air: every pair of earbuds in range
    /// broadcasts one several times a second, whoever owns them.
    ///
    /// This used to mint a catalogue record from each of them, keyed by model
    /// id, with no test of ownership anywhere — so carrying the Mac through a
    /// café catalogued strangers' AirPods for ever. An advertisement may now
    /// only *attach readings to* a device the Mac is already paired with; it
    /// creates nothing, and when it belongs to nobody it says nothing.
    ///
    /// Attaching to the paired record rather than keeping a parallel one also
    /// ends the duplicate pair the catalogue used to hold for the same
    /// earbuds. `DeviceIdentity.canonical` says there is no trustworthy
    /// identifier relating the two; there is one, and it is the model id — the
    /// advertisement carries it big-endian and `system_profiler` reports the
    /// same model as a byte-swapped product id. It identifies a *model*, so an
    /// ambiguous match is refused rather than guessed: see
    /// `PairedDeviceRegistry.Answer.airPodsOwner(ofModel:)`.
    public static func fromProximity(
        _ proximity: AirPodsProximity,
        paired: PairedDeviceRegistry.Answer?,
        at observedAt: Date
    ) -> DeviceObservation? {
        guard let owner = owner(of: proximity, paired: paired) else { return nil }

        var readings: [BatteryReading] = []
        func add(_ component: BatteryComponent, _ level: Double?, _ charging: Bool) {
            guard let level else { return }
            readings.append(BatteryReading(
                component: component,
                level: level,
                // The advertisement states this per component, so it is
                // evidence rather than a guess.
                charging: charging ? .charging : .notCharging,
                observedAt: observedAt,
                // Filed under the paired device's identity, which is re-read
                // every ten minutes and allowed thirty — but *this* reading
                // came off the air, where silence means something within
                // five.
                origin: .proximityName
            ))
        }
        add(.left, proximity.leftBattery, proximity.isChargingLeft)
        add(.right, proximity.rightBattery, proximity.isChargingRight)
        add(.case, proximity.caseBattery, proximity.isChargingCase)

        guard !readings.isEmpty else { return nil }

        return DeviceObservation(
            // The paired device's own identity. One record per pair of
            // earbuds, holding both what the paired list reports and what the
            // air carries.
            deviceID: owner.identity,
            // The name macOS knows it by, not the model's generic one. The
            // catalogue showed "AirPods 4 (ANC)" for earbuds the user had
            // named "Ege AirPods"; that drift came from here.
            name: owner.name,
            readings: readings,
            // An advertisement means "in range", not "connected to this Mac"
            // — and its absence later will mean nothing at all. Anything
            // firmer than `unknown` here would be invented.
            presence: .unknown,
            observedAt: observedAt,
            symbolName: proximity.symbolName,
            isApple: true,
            // No hint: the identity is already the stable one. The hint
            // existed to key a record by model id, which is exactly what must
            // not happen any more.
            canonicalHint: nil,
            // In range, which is not an attachment: a case opening nearby must
            // not alert as though the earbuds had just been put in.
            cause: .advertisement
        )
    }

    /// This Mac's own battery.
    public static func fromMac(
        name: String,
        level: Double,
        isCharging: Bool,
        at observedAt: Date
    ) -> DeviceObservation {
        DeviceObservation(
            deviceID: .thisMac,
            name: name,
            readings: [BatteryReading(
                component: .main,
                level: level,
                charging: isCharging ? .charging : .notCharging,
                observedAt: observedAt
            )],
            // This Mac is attached for as long as its provider is running.
            presence: .connected,
            observedAt: observedAt,
            symbolName: "laptopcomputer",
            isApple: true
        )
    }
}
