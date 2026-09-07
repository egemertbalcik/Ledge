import CoreBluetooth
import Foundation
import os

/// Scans BLE advertisements for AirPods proximity messages and reports the
/// decoded battery + lid state.
///
/// This is the one path that sees the case being opened while the AirPods are
/// already connected — the ordinary IOBluetooth connect/disconnect notifications
/// never fire for that. The cost is a real Bluetooth permission (a
/// `CBCentralManager` prompts on first use), which is why it is opt-in behind its
/// own provider rather than always-on.
@MainActor
public final class AirPodsProximityScanner: NSObject, CBCentralManagerDelegate {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "airpods")

    /// Fires for each decoded advertisement from a *nearby* set of AirPods.
    public var onUpdate: (AirPodsProximity) -> Void = { _ in }

    /// Only advertisements at least this strong are surfaced, so a colleague's
    /// AirPods across the room do not pop a card. The user's own, on the desk or
    /// in hand, sit well above this.
    private let minimumRSSI: Int

    private var central: CBCentralManager?

    /// How long each listening window lasts, and how long the radio rests
    /// between them.
    ///
    /// This used to scan continuously, unfiltered, with duplicates allowed —
    /// the most expensive mode CoreBluetooth has, running for as long as the
    /// app did. Every advertising packet from every device in range was
    /// decoded and thrown away, all day, to catch the few seconds when a case
    /// is opened.
    ///
    /// A case announces itself for around half a minute when the lid opens, so
    /// a short window every few seconds catches it with time to spare while
    /// leaving the radio alone for three quarters of the time.
    static let windowDuration: TimeInterval = 1.5
    static let windowPeriod: TimeInterval = 6

    /// How long a window is held open after something nearby is heard, so an
    /// interaction already under way is not chopped up by the duty cycle.
    static let attentiveHold: TimeInterval = 6

    private var windowTimer: DispatchSourceTimer?
    private var windowEnd: DispatchWorkItem?
    private var isScanning = false
    /// Whether the open window is delivering every repeat, or just the first
    /// packet from each device.
    private var isAttentive = false

    public init(minimumRSSI: Int = -55) {
        self.minimumRSSI = minimumRSSI
        super.init()
    }

    /// Whether Bluetooth is authorised, without prompting.
    public static var isAuthorized: Bool {
        CBManager.authorization == .allowedAlways
    }

    public func start() {
        guard central == nil else { return }
        // Creating the manager is what raises the system's Bluetooth prompt.
        // A provider that starts at launch must never do that on a fresh Mac
        // — the ask belongs to the user (Settings → Permissions → Allow…), so
        // until the grant exists the scan stays idle and the coordinator
        // restarts this provider once it lands.
        guard Self.isAuthorized else {
            Self.log.notice("Bluetooth not granted — proximity scan idle until allowed")
            return
        }
        // Delegate callbacks on the main queue keep the actor story simple.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func stop() {
        windowTimer?.cancel()
        windowTimer = nil
        windowEnd?.cancel()
        windowEnd = nil
        isScanning = false
        isAttentive = false
        central?.stopScan()
        central = nil
    }

    // MARK: - Duty cycle

    private func startDutyCycle() {
        windowTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Generous leeway: the exact instant a window opens does not matter,
        // and letting the kernel line these up with other work is the
        // difference between a wake-up of our own and riding along with one.
        timer.schedule(
            deadline: .now(),
            repeating: Self.windowPeriod,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // A listening window only has to hear each device once to know
                // whether a case is open, so repeats stay switched off until
                // there is something worth following.
                self?.openWindow(for: Self.windowDuration, attentive: false)
            }
        }
        timer.resume()
        windowTimer = timer
    }

    /// Listens for `duration`, then stops. Called again while a window is open,
    /// it extends it — and promotes it if the new call wants every repeat.
    ///
    /// - Parameter attentive: deliver every advertisement rather than the
    ///   first from each device. Costly, and only worth it while a set of
    ///   AirPods of ours is in range and changing: the battery figures and lid
    ///   state on screen come from those repeats.
    private func openWindow(for duration: TimeInterval, attentive: Bool) {
        guard let central, central.state == .poweredOn else { return }
        if !isScanning || (attentive && !isAttentive) {
            // Restarting is the only way to change the duplicate setting.
            if isScanning { central.stopScan() }
            // No service filter: Apple broadcasts proximity state in
            // manufacturer data alone, and CoreBluetooth cannot filter on that.
            central.scanForPeripherals(
                withServices: nil,
                options: attentive ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : nil
            )
            isScanning = true
            isAttentive = attentive
        }
        windowEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isScanning else { return }
                self.central?.stopScan()
                self.isScanning = false
                self.isAttentive = false
            }
        }
        windowEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: end)
    }

    // MARK: - CBCentralManagerDelegate (main queue)

    public nonisolated func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        // Read the state (a Sendable value) here; touch the manager only through
        // the main-actor-isolated `self.central`, so the non-Sendable object is
        // never sent across the actor boundary.
        let state = manager.state
        MainActor.assumeIsolated {
            switch state {
            case .poweredOn:
                self.startDutyCycle()
                Self.log.notice("AirPods proximity scan started (duty-cycled)")
            case .unauthorized:
                Self.log.notice("Bluetooth not authorised — proximity scan idle")
            default:
                break
            }
        }
    }

    public nonisolated func centralManager(
        _ manager: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // 127 is CoreBluetooth's "RSSI unavailable" sentinel, not a strong
        // signal — without this check it sails past the distance filter.
        guard RSSI.intValue != 127, RSSI.intValue >= minimumRSSI,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              var proximity = AirPodsProximityDecoder.decode(manufacturerData: data)
        else { return }
        // Read before the actor hop: the peripheral is not Sendable, its
        // identifier is.
        proximity.peripheralID = peripheral.identifier

        MainActor.assumeIsolated {
            // Something of ours is right here and talking: hold the window open
            // so the card's battery figures and lid state keep up.
            openWindow(for: Self.attentiveHold, attentive: true)
            onUpdate(proximity)
        }
    }
}
