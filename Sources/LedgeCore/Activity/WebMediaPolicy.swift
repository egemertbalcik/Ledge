import Foundation

/// Whether a web page's media may be shown, and where.
///
/// A browser holds one now-playing slot for every tab and hands it around, so
/// what reaches the notch from a browser is often not what the user chose to
/// play — an autoplaying video in a background tab registers exactly as a
/// track does. Off by default for that reason: native players say what they
/// are playing and a page does not.
///
/// Two switches, and the second depends on the first. A card is the smaller
/// commitment; a place in the compact view is the larger one, because the ears
/// are what the notch shows when nobody is looking at it.
///
/// The fourth combination — compact on, cards off — is not a state the user
/// can reach through the interface, but it is a state a preference file can
/// hold: hand-edited, or left behind by turning cards off in an older build.
/// It is read as both off, so compact content cannot reappear by itself when
/// cards are switched back on.
public struct WebMediaPolicy: Equatable, Sendable {

    /// Whether a web page's media may have a card at all.
    public let showsCards: Bool

    /// Whether it may also hold the compact view. Never true without
    /// `showsCards` — see the type's note.
    public let showsInCompact: Bool

    public init(showsCards: Bool, showsInCompact: Bool) {
        self.showsCards = showsCards
        self.showsInCompact = showsCards && showsInCompact
    }

    /// What an empty preference store means, and what the fourth combination
    /// resolves to.
    public static let hidden = WebMediaPolicy(showsCards: false, showsInCompact: false)

    /// Both switches on: a web page's media treated exactly as a player's.
    public static let shown = WebMediaPolicy(showsCards: true, showsInCompact: true)

    /// Whether media from this owner may have a card.
    ///
    /// - Parameter ownerIsApp: false for a web page — see `MediaOwner`.
    ///   Native apps are unaffected by either switch, which is the point: this
    ///   changes what browsers may do and nothing else.
    public func allowsCard(ownerIsApp: Bool) -> Bool {
        ownerIsApp || showsCards
    }

    /// Whether media from this owner may hold the compact view.
    public func allowsCompact(ownerIsApp: Bool) -> Bool {
        ownerIsApp || showsInCompact
    }
}
