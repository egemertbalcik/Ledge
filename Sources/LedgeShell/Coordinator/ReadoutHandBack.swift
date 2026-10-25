import Foundation
import LedgeCore

/// Hands an open card back as soon as the pointer is on the card rather than
/// on the level readout standing in front of it.
///
/// A readout under the pointer is held open so its slider can be reached for.
/// A pointer on the card around it is reaching for nothing, so the hold has no
/// reason to stand — and since the card's region keeps that pointer "inside"
/// (`ReadoutOverCard`), no exit would ever come to end it. So, while a readout
/// is held over a card, this looks four times a second.
///
/// Its own type because its lifetime is the hard part, and each rule here was
/// a bug found by review:
///
/// - A new key press starts a new readout with its own duration. A look that
///   was already queued must not retire it early, so a request cancels the
///   watch; it starts again only once that readout is held in its turn.
/// - With the screens dark the pointer is not tracked, so nothing could end
///   the watch, and it would poll for as long as the Mac stayed locked. It
///   stops on dormancy, never reschedules while dark, and comes back on wake
///   only if a readout is still held over a card.
/// - A readout whose timeout comes mid-drag is held all the same, and is
///   watched from then on: the looks refuse to release while the slider is
///   being dragged, and hand back once it is let go. Refusing to start the
///   watch then left nothing to end the hold after the drag.
/// - Only a readout that has actually reached its hold is watched again on
///   wake. One still inside its own duration looks the same, and waking used
///   to hand it back the moment the screens came on.
/// - It stops with the coordinator.
@MainActor
final class ReadoutHandBack {

    /// How often a held readout is looked at.
    let interval: TimeInterval

    private let state: () -> NotchState
    private let isAdjusting: () -> Bool
    private let handsBack: () -> Bool
    private let release: () -> Void

    private var pending: DispatchWorkItem?
    private var dormant = false
    /// Whether the readout now up has reached its hold — its timeout, or a
    /// hover, came while it stood over a card. Kept through dormancy; a new
    /// request starts again without one.
    private var holdEstablished = false

    /// How many looks have run. For the tests, which have to know a look
    /// really happened before asserting what it did.
    private(set) var looks = 0

    var isWatching: Bool { pending != nil }

    init(
        interval: TimeInterval = 0.25,
        state: @escaping () -> NotchState,
        isAdjusting: @escaping () -> Bool,
        handsBack: @escaping () -> Bool,
        release: @escaping () -> Void
    ) {
        self.interval = interval
        self.state = state
        self.isAdjusting = isAdjusting
        self.handsBack = handsBack
        self.release = release
    }

    /// Whether a readout is held up over a card under the pointer — the only
    /// state there is anything to watch in.
    static func isHeldOverCard(_ state: NotchState) -> Bool {
        state.phase == .hud && state.isHovering && ReadoutOverCard.coversCard(state)
    }

    /// Follows the reducer, after each event has been applied.
    func follow(_ event: NotchEvent) {
        switch event {
        case .hudRequested:
            // A new readout: whatever was queued belonged to the old one, and
            // this one has not been held yet.
            cancel()
            holdEstablished = false
        case .timerFired(.hud), .hoverChanged(true):
            // The two ways a readout comes to be held under the pointer. A
            // drag in progress does not stop the watch starting: the looks
            // will not release until the drag ends.
            if Self.isHeldOverCard(state()) {
                holdEstablished = true
                start()
            }
        default:
            break
        }
    }

    /// The screens went dark, or came back.
    func setDormant(_ dark: Bool) {
        dormant = dark
        if dark {
            cancel()
        } else if holdEstablished, Self.isHeldOverCard(state()) {
            start()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func start(after delay: TimeInterval = 0) {
        cancel()
        guard !dormant else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.look() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func look() {
        pending = nil
        guard !dormant, Self.isHeldOverCard(state()) else { return }
        looks += 1
        if !isAdjusting(), handsBack() {
            release()
            return
        }
        start(after: interval)
    }
}
