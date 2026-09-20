import Foundation

/// Whether a Bluetooth listening window should be held open.
///
/// The scanner duty-cycles: a short window every few seconds, so the radio is
/// mostly idle. While something of ours is in range *and changing*, the window
/// is held open so the battery figures and lid state keep up.
///
/// The trap is that "in range and changing" was read as "an advertisement
/// arrived". AirPods advertise many times a second, and in attentive mode every
/// duplicate is delivered — so each one pushed the window's end further out and
/// the window never closed. The duty cycle was defeated exactly when AirPods
/// were nearby, which is most of the time, leaving the most expensive scan mode
/// running continuously.
///
/// So the window is held open by *change*, not by traffic, and there is a
/// ceiling on how long it may stay open regardless. Pure and clockless: the
/// caller supplies the time.
public struct ProximityScanWindow: Equatable, Sendable {

    /// The longest an attentive window may run continuously before dropping
    /// back to the duty cycle, however much is changing. A backstop: something
    /// that changes forever is a fault, and a fault should not hold the radio.
    public static let ceiling: TimeInterval = 30

    /// How long after the last real change the window stays open.
    public static let hold: TimeInterval = 6

    /// When the current attentive run began, or nil if it is not running.
    public private(set) var attentiveSince: TimeInterval?
    /// When the window is currently due to close.
    public private(set) var closesAt: TimeInterval?

    public init() {}

    public enum Decision: Equatable, Sendable {
        /// Hold the window open until `until`, in attentive mode.
        case hold(until: TimeInterval)
        /// Nothing to do: already covered, and nothing has changed.
        case leave
        /// Stop attentive scanning and let the duty cycle take over.
        case release
    }

    /// An advertisement arrived.
    ///
    /// - Parameters:
    ///   - changed: whether it says anything different from the last one.
    ///   - now: current time.
    public mutating func advertisement(changed: Bool, now: TimeInterval) -> Decision {
        // Ceiling first: it outranks any amount of change.
        if let since = attentiveSince, now - since >= Self.ceiling {
            attentiveSince = nil
            closesAt = nil
            return .release
        }

        guard changed else {
            // Traffic without news. If the window is already due to close, let
            // it: repeats of a value nobody is waiting for are what kept the
            // radio on.
            return .leave
        }

        if attentiveSince == nil { attentiveSince = now }
        let until = now + Self.hold
        closesAt = until
        return .hold(until: until)
    }

    /// The window closed on its own.
    public mutating func closed() {
        attentiveSince = nil
        closesAt = nil
    }

    /// Whether an attentive window is currently open.
    public var isAttentive: Bool { attentiveSince != nil }
}
