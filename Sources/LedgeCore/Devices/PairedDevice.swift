import Foundation

/// One device the Mac is actually paired with.
///
/// The catalogue's test of ownership. Everything Ledge stores about hardware
/// has to answer "is this the user's?", and the only thing that can answer it
/// is the system's own paired list: a Bluetooth radio hears every device in
/// the room, and hearing one says nothing about whose it is. Carried as a
/// value because the answer is read on the main actor, inside an actor, and
/// from a provider, and none of them may hold a reference to the Bluetooth
/// stack.
public struct PairedDevice: Hashable, Sendable {

    /// Normalised on the way in: the sources disagree on case and separator,
    /// and an address compared raw matches nothing.
    public let address: String

    /// What macOS calls it. The authority on the name — a record whose name
    /// came from somewhere else has drifted, and the drift is visible.
    public var name: String

    /// Whether macOS says it is connected *right now*. A full answer is the
    /// only thing that can retire a record still claiming an attachment.
    public var isConnected: Bool

    /// Bluetooth SIG company identifier, when the system reports one.
    public var vendorID: UInt16?
    /// Product identifier, when the system reports one. The one field that
    /// can relate an over-the-air advertisement to a paired device — see
    /// `advertisedModel`.
    public var productID: UInt16?

    public var symbolName: String
    public var isApple: Bool

    public init(
        address: String,
        name: String,
        isConnected: Bool = false,
        vendorID: UInt16? = nil,
        productID: UInt16? = nil,
        symbolName: String = "headphones",
        isApple: Bool = false
    ) {
        self.address = PairedDevice.normalise(address)
        self.name = name
        self.isConnected = isConnected
        self.vendorID = vendorID
        self.productID = productID
        self.symbolName = symbolName
        self.isApple = isApple
    }

    /// The identity a record for this device is stored under.
    public var identity: DeviceIdentity { .bluetooth(address) }

    /// Apple's Bluetooth SIG company identifier.
    public static let appleVendorID: UInt16 = 0x004C

    /// The Continuity model id this device would broadcast, if it broadcasts
    /// at all.
    ///
    /// An AirPods proximity advertisement carries a two-byte model id read
    /// big-endian — `0x2420` — while `system_profiler` reports the same model
    /// as a product id read the other way round — `0x2024`. Confirmed against
    /// this Mac's own paired list: "Ege Mert's AirPods Pro" reports product
    /// `0x2024` and advertises model `0x2420`; "Ege AirPods" reports `0x201B`
    /// and advertises `0x1B20`.
    ///
    /// That byte swap is the link the catalogue has been missing. It is a
    /// *model* identifier, not a serial number, so it can only be trusted
    /// when exactly one paired device claims it — see `airPodsOwner(ofModel:)`.
    public var advertisedModel: UInt16? {
        guard vendorID == PairedDevice.appleVendorID, let productID else { return nil }
        return productID.byteSwapped
    }

    /// Upper-case hex is how `system_profiler` prints an address and
    /// lower-case dashes are how IOBluetooth hands one back; `DeviceIdentity`
    /// stores lower-case. One form here, so a comparison means something.
    public static func normalise(_ raw: String) -> String {
        let hex = Array(raw.lowercased().filter(\.isHexDigit))
        guard hex.count == 12 else { return raw.lowercased() }
        return stride(from: 0, to: 12, by: 2)
            .map { String(hex[$0...$0 + 1]) }
            .joined(separator: ":")
    }
}

/// What the Bluetooth stack last said the Mac is paired with.
///
/// **The absence of an answer is not an empty answer.** This exists as a
/// separate type, with no empty default anywhere, because the obvious shape —
/// a `Set` that starts empty — means every judgement made before the stack
/// has spoken reads as "paired with nothing", and a catalogue pruned against
/// that deletes everything the user owns. Nothing may be dropped, and no
/// record refused, until `current` is non-nil.
public final class PairedDeviceRegistry: @unchecked Sendable {

    /// One complete reading of the paired list.
    public struct Answer: Equatable, Sendable {

        public var devices: [PairedDevice]
        /// Bumped per answer, so a consumer can tell a fresh reading from the
        /// one it already acted on without comparing the whole list.
        public var generation: Int
        public var at: Date

        public init(devices: [PairedDevice], generation: Int, at: Date) {
            self.devices = devices
            self.generation = generation
            self.at = at
        }

        public func device(for id: DeviceIdentity) -> PairedDevice? {
            guard id.source == .bluetoothAddress else { return nil }
            return devices.first { $0.identity == id }
        }

        public func contains(_ id: DeviceIdentity) -> Bool { device(for: id) != nil }

        /// The paired device an AirPods advertisement belongs to, or nil.
        ///
        /// Nil when nothing matches — a stranger's earbuds in a cafe — and
        /// **also** when more than one paired device claims the model, because
        /// a model id cannot tell two identical sets apart. Attaching the
        /// readings to a coin-flip winner would put one set's battery on the
        /// other's record, which is worse than showing nothing.
        public func airPodsOwner(ofModel model: UInt16) -> PairedDevice? {
            let candidates = devices.filter { $0.advertisedModel == model }
            guard candidates.count == 1 else { return nil }
            return candidates[0]
        }
    }

    private let lock = NSLock()
    private var stored: Answer?

    /// Connection events, with when they happened.
    ///
    /// A reading of the paired list samples connection state at the moment it
    /// runs, and `system_profiler` takes seconds to answer. An event that
    /// arrives while a reading is in flight is *newer* than that reading, and
    /// without this the stale answer landed on top of it: connect, then the
    /// list that had already sampled "not connected" publishes, and the card
    /// says disconnected until the next ten-minute read. Kept for events
    /// before the first reading too, which otherwise had nothing to patch.
    private var liveConnection: [String: (isConnected: Bool, at: Date)] = [:]

    /// When the last complete reading was taken.
    ///
    /// Kept apart from `Answer.at`, which a connection event also moves: that
    /// event is about one device, and an inventory is about all of them.
    private var lastInventoryAt: Date?

    public init() {}

    /// The last complete reading, or nil if the stack has not answered yet.
    public var current: Answer? { lock.withLock { stored } }

    /// Records a complete reading of the paired list.
    ///
    /// Complete is the requirement: a partial list would read as "the user is
    /// not paired with the rest", which is the one thing this type exists to
    /// prevent.
    /// - Parameter at: when the list was *read*, not when it was published.
    ///   The difference decides which of a reading and a connection event is
    ///   the newer evidence, and a slow read publishes long after it sampled.
    @discardableResult
    public func answer(_ devices: [PairedDevice], at: Date = Date()) -> Acceptance {
        lock.withLock {
            // A reading older than the *reading* already here says nothing
            // new. Two reads can be in flight at once — a startup read and
            // the ten-minute one, or two providers — and the last to finish
            // is not the last to have looked.
            //
            // Against the last reading, not against the last thing that
            // happened: a connection event is evidence about one device and
            // says nothing about who is paired, so letting it move this line
            // meant one device's churn could keep discarding another
            // device's arrival in the list.
            if let stored, let lastRead = lastInventoryAt, at < lastRead {
                return .older(stored)
            }
            lastInventoryAt = at
            var merged = devices
            // Anything seen to happen after this reading was taken outranks
            // it. Only connection state: membership is the reading's own
            // business, and an event never adds or removes a device.
            for (address, evidence) in liveConnection where evidence.at > at {
                guard let index = merged.firstIndex(where: { $0.address == address }) else { continue }
                merged[index].isConnected = evidence.isConnected
            }
            // Evidence older than this reading has been incorporated by it.
            liveConnection = liveConnection.filter { $0.value.at > at }
            let answer = Answer(
                devices: merged,
                generation: (stored?.generation ?? 0) + 1,
                at: at
            )
            stored = answer
            return .accepted(answer)
        }
    }

    /// What became of a reading that was offered.
    public enum Acceptance: Equatable, Sendable {
        /// It was the newest reading, and is now the answer.
        case accepted(Answer)
        /// Older than the reading already stored; nothing changed, and
        /// nothing derived from it should be acted on either — its battery
        /// levels are as old as its membership.
        case older(Answer)

        public var answer: Answer {
            switch self {
            case .accepted(let answer), .older(let answer): answer
            }
        }

        public var wasAccepted: Bool {
            if case .accepted = self { return true }
            return false
        }
    }

    /// One device connected or disconnected, as the system said so.
    ///
    /// Not a new reading of the list: membership is untouched, and a device
    /// this has never heard of is ignored rather than invented. It exists
    /// because the list itself is read at startup and every ten minutes,
    /// which is far too slow to be asked "is this connected *now*" — a card
    /// published seconds after a real connect used to say "Disconnected",
    /// and one published after a goodbye said "Connected".
    ///
    /// The generation is bumped: the answer changed, and a consumer that
    /// acted on the old one has something new to act on.
    @discardableResult
    public func connectionChanged(
        address: String,
        isConnected: Bool,
        at: Date = Date()
    ) -> Answer? {
        lock.withLock {
            let wanted = PairedDevice.normalise(address)
            // Remembered whether or not a list has been read yet, and whether
            // or not this device is in the one that has: a reading still in
            // flight may be about to land with an older view of it.
            liveConnection[wanted] = (isConnected, at)
            guard let previous = stored else { return nil }
            guard let index = previous.devices.firstIndex(where: { $0.address == wanted }),
                  previous.devices[index].isConnected != isConnected
            else { return nil }
            var devices = previous.devices
            devices[index].isConnected = isConnected
            // The reading's own time is kept: this is one device's news, not
            // a fresh look at the list. `needsAReading` asks when the list
            // was last read, and an event is not that.
            let answer = Answer(
                devices: devices,
                generation: previous.generation + 1,
                at: previous.at
            )
            stored = answer
            return answer
        }
    }
}
