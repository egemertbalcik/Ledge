import Foundation

/// One remembered reading.
public struct BatterySample: Hashable, Sendable, Codable {
    public var component: BatteryComponent
    public var level: Double
    public var charging: ChargingState
    public var at: Date
    /// Whether the device was connected when this was seen. A gap in
    /// connection is worth drawing; a flat line across it would be a lie.
    public var isConnected: Bool

    public init(
        component: BatteryComponent,
        level: Double,
        charging: ChargingState,
        at: Date,
        isConnected: Bool
    ) {
        self.component = component
        self.level = level
        self.charging = charging
        self.at = at
        self.isConnected = isConnected
    }
}

/// What is worth writing down, and what is worth keeping.
///
/// Event-driven: samples arrive when a source already had something to say.
/// Nothing here polls, and nothing here asks a source for a reading.
public enum BatteryHistory {

    /// Below this, a change in level is noise. AirPods report in coarse steps
    /// anyway, and a chart of 1% jitter is a chart of nothing.
    public static let significantChange: Double = 0.05

    /// Even an unchanged battery is worth a point occasionally, so a flat
    /// week looks like a flat week rather than an absence of data.
    public static let heartbeat: TimeInterval = 60 * 60

    /// Retention. Both bounds apply; whichever bites first wins.
    public static let maximumAge: TimeInterval = 90 * 24 * 60 * 60
    public static let maximumSamplesPerDevice = 2_000

    /// How long a record under a **rotating** identifier is kept after it
    /// stops being seen.
    ///
    /// Short, because such a record is not a device — it is one appearance of
    /// a device. macOS rotates CoreBluetooth identifiers every few minutes, so
    /// without this the catalogue accumulated a new row per rotation.
    ///
    /// Ten minutes: long enough that a device which went quiet for a moment is
    /// not retired mid-use, short enough that a retired appearance does not
    /// linger as a second row for long.
    public static let rotatingRecordGrace: TimeInterval = 10 * 60

    /// How long a record under a stable identifier is kept after it stops
    /// being seen. Long: a device you used last month is worth remembering.
    public static let staleRecordAge: TimeInterval = 90 * 24 * 60 * 60

    /// A ceiling on records regardless of age, so nothing unforeseen can grow
    /// the catalogue without limit. Pinned records are never counted out.
    public static let maximumDevices = 64

    /// Whether a new reading is worth storing, given the last one kept.
    ///
    /// Coalesces the repeats that a duty-cycled scanner produces by the dozen
    /// — the same level, seconds apart, saying nothing new.
    public static func isWorthKeeping(
        _ candidate: BatterySample,
        after previous: BatterySample?
    ) -> Bool {
        guard let previous else { return true }
        if candidate.component != previous.component { return true }
        // A change in what the device is *doing* always matters, however
        // small the level move.
        if candidate.charging != previous.charging { return true }
        if candidate.isConnected != previous.isConnected { return true }
        if abs(candidate.level - previous.level) >= significantChange { return true }
        if candidate.at.timeIntervalSince(previous.at) >= heartbeat { return true }
        return false
    }

    /// Drops what is too old or too plentiful.
    ///
    /// Age first, then count, and the count keeps the *newest*: a device that
    /// has been chatty today should not lose today to make room for last
    /// month.
    public static func pruned(_ samples: [BatterySample], now: Date) -> [BatterySample] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        var kept = samples.filter { $0.at >= cutoff }
        if kept.count > maximumSamplesPerDevice {
            kept.sort { $0.at < $1.at }
            kept.removeFirst(kept.count - maximumSamplesPerDevice)
        }
        return kept
    }

    /// The windows the detail view offers.
    public enum Window: String, CaseIterable, Sendable {
        case day, week, month

        public var duration: TimeInterval {
            switch self {
            case .day: 24 * 60 * 60
            case .week: 7 * 24 * 60 * 60
            case .month: 30 * 24 * 60 * 60
            }
        }

        public var title: String {
            switch self {
            case .day: "24 hours"
            case .week: "7 days"
            case .month: "30 days"
            }
        }
    }

    /// The samples inside a window.
    public static func samples(
        _ samples: [BatterySample],
        in window: Window,
        now: Date
    ) -> [BatterySample] {
        let start = now.addingTimeInterval(-window.duration)
        return samples.filter { $0.at >= start }.sorted { $0.at < $1.at }
    }

    /// Whether there is enough to draw a trend rather than invent one.
    ///
    /// Two points a minute apart is not a day's history, and a chart drawn
    /// from it would imply a shape nobody observed.
    public static func hasEnoughHistory(
        _ samples: [BatterySample],
        in window: Window,
        now: Date
    ) -> Bool {
        let inWindow = Self.samples(samples, in: window, now: now)
        guard inWindow.count >= 3 else { return false }
        guard let first = inWindow.first, let last = inWindow.last else { return false }
        // Span at least a tenth of the window, or the "24 hours" label is
        // describing ten minutes of data.
        return last.at.timeIntervalSince(first.at) >= window.duration / 10
    }
}
