import Foundation

/// What the helper answers a client.
///
/// Every answer that is not `ok` names something the user could act on, which
/// is why there are so many of them: the app turns each one into a sentence on
/// the card, and "it didn't work" is not a sentence anybody can act on.
public enum KeepAwakeHelperCode: Int, Equatable, Sendable, CaseIterable {
    /// The request was accepted and, for a hold, persisted.
    case ok = 0
    /// Sleep is already disabled by somebody who is not Ledge. The daemon
    /// never touches it in this state, and never will until it reads 0 again.
    case foreign = 1
    /// The other Ledge build's daemon holds a live claim on this Mac.
    case inUseByOtherLedge = 2
    /// An older generation than the daemon has already seen for this session,
    /// or a session the daemon has retired. The app must hold again with a new
    /// generation if it still wants one.
    case stale = 3
    /// Too many client requests are already waiting. Holds only; a release is
    /// never refused.
    case busy = 4
    /// The claim store refused the write, so nothing privileged was done.
    case persistFailed = 5
    /// `pmset` refused the change, or the readback contradicted it.
    case pmsetFailed = 6
    /// The session named is not the one being held.
    case notHolder = 7
    /// A malformed session id, a backwards generation, or a deadline later
    /// than the one this session already fixed.
    case invalidArgument = 8
}

/// The XPC contract between Ledge and its root daemon.
///
/// Deliberately tiny, and deliberately dumb. The daemon decides only "may this
/// hold continue" and "is every claim restored"; every policy question — the
/// battery floor, the thermal floor, what the user sees — stays in the app,
/// where it can be changed without shipping new code that runs as root.
///
/// `Int` on the wire rather than the result enum: an `@objc` enum would travel
/// as an `NSInteger` anyway, and keeping the raw value explicit means a future
/// code the client does not know about arrives as a number it can log rather
/// than as a decoding failure.
@objc public protocol KeepAwakeHelperProtocol {

    /// What the daemon believes about this Mac right now. Answered from
    /// memory: a status call never spawns anything.
    ///
    /// - Parameters:
    ///   - build: the daemon's launchd label, which is what tells the debug
    ///     daemon from the release one.
    ///   - sleepDisabled: the last reading, or -1 if it has not read one yet.
    ///   - ours: Ledge holds the claim that explains a reading of 1.
    ///   - clean: no outstanding claim of this daemon's label and nothing in
    ///     flight. Note that this says nothing about `sleepDisabled`: 1 set by
    ///     somebody else is still clean, because it is not Ledge's to undo.
    ///   - cleanupPending: a claim of ours whose restoration has not been
    ///     confirmed. The app keeps the daemon registered while this is true.
    ///   - otherLedgeHolds: the other build's daemon holds a live claim.
    ///   - lowPowerClaimed: a Low Power Mode claim of ours is outstanding.
    ///     Always false until 2b ships; it is in the reply because the shape
    ///     of a reply is the hard thing to change later, not its value.
    func status(reply: @escaping (_ build: String, _ sleepDisabled: Int, _ ours: Bool,
                                  _ clean: Bool, _ cleanupPending: Bool,
                                  _ otherLedgeHolds: Bool, _ lowPowerClaimed: Bool) -> Void)

    /// Takes or renews the hold. Idempotent: this is the heartbeat, sent every
    /// 30 s, and the daemon answers only once the renewal is on disk.
    ///
    /// The first hold of a session fixes its deadline, and a nil deadline
    /// means the hold runs until it is released or the lease lapses. Nothing
    /// a client sends can extend a deadline it has already fixed.
    func hold(session: String, generation: Int, until deadline: Date?,
              leaseSeconds: Double, reply: @escaping (_ code: Int) -> Void)

    /// Ends the hold. Never refused and never queued: everything about a
    /// release moves this Mac towards being allowed to sleep again, so there
    /// is no state in which refusing one is the safer answer.
    func release(session: String, generation: Int, reply: @escaping (_ code: Int) -> Void)

    /// Turns Low Power Mode on for as long as the hold lasts, or gives it back.
    ///
    /// ## Why this is worth a privileged call at all
    ///
    /// Low Power Mode throttles the CPU, and throttling the CPU is exactly
    /// what you would not want for a Mac left running work. The agents this
    /// feature exists for are network-bound — Claude Code, Codex, a long sync
    /// — and spend almost all of their time waiting on a socket, not on a
    /// clock. So the throttle costs them close to nothing and the battery
    /// saving is real, which is the whole reason this is here and not in the
    /// list of things deliberately not copied.
    ///
    /// Same lease and generation rules as `hold`, and the same ordering: the
    /// prior value is journalled into the claim before anything is written,
    /// and the claim is cleared only after a readback agrees. **The prior is
    /// the point.** A user who had Low Power Mode on themselves — or on for
    /// battery only, which System Settings offers and people pick — must have
    /// it exactly that way when the session ends. A restore that could not
    /// tell "we turned it on" from "it was already on" would switch off
    /// something they chose.
    ///
    /// Answered as soon as the request is accepted, like `release` and unlike
    /// `hold`: the write happens behind the same one-at-a-time lock the sleep
    /// setting uses, and a client that waited for it would be waiting on a
    /// `pmset` child for no decision of its own. Whether it landed is what
    /// `status`'s `lowPowerClaimed` is for.
    ///
    /// - Parameters:
    ///   - on: true while the hold should carry Low Power Mode; false to put
    ///     the setting back the way it was found.
    func setLowPowerMode(_ on: Bool, session: String, generation: Int,
                         reply: @escaping (_ code: Int) -> Void)
}
