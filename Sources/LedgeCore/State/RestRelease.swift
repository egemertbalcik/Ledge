import Foundation

/// Whether a rest whose time is up is free to end yet.
///
/// A paused track holds the island for its linger, and a level readout that
/// appears beside it is a *guest* of that rest. When the linger ran out
/// underneath the guest, the track vanished mid-readout and the next press of
/// the brightness key — finding no companion left to sit beside — drew the
/// readout across the whole compact view instead. One press of one key, two
/// entirely different notches.
///
/// So a rest with a guest beside it waits. What waits is always something
/// already living on borrowed time — a linger, a paused timer's grace — and
/// every guest is short-lived by construction, so the wait is seconds. A
/// standing neighbour, like a running timer beside the music, is not a guest
/// and holds nothing open: it would keep the track for its whole session.
public struct RestRelease: Equatable, Sendable {

    /// Whether a release is owed as soon as the island is the rest's alone.
    public private(set) var isPending = false

    public init() {}

    /// The rest's time is up. Answers whether it may end now; `false` means it
    /// has been deferred and `flush` will report it later.
    public mutating func release(hasGuest: Bool) -> Bool {
        guard hasGuest else {
            isPending = false
            return true
        }
        isPending = true
        return false
    }

    /// Something changed on the island. Answers whether a deferred release may
    /// now go through.
    ///
    /// `force` is the backstop for a guest that never leaves: nothing should
    /// be able to hold a finished rest open indefinitely.
    public mutating func flush(hasGuest: Bool, force: Bool = false) -> Bool {
        guard isPending, force || !hasGuest else { return false }
        isPending = false
        return true
    }

    /// Forgets a deferred release: the fact it was waiting on has been
    /// replaced by a newer one, which brings its own lifetime.
    public mutating func cancel() {
        isPending = false
    }
}
