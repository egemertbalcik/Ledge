import Foundation

/// Whether a battery is taking on charge.
///
/// Three states, not two. "We do not know" is the common case — most sources
/// report a level and nothing else — and it must never be mistaken for "not
/// charging", because a charged alert that fires on a guess is an alert that
/// fires at the wrong moment.
public enum ChargingState: String, Hashable, Sendable, Codable {
    case unknown
    case charging
    case notCharging
}

/// How much a reading can be trusted right now.
public enum ReadingReliability: String, Hashable, Sendable, Codable {
    /// Observed just now, from a source that was speaking for this device.
    case fresh
    /// Real, but old enough that it describes the past. Shown, never alerted
    /// on, and never presented as the current value.
    case stale
    /// Present but not to be believed — a malformed payload, a level outside
    /// the possible range, a source that contradicted itself.
    case unreliable
}

/// One battery, at one moment.
public struct BatteryReading: Hashable, Sendable, Codable {

    public var component: BatteryComponent
    /// 0...1. Clamped on the way in; a source that reports otherwise is
    /// marked unreliable rather than trusted and squashed.
    public private(set) var level: Double
    public var charging: ChargingState
    public var observedAt: Date
    public var reliability: ReadingReliability

    public init(
        component: BatteryComponent,
        level: Double,
        charging: ChargingState = .unknown,
        observedAt: Date,
        reliability: ReadingReliability = .fresh
    ) {
        self.component = component
        self.charging = charging
        self.observedAt = observedAt

        // A level that is not a number, or outside the only range a fraction
        // can occupy, is a broken reading — not a reading to be clamped into
        // looking sensible. It is kept so the device still appears, and marked
        // so nothing acts on it.
        if level.isFinite, (0...1).contains(level) {
            self.level = level
            self.reliability = reliability
        } else {
            self.level = min(max(level.isFinite ? level : 0, 0), 1)
            self.reliability = .unreliable
        }
    }

    /// Whether this reading may drive an alert. Only a fresh, believable one.
    public var isActionable: Bool { reliability == .fresh }

}

/// What a source is able to say about whether a device is attached.
///
/// Three states, because the absence of news is not news. A scanner that has
/// stopped hearing a set of AirPods knows only that it has stopped hearing
/// them — they may be in a pocket, or connected to a phone, or across the
/// room. Reporting that as `disconnected` would be inventing an event nobody
/// observed, so it is `unknown` and the *freshness* of the reading is what
/// tells the user it is old.
///
/// Only a source that saw an actual attach or detach reports the first two.
public enum DevicePresence: String, Hashable, Sendable, Codable {
    /// Seen to connect, or known to be connected right now.
    case connected
    /// Seen to disconnect. An event, not an inference.
    case disconnected
    /// In range, or last heard from, but nothing was observed either way.
    case unknown
}

/// What a source saw, normalised, before anything decides what it means.
///
/// Providers report these; the catalogue and the alert engine consume them.
/// Deliberately a value with no behaviour: it is the boundary that keeps a
/// Bluetooth scanner from knowing anything about settings or alerts.
/// Why an observation exists.
///
/// The difference decides whether a device counts as having just *attached*,
/// which is the one case an alert may fire on a first reading with nothing to
/// have crossed. Launching with low AirPods already in your ears is not an
/// attachment: the list of what was already connected is an inventory, and an
/// inventory is a baseline, not news.
public enum ObservationCause: Equatable, Sendable, Codable {

    /// A real connect or disconnect callback from the system.
    case connectionEvent

    /// The list of what was already connected when a provider started.
    case startupInventory

    /// The periodic re-ask of devices already known to be connected.
    case periodicRefresh

    /// A proximity broadcast, which says a device is nearby and nothing about
    /// it attaching.
    case advertisement

    /// Whether this cause may give a device attachment semantics.
    public var isAttachmentEvidence: Bool { self == .connectionEvent }
}

public struct DeviceObservation: Hashable, Sendable {

    /// Stable identity from the source — a Bluetooth address, a peripheral
    /// UUID. **Never** the display name.
    public var deviceID: DeviceIdentity
    public var name: String
    /// May be empty: a disconnect is worth recording even though it carries
    /// no levels, and an empty list must not erase what was last known.
    public var readings: [BatteryReading]
    public var presence: DevicePresence
    public var observedAt: Date

    /// How the device is drawn. Carried on the observation because the source
    /// is the only thing that knows — without it every catalogue record kept
    /// the defaults, so an AirPods row and its alert card wore a generic
    /// headphones glyph and lost the Apple tint.
    public var symbolName: String
    public var isApple: Bool

    /// A stable discriminator from the source, for identities that rotate.
    ///
    /// AirPods advertise a model identifier that does not change, which is a
    /// better key than the display name: keying on the name meant renaming a
    /// device started a fresh record and lost its history. Nil when the source
    /// has nothing stable to offer, in which case the name is the fallback.
    public var canonicalHint: String?

    /// Why this observation exists — see `ObservationCause`. Defaults to the
    /// quiet reading: anything that has not said it is a connection event is
    /// treated as a sighting, so a new source cannot create attachment
    /// semantics by omission.
    public var cause: ObservationCause

    public init(
        deviceID: DeviceIdentity,
        name: String,
        readings: [BatteryReading],
        presence: DevicePresence,
        observedAt: Date,
        symbolName: String = "headphones",
        isApple: Bool = false,
        canonicalHint: String? = nil,
        cause: ObservationCause = .periodicRefresh
    ) {
        self.deviceID = deviceID
        self.name = name
        self.readings = readings
        self.presence = presence
        self.observedAt = observedAt
        self.symbolName = symbolName
        self.isApple = isApple
        self.canonicalHint = canonicalHint
        self.cause = cause
    }

    /// The identity this observation's record is stored under.
    public var canonicalID: DeviceIdentity {
        deviceID.canonical(hint: canonicalHint, name: name)
    }

    public func reading(for component: BatteryComponent) -> BatteryReading? {
        readings.first { $0.component == component }
    }
}

/// How a device is identified, and by whom.
///
/// Identity never comes from the display name. Two pairs of AirPods called
/// "AirPods Pro" are two devices, and a renamed device is the same one.
public struct DeviceIdentity: Hashable, Sendable, Codable {

    public enum Source: String, Hashable, Sendable, Codable {
        /// A Bluetooth address from the paired-device list.
        case bluetoothAddress
        /// A CoreBluetooth peripheral identifier, seen over the air.
        ///
        /// **Rotates.** macOS hands out a new one for the same physical device
        /// as its BLE address changes for privacy — observed here as a fresh
        /// identifier every few minutes. Never the key a record is stored
        /// under; see `canonical`.
        case peripheralUUID
        /// The stable stand-in for a rotating identifier: what the device
        /// calls itself.
        ///
        /// Not a real identifier, and it cannot tell two same-model sets
        /// apart. It is the best available key for a device whose only other
        /// name changes every few minutes, and the alternative — a record per
        /// rotation — loses that device's history, its alert latches and the
        /// rules the user set on it, every few minutes, for ever.
        case proximityName
        /// This Mac.
        case thisMac
    }

    public var source: Source
    public var value: String

    public init(source: Source, value: String) {
        self.source = source
        self.value = value
    }

    public static func bluetooth(_ address: String) -> Self {
        .init(source: .bluetoothAddress, value: address.lowercased())
    }

    public static func peripheral(_ uuid: UUID) -> Self {
        .init(source: .peripheralUUID, value: uuid.uuidString)
    }

    public static let thisMac = Self(source: .thisMac, value: "this-mac")

    /// The identity a record is stored under.
    ///
    /// A rotating identifier is canonicalised to the device's name, so one
    /// logical device keeps one record — with its history, its latches, its
    /// pinning and the user's own rules — across every rotation. Everything
    /// else is already stable and is its own canonical form.
    ///
    /// - Parameters:
    ///   - hint: a stable discriminator from the source, preferred over the
    ///     name — an AirPods model identifier, say, which survives a rename.
    ///   - name: what the device called itself, used when there is no hint.
    ///
    /// **Known limitation, not a solved problem.** The hint is a *model*
    /// identifier, so two sets of the same model of AirPods canonicalise to
    /// one record: their proximity readings merge, and the record shows
    /// whichever advertised most recently. The alternative — keying on the
    /// rotating peripheral UUID — was measured on this Mac producing a fresh
    /// identifier every few minutes and a new "device" with it, for ever.
    /// Between a bounded wrong answer and unbounded growth, this is the
    /// bounded one.
    ///
    /// Nor is the proximity record related to the same earbuds' entry from the
    /// paired-device list: there is no trustworthy identifier linking the two,
    /// and matching on the display name would be exactly the mistake that
    /// makes two identical sets one device. Both records stay; the *alert* is
    /// deduplicated instead — see `BatteryAlertEngine.withoutDuplicates`.
    ///
    /// Fixing either properly needs evidence this code cannot get: hardware
    /// validation with two same-model sets, and an identifier Apple does not
    /// publish. Do not invent one.
    public func canonical(hint: String? = nil, name: String) -> DeviceIdentity {
        switch source {
        case .peripheralUUID:
            if let hint, !hint.isEmpty {
                return Self(source: .proximityName, value: hint.lowercased())
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing stable to key on at all. Keeping the rotating value
            // means such a record is transient, which retention then retires.
            guard !trimmed.isEmpty else { return self }
            return Self(source: .proximityName, value: trimmed.lowercased())
        case .bluetoothAddress, .proximityName, .thisMac:
            return self
        }
    }

    /// Whether this identifier is stable enough to keep a record under.
    ///
    /// CoreBluetooth peripheral identifiers **rotate**: macOS hands out a new
    /// one for the same physical device as its BLE address changes for
    /// privacy. Observed on this Mac: one set of AirPods produced a fresh
    /// identifier roughly every few minutes, so a catalogue keyed on it grew a
    /// new "device" each time — for ever.
    ///
    /// A Bluetooth address from the paired list, and this Mac, are stable. A
    /// record under a rotating identifier is kept only while it is being seen,
    /// and retired once it goes quiet.
    public var isDurable: Bool {
        switch source {
        case .bluetoothAddress, .thisMac, .proximityName: true
        case .peripheralUUID: false
        }
    }

    /// Whether something other than the catalogue already alerts for this
    /// device.
    ///
    /// True for this Mac: `BatteryProvider` has announced its battery
    /// transitions since long before the catalogue existed, with thresholds
    /// and wording of its own. The catalogue records its history and shows it
    /// in the list, and stays out of the alerting.
    public var ownsItsOwnAlerting: Bool { source == .thisMac }

    /// How long a reading from this kind of source describes *now*.
    ///
    /// Derived rather than stamped, so there is no timer anywhere deciding
    /// that something has gone stale — the question is only ever asked when
    /// somebody looks, and the answer follows the clock.
    ///
    /// The intervals follow how often each source speaks at all. A
    /// duty-cycled advertisement arrives within seconds when the device is
    /// present, so five minutes of silence is already meaningful. The paired
    /// device list is re-read every ten minutes, so thirty is the first point
    /// at which silence means something. This Mac reports on change and is
    /// never absent while its provider runs.
    public var freshnessInterval: TimeInterval {
        switch source {
        case .peripheralUUID, .proximityName: 5 * 60
        case .bluetoothAddress: 30 * 60
        case .thisMac: 15 * 60
        }
    }

    /// Whether this source reports only when something changes, rather than
    /// repeating itself on a cadence.
    ///
    /// This Mac's battery does: it is read from the power source, which
    /// announces changes and says nothing while a charged battery sits on the
    /// charger. Judging it by elapsed time marked the one device that is
    /// certainly present as stale after fifteen quiet minutes. Nothing is
    /// polled to fix that — the absence of news is simply not evidence of
    /// absence for this kind of source.
    public var reportsOnlyOnChange: Bool { source == .thisMac }
}
