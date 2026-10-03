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
    public static func fromBluetooth(
        _ device: BluetoothDeviceSnapshot,
        at observedAt: Date
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
            isApple: device.isApple
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
            symbolName: symbolName, isApple: isApple
        )
    }

    /// An AirPods proximity advertisement.
    ///
    /// These *do* carry charging evidence per component, which is why AirPods
    /// can support charged alerts and a plain Bluetooth accessory cannot.
    public static func fromProximity(
        _ proximity: AirPodsProximity,
        name: String,
        at observedAt: Date
    ) -> DeviceObservation? {
        guard let peripheralID = proximity.peripheralID else { return nil }

        var readings: [BatteryReading] = []
        func add(_ component: BatteryComponent, _ level: Double?, _ charging: Bool) {
            guard let level else { return }
            readings.append(BatteryReading(
                component: component,
                level: level,
                // The advertisement states this per component, so it is
                // evidence rather than a guess.
                charging: charging ? .charging : .notCharging,
                observedAt: observedAt
            ))
        }
        add(.left, proximity.leftBattery, proximity.isChargingLeft)
        add(.right, proximity.rightBattery, proximity.isChargingRight)
        add(.case, proximity.caseBattery, proximity.isChargingCase)

        guard !readings.isEmpty else { return nil }

        return DeviceObservation(
            deviceID: .peripheral(peripheralID),
            name: name,
            readings: readings,
            // An advertisement means "in range", not "connected to this Mac"
            // — and its absence later will mean nothing at all. Anything
            // firmer than `unknown` here would be invented.
            presence: .unknown,
            observedAt: observedAt,
            symbolName: proximity.symbolName,
            isApple: true,
            // The model identifier does not change, so a renamed device keeps
            // its record and its history.
            canonicalHint: "airpods-model-\(proximity.model)"
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
