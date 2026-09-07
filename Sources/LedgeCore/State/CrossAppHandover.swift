import Foundation

/// Whether a second player that is *also* playing should take the notch from
/// the one already holding it.
///
/// Two things making sound at once is a real state and the notch has to pick
/// one. Which one depends on what they are:
///
/// - A page taking over from an app is refused. Autoplay in a timeline claims
///   to be playing, arrives while your music is going, and is not something
///   anybody started; letting it through was the bug that took the notch away
///   from the track eighty times in nine minutes.
/// - Anything else hands over once the newcomer has kept playing for a couple
///   of seconds: an app starting while a page plays, one app starting while
///   another does, a page while another page does. In each of those the user
///   pressed something.
///
/// A paused incumbent never reaches here — the seat is free and the newcomer
/// takes it at once.
///
/// Pure and clockless. `isApp` is passed in because what counts as an app is
/// the media layer's business, not this rule's.
public struct CrossAppHandover: Equatable, Sendable {

    /// How long a second player must keep playing before it takes the notch.
    /// Longer than the within-player corroboration: this hands the card to a
    /// different application, so a moment of overlap while one is being
    /// stopped must not count.
    public static let corroboration: TimeInterval = 2.5

    /// The other app that has been playing alongside the incumbent, and since
    /// when.
    private var challenger: (bundleID: String, at: TimeInterval)?

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.challenger?.bundleID == rhs.challenger?.bundleID
            && lhs.challenger?.at == rhs.challenger?.at
    }

    /// - Parameters:
    ///   - heldBundleID: the player holding the notch, which is still playing.
    ///   - newcomerBundleID: the player that also claims to be playing.
    ///   - newcomerIsPlaying: whether it really is.
    ///   - isApp: whether a bundle identifier belongs to something the user
    ///     could have opened, as opposed to a page inside a browser.
    public mutating func handsOver(
        from heldBundleID: String,
        to newcomerBundleID: String,
        newcomerIsPlaying: Bool,
        at now: TimeInterval,
        isApp: (String) -> Bool
    ) -> Bool {
        guard newcomerIsPlaying, newcomerBundleID != heldBundleID else {
            challenger = nil
            return false
        }
        if isApp(heldBundleID), !isApp(newcomerBundleID) {
            challenger = nil
            return false
        }
        if let challenger, challenger.bundleID == newcomerBundleID {
            return now - challenger.at >= Self.corroboration
        }
        challenger = (newcomerBundleID, now)
        return false
    }
}
