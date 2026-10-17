import Foundation
import Testing

@testable import LedgeCore

/// What the lid-closed mode says, and when it says nothing.
///
/// The daemon answers in numbers. These are about the one thing the app owes
/// the user in exchange: a sentence per answer, each one naming something that
/// could be done about it. "It didn't work" is not a sentence anybody can act
/// on, and a feature that holds a Mac awake with its lid shut has fewer places
/// than most to hide a vague one.
@Suite("Keep Awake, lid closed")
struct KeepAwakeLidTests {

    private static let everyState: [KeepAwakeLidState] =
        [.unsignedBuild, .notInstalled, .needsApproval, .unreachable, .off, .holding, .unconfirmed]
            + KeepAwakeLidCode.allCases.map { .refused($0) }

    // MARK: - The nine codes

    /// Eight refusals, one `ok`. The protocol's own note says each one names
    /// something the user could act on; this is the half of that promise the
    /// app has to keep.
    @Test("Every refusal has a sentence of its own")
    func everyRefusalSpeaks() {
        var seen: Set<String> = []
        for code in KeepAwakeLidCode.allCases {
            let sentence = KeepAwakeCopy.lidRefused(code)
            #expect(!sentence.isEmpty, "\(code) says nothing")
            #expect(sentence.count > 30, "\(code) says too little to act on: \(sentence)")
            #expect(sentence.hasSuffix("."), "\(code) is not a sentence: \(sentence)")
            #expect(seen.insert(sentence).inserted,
                    "\(code) shares its sentence with another refusal")
        }
        #expect(seen.count == 8, "the daemon has eight ways to say no")
    }

    /// Somebody else set it, and Ledge will not take it back. The sentence has
    /// to say both without blaming anyone — the user may well have set it
    /// themselves, in another app, on purpose.
    @Test("Foreign says who it isn't, and that Ledge will leave it alone")
    func foreignBlamesNobody() {
        let sentence = KeepAwakeCopy.lidRefused(.foreign)
        #expect(sentence.contains("Ledge didn't set that"))
        #expect(sentence.lowercased().contains("won't change it"))
        // Somewhere to go and look. A refusal that names no suspect leaves the
        // user to hunt through every app they have ever installed.
        #expect(sentence.contains("pmset") || sentence.lowercased().contains("another app"))
    }

    @Test("The other build is named as the other build, not as a stranger")
    func otherLedgeIsNamed() {
        #expect(KeepAwakeCopy.lidRefused(.inUseByOtherLedge).contains("other build of Ledge"))
    }

    // MARK: - Silence is not failure

    /// The whole of `temporarilyUnavailable`. The daemon drops a hold on its
    /// own lease, not on Ledge's inability to reach it, so an unanswered
    /// heartbeat means "probably still held, we just cannot confirm". A card
    /// that reported it as a failure would be telling the user their Mac is
    /// about to sleep when it almost certainly is not — and the one thing they
    /// would do about that is open the lid, which is what the mode exists to
    /// spare them.
    @Test("An unconfirmed hold is still a hold")
    func unconfirmedIsLive() {
        #expect(KeepAwakeLidState.unconfirmed.isLive)
        #expect(!KeepAwakeLidState.unconfirmed.isRefusal)
    }

    @Test("The unconfirmed sentence does not announce an ending")
    func unconfirmedDoesNotAlarm() {
        let sentence = KeepAwakeCopy.lidUnconfirmed.lowercased()
        for alarm in ["failed", "lost", "ended", "stopped", "will sleep", "about to sleep"] {
            #expect(!sentence.contains(alarm),
                    "the unconfirmed sentence reports a failure that has not happened: \(alarm)")
        }
        #expect(sentence.contains("still stands"), "it has to say the hold is probably fine")
        #expect(sentence.contains("still trying"), "and that Ledge has not given up")
    }

    // MARK: - What may be offered

    /// A button that cannot work is worse than no button: it costs a press and
    /// teaches the user the feature is broken rather than unavailable.
    @Test("Only a refusal that could go differently is worth a second press")
    func retryOnlyWhereItCouldWork() {
        #expect(!KeepAwakeLidCode.foreign.isWorthRetrying)
        #expect(!KeepAwakeLidCode.inUseByOtherLedge.isWorthRetrying)
        for code in KeepAwakeLidCode.allCases
        where code != .foreign && code != .inUseByOtherLedge {
            #expect(code.isWorthRetrying, "\(code) is bad luck, not a standing fact")
        }
    }

    @Test("Arming is offered only where it could take")
    func armingIsOfferedHonestly() {
        #expect(KeepAwakeLidState.off.mayArm)
        #expect(!KeepAwakeLidState.holding.mayArm, "it is already on")
        #expect(!KeepAwakeLidState.unconfirmed.mayArm, "it is already on, probably")
        #expect(!KeepAwakeLidState.notInstalled.mayArm)
        #expect(!KeepAwakeLidState.unsignedBuild.mayArm)
        #expect(!KeepAwakeLidState.refused(.foreign).mayArm)
        #expect(!KeepAwakeLidState.refused(.inUseByOtherLedge).mayArm)
        #expect(KeepAwakeLidState.refused(.busy).mayArm)
        #expect(KeepAwakeLidState.refused(.pmsetFailed).mayArm)
    }

    @Test("Nothing is both live and offerable")
    func liveIsNeverOfferable() {
        for state in Self.everyState {
            #expect(!(state.isLive && state.mayArm),
                    "\(state) would offer to start something already running")
        }
    }

    // MARK: - What the card says

    @Test("Off says nothing, so the standing line stands")
    func offIsSilent() {
        #expect(KeepAwakeCopy.lid(.off) == nil)
    }

    @Test("Every other state says something")
    func everyOtherStateSpeaks() {
        for state in Self.everyState where state != .off {
            let sentence = KeepAwakeCopy.lid(state)
            #expect(sentence?.isEmpty == false, "\(state) has nothing to say")
        }
    }

    /// The press that cannot start anything is the press that most has to say
    /// something, and this is what makes that true by construction rather than
    /// by the card remembering to.
    ///
    /// The card keeps a slot for this sentence that nothing else can occupy,
    /// and pressing Lid closed in a state that cannot arm fills it. That only
    /// works if there is always a sentence to put there — so: anything that
    /// cannot arm has a reason, and the only state with no reason is the one
    /// that can. A previous build had the two collapsed into one line shared
    /// with the ready card's failure sentence, and a standing failure from an
    /// earlier session took the line, dropped the reason, and left the button
    /// doing nothing visible at all.
    @Test("Anything that cannot arm has a reason to give")
    func refusalAlwaysExplains() {
        for state in Self.everyState {
            if state.mayArm || state.isLive { continue }
            #expect(KeepAwakeCopy.lid(state)?.isEmpty == false,
                    "\(state) cannot arm and cannot say why")
        }
        // And the converse, which is what stops the rule above from being
        // satisfied by giving every state a sentence: off is the one state
        // with nothing to explain, and it is offerable.
        #expect(KeepAwakeLidState.off.mayArm)
        #expect(KeepAwakeCopy.lid(.off) == nil)
    }

    /// A running card is about this session. "Not set up" and "this build
    /// can't" are about the app, and a session that is running was plainly
    /// started without either being in the way.
    @Test("Only this session's states belong on a running card")
    func runningCardIsAboutThisSession() {
        #expect(KeepAwakeLidState.holding.belongsOnARunningCard)
        #expect(KeepAwakeLidState.unconfirmed.belongsOnARunningCard)
        #expect(KeepAwakeLidState.refused(.pmsetFailed).belongsOnARunningCard)
        #expect(!KeepAwakeLidState.off.belongsOnARunningCard)
        #expect(!KeepAwakeLidState.notInstalled.belongsOnARunningCard)
        #expect(!KeepAwakeLidState.unsignedBuild.belongsOnARunningCard)
    }

    /// `SMAppService` will not register a daemon from an ad-hoc signature, so
    /// this is a fact about the build rather than a failure to retry.
    @Test("The unsigned build is told the truth about itself")
    func unsignedBuildIsHonest() {
        #expect(!KeepAwakeLidState.unsignedBuild.isInstallable)
        #expect(KeepAwakeLidState.notInstalled.isInstallable)
        let sentence = KeepAwakeCopy.lidUnsignedBuild
        #expect(sentence.contains("isn't signed"))
        #expect(sentence.contains("release build"), "it has to name what would work")
    }

    // MARK: - The menu-bar item

    /// With the lid shut and an external display attached, the built-in panel
    /// is off — so the notch, which is the whole of Ledge's UI, does not
    /// exist. Without this item the user has no feedback that their Mac is
    /// being held awake and no way to stop it without opening the lid.
    @Test("There is an item exactly while there is something to end")
    func theItemFollowsTheHold() {
        // `isLive` was the rule and it was the wrong question. The item is
        // not a status light, it is the *only* way to end a hold once the lid
        // is down — so it has to follow whether there may be something to
        // end, which is not the same as whether the daemon last said yes.
        // A renewal answered `busy` leaves the lease it refused to renew
        // standing, and the item vanished over a Mac that was being held.
        for state in Self.everyState {
            let badge = KeepAwakeLidBadge.badge(for: state, remaining: "2h 14m")
            #expect((badge != nil) == state.needsAWayOut,
                    "\(state): the menu-bar item does not follow what there is to end")
        }
        // The four that mean nothing was ever asked for, spelled out, so a
        // state added to the enum has to be thought about rather than
        // inheriting an answer.
        for state: KeepAwakeLidState in [.off, .notInstalled, .needsApproval, .unsignedBuild] {
            #expect(KeepAwakeLidBadge.badge(for: state, remaining: nil) == nil,
                    "\(state.name): an item for a hold nobody asked for")
        }
        for state: KeepAwakeLidState in [.holding, .unconfirmed, .applying, .cannotTell,
                                         .unreachable, .refused(.busy), .refused(.foreign)] {
            #expect(KeepAwakeLidBadge.badge(for: state, remaining: nil) != nil,
                    "\(state.name): no way out of a hold that may be standing")
        }
    }

    @Test("Only a confirmed hold is announced as covering the lid")
    func onlyConfirmedPromisesTheLid() {
        // The item exists for every state above; what it *says* is a
        // different question. Promising "awake with the lid shut" over an
        // unconfirmed or refused renewal is the one overclaim that could cost
        // somebody their work, because the menu bar is what they are looking
        // at when the lid is already down.
        let confirmed = KeepAwakeLidBadge.badge(for: .holding, remaining: "2h 14m")
        #expect(confirmed?.headline == KeepAwakeCopy.lidMenuHeadline(remaining: "2h 14m"))
        for state: KeepAwakeLidState in [.cannotTell, .unreachable,
                                         .refused(.busy), .refused(.foreign)] {
            let badge = KeepAwakeLidBadge.badge(for: state, remaining: "2h 14m")
            #expect(badge?.headline == KeepAwakeCopy.lidMenuHeadlineCannotTell,
                    "\(state.name) promised the lid was covered")
        }
    }

    @Test("The item can always end the hold")
    func theItemCanEndIt() {
        let badge = KeepAwakeLidBadge.badge(for: .holding, remaining: "2h 14m")
        #expect(badge?.endTitle.isEmpty == false)
        // Named for the whole act: from the menu bar there is no card nearby
        // to make a bare "End" mean anything in particular.
        #expect(badge?.endTitle.lowercased().contains("sleep") == true)
    }

    @Test("The item says how long is left, and what it is")
    func theItemSaysWhatAndHowLong() {
        let badge = KeepAwakeLidBadge.badge(for: .holding, remaining: "2h 14m")
        #expect(badge?.headline.contains("2h 14m") == true)
        #expect(badge?.headline.lowercased().contains("lid") == true)
        #expect(badge?.spoken.isEmpty == false, "a symbol says nothing aloud")
    }

    /// The silence is said in the menu, where there is room for it, rather
    /// than drawn as a different icon that would read as a different feature.
    @Test("An unconfirmed hold explains itself in the menu")
    func unconfirmedExplainsItself() {
        let holding = KeepAwakeLidBadge.badge(for: .holding, remaining: "2h 14m")
        let quiet = KeepAwakeLidBadge.badge(for: .unconfirmed, remaining: "2h 14m")
        #expect(holding?.detail == nil, "nothing is wrong, so nothing is said")
        #expect(quiet?.detail == KeepAwakeCopy.lidUnconfirmed)
        #expect(holding?.symbolName == quiet?.symbolName,
                "two glyphs would read as two features at the size a menu bar draws them")
    }

    @Test("A hold with nothing counting down still has a headline")
    func openEndedStillSpeaks() {
        let badge = KeepAwakeLidBadge.badge(for: .holding, remaining: nil)
        #expect(badge?.headline == KeepAwakeCopy.lidMenuHeadlineOpenEnded)
    }

    // MARK: - The payload

    @Test("A payload with no lid state says nothing about the lid")
    func payloadDefaultsToNotInstalled() {
        #expect(KeepAwakePayload(phase: .ready).lid == .notInstalled)
    }
}
