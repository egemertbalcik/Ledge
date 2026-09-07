import Foundation
import IOBluetooth
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

    public init(
        name: String,
        address: String,
        isConnected: Bool = true,
        batteryLevels: [String: Double] = [:],
        symbolName: String = "headphones",
        isApple: Bool = false
    ) {
        self.name = name
        self.address = address
        self.isConnected = isConnected
        self.batteryLevels = batteryLevels
        self.symbolName = symbolName
        self.isApple = isApple
    }
}

/// A place connected-device information can come from.
///
/// Watching is push-only by design. Every implementation must be able to sit
/// idle indefinitely and cost nothing — see `IOBluetoothDeviceSource` for why
/// the obvious polling shape is not on the table.
@MainActor
public protocol BluetoothDeviceSource: AnyObject {

    /// False when the Mac has no Bluetooth controller at all.
    var isAvailable: Bool { get }

    func connectedDevices() async -> [BluetoothDeviceSnapshot]

    func startWatching(
        onConnect: @escaping (BluetoothDeviceSnapshot) -> Void,
        onDisconnect: @escaping (String) -> Void
    )

    func stopWatching()
}

/// Connected devices and their battery levels, prompting as little as possible.
///
/// `CBCentralManager` is the API everyone reaches for and is the wrong one here.
/// It is gated on `kTCCServiceBluetoothAlways`, and merely creating the manager
/// powers up the stack and puts a "Ledge would like to use Bluetooth" dialog on
/// screen. For an overlay that has not been asked to do anything yet, that is a
/// non-starter.
///
/// `IOBluetooth` is the better path, but not a free one: Apple DTS have stated
/// that IOBluetooth is gated by the same TCC service starting with Sonoma. It
/// differs from CoreBluetooth in the ways that matter — it answers from the
/// paired list instead of scanning, it never prompts on its own, and when access
/// is refused it fails *silently*, returning an empty list rather than throwing.
/// Silence is why nothing below treats an empty result as an error.
///
/// `system_profiler SPBluetoothDataType -json` is the un-gated leg, and the
/// reason this works at all when the grant is missing. It is Apple-signed and
/// carries the private `com.apple.bluetooth.system` entitlement, so it reads the
/// stack on its own authority — and it reports connection state *and* per-
/// component battery, which IOBluetooth does not expose at all. It is therefore
/// the primary source, with IOBluetooth adding the LE links it can omit.
///
/// What IOBluetooth uniquely provides is a push: connect and disconnect
/// notifications. Nothing else offers them, which is what keeps this off a
/// timer. `system_profiler` costs ~150ms and is spawned only when a device
/// actually connects or when the card is explicitly asked for its contents —
/// never on a schedule. An overlay that woke a subprocess every few seconds
/// forever would be indefensible, and connect events are already the only
/// moments the answer changes in a way the card cares about.
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

    public override init() {
        super.init()
    }

    /// True when a controller exists and reports a real address.
    ///
    /// A Mac with Bluetooth removed or failed still vends a controller object,
    /// but its address reads back as all zeroes — so the address is the test,
    /// not the object. A refused permission may present the same way; both mean
    /// the same thing to the caller, since the card is driven by notifications
    /// that would not arrive either.
    public var isAvailable: Bool {
        guard let address = IOBluetoothHostController.default()?.addressAsString() else {
            return false
        }
        return address.contains { $0.isHexDigit && $0 != "0" }
    }

    // MARK: - Reading

    public func connectedDevices() async -> [BluetoothDeviceSnapshot] {
        // `system_profiler` leads because it needs no grant and is the only
        // source of battery levels.
        let profiled = await Self.profiledDevices()
        var byAddress = profiled.filter { $0.value.isConnected }

        // IOBluetooth sees LE links that `system_profiler` can leave out, so it
        // only ever adds. When the permission is missing this loop is empty and
        // the result is simply the profiled set.
        for identity in Self.connectedIdentities()
        where byAddress[identity.address] == nil
            && Self.isAnnounceworthy(name: identity.name, classMajor: identity.classMajor) {
            byAddress[identity.address] = Self.snapshot(
                for: identity,
                profiled: profiled[identity.address]
            )
        }

        // Sorted, because a dictionary's order is not stable between calls and
        // the cards would shuffle.
        return byAddress.values.sorted { $0.name < $1.name }
    }

    /// Name, address and class of a device, carried across the actor hop
    /// because `IOBluetoothDevice` is a non-Sendable ObjC class and must not
    /// travel.
    private struct Identity: Sendable {
        let name: String
        let address: String
        let classMajor: BluetoothDeviceClassMajor
    }

    private static func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
    }

    private static func connectedIdentities() -> [Identity] {
        pairedDevices().filter { $0.isConnected() }.compactMap(identity)
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
        if let minor = minorType?.lowercased() {
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

    private static func identity(of device: IOBluetoothDevice) -> Identity? {
        guard let address = address(of: device) else { return nil }
        // `nameOrAddress` rather than `name`: an LE device that has not been
        // interrogated yet has no name, and a blank card is worse than a MAC.
        let name = device.name ?? device.nameOrAddress ?? address
        return Identity(name: name, address: address, classMajor: device.deviceClassMajor)
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
            isConnected: true,
            // Absent battery data is expected — most devices have none, and
            // AirPods take a moment after connecting to report any.
            batteryLevels: profiled?.batteryLevels ?? [:],
            // Prefer the profiled symbol: it was chosen with the reported device
            // type in hand, which the name alone does not give us.
            symbolName: profiled?.symbolName ?? symbolName(productName: identity.name),
            isApple: isAppleDevice(productName: identity.name)
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

        connectRegistration = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )

        // Devices already connected when watching starts never send a connect
        // notification, so their disconnect has to be armed by hand.
        for device in Self.pairedDevices() where device.isConnected() {
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
        guard let address = Self.address(of: device),
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
        Task { @MainActor [weak self] in
            guard let self else { return }
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
            let profiled = await Self.profiledDevices()
            // The enrichment can take seconds; a flap inside that window has
            // already delivered the disconnect. Announcing the connect now
            // would present a device that is gone — and its one-shot
            // disconnect registration has spent itself, so no goodbye would
            // ever correct the card.
            guard device.isConnected() else { return }
            guard let handler = self.onConnect else { return }
            handler(Self.snapshot(for: identity, profiled: profiled[identity.address]))
        }
    }

    @objc private nonisolated func deviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        nonisolated(unsafe) let device = device
        Task { @MainActor [weak self] in
            guard let self, let address = Self.address(of: device) else { return }
            // The registration is one-shot and has already invalidated itself;
            // only our reference to it needs clearing. Calling `unregister()`
            // here would be a second release of something IOBluetooth dropped.
            self.disconnectRegistrations.removeValue(forKey: address)
            self.onDisconnect?(address)
        }
    }

    // MARK: - system_profiler

    private nonisolated static func profiledDevices() async -> [String: BluetoothDeviceSnapshot] {
        guard let data = await runSystemProfiler() else { return [:] }
        return Dictionary(parse(data).map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Runs `system_profiler` and returns its stdout, or nil on any failure.
    ///
    /// Failure is not exceptional: the tool can be slow, killed, or emit
    /// something we cannot use. The card renders without battery levels, so
    /// every path here degrades to nil rather than propagating.
    private nonisolated static func runSystemProfiler() async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                // No `-detailLevel`: `mini` drops `device_address`, which is the
                // one field this cannot work without.
                process.arguments = ["SPBluetoothDataType", "-json"]

                let stdout = Pipe()
                process.standardOutput = stdout
                // Discarded rather than piped. A piped stderr that nobody drains
                // will deadlock the child once it fills, and there is nothing
                // here that a warning line would change.
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    log.debug("system_profiler failed to launch: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }

                // Kill it if it overruns. Cancelled on normal exit below, so the
                // timer never fires for a healthy query.
                let deadline = DispatchWorkItem {
                    guard process.isRunning else { return }
                    log.notice("system_profiler timed out after \(queryTimeout, privacy: .public)s — terminating")
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + queryTimeout, execute: deadline)

                // Read to EOF first: the output comfortably exceeds a pipe
                // buffer on a Mac with several paired devices, and reading after
                // waitUntilExit would deadlock against it. On a timeout,
                // terminate() closes the pipe and this returns.
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()

                guard process.terminationStatus == 0 else {
                    log.debug("system_profiler exited \(process.terminationStatus, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Parsing

    /// Every device `system_profiler` reported, connected or not.
    ///
    /// Written against this shape, recorded on macOS 26.4 and trimmed — see
    /// `sampleJSON` for the full recording:
    ///
    ///     { "SPBluetoothDataType": [ {
    ///         "controller_properties": { ... },
    ///         "device_connected": [
    ///           { "AirPods Pro": {
    ///               "device_address": "AA:BB:CC:11:22:33",
    ///               "device_batteryLevelCase": "%100",
    ///               "device_minorType": "Headphones" } } ],
    ///         "device_not_connected": [ ... ] } ] }
    ///
    /// Nothing about that is guaranteed. Each device is a single-entry
    /// dictionary keyed by its *user-assigned name*, so no key at that level is
    /// knowable ahead of time; battery values are locale-formatted strings, and
    /// on this machine the percent sign is a prefix (`"%100"`, en_TR) where a US
    /// machine prints `"100%"`; and older releases flattened everything into one
    /// `device_title` array with a `device_isconnected` field instead of
    /// splitting by state. So this reads defensively throughout: every cast is
    /// optional, an unrecognised shape yields fewer devices rather than an
    /// error, and a device that survives with no battery keys is still returned.
    public nonisolated static func parse(_ json: Data) -> [BluetoothDeviceSnapshot] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [Any]
        else {
            log.debug("system_profiler output was not the expected shape")
            return []
        }

        // nil means "the entry says so itself", which is the legacy layout.
        let groups: [(key: String, isConnected: Bool?)] = [
            ("device_connected", true),
            ("device_not_connected", false),
            ("device_title", nil),
        ]

        var snapshots: [BluetoothDeviceSnapshot] = []
        var seen: Set<String> = []

        for section in sections {
            guard let section = section as? [String: Any] else { continue }

            for group in groups {
                guard let entries = section[group.key] as? [Any] else { continue }

                for entry in entries {
                    guard let entry = entry as? [String: Any] else { continue }

                    for (name, fields) in entry {
                        guard let fields = fields as? [String: Any],
                              let rawAddress = fields["device_address"] as? String
                        else { continue }

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

                        snapshots.append(
                            BluetoothDeviceSnapshot(
                                name: name,
                                address: address,
                                isConnected: connected,
                                batteryLevels: batteryLevels(from: fields),
                                symbolName: symbolName(
                                    productName: name,
                                    minorType: minorType
                                )
                            )
                        )
                    }
                }
            }
        }
        return snapshots
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
    public nonisolated static func symbolName(
        productName: String,
        minorType: String? = nil
    ) -> String {
        if let symbol = symbol(matching: productName) { return symbol }
        if let minorType, let symbol = symbol(matching: minorType) { return symbol }
        return "headphones"
    }

    /// Matched on the product name because it is the one field every source
    /// supplies. A vendor id would be stricter, but `system_profiler` does not
    /// report one for classic Bluetooth devices, so this would fall back to the
    /// name anyway.
    public nonisolated static func isAppleDevice(productName: String) -> Bool {
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

