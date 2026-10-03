import Foundation

/// Why an output is silent — and it can be both at once.
///
/// CoreAudio has one mute property per device and no room for a reason, but
/// Ledge sets it for two: the mute key, and silence at a level of zero, where
/// the scalar alone leaves the output playing at its lowest gain. Only the
/// first is the red muted state on screen.
///
/// The two have to compose rather than replace each other. On hardware that
/// clamps a zero scalar — this Mac's own speakers read back 0.062 at −47.6 dB
/// — the sequence that broke was: turn the sound all the way down (silence by
/// zero), press mute (which *replaced* that reason), press mute again, and the
/// clamped minimum came back audible. Both reasons are now held, and the
/// device is muted while either stands.
public struct MuteReasons: Equatable, Sendable {

    /// The user pressed mute, here or anywhere else.
    public var userMuted: Bool

    /// Ledge muted the device because the level it was asked for was zero.
    ///
    /// Tracked against the level *requested*, never the level read back: a
    /// device that clamps zero reports an audible scalar, and judging by that
    /// would lose the only reason the output is silent.
    public var zeroSilence: Bool

    public init(userMuted: Bool = false, zeroSilence: Bool = false) {
        self.userMuted = userMuted
        self.zeroSilence = zeroSilence
    }

    public static let none = MuteReasons()

    /// What the device's mute property should be.
    public var deviceMuted: Bool { userMuted || zeroSilence }

    /// What the interface shows. Only the user's own mute is red.
    public var showsMuted: Bool { userMuted }

    /// Whether anything at all is holding this output silent.
    public var isEmpty: Bool { !userMuted && !zeroSilence }
}

/// The mute reasons for each output, kept apart from the hardware's own flag.
///
/// Per device, because one latch for the whole Mac meant turning an AirPlay
/// speaker down to nothing changed what the built-in output claimed about
/// itself. Routes come and go, so the ledger is pruned to the devices that
/// still exist rather than growing for the life of the process.
///
/// Pure and clockless: the caller owns the storage and the lock, which is what
/// lets every rule in here be tested without an audio device.
public struct MuteIntentLedger: Equatable, Sendable {

    private var reasons: [UInt32: MuteReasons] = [:]

    public init() {}

    public func reasons(for device: UInt32) -> MuteReasons {
        reasons[device] ?? .none
    }

    /// Whether the interface should show this output as muted.
    public func showsMuted(for device: UInt32) -> Bool {
        reasons(for: device).showsMuted
    }

    public mutating func set(_ value: MuteReasons, for device: UInt32) {
        if value.isEmpty {
            reasons.removeValue(forKey: device)
        } else {
            reasons[device] = value
        }
    }

    /// Takes in a mute state that arrived from outside Ledge.
    ///
    /// - Parameters:
    ///   - isSelfWrite: whether Ledge wrote this output a moment ago, in which
    ///     case the reading is our own echo and says nothing about intent. The
    ///     case that needs it: a device that clamps zero reports 0.062 while
    ///     muted, which looks exactly like somebody muting at an audible level.
    public mutating func observed(
        muted: Bool,
        level: Double,
        for device: UInt32,
        isSelfWrite: Bool
    ) {
        guard !isSelfWrite else { return }
        var current = reasons(for: device)
        guard muted else {
            // Unmuted from outside: neither reason survives, whatever we
            // believed. The hardware is the last word on silence.
            set(.none, for: device)
            return
        }
        // Muted, and nothing of ours explains it. Above zero that is somebody
        // muting; at or near zero it could as easily be our own silence, and
        // claiming it as the user's would put a red pill on the volume keys.
        if current.isEmpty {
            if level > 0 {
                current.userMuted = true
            } else {
                current.zeroSilence = true
            }
            set(current, for: device)
        }
        // Otherwise one of our reasons already accounts for it, and a clamped
        // readback above zero does not promote it to the user's.
    }

    /// Forgets outputs that no longer exist, so a Mac that has seen forty
    /// AirPlay speakers does not carry forty entries.
    public mutating func keepOnly(_ devices: Set<UInt32>) {
        reasons = reasons.filter { devices.contains($0.key) }
    }

    /// How many outputs are remembered. For tests and diagnostics.
    public var count: Int { reasons.count }

    /// Prunes against an inventory, or keeps everything when there isn't one.
    ///
    /// "No devices" and "the question could not be answered" are different
    /// facts, and conflating them cost real state: a transient CoreAudio
    /// enumeration failure read as an empty Mac, every entry was dropped, and
    /// an output that had been turned all the way down came back showing its
    /// clamped minimum with the next step starting from there.
    public mutating func reconcile(with inventory: DeviceInventory) {
        switch inventory {
        case .unavailable:
            break
        case .devices(let ids):
            keepOnly(ids)
        }
    }
}

/// What a device enumeration found, including the case where it found nothing
/// out.
public enum DeviceInventory: Equatable, Sendable {

    /// The enumeration failed. Says nothing about what exists.
    case unavailable

    /// Every output the system reported — possibly none, which is a fact.
    case devices(Set<UInt32>)

    /// What a classification pass means for retention.
    ///
    /// Everything except a *confirmed* non-output is kept. A device whose
    /// capability could not be read proves nothing: a successful device list
    /// followed by one failed per-device query used to erase that device's
    /// reasons, which is the same mistake as reading a failed enumeration as
    /// an empty Mac, one level down.
    public static func retaining(_ capabilities: [UInt32: OutputCapability]) -> DeviceInventory {
        .devices(Set(capabilities.filter { $0.value != .notOutput }.keys))
    }
}

/// Whether a device can play sound, including the case where the question
/// could not be answered.
///
/// Three states rather than a Bool, because the Bool answered "no" to both
/// "this device has no outputs" and "the query failed", and those have
/// opposite consequences for state the user established.
public enum OutputCapability: Equatable, Sendable {

    /// Confirmed: it has output streams.
    case output

    /// Confirmed: it has none.
    case notOutput

    /// The query failed. Says nothing either way.
    case unknown
}
