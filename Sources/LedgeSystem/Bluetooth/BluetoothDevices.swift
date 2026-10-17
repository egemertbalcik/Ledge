import CoreBluetooth
import Foundation
import IOBluetooth
import LedgeCore
import os

/// One Bluetooth device, as much as can be learned about it without asking the
/// user for anything.
public struct BluetoothDeviceSnapshot: Equatable, Sendable {

    public var name: String

    /// Stable identity, normalised to upper-case colon-separated hex.
    ///
    /// The two sources disagree on format — IOBluetooth hands back
    /// `08-5d-53-a9-d9-3e`, `system_profiler` prints `08:5D:53:A9:D9:3E` — so
    /// nothing may key off a raw address string.
    public var address: String

    public var isConnected: Bool

    /// 0...1 per component, keyed "Case" / "Left" / "Right" / "Battery".
    /// Empty when the device reports nothing, which is normal and not an error.
    public var batteryLevels: [String: Double]

    /// SF Symbol guessed from the product name. Becomes `DevicePayload.symbolName`.
    public var symbolName: String

    /// Whether this is Apple's own hardware, which is the only gear that keeps
    /// the tinted icon.
    public var isApple: Bool

    /// Bluetooth SIG company id, as the profiler reports it. Carried because
    /// it is half of the only identifier that can relate a paired device to
    /// the advertisements it broadcasts — see `PairedDevice.advertisedModel`.
    public var vendorID: UInt16?
    /// Product id, same source and same reason. Absent for a device the
    /// profiler did not describe (an LE link read natively) and for classic
    /// devices macOS reports nothing about.
    public var productID: UInt16?

    public init(
        name: String,
        address: String,
        isConnected: Bool = true,
        batteryLevels: [String: Double] = [:],
        symbolName: String = "headphones",
        isApple: Bool = false,
        vendorID: UInt16? = nil,
        productID: UInt16? = nil
    ) {
        self.name = name
        self.address = address
        self.isConnected = isConnected
        self.batteryLevels = batteryLevels
        self.symbolName = symbolName
        self.isApple = isApple
        self.vendorID = vendorID
        self.productID = productID
    }

    /// The same device as the catalogue's ownership test sees it.
    public var pairedDevice: PairedDevice {
        PairedDevice(
            address: address,
            name: name,
            isConnected: isConnected,
            vendorID: vendorID,
            productID: productID,
            symbolName: symbolName,
            isApple: isApple
        )
    }
}

/// One reading of the paired list, and when it was taken.
///
/// The timestamp is not decoration. A reading is compared against connection
/// events to decide which is the newer evidence, and `system_profiler` takes
/// a second or more to answer — one whose answer is shared or briefly reused
/// describes the world at the moment it ran, not at the moment it was handed
/// over.
public struct PairedListReading: Sendable {
    public var devices: [BluetoothDeviceSnapshot]
    public var readAt: Date

    public init(devices: [BluetoothDeviceSnapshot], readAt: Date) {
        self.devices = devices
        self.readAt = readAt
    }
}

/// A place connected-device information can come from.
///
/// Watching is push-only by design. Every implementation must be able to sit
/// idle indefinitely and cost nothing — see `IOBluetoothDeviceSource` for why
/// the obvious polling shape is not on the table.
@MainActor
public protocol BluetoothDeviceSource: AnyObject {

    /// Whether this source can supply devices, including a permission-free fallback.
    var isAvailable: Bool { get }

    /// Every device the Mac is paired with, connected or not.
    ///
    /// The catalogue's ownership test. Separate from `connectedDevices()`
    /// because "not connected" is exactly the information ownership needs:
    /// a paired device that is switched off is still the user's, and a
    /// connected one that is *missing* from this list is a passer-by.
    ///
    /// Nil when the Mac could not be asked — not an empty list. The two used
    /// to be the same value, and the difference is the user's data: an empty
    /// list is an answer, and the catalogue prunes every record against it.
    /// A `system_profiler` that timed out therefore read as "this Mac is
    /// paired with nothing", and one slow process could delete every device
    /// and its battery history.
    func pairedDevices() async -> PairedListReading?

    func connectedDevices() async -> [BluetoothDeviceSnapshot]

    func startWatching(
        onConnect: @escaping (BluetoothDeviceSnapshot) -> Void,
        onDisconnect: @escaping (String) -> Void
    )

    func stopWatching()
}

extension BluetoothDeviceSource {
    /// The connected subset, for the sources that only ever had one list.
    ///
    /// A read that failed reports nothing connected, which is what this
    /// caller can do with it: cards are drawn from what was seen, and an
    /// unread list has seen nothing. Pruning is the caller that must know the
    /// difference, and it asks `pairedDevices()` itself.
    public func connectedDevices() async -> [BluetoothDeviceSnapshot] {
        await pairedDevices()?.devices.filter(\.isConnected) ?? []
    }
}

/// Connected devices and their battery levels without requesting permission.
///
/// Native controller reads, paired-device reads and notification registrations
/// require an existing Bluetooth grant. The static CoreBluetooth authorization
/// check never constructs a manager or starts a scan.
///
/// `system_profiler SPBluetoothDataType -json` remains available without that
/// grant and supplies connection state and per-component battery levels. Native
/// reads add LE links it can omit; native notifications provide immediate
/// connect/disconnect events only while authorized. The profiler fallback still
/// supports explicit reads and the provider's infrequent low-battery checks.
@MainActor
public final class IOBluetoothDeviceSource: NSObject, BluetoothDeviceSource {

    // Nonisolated: read from closures running on a background queue.
    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "bluetooth")

    /// How long `system_profiler` may take before it is killed.
    ///
    /// Measured at ~150ms on healthy hardware. The deadline exists for the
    /// unhealthy case: `system_profiler` talks to `bluetoothd`, and a wedged
    /// daemon would otherwise park the connect handler forever.
    private nonisolated static let queryTimeout: TimeInterval = 4

    /// Class-wide registration: fires for every device, including ones paired
    /// after we started.
    private var connectRegistration: IOBluetoothUserNotification?

    /// Disconnect is per-device and must be armed while the device is connected,
    /// keyed by normalised address.
    private var disconnectRegistrations: [String: IOBluetoothUserNotification] = [:]

    private var onConnect: ((BluetoothDeviceSnapshot) -> Void)?
    private var onDisconnect: ((String) -> Void)?

    private let mayAccessNative: () -> Bool
    private let controllerAddress: () -> String?
    private let readPairedDevices: () -> [IOBluetoothDevice]?
    private let registerConnect: (IOBluetoothDeviceSource) -> IOBluetoothUserNotification?
    private let profileDevices: () async -> (devices: [String: BluetoothDeviceSnapshot]?, sampledAt: TimeInterval)

    public override convenience init() {
        self.init(
            mayAccessNative: { CBCentralManager.authorization == .allowedAlways },
            controllerAddress: { IOBluetoothHostController.default()?.addressAsString() },
            // Nil means the stack would not answer — the daemon is not up,
            // or access has gone away — which is not the same as a Mac with
            // nothing paired. Only an actual list is a reading.
            readPairedDevices: {
                guard let devices = IOBluetoothDevice.pairedDevices() else { return nil }
                return devices.compactMap { $0 as? IOBluetoothDevice }
            },
            registerConnect: { source in
                IOBluetoothDevice.register(
                    forConnectNotifications: source,
                    selector: #selector(IOBluetoothDeviceSource.deviceConnected(_:device:))
                )
            },
            profileDevices: Self.profiledDevices
        )
    }

    /// Inject the system boundaries so the no-permission path can be tested
    /// without touching the Bluetooth stack or spawning a process.
    init(
        mayAccessNative: @escaping () -> Bool,
        controllerAddress: @escaping () -> String?,
        readPairedDevices: @escaping () -> [IOBluetoothDevice]?,
        registerConnect: @escaping (IOBluetoothDeviceSource) -> IOBluetoothUserNotification?,
        profileDevices: @escaping () async -> (devices: [String: BluetoothDeviceSnapshot]?, sampledAt: TimeInterval)
    ) {
        self.mayAccessNative = mayAccessNative
        self.controllerAddress = controllerAddress
        self.readPairedDevices = readPairedDevices
        self.registerConnect = registerConnect
        self.profileDevices = profileDevices
        super.init()
    }

    public var isAvailable: Bool {
        // Without authorization the profiler fallback is still usable. Do not
        // inspect the native controller just to compute a settings label.
        guard mayAccessNative() else { return true }
        guard let address = controllerAddress() else { return false }
        return address.contains { $0.isHexDigit && $0 != "0" }
    }

    // MARK: - Reading

    /// The whole paired list, each entry saying whether it is connected.
    ///
    /// `system_profiler SPBluetoothDataType` enumerates what macOS is paired
    /// with, which is precisely the question ownership asks — and it answers
    /// it without any Bluetooth grant, so the catalogue can tell the user's
    /// hardware from a stranger's even when Ledge has been refused access to
    /// the radio.
    public func pairedDevices() async -> PairedListReading? {
        // `system_profiler` leads because it needs no grant and is the only
        // source of battery levels.
        let (profiled, sampledAt) = await profileDevices()

        // Recheck after the asynchronous profiler read: permission may have
        // changed while the process was running.
        // Permission is not an answer: the stack can be reachable and still
        // decline to say anything.
        let identities = mayAccessNative() ? pairedIdentities() : nil
        // Nothing answered. Returning an empty list here would be a claim
        // that the Mac is paired with nothing, which is the one claim that
        // deletes records.
        guard profiled != nil || identities != nil else { return nil }

        var byAddress = profiled ?? [:]
        for identity in identities ?? []
        where byAddress[identity.address] == nil
            && Self.isAnnounceworthy(name: identity.name, classMajor: identity.classMajor) {
            byAddress[identity.address] = Self.snapshot(
                for: identity,
                profiled: profiled?[identity.address]
            )
        }

        // Sorted, because a dictionary's order is not stable between calls and
        // the cards would shuffle.
        //
        // Stamped with the *oldest* part of the answer: the profiler's own
        // sample, when there was one. Claiming the moment this returned would
        // make a reading that began before a connect look newer than it.
        let readAt = profiled == nil
            ? Date()
            : Date(timeIntervalSinceReferenceDate: sampledAt)
        return PairedListReading(
            devices: byAddress.values.sorted { $0.name < $1.name },
            readAt: readAt
        )
    }

    /// Name, address, class and connection state of a device, carried across
    /// the actor hop because `IOBluetoothDevice` is a non-Sendable ObjC class
    /// and must not travel.
    private struct Identity: Sendable {
        let name: String
        let address: String
        let classMajor: BluetoothDeviceClassMajor
        let isConnected: Bool
    }

    /// Every paired device the native list knows, connected or not. The
    /// disconnected ones matter: they are the user's hardware too, and a
    /// catalogue that only ever hears about connected devices cannot tell
    /// "switched off in a drawer" from "someone else's".
    ///
    /// Nil when the stack would not answer at all.
    private func pairedIdentities() -> [Identity]? {
        readPairedDevices().map { $0.compactMap(Self.identity) }
    }

    /// Whether a device's connection is worth announcing at all.
    ///
    /// Phones, watches, tablets and other Macs connect over Bluetooth
    /// constantly for Continuity — unlock, Handoff, hotspot — and none of
    /// those moments is the user putting a device on. Announcing "iPhone
    /// connected" several times a day is noise wearing a headphone icon.
    ///
    /// Class alone cannot decide this: every LE-only link — which is how a
    /// modern iPhone or Watch shows up — reports a class of 0, the same as an
    /// LE keyboard (the comment on `symbolName` has said so all along; the
    /// first version of this filter tested class anyway and filtered
    /// nothing). So the name and, when a profile exists, the reported minor
    /// type carry the decision, with the classic class kept as a bonus for
    /// old-style pairings.
    nonisolated static func isAnnounceworthy(
        name: String,
        classMajor: BluetoothDeviceClassMajor = 0,
        minorType: String? = nil
    ) -> Bool {
        if classMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone)
            || classMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorComputer)
            || classMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorWearable) {
            return false
        }
        if let minor = minorType?.lowercased(), !isAudioType(minor) {
            for needle in ["phone", "watch", "computer", "laptop", "desktop", "tablet", "ipad"]
            where minor.contains(needle) { return false }
        }
        let lowered = name.lowercased()
        for needle in [
            "iphone", "ipad", "apple watch", "watch series", "watch ultra",
            "macbook", "imac", "mac mini", "mac studio", "mac pro",
        ] where lowered.contains(needle) { return false }

        // Non-Apple phones and watches tether and drop links just as
        // restlessly, and an LE link gives no class to test. Patterns rather
        // than substrings so audio gear survives: "Galaxy Buds" and
        // "Pixel Buds" must pass while "Galaxy S24", "Pixel 9" and
        // "Galaxy Watch4" do not.
        for pattern in [
            #"(^|\s)watch(\s|\d|$)"#,           // any brand's smartwatch
            #"(^|\s)galaxy\s(?!buds|fit)"#,     // Samsung phones/tablets; earbuds and bands stay
            #"(^|\s)pixel\s(?!buds)"#,          // Pixel phones/tablets; earbuds stay
            // Same earbud exception as above: "Redmi Buds 4" and
            // "OnePlus Buds Pro 2" are audio gear, not phones.
            #"(^|\s)(xperia|redmi|oneplus|poco|iqoo)(\s(?!buds|pods|earbuds)|\d|$)"#,
        ] where lowered.range(of: pattern, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    /// Whether a reported minor type is audio gear.
    ///
    /// Checked *before* the Continuity filter below, because "Headphones"
    /// contains "phone". It did not, and the substring test therefore threw
    /// away every pair of headphones `system_profiler` reported — which is
    /// how a Mac paired with two sets of AirPods ended up with neither in its
    /// catalogue, and with their battery levels unreachable: the profiler is
    /// the only source of those.
    nonisolated static func isAudioType(_ minorType: String) -> Bool {
        let text = minorType.lowercased()
        return ["headphone", "headset", "earphone", "earbud", "speaker", "hands-free", "audio"]
            .contains { text.contains($0) }
    }

    private static func identity(of device: IOBluetoothDevice) -> Identity? {
        guard let address = address(of: device) else { return nil }
        // `nameOrAddress` rather than `name`: an LE device that has not been
        // interrogated yet has no name, and a blank card is worse than a MAC.
        let name = device.name ?? device.nameOrAddress ?? address
        return Identity(
            name: name, address: address,
            classMajor: device.deviceClassMajor,
            isConnected: device.isConnected()
        )
    }

    private static func address(of device: IOBluetoothDevice) -> String? {
        guard let raw = device.addressString, !raw.isEmpty else { return nil }
        return normalizeAddress(raw)
    }

    private static func snapshot(
        for identity: Identity,
        profiled: BluetoothDeviceSnapshot?
    ) -> BluetoothDeviceSnapshot {
        BluetoothDeviceSnapshot(
            name: identity.name,
            address: identity.address,
            isConnected: identity.isConnected,
            // Absent battery data is expected — most devices have none, and
            // AirPods take a moment after connecting to report any.
            batteryLevels: profiled?.batteryLevels ?? [:],
            // Prefer the profiled symbol: it was chosen with the reported device
            // type in hand, which the name alone does not give us.
            symbolName: profiled?.symbolName ?? symbolName(productName: identity.name),
            isApple: isAppleDevice(productName: identity.name),
            // Only the profiler reports these; a native LE read has neither.
            vendorID: profiled?.vendorID,
            productID: profiled?.productID
        )
    }

    // MARK: - Watching

    public func startWatching(
        onConnect: @escaping (BluetoothDeviceSnapshot) -> Void,
        onDisconnect: @escaping (String) -> Void
    ) {
        stopWatching()
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect

        guard mayAccessNative() else { return }
        connectRegistration = registerConnect(self)

        // Devices already connected when watching starts never send a connect
        // notification, so their disconnect has to be armed by hand.
        for device in readPairedDevices() ?? [] where device.isConnected() {
            armDisconnect(for: device)
        }

        Self.log.debug("watching bluetooth, \(self.disconnectRegistrations.count) already connected")
    }

    public func stopWatching() {
        connectRegistration?.unregister()
        connectRegistration = nil

        // The disconnect notifications are one-shots that invalidate themselves
        // when they fire. A disconnect that fired on IOBluetooth's thread but
        // whose main-actor cleanup Task has not yet run is still in this dict —
        // calling `unregister()` on it would be a second release of something
        // IOBluetooth already dropped, the exact crash the disconnect handler is
        // written to avoid. And *dropping* the references is no better: a
        // stop/start cycle would then re-register the same still-connected
        // device, stacking one live registration per cycle and delivering the
        // eventual disconnect N times. So the dict is kept — `armDisconnect`
        // dedupes against it, a registration that fires while stopped finds
        // `onDisconnect` nil and is a no-op, and it removes itself from the
        // dict either way.
        onConnect = nil
        onDisconnect = nil
    }

    private func armDisconnect(for device: IOBluetoothDevice) {
        guard mayAccessNative(), let address = Self.address(of: device),
              disconnectRegistrations[address] == nil
        else { return }

        disconnectRegistrations[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
    }

    /// IOBluetooth delivers this on *its own* thread, not the main run loop —
    /// verified by a crash where the main-actor executor check trapped. So the
    /// callback is `nonisolated` and hops the entire body onto the main actor
    /// before touching any isolated state.
    ///
    /// The device object is captured across the hop with `nonisolated(unsafe)`:
    /// `IOBluetoothDevice` is imported as non-Sendable, but its accessors are
    /// thread-agnostic ObjC and safe to read from any thread.
    @objc private nonisolated func deviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        nonisolated(unsafe) let device = device
        nonisolated(unsafe) let notification = notification
        Task { @MainActor [weak self] in
            guard let self, self.mayAccessNative(),
                  self.connectRegistration === notification
            else { return }
            self.armDisconnect(for: device)
            guard let identity = Self.identity(of: device),
                  Self.isAnnounceworthy(
                      name: identity.name,
                      classMajor: device.deviceClassMajor
                  )
            else { return }

            // One emission, after enrichment, rather than a bare snapshot now
            // and a battery update a moment later: the second would re-render
            // the card and make the levels appear to pop in.
            let profiled = await self.profileDevices()
            // The enrichment can take seconds; a flap inside that window has
            // already delivered the disconnect. Announcing the connect now
            // would present a device that is gone — and its one-shot
            // disconnect registration has spent itself, so no goodbye would
            // ever correct the card.
            guard self.mayAccessNative(),
                  self.connectRegistration === notification,
                  device.isConnected()
            else { return }
            guard let handler = self.onConnect else { return }
            handler(Self.snapshot(for: identity, profiled: profiled.devices?[identity.address]))
        }
    }

    @objc private nonisolated func deviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        nonisolated(unsafe) let notification = notification
        Task { @MainActor [weak self] in
            // Resolve the address from our registration table rather than
            // reading the device after a possible permission revocation.
            guard let self, let address = self.disconnectRegistrations.first(where: {
                $0.value === notification
            })?.key else { return }
            // The registration is one-shot and has already invalidated itself;
            // only our reference to it needs clearing. Calling `unregister()`
            // here would be a second release of something IOBluetooth dropped.
            self.disconnectRegistrations.removeValue(forKey: address)
            guard self.mayAccessNative() else { return }
            self.onDisconnect?(address)
        }
    }

    // MARK: - system_profiler

    /// One at a time, shared between simultaneous callers. A wake reconnects
    /// every paired device at once, and each notification asks for this.
    /// Nil when the tool could not be run or its output could not be used —
    /// which is a different thing from a Mac with nothing paired.
    private nonisolated static let profilerGate = ProfilerGate<[String: BluetoothDeviceSnapshot]?> {
        guard let data = await runSystemProfiler(), let parsed = parse(data) else { return nil }
        return Dictionary(parsed.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private nonisolated static func profiledDevices()
        async -> (devices: [String: BluetoothDeviceSnapshot]?, sampledAt: TimeInterval)
    {
        let reading = await profilerGate.reading()
        return (reading.value, reading.sampledAt)
    }

    /// Runs `system_profiler` and returns its stdout, or nil on any failure.
    ///
    /// Failure is not exceptional: the tool can be slow, killed, or emit
    /// something we cannot use. The card renders without battery levels, so
    /// every path here degrades to nil rather than propagating.
    ///
    /// The lifetime belongs to `ChildProcess`: continuous pipe draining, a
    /// deadline, and SIGKILL after SIGTERM. This used to terminate once and
    /// then block in `readDataToEndOfFile`, so a copy stuck in IPC could
    /// outlive its timeout — and since the single-flight gate waits on this,
    /// one stuck child would have held every caller behind it.
    private nonisolated static func runSystemProfiler() async -> Data? {
        let outcome = await ChildProcess.run(
            executable: "/usr/sbin/system_profiler",
            // No `-detailLevel`: `mini` drops `device_address`, which is the
            // one field this cannot work without.
            arguments: ["SPBluetoothDataType", "-json"],
            timeout: queryTimeout
        )
        guard outcome.succeeded else {
            log.debug("system_profiler did not answer (status \(outcome.status, privacy: .public))")
            return nil
        }
        return outcome.standardOutput
    }


    /// Nil when the output could not be used at all.
    ///
    /// An empty array is an answer — a Mac with nothing paired — and the
    /// catalogue deletes records against it. Output that is not the shape
    /// this understands is not that answer, and returning one used to be
    /// enough to wipe every device and its battery history.
    public nonisolated static func parse(_ json: Data) -> [BluetoothDeviceSnapshot]? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [Any]
        else {
            log.debug("system_profiler output was not the expected shape")
            return nil
        }

        // nil means "the entry says so itself", which is the legacy layout.
        let groups: [(key: String, isConnected: Bool?)] = [
            ("device_connected", true),
            ("device_not_connected", false),
            ("device_title", nil),
        ]

        var snapshots: [BluetoothDeviceSnapshot] = []
        var seen: Set<String> = []
        /// Whether the output looked like something this understands at all.
        ///
        /// The root being right is not enough: sections full of nothing this
        /// recognises produced an empty list, which reads as "this Mac is
        /// paired with nothing" — the claim that deletes records. A Mac that
        /// really is paired with nothing still prints a controller section,
        /// so there is always something to recognise.
        var recognisable = false

        /// Whether anything in the output could not be read.
        ///
        /// Recognising *a* familiar key is not the same as having decoded the
        /// list. A section this cannot read, a device group that is not a
        /// list, an entry that is not a device, or a device with no address:
        /// each of those means the answer below is missing something, and an
        /// answer missing a device is indistinguishable from a Mac that is
        /// not paired with it. The sweep deletes against that.
        var incomplete = false

        for section in sections {
            guard let section = section as? [String: Any] else {
                incomplete = true
                continue
            }
            // A controller section is how a Mac with nothing paired still
            // says something. Only when it *is* a section: `null`, or a
            // number, is the key being present and the data being unusable,
            // which is the opposite of a reading.
            if let controller = section["controller_properties"] {
                if controller is [String: Any] {
                    recognisable = true
                } else {
                    incomplete = true
                }
            }

            for group in groups {
                guard section[group.key] != nil else { continue }
                recognisable = true
                guard let entries = section[group.key] as? [Any] else {
                    incomplete = true
                    continue
                }

                for entry in entries {
                    guard let entry = entry as? [String: Any] else {
                        incomplete = true
                        continue
                    }

                    for (name, fields) in entry {
                        guard let fields = fields as? [String: Any],
                              let rawAddress = fields["device_address"] as? String
                        else {
                            // A device this cannot identify is a device the
                            // catalogue would never hear about again.
                            incomplete = true
                            continue
                        }

                        // The *raw* value, before normalising: that step
                        // throws away everything that is not a hex digit, so
                        // asking it afterwards is asking about something the
                        // output never said. "AA:BB:CC:DD:EE:00!" is not an
                        // address, and it became one.
                        guard isUsableAddress(rawAddress) else {
                            incomplete = true
                            continue
                        }
                        let address = normalizeAddress(rawAddress)
                        // A release that emits both layouts would list a device
                        // twice; first writer wins.
                        guard seen.insert(address).inserted else { continue }

                        let connected = group.isConnected
                            ?? ((fields["device_isconnected"] as? String)?
                                .lowercased().contains("yes") ?? false)

                        // Continuity devices never enter the set: this feeds
                        // both the connect enrichment and the periodic
                        // battery sweep, and a phone must reach neither.
                        let minorType = fields["device_minorType"] as? String
                        guard isAnnounceworthy(name: name, minorType: minorType) else { continue }

                        let vendorID = hexIdentifier(fields["device_vendorID"])
                        let productID = hexIdentifier(fields["device_productID"])
                        snapshots.append(
                            BluetoothDeviceSnapshot(
                                name: name,
                                address: address,
                                isConnected: connected,
                                batteryLevels: batteryLevels(from: fields),
                                symbolName: symbolName(
                                    productName: name,
                                    minorType: minorType,
                                    vendorID: vendorID,
                                    productID: productID
                                ),
                                isApple: isAppleDevice(
                                    productName: name, vendorID: vendorID
                                ),
                                vendorID: vendorID,
                                productID: productID
                            )
                        )
                    }
                }
            }
        }
        // Nothing in the output was anything this knows. Whatever that is, it
        // is not a reading of the paired list.
        guard recognisable else {
            log.debug("system_profiler output held no bluetooth sections")
            return nil
        }
        // Something in it could not be read. What comes back would be a
        // partial list presented as a complete one, and the difference is
        // somebody's device being deleted.
        guard !incomplete else {
            log.debug("system_profiler output was incomplete")
            return nil
        }
        return snapshots
    }

    /// Whether a normalised address can identify a device.
    ///
    /// Six hex pairs, which is what every Bluetooth address is. Checked where
    /// the inventory is built rather than in `PairedDevice`, which is also
    /// constructed for things that have no address at all — picking a glyph
    /// for a model id, say — and must stay able to.
    public nonisolated static func isUsableAddress(_ address: String) -> Bool {
        // Twelve hex digits, and nothing between them but the separators the
        // two spellings use — `AA:BB:…` here, `aa-bb-…` in `PairedDevice`.
        guard address.filter(\.isHexDigit).count == 12 else { return false }
        return address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "-" }
    }

    /// The four keys the reporter can emit, confirmed against the strings in
    /// `SPBluetoothReporter.spreporter`. Anything else is ignored.
    private nonisolated static let batteryKeys: [(key: String, label: String)] = [
        ("device_batteryLevelMain", "Battery"),
        ("device_batteryLevelCase", "Case"),
        ("device_batteryLevelLeft", "Left"),
        ("device_batteryLevelRight", "Right"),
    ]

    private nonisolated static func batteryLevels(from fields: [String: Any]) -> [String: Double] {
        var levels: [String: Double] = [:]
        for entry in batteryKeys {
            guard let level = percentage(fields[entry.key]) else { continue }
            levels[entry.label] = level
        }
        return levels
    }

    /// `"0x2024"` → `0x2024`. nil for the devices macOS reports no ids for,
    /// which is most classic gear and every LE link it has not interrogated.
    nonisolated static func hexIdentifier(_ value: Any?) -> UInt16? {
        guard let text = value as? String else { return nil }
        let digits = text.lowercased().replacingOccurrences(of: "0x", with: "")
        return UInt16(digits, radix: 16)
    }

    /// "85%", "%85", "85 %" or a bare number → 0...1.
    ///
    /// The sign's position and the decimal separator both follow the user's
    /// locale, so the digits are extracted rather than the symbols stripped. A
    /// locale using non-Western digits yields nil, which costs a battery reading
    /// and nothing else.
    nonisolated static func percentage(_ value: Any?) -> Double? {
        let text: String
        switch value {
        case let string as String: text = string
        // Some releases emit the level as a number instead of a string.
        case let number as NSNumber: text = number.stringValue
        default: return nil
        }

        let digits = text.filter { ($0.isNumber && $0.isASCII) || $0 == "." || $0 == "," }
        guard let raw = Double(digits.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return min(max(raw / 100, 0), 1)
    }

    /// Upper-case, colon-separated. Left alone if it is not twelve hex digits,
    /// because a mangled identity is still better than a dropped device.
    nonisolated static func normalizeAddress(_ raw: String) -> String {
        let hex = Array(raw.uppercased().filter(\.isHexDigit))
        guard hex.count == 12 else { return raw.uppercased() }
        return stride(from: 0, to: 12, by: 2)
            .map { String(hex[$0...$0 + 1]) }
            .joined(separator: ":")
    }

    // MARK: - Symbols

    /// A conservative SF Symbol guess. Every name below exists on macOS 26,
    /// checked against `CoreGlyphs.bundle` — note that `magictrackpad` does not,
    /// despite being the obvious guess.
    ///
    /// The name is tried before the reported type because it is more specific:
    /// AirPods Pro and AirPods Max both report the type "Headphones". The type
    /// is the fallback, since plenty of devices are named after their brand
    /// rather than what they are.
    ///
    /// `IOBluetoothDevice.deviceClassMajor` would be the principled input and is
    /// not used: LE-only peripherals — keyboards, watches, phones — report a
    /// class of 0/0, so it identifies exactly the devices whose names already
    /// give them away.
    /// - Parameters:
    ///   - vendorID: with `productID`, the one input here that is not a guess.
    ///     A user who renames their AirPods "Ege AirPods" leaves the name
    ///     saying nothing and the minor type saying only "Headphones", so the
    ///     paired-list row wore a generic glyph while the same earbuds' own
    ///     advertisement knew exactly which model they were. The reported
    ///     product id is that model — see `PairedDevice.advertisedModel` —
    ///     so it is consulted first and the naming guesses stay as fallbacks.
    public nonisolated static func symbolName(
        productName: String,
        minorType: String? = nil,
        vendorID: UInt16? = nil,
        productID: UInt16? = nil
    ) -> String {
        let device = PairedDevice(
            address: "", name: productName, vendorID: vendorID, productID: productID
        )
        if let model = device.advertisedModel, AirPodsProximity.isKnownModel(model) {
            return AirPodsProximity.symbolName(forModel: model)
        }
        if let symbol = symbol(matching: productName) { return symbol }
        if let minorType, let symbol = symbol(matching: minorType) { return symbol }
        return "headphones"
    }

    /// Matched on the product name because it is the one field every source
    /// supplies. A vendor id would be stricter, but `system_profiler` does not
    /// report one for classic Bluetooth devices, so this would fall back to the
    /// name anyway.
    /// - Parameter vendorID: definitive when present. The name is a guess that
    ///   a rename defeats — "Ege AirPods" contains "airpods" only by luck, and
    ///   "Ege's Buds" would not.
    public nonisolated static func isAppleDevice(
        productName: String,
        vendorID: UInt16? = nil
    ) -> Bool {
        if let vendorID { return vendorID == PairedDevice.appleVendorID }
        let text = productName.lowercased()
        // Beats is Apple's, and its accessories report battery the same way.
        return ["airpods", "beats", "powerbeats", "apple", "magic mouse", "magic keyboard",
                "magic trackpad", "homepod", "iphone", "ipad", "imac", "macbook",
                "apple watch", "apple pencil", "airtag", "siri remote"]
            .contains { text.contains($0) }
    }

    private nonisolated static func symbol(matching text: String) -> String? {
        let text = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        // Ordered: "airpods max" also contains "airpods".
        if has("airpods max", "airpodsmax") { return "airpodsmax" }
        if has("airpods pro") { return "airpods.pro" }
        if has("airpods") { return "airpods.gen3" }
        if has("beats", "powerbeats") { return "beats.headphones" }
        if has("keyboard", "keychron", "nuphy") { return "keyboard" }
        if has("trackpad") { return "rectangle.and.hand.point.up.left" }
        if has("mouse", "pointing") { return "magicmouse" }
        if has("speaker", "homepod", "soundlink") { return "hifispeaker" }
        if has("gamepad", "controller", "dualshock", "dualsense", "joy-con", "xbox") {
            return "gamecontroller"
        }
        if has("display", "monitor") { return "display" }
        if has("headphone", "headset", "earbud") { return "headphones" }
        return nil
    }

    /// A real recording, anonymised, so `parse` can be tested with no hardware.
    ///
    /// Kept verbatim apart from the names and addresses, percent prefix
    /// included — that is what a non-US locale actually produces.
    public nonisolated static let sampleJSON = """
    {
      "SPBluetoothDataType" : [
        {
          "controller_properties" : {
            "controller_address" : "AA:BB:CC:00:11:22",
            "controller_chipset" : "BCM_4387",
            "controller_state" : "attrib_on",
            "controller_transport" : "PCIe"
          },
          "device_connected" : [
            {
              "Someone’s AirPods Pro" : {
                "device_address" : "60:FD:A6:00:00:01",
                "device_batteryLevelCase" : "%100",
                "device_batteryLevelLeft" : "%85",
                "device_batteryLevelRight" : "%90",
                "device_firmwareVersion" : "7E93",
                "device_minorType" : "Headphones",
                "device_productID" : "0x2024",
                "device_vendorID" : "0x004C"
              }
            }
          ],
          "device_not_connected" : [
            {
              "Wireless Keyboard" : {
                "device_address" : "F1:3F:A2:00:00:02",
                "device_minorType" : "Keyboard",
                "device_productID" : "0x3246",
                "device_vendorID" : "0x19F5"
              }
            },
            {
              "Someone’s Phone" : {
                "device_address" : "C4:52:4F:00:00:03",
                "device_rssi" : "-63"
              }
            }
          ]
        }
      ]
    }
    """
}
