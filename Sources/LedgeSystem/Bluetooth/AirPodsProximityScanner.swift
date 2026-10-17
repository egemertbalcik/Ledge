import CoreBluetooth
import Foundation
import LedgeCore
import os

/// Something that reports AirPods proximity advertisements.
///
/// A seam, so a test can drive the provider above it with advertisements of
/// its own and never build a `CBCentralManager`. The tests for the card used
/// the real scanner and relied on the test machine having no Bluetooth grant
/// to stay inert — which is not a property of the test, it is a property of
/// whoever happens to run it.
@MainActor
public protocol ProximityScanning: AnyObject {

    /// Fires for each decoded advertisement, with its strength on it.
    var onUpdate: (AirPodsProximity) -> Void { get set }

    /// Whether an advertisement is one of the user's own. Used for one
    /// thing: whether a reading may hold the radio open.
    var isOurs: (AirPodsProximity) -> Bool { get set }

    func start()
    func stop()
}

/// Scans BLE advertisements for AirPods proximity messages and reports the
/// decoded battery + lid state.
///
/// This is the one path that sees the case being opened while the AirPods are
/// already connected — the ordinary IOBluetooth connect/disconnect notifications
/// never fire for that. The cost is a real Bluetooth permission (a
/// `CBCentralManager` prompts on first use), which is why it is opt-in behind its
/// own provider rather than always-on.
@MainActor
public final class AirPodsProximityScanner: NSObject, ProximityScanning, CBCentralManagerDelegate {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "airpods")

    /// Fires for each decoded advertisement, with its strength on it.
    ///
    /// Every valid reading, not only the near ones: how far away a set of
    /// AirPods is has nothing to do with whether its battery figures are
    /// true, and the catalogue wants the figures. Whether a *card* appears is
    /// a separate decision, made where cards are made.
    public var onUpdate: (AirPodsProximity) -> Void = { _ in }

    /// Whether an advertisement is one of the user's own.
    ///
    /// Supplied by the owner of the paired list, because this object has no
    /// business knowing how ownership is decided. It is used for one thing:
    /// whether a reading may hold the radio open. A stranger's earbuds
    /// changing state at the next table used to extend Ledge's listening
    /// window — the most expensive scan mode CoreBluetooth has — for readings
    /// that were then refused downstream.
    public var isOurs: (AirPodsProximity) -> Bool = { _ in true }

    /// Weaker than this and the reading is noise rather than a device: a
    /// sanity floor, not a distance policy.
    ///
    /// This used to be −55, and it was the only gate: a set of AirPods on the
    /// far side of the room reported nothing at all, so its battery history
    /// simply stopped. −55 is now where *cards* begin, which is the decision
    /// that actually depends on being close.
    private let minimumRSSI: Int

    /// How close something has to be before it may hold the listening window
    /// open. Holding the radio open is for a device in hand and changing.
    private let attentiveRSSI: Int

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
    static let attentiveHold: TimeInterval = ProximityScanWindow.hold

    /// Holds the attentive window open by *change* rather than by traffic, and
    /// caps how long it may stay open at all.
    private var window = ProximityScanWindow()
    /// The last reading seen from each device, so a repeat can be told from
    /// news. AirPods re-advertise the same state many times a second.
    ///
    /// Bounded, because BLE private addresses rotate every quarter of an hour
    /// or so: each rotation mints a key that will never be seen again, and
    /// without a cap the table grew for the whole life of the app. Dropping it
    /// wholesale costs one repeat being read as news per device.
    private var lastSeen: [UUID: AirPodsProximity] = [:]

    /// How many devices' last readings are kept. Generous for a desk, a cafe
    /// or a train carriage; the cost of being wrong is one extra window.
    private static let lastSeenLimit = 32

    private var windowTimer: DispatchSourceTimer?
    private var windowEnd: DispatchWorkItem?
    private var isScanning = false
    /// Whether the open window is delivering every repeat, or just the first
    /// packet from each device.
    private var isAttentive = false

    public init(minimumRSSI: Int = -90, attentiveRSSI: Int = -55) {
        self.minimumRSSI = minimumRSSI
        self.attentiveRSSI = attentiveRSSI
        super.init()
    }

    /// Whether an advertisement is worth holding the radio open for.
    ///
    /// Three things at once, and all three matter: it has to be saying
    /// something new, it has to be the user's, and it has to be close. Any one
    /// of them alone kept the attentive window open for traffic nobody was
    /// waiting on.
    nonisolated static func holdsTheWindow(changed: Bool, isOurs: Bool, rssi: Int, closeEnough: Int) -> Bool {
        changed && isOurs && rssi >= closeEnough
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
        // Forget the attentive run, or a scanner started again would
        // inherit the previous window and its spent ceiling.
        window.closed()
        windowTimer?.cancel()
        windowTimer = nil
        windowEnd?.cancel()
        windowEnd = nil
        isScanning = false
        isAttentive = false
        // Nothing here is worth carrying into the next run: a scanner started
        // again has no idea how long it was off, and a stale reading would
        // make the first real advertisement look like a repeat.
        lastSeen.removeAll()
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
                guard let self else { return }
                self.window.closed()
                guard self.isScanning else { return }
                self.central?.stopScan()
                self.isScanning = false
                self.isAttentive = false
            }
        }
        windowEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: end)
    }

    /// Ends the current window now.
    private func closeWindow() {
        windowEnd?.cancel()
        windowEnd = nil
        window.closed()
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        isAttentive = false
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
        let strength = RSSI.intValue
        guard strength != 127, strength >= minimumRSSI,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              var proximity = AirPodsProximityDecoder.decode(manufacturerData: data)
        else { return }
        // Read before the actor hop: the peripheral is not Sendable, its
        // identifier is.
        proximity.peripheralID = peripheral.identifier
        proximity.rssi = strength

        MainActor.assumeIsolated {
            // Something of ours is right here. Whether that is worth holding
            // the radio open depends on whether it is *saying* anything new:
            // extending on every advertisement meant the window never closed
            // while AirPods were in range, which is most of the time.
            let id = proximity.peripheralID
            let changed = id.map { lastSeen[$0] != proximity } ?? true
            if let id {
                if lastSeen.count >= Self.lastSeenLimit, lastSeen[id] == nil {
                    lastSeen.removeAll()
                }
                lastSeen[id] = proximity
            }

            let holds = Self.holdsTheWindow(
                changed: changed,
                isOurs: isOurs(proximity),
                rssi: strength,
                closeEnough: attentiveRSSI
            )
            switch window.advertisement(changed: holds, now: Date().timeIntervalSinceReferenceDate) {
            case .hold:
                openWindow(for: Self.attentiveHold, attentive: true)
            case .leave:
                break
            case .release:
                // Long enough. Back to the duty cycle, which will look again
                // shortly; a fault that changes forever must not own the radio.
                closeWindow()
            }

            onUpdate(proximity)
        }
    }
}
