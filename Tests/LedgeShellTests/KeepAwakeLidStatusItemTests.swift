import AppKit
import Foundation
import LedgeCore
import ServiceManagement
import Testing

@testable import LedgeShell

/// The menu-bar item a lid-closed hold puts up.
///
/// Nothing here touches `NSStatusBar`. Putting a real item in a real menu bar
/// to find out what it does would be a test suite making itself visible on
/// somebody's Mac, so the two decisions worth checking are made by code that
/// needs no status bar to make them: what a new reading means for the item
/// that is already there, and what the menu actually offers.
@MainActor
@Suite("The lid-closed menu-bar item")
struct KeepAwakeLidStatusItemTests {

    private static func badge(_ remaining: String = "2h 14m",
                              state: KeepAwakeLidState = .holding) -> KeepAwakeLidBadge {
        KeepAwakeLidBadge.badge(for: state, remaining: remaining)!
    }

    // MARK: - When there is an item at all

    @Test("A hold that starts draws an item")
    func holdDrawsAnItem() {
        #expect(KeepAwakeLidStatusItem.plan(from: nil, to: Self.badge())
            == .draw(Self.badge()))
    }

    @Test("A hold that ends takes it away")
    func endTakesItAway() {
        #expect(KeepAwakeLidStatusItem.plan(from: Self.badge(), to: nil) == .remove)
    }

    @Test("Nothing to nothing is nothing")
    func nothingStaysNothing() {
        #expect(KeepAwakeLidStatusItem.plan(from: nil, to: nil) == .nothing)
    }

    /// The publish path fires once a minute for the whole of a session that
    /// may run for days. Rebuilding an unchanged item makes it jump in the
    /// menu bar, and rebuilding its menu underneath an open one closes it.
    @Test("An unchanged reading leaves the item exactly where it is")
    func unchangedIsLeftAlone() {
        #expect(KeepAwakeLidStatusItem.plan(from: Self.badge(), to: Self.badge()) == .nothing)
    }

    @Test("A countdown that has moved redraws it")
    func movedCountdownRedraws() {
        #expect(KeepAwakeLidStatusItem.plan(from: Self.badge("2h 14m"), to: Self.badge("2h 13m"))
            == .draw(Self.badge("2h 13m")))
    }

    /// A daemon that goes quiet mid-session must not take the item away — the
    /// hold is almost certainly still standing — but the menu now has
    /// something extra to say, so the item is redrawn rather than left.
    @Test("A hold that becomes unconfirmed keeps its item and gains a sentence")
    func unconfirmedKeepsTheItem() {
        let quiet = Self.badge(state: .unconfirmed)
        let change = KeepAwakeLidStatusItem.plan(from: Self.badge(), to: quiet)
        #expect(change == .draw(quiet))
        #expect(change != .remove, "the user would be told the hold had ended, which it has not")
    }

    // MARK: - What the menu offers

    /// The whole point of the item. With the lid shut and an external display
    /// attached there is no notch, so this menu is the only way to stop a Mac
    /// being held awake short of opening the lid.
    @Test("The menu can end the hold")
    func theMenuEndsTheHold() {
        var ended = 0
        let item = KeepAwakeLidStatusItem(end: { ended += 1 })
        let menu = item.menu(for: Self.badge())
        let ending = menu.items.last
        #expect(ending?.title == Self.badge().endTitle, "the menu's last item is not the verb")
        if let ending, let action = ending.action, let target = ending.target as? NSObject {
            target.perform(action)
        }
        #expect(ended == 1, "the menu's one verb did nothing")
    }

    /// A coffee cup in the menu bar explains nothing on its own. The sentence
    /// comes first, and it is not pressable, because it is not a command.
    @Test("The menu says what it is before it offers to stop it")
    func theMenuSaysWhatItIs() {
        let item = KeepAwakeLidStatusItem(end: {})
        let menu = item.menu(for: Self.badge())
        #expect(menu.items.first?.title == Self.badge().headline)
        #expect(menu.items.first?.isEnabled == false)
        #expect(menu.items.first?.action == nil)
    }

    @Test("A hold nobody can confirm says so in the menu, where there is room")
    func unconfirmedSaysSoInTheMenu() {
        let item = KeepAwakeLidStatusItem(end: {})
        let titles = item.menu(for: Self.badge(state: .unconfirmed)).items.map(\.title)
        #expect(titles.contains(KeepAwakeCopy.lidUnconfirmed))
        let plain = item.menu(for: Self.badge()).items.map(\.title)
        #expect(!plain.contains(KeepAwakeCopy.lidUnconfirmed),
                "a hold that is fine was reported as one that might not be")
    }
}

/// What the app may believe about the helper, before it believes anything.
///
/// The three system calls behind this answer differently on every Mac and in
/// a test bundle answer about the test runner, so what is pinned here is the
/// order they are read in — which is the part that is a decision rather than
/// a reading.
@MainActor
@Suite("Whether the lid-closed helper could be here")
struct KeepAwakeHelperInstallTests {

    /// Asking `SMAppService` about a build macOS will not register is asking a
    /// question whose answer cannot matter, and reporting "not set up" would
    /// invite a press that can never work.
    @Test("A build macOS won't register is said to be unsignable, not unset")
    func unsignedOutranksEverything() {
        var asked = 0
        let reading = KeepAwakeHelperInstall.reading(
            isDistributable: false,
            hasDaemonPlist: { asked += 1; return true },
            registration: { asked += 1; return .enabled }
        )
        #expect(reading == .unsignedBuild)
        #expect(asked == 0, "a build that cannot install was asked about installing")
    }

    @Test("A bundle with no daemon in it has nothing to register")
    func noPlistIsNotInstalled() {
        var registered = 0
        let reading = KeepAwakeHelperInstall.reading(
            isDistributable: true,
            hasDaemonPlist: { false },
            registration: { registered += 1; return .enabled }
        )
        #expect(reading == .notInstalled)
        #expect(registered == 0, "launchd was asked about a daemon that is not in the bundle")
    }

    /// Only an enabled daemon is set up: one waiting for approval holds
    /// nothing, and saying it was set up would promise a hold that cannot
    /// happen.
    @Test("Only an enabled daemon counts as set up")
    func onlyEnabledCounts() {
        #expect(KeepAwakeHelperInstall.reading(isDistributable: true, hasDaemonPlist: { true },
                                               registration: { .enabled }) == .installed)
        for other: SMAppService.Status in [.notRegistered, .notFound, .requiresApproval] {
            #expect(KeepAwakeHelperInstall.reading(isDistributable: true, hasDaemonPlist: { true },
                                                   registration: { other }) != .installed,
                    "a status other than enabled was taken as set up")
        }
    }

    /// The state this whole distinction exists for. Waiting for approval needs
    /// something different from the user than not being set up does — and
    /// folded together, somebody who had just pressed Set Up was told to go
    /// and press Set Up.
    @Test("Waiting for approval is its own answer, not 'not set up'")
    func approvalIsItsOwnState() {
        #expect(KeepAwakeHelperInstall.reading(isDistributable: true, hasDaemonPlist: { true },
                                               registration: { .requiresApproval }) == .needsApproval)
        #expect(KeepAwakeHelperInstall.reading(isDistributable: true, hasDaemonPlist: { true },
                                               registration: { .notRegistered }) == .notInstalled)
    }

    /// And the sentences differ, which is the whole point of the state.
    @Test("Each state says something different to do")
    func eachStateSaysSomethingDifferent() {
        let said = [KeepAwakeHelperInstallation.unsignedBuild, .notInstalled,
                    .needsApproval, .installed].map(KeepAwakeCopy.lidInstallation)
        #expect(Set(said).count == said.count, "two states say the same thing: \(said)")
        #expect(KeepAwakeCopy.lidInstallation(.needsApproval).contains("Login Items"),
                "the approval sentence does not name where to go")
    }
}
