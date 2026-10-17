import Foundation

/// Whether a meeting's link is worth offering, and for how long.
///
/// The rule is bounded at both ends, which the first version was not: it
/// offered anything starting in under ten minutes, and "starting in under ten
/// minutes" is also true of a meeting that began at nine this morning. The
/// button stayed on the card all day, taking the room the day's own events
/// needed and pointing at a call that had ended.
///
/// Pure and clockless, like the other rules in this folder: the caller passes
/// the times it already has.
public enum MeetingJoin {

    /// How early the link appears. Half an hour is long enough to be somewhere
    /// before it starts, and short enough that a meeting this afternoon is not
    /// treated as news.
    public static let leadTime: TimeInterval = 30 * 60

    /// What a meeting is assumed to run for when its end is unknown — an older
    /// payload, or a source that reports no end. Better a wrong hour than a
    /// button that never leaves.
    public static let assumedLength: TimeInterval = 60 * 60

    /// - Parameters:
    ///   - startsIn: seconds until it starts; negative once it has begun.
    ///   - endsIn: seconds until it ends; negative once it is over, nil when
    ///     unknown.
    ///   - hasLink: whether there is a usable video-call link at all.
    /// - Returns: whether to offer the Join button.
    public static func isOffered(
        startsIn: TimeInterval,
        endsIn: TimeInterval?,
        hasLink: Bool
    ) -> Bool {
        guard hasLink, startsIn <= leadTime else { return false }
        // The end time answers "is this still running" exactly. Without one,
        // an hour from the start stands in.
        if let endsIn { return endsIn > 0 }
        return startsIn > -assumedLength
    }
}

public extension EventPayload {

    /// The link to join this meeting, if it is being offered right now.
    ///
    /// Here rather than in the card, because two layers have to agree about
    /// it. The card draws Join and the camera segment from it; the shell
    /// needs the same answer for a card it cannot see — a readout standing
    /// over the calendar takes the view off screen, and a meeting that ends
    /// behind one would otherwise leave a camera running in a frame whose
    /// only control had gone with the capsule.
    var joinLink: URL? {
        guard hasEvent,
              let link = meetingURL,
              let url = URL(string: link),
              url.scheme != nil,
              MeetingJoin.isOffered(startsIn: startsIn, endsIn: endsIn, hasLink: true)
        else { return nil }
        return url
    }
}
