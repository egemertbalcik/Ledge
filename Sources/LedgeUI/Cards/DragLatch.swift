import Foundation

/// Who currently holds a card's drag latch.
///
/// The latch keeps the notch open while a pointer is down, so a drag that
/// wanders off the shape does not close the card out from under it. Taking it
/// is easy; letting go of it is where this type earns its place.
///
/// A gesture releases the latch in `onEnded`, and a view that is taken off
/// screen mid-drag never gets one. The media card is replaced on every track
/// change, a route row goes away the moment its device is unplugged, and the
/// shell only resets the latch when the notch leaves an open phase — which a
/// card being swapped for another one does not do. So the latch stayed set,
/// and the notch stayed open and swallowing clicks until something unrelated
/// happened to clear it.
///
/// The other half of the problem is the obvious fix making things worse: a
/// disappearing view calling "let go" releases whatever is latched, including
/// a drag that has just begun somewhere else. So a drag is given a token when
/// it takes the latch, and only the holder of the current token can release
/// it. Anyone else saying "let go" is a view that has already been replaced,
/// and is ignored.
@MainActor
public final class DragLatch {

    /// Tokens are handed out in order and never reused, so a stale one cannot
    /// come back round and match by accident.
    private var nextToken = 0

    /// The token of the drag holding the latch, or nil when nothing is.
    private var holder: Int?

    public init() {}

    /// Whether a drag is in flight. Diagnostic — the latch's real effect is on
    /// whatever `apply` is given.
    public var isHeld: Bool { holder != nil }

    /// Takes the latch for a new drag and returns its token.
    ///
    /// A drag beginning while another is still latched takes it over rather
    /// than being refused: a pointer can only be in one place, so the newer
    /// claim is the true one, and the older holder's release is then ignored.
    @discardableResult
    public func begin(_ apply: (Bool) -> Void) -> Int {
        nextToken += 1
        let token = nextToken
        let wasHeld = holder != nil
        holder = token
        if !wasHeld { apply(true) }
        return token
    }

    /// Lets go, if this is still the drag that is holding on.
    public func end(_ token: Int, _ apply: (Bool) -> Void) {
        guard holder == token else { return }
        holder = nil
        apply(false)
    }
}
