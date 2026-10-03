import Foundation

/// What Ledge remembers about one device.
public struct DeviceRecord: Hashable, Sendable, Codable, Identifiable {

    public var id: DeviceIdentity
    public var name: String
    public var symbolName: String
    public var isApple: Bool

    /// What was last *observed* about attachment. Never inferred from
    /// silence — see `DevicePresence`.
    public var presence: DevicePresence
    /// The last readings seen, each carrying its own age. Never presented as
    /// current without checking `reliability`.
    public var readings: [BatteryReading]

    public var firstSeen: Date
    public var lastSeen: Date
    public var lastConnected: Date?

    public var isPinned: Bool
    public var isHidden: Bool

    public var alerts: DeviceAlertConfiguration
    /// Per-component "have I already said this".
    public var alertState: [BatteryComponent: ComponentAlertState]

    public init(
        id: DeviceIdentity,
        name: String,
        symbolName: String = "headphones",
        isApple: Bool = false,
        presence: DevicePresence = .unknown,
        readings: [BatteryReading] = [],
        firstSeen: Date,
        lastSeen: Date,
        lastConnected: Date? = nil,
        isPinned: Bool = false,
        isHidden: Bool = false,
        alerts: DeviceAlertConfiguration = .untouched,
        alertState: [BatteryComponent: ComponentAlertState] = [:]
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.isApple = isApple
        self.presence = presence
        self.readings = readings
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.lastConnected = lastConnected
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.alerts = alerts
        self.alertState = alertState
    }

    /// The lowest battery being worn, for the list row. nil when the device
    /// reports nothing.
    public var lowestInUseLevel: Double? {
        readings.filter { $0.component.isInUse && $0.reliability != .unreliable }
            .map(\.level).min()
    }

    /// Whether one reading describes *now*.
    ///
    /// Three things have to hold, and only the first was being checked:
    ///
    /// - the reading is believable at all;
    /// - the device has not been seen to **disconnect** — a disconnect keeps
    ///   the last known levels on purpose, and the moment it happens they
    ///   describe the past, however recent they are;
    /// - the reading itself is recent. Its own timestamp, not the record's:
    ///   a disconnect updates `lastSeen`, so judging by the record made a
    ///   two-day-old level look current the instant the device went away.
    public func isCurrent(_ reading: BatteryReading, now: Date) -> Bool {
        guard reading.reliability == .fresh else { return false }
        guard presence != .disconnected else { return false }
        return now.timeIntervalSince(reading.observedAt) <= id.freshnessInterval
    }

    /// The lowest worn battery that still describes now, and whether what is
    /// shown is historical. One place, so the row and the detail pane cannot
    /// disagree.
    public func displayedLowestInUse(now: Date) -> (level: Double?, isHistorical: Bool) {
        let worn = readings.filter { $0.component.isInUse && $0.reliability != .unreliable }
        guard let lowest = worn.min(by: { $0.level < $1.level }) else { return (nil, false) }
        return (lowest.level, !isCurrent(lowest, now: now))
    }

    /// Whether what this record says describes now.
    ///
    /// Derived, every time it is asked, from when the device was last heard
    /// and how talkative its kind of source is. There is no timer marking
    /// records stale and no stored flag to go out of date — a clock that
    /// jumps forwards or backwards simply produces a different answer to the
    /// same question, which is the behaviour wanted.
    public func isFresh(now: Date) -> Bool {
        now.timeIntervalSince(lastSeen) <= id.freshnessInterval
    }

    public func isStale(now: Date) -> Bool { !isFresh(now: now) }

    /// What to show, in one place: the observed attachment, qualified by
    /// whether we still believe it.
    ///
    /// A device seen to connect and then not heard from for an hour is
    /// "connected, as far as we know an hour ago" — not "disconnected", which
    /// nobody observed.
    public func status(now: Date) -> Status {
        Status(presence: presence, isFresh: isFresh(now: now))
    }

    public struct Status: Hashable, Sendable {
        public var presence: DevicePresence
        public var isFresh: Bool

        public init(presence: DevicePresence, isFresh: Bool) {
            self.presence = presence
            self.isFresh = isFresh
        }
    }
}

/// The whole catalogue, as stored.
///
/// Versioned from the first release: a schema that cannot say what it is
/// cannot be migrated, and the first time that matters is the first time it
/// is too late.
public struct DeviceCatalogue: Sendable, Codable {

    /// Bumped whenever the stored shape changes in a way that needs handling.
    public static let currentVersion = 1

    public var version: Int
    public var devices: [DeviceRecord]
    /// Keyed by device, then component. Kept beside the records rather than
    /// inside them so a history rewrite does not rewrite the catalogue.
    public var history: [String: [BatterySample]]

    /// History the user chose to keep after removing its device.
    ///
    /// Maintenance drops history whose device is gone; without this it also
    /// dropped the history somebody had explicitly asked to keep, which made
    /// "Remove, Keep History" a lie within the hour.
    public var retainedHistory: Set<String>

    public init(
        version: Int = DeviceCatalogue.currentVersion,
        devices: [DeviceRecord] = [],
        history: [String: [BatterySample]] = [:],
        retainedHistory: Set<String> = []
    ) {
        self.version = version
        self.devices = devices
        self.history = history
        self.retainedHistory = retainedHistory
    }

    // MARK: - Codable

    /// Decoded field by field, with defaults.
    ///
    /// A synthesised decoder demands every key, so adding `retainedHistory`
    /// would have made every catalogue written before it unreadable — and an
    /// unreadable catalogue is quarantined, so the first upgrade would have
    /// silently thrown away everybody's history. A new field must always be
    /// optional on the way in.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        devices = try container.decodeIfPresent([DeviceRecord].self, forKey: .devices) ?? []
        history = try container.decodeIfPresent(
            [String: [BatterySample]].self, forKey: .history
        ) ?? [:]
        retainedHistory = try container.decodeIfPresent(
            Set<String>.self, forKey: .retainedHistory
        ) ?? []
    }

    /// The key history is filed under. Identity, never the name.
    public static func historyKey(_ id: DeviceIdentity) -> String {
        "\(id.source.rawValue):\(id.value)"
    }

    public func index(of id: DeviceIdentity) -> Int? {
        devices.firstIndex { $0.id == id }
    }

    /// Brings a stored catalogue up to the current shape.
    ///
    /// A version from the future is not downgraded — it is refused, and the
    /// caller starts fresh rather than writing a shape it does not understand
    /// over somebody's history.
    public static func migrated(_ stored: DeviceCatalogue) -> DeviceCatalogue? {
        guard stored.version <= currentVersion else { return nil }
        var catalogue = stored
        // No migrations yet; version 1 is the first shape. The switch is here
        // so the next one has an obvious home.
        catalogue.version = currentVersion
        return catalogue
    }
}
