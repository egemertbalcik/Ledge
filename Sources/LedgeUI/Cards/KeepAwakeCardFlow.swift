import LedgeCore

/// What the Keep Awake card is in the middle of.
///
/// Pulled out of the view as a value, because the bug it exists to prevent is
/// not visible in a rendered card and cannot be reached by drawing one.
///
/// The card has two faces — two switches, or the question the lid-closed mode
/// asks — and swapping between them is not an event. It used to be: the
/// resting face carried `.onDisappear { isAsking = false }`, meant for the
/// card being dismissed, and the resting face also disappears the instant the
/// question replaces it. So pressing Lid closed set the flag, the face it was
/// pressed on went away, its handler cleared the flag, and the question
/// vanished in the same frame it arrived. From the outside: a dead switch that
/// flickers.
///
/// The fix is this type's shape rather than a line in the view. There is no
/// `faceChanged()` here to call by mistake. The only thing that resets the
/// card is the card going away.
struct KeepAwakeCardFlow: Equatable, Sendable {

    /// Whether the card is asking how long the lid-closed hold should run.
    ///
    /// Nothing is held while this is true. The first press turns the card into
    /// the question; the second answers it.
    private(set) var isAsking = false

    /// Whether the user reached for the lid-closed mode and was told why it
    /// cannot start. Held here rather than in the payload because it is a fact
    /// about this reading of this card — it goes when the card does.
    private(set) var showsLidNote = false

    /// The seeded values are for tests and the state gallery, which have to
    /// photograph a card mid-question without a pointer to press it with.
    /// Which reading the card is waiting on.
    ///
    /// Every lid press starts a read of the daemon, and reads come back in
    /// whatever order they finish. Two presses, a cancel, and the second
    /// read's answer reopened a question the user had just dismissed. Only the
    /// newest press may act on its answer, and cancelling or leaving retires
    /// the ticket so no answer in flight can act at all.
    private var ticket = 0

    init(isAsking: Bool = false, showsLidNote: Bool = false) {
        self.isAsking = isAsking
        self.showsLidNote = showsLidNote
    }

    /// What the card shows, with the bookkeeping left out.
    ///
    /// The ticket counter is not state the user can see — two cards showing
    /// the same thing having asked the daemon a different number of times are
    /// the same card — so it stays out of what the tests compare. Equality on
    /// the whole value would make every transition look non-idempotent for a
    /// reason nobody could observe.
    struct Appearance: Equatable, Sendable {
        var isAsking: Bool
        var showsLidNote: Bool
        var hovering: Int?
    }

    var appearance: Appearance {
        Appearance(isAsking: isAsking, showsLidNote: showsLidNote, hovering: hovering)
    }

    /// Takes a ticket for a press that is about to go and ask the daemon.
    mutating func beganAsking() -> Int {
        ticket += 1
        return ticket
    }

    /// Whether an answer that has just come back is still the one being
    /// waited for.
    func isCurrent(_ ticket: Int) -> Bool { ticket == self.ticket }

    /// Which stop the pointer or the keyboard is resting on, if any.
    ///
    /// View-local in every sense — it never outlives the card — but it lives
    /// here with the rest of what the card is in the middle of, because the
    /// preview it drives shares a line with the consequence sentence and the
    /// two must not both try to own it.
    private(set) var hovering: Int?

    mutating func hovered(_ stop: Int?) { hovering = stop }

    /// The lid stop was pressed, and `lid` is what the daemon answered
    /// *after* being asked again — not the reading the card happened to be
    /// drawn with. Deciding on the stale one is how the press straight after
    /// approving the helper in System Settings still said "not set up".
    mutating func pressedLidSwitch(answer lid: KeepAwakeLidState, ticket: Int? = nil) {
        // An answer to a press that has been superseded, cancelled or left
        // behind changes nothing. It was already acted on, or deliberately
        // abandoned.
        if let ticket, !isCurrent(ticket) { return }
        if lid.mayArm {
            showsLidNote = false
            isAsking = true
        } else {
            // The question is not opened, and the reason is put on the card.
            // Leaving `isAsking` alone rather than clearing it: a press that
            // cannot arm must not close a question somebody is already
            // answering.
            showsLidNote = true
        }
    }

    /// The question was answered, and a hold asked for.
    mutating func answeredQuestion() {
        ticket += 1
        isAsking = false
        showsLidNote = false
    }

    /// The question was dismissed with "never mind".
    mutating func cancelledQuestion() {
        ticket += 1
        isAsking = false
    }

    /// A running lid-closed hold was switched off. The hold becomes a plain
    /// one; there is nothing to ask and nothing to explain.
    mutating func droppedLidHold() {
        showsLidNote = false
    }

    /// A stop was pressed that is not the lid question.
    ///
    /// Clears the explanation, which was about a press that is no longer the
    /// last thing the user did — and retires the read the lid press was
    /// waiting on. Without that, pressing Off and then having a refresh come
    /// back a second later opened the length question over a card that was
    /// already finished: the user's last word was Off, and a read they had
    /// moved past reopened a form.
    mutating func movedToAnotherStop() {
        showsLidNote = false
        ticket += 1
    }

    /// The card itself went away — swiped past, dismissed, the notch closed.
    ///
    /// The one event that resets everything, and the only one. A card that
    /// comes back comes back resting rather than half-asked, and without a
    /// sentence somebody asked for a reading ago.
    mutating func cardWentAway() {
        ticket += 1
        hovering = nil
        isAsking = false
        showsLidNote = false
    }
}
