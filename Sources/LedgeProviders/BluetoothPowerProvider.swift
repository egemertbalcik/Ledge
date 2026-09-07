import Foundation
import LedgeCore
import LedgeSystem

/// Announces Bluetooth being switched on or off.
///
/// Flipping it changes what the Mac can do, and the only acknowledgement is a
/// menu-bar icon changing shape in the corner of the eye. Devices disconnect
/// silently, and the first symptom is a keyboard that has stopped typing — a
/// glance in the notch turns a mystery into a fact.
///
/// Deliberately the *switch* rather than connectivity, and deliberately only
/// changes: whatever the radio was doing when Ledge started is the status quo,
/// and the notch is not a status bar.
///
/// Wi-Fi had the same treatment and has been taken out again. CoreWLAN posts
/// its power event and updates the interface in that order, with a gap that is
/// not ours to control, and the resulting card was unreliable enough that a
/// switch nobody could trust was worse than no switch at all.
@MainActor
public final class BluetoothPowerProvider: ActivityProvider {

    public let identifier = "bluetooth-power"

    /// The same beat as the other one-glance indicators.
    static let lifetime: TimeInterval = 2.0

    public static let activityID = ActivityID(kind: .device, source: "radio.bluetooth")

    private let source: any RadioPowerWatching
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    public init(
        source: any RadioPowerWatching = BluetoothPowerSource(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            self.source.startWatching { [weak self] isOn in
                self?.announce(isOn)
            }
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
    }

    private func announce(_ isOn: Bool) {
        continuation?.yield(.publish(Activity(
            id: Self.activityID,
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: "Bluetooth",
                // Drawn by the app: SF Symbols ships no Bluetooth glyph, and
                // there is only one of it — the far ear carries the state.
                symbolName: LedgeSymbol.bluetooth,
                // Nothing to charge: this is a switch, not a device.
                batteryLevels: [:],
                isConnected: isOn,
                isApple: true,
                // The glyph names the radio, the far ear says which way the
                // switch went. Neither ear has to carry both.
                statusText: isOn ? "On" : "Off",
                statusStyle: .badge
            ))
        )))
    }
}
