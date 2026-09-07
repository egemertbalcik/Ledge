import CoreBluetooth
import Foundation
import LedgeCore
import os

/// Watches whether a radio is switched on.
@MainActor
public protocol RadioPowerWatching: AnyObject {
    /// Reports the new state on a change. Never fired for the state the radio
    /// was already in when watching began — that is not news.
    func startWatching(_ onChange: @escaping @MainActor (_ isOn: Bool) -> Void)
    func stopWatching()
}

/// Bluetooth's power switch.
///
/// Read through `CBCentralManager`, which is the only public way to see it —
/// and the reason this provider is gated on the Bluetooth permission the app
/// already asks for. No scanning is started here: the manager is created,
/// asked what state it is in, and left alone.
@MainActor
public final class BluetoothPowerSource: NSObject, RadioPowerWatching, CBCentralManagerDelegate {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "radio")

    private var central: CBCentralManager?
    private var onChange: (@MainActor (Bool) -> Void)?
    /// Nil until the first state arrives: the manager reports its state once
    /// on creation, and that first report is the status quo rather than news.
    private var isOn: Bool?

    public override init() { super.init() }

    public func startWatching(_ onChange: @escaping @MainActor (_ isOn: Bool) -> Void) {
        stopWatching()
        guard CBManager.authorization == .allowedAlways else {
            Self.log.notice("Bluetooth not granted — the switch cannot be watched")
            return
        }
        self.onChange = onChange
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func stopWatching() {
        central = nil
        onChange = nil
        isOn = nil
    }

    public nonisolated func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        let poweredOn = manager.state == .poweredOn
        // `.unknown` and `.resetting` are the manager settling, not the user
        // reaching for a switch.
        let settled = manager.state == .poweredOn || manager.state == .poweredOff
        MainActor.assumeIsolated {
            guard settled else { return }
            defer { isOn = poweredOn }
            guard let was = isOn, was != poweredOn else { return }
            onChange?(poweredOn)
        }
    }
}
