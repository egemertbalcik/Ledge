import Foundation

/// The scrub bar with a pointer on it.
///
/// Two things have to travel together: where the pointer is, and which song it
/// grabbed. Held apart they come apart — a fraction is measured against one
/// song's length and goes on being drawn against the next song's, which is a
/// position that means nothing about anything.
///
/// A track changing under a live pointer is the case this exists for, and it
/// is not rare: tracks end while people are scrubbing them. The drag was about
/// a song that is no longer on the card, and the song that replaced it is not
/// one the user asked to scrub — so the grip is abandoned rather than handed
/// over, and nothing is drawn or acted on until the pointer lifts.
///
/// Pure and clockless, like `SeekIntent` and `PauseClock`.
public struct ScrubGrip: Equatable, Sendable {

    private enum State: Equatable, Sendable {
        case idle
        /// A pointer is down, and this is the song it took hold of.
        case holding(item: String, fraction: Double)
        /// A pointer is still down, but the song it grabbed has gone. Nothing
        /// is drawn and nothing will be acted on until it lifts.
        case abandoned
    }

    private var state: State = .idle

    public init() {}

    /// Whether a pointer is on the bar — including one whose song has gone.
    ///
    /// Asked by anything else that would move the bar, so a second way in
    /// (VoiceOver's step, say) does not fight a drag that is already running
    /// and leave the two disagreeing about where the bar is.
    public var isHeld: Bool { state != .idle }

    /// The song the pointer took hold of, while it still holds one.
    public var grabbedItem: String? {
        guard case .holding(let item, _) = state else { return nil }
        return item
    }

    /// The pointer moved. The first move is what takes the grip.
    public mutating func moved(to fraction: Double, on item: String) {
        let clamped = min(max(fraction, 0), 1)
        switch state {
        case .idle:
            state = .holding(item: item, fraction: clamped)
        case .holding(let held, _):
            // A move arriving under a different song means the change was not
            // seen through `itemChanged`. Same answer either way: this drag
            // was about the other song.
            state = held == item ? .holding(item: held, fraction: clamped) : .abandoned
        case .abandoned:
            break
        }
    }

    /// The pointer lifted.
    ///
    /// - Returns: the fraction to act on, or nil when there is nothing to act
    ///   on — no grip, or one taken on a song that is no longer here.
    public mutating func released(on item: String) -> Double? {
        defer { state = .idle }
        guard case .holding(let held, let fraction) = state, held == item else { return nil }
        return fraction
    }

    /// The song on the card changed.
    public mutating func itemChanged() {
        if case .holding = state { state = .abandoned }
    }

    /// What the bar should draw, or nil to let the player speak for itself.
    public func displayed(on item: String) -> Double? {
        guard case .holding(let held, let fraction) = state, held == item else { return nil }
        return fraction
    }
}
