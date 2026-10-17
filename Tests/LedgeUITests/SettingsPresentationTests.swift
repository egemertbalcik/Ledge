import LedgeCore
import Testing

@testable import LedgeUI

/// The decisions the settings window makes, checked away from the views that
/// draw them. Each of these was a `switch` inside a `body`, where nobody could
/// see it and no test could reach it.
@Suite("Settings presentation")
struct SettingsPresentationTests {

    // MARK: - Panes

    @Test("Every pane has a name, and no two panes share one")
    func paneNamesAreUniqueAndPresent() {
        var seen: Set<String> = []
        for pane in SettingsPane.allCases {
            #expect(!pane.title.isEmpty, "\(pane) has no name")
            #expect(seen.insert(pane.title).inserted, "two panes are both called \(pane.title)")
        }
    }

    /// The sidebar said "Sound & Brightness", the title bar said "Levels", and
    /// the debug switch wanted "hud" — three names for one pane, kept in step
    /// by hand across three tables.
    @Test("A pane answers to its own name")
    func panesAnswerToTheirNames() {
        for pane in SettingsPane.allCases {
            #expect(SettingsPane.named(pane.rawValue) == pane)
        }
    }

    @Test("The retired pane names still land somewhere sensible")
    func retiredNamesStillWork() {
        // The readout settings moved onto the card they belong to, so the old
        // names open Cards with that card already showing.
        #expect(SettingsPane.named("hud") == .cards)
        #expect(SettingsPane.card(named: "hud") == "levels")
        #expect(SettingsPane.named("levels") == .cards)
        #expect(SettingsPane.named("advanced") == .tuning)
    }

    @Test("A card can be opened by name, and nothing else is mistaken for one")
    func cardSwitch() {
        // Naming a card names the pane it lives in, too.
        #expect(SettingsPane.named("card:weather") == .cards)
        #expect(SettingsPane.card(named: "card:weather") == "weather")
        #expect(SettingsPane.card(named: "general") == nil)
        #expect(SettingsPane.card(named: nil) == nil)
        #expect(SettingsPane.named(nil) == nil)
        #expect(SettingsPane.named("") == nil)
        #expect(SettingsPane.named("nonsense") == nil)
    }

    // MARK: - Card rows

    private func descriptor(
        id: String = "calendar",
        permission: PermissionKind? = .calendars,
        isEnabled: Bool = true,
        isAvailable: Bool = true
    ) -> ProviderDescriptor {
        ProviderDescriptor(
            id: id, displayName: "Calendar", kind: .event, permission: permission,
            isEnabled: isEnabled, isAvailable: isAvailable
        )
    }

    @Test("A card that is on and blocked says what it is waiting for")
    func blockedCardWarns() {
        let row = CardRowPresentation(provider: descriptor(isEnabled: true, isAvailable: false))
        #expect(row.warning == "Needs Calendar access")
    }

    /// A card that is off asks for no permission and does no work, so there is
    /// nothing for it to be waiting for. The pane used to shout "Waiting for
    /// Calendar access" in orange beside a switch the user had deliberately
    /// turned off.
    @Test("A card that is off is waiting for nothing")
    func disabledCardIsSilent() {
        let row = CardRowPresentation(provider: descriptor(isEnabled: false, isAvailable: false))
        #expect(row.warning == nil)
    }

    @Test("A card that needs no permission never warns")
    func permissionlessCardIsSilent() {
        let row = CardRowPresentation(
            provider: descriptor(id: "timer", permission: nil, isAvailable: false)
        )
        #expect(row.warning == nil)
    }

    @Test("Every card has something to say about itself")
    func everyCardHasASummary() {
        let ids = [
            "nowplaying", "battery", "bluetooth", "airpods-proximity", "devicealerts",
            "audioroute", "bluetooth-power", "keyboard", "capslock", "calendar",
            "focus", "weather", "levels", "timer", "shelf", "notes", "privacy",
            "keep-awake",
        ]
        let fallback = CardRowPresentation.summary(for: "something-new")
        for id in ids {
            #expect(
                CardRowPresentation.summary(for: id) != fallback,
                "\(id) falls back to the generic summary"
            )
            #expect(CardGroup.of(id) != .other, "\(id) is not grouped")
        }
    }

    @Test("A card id nobody has placed still appears, in More")
    func unknownCardIsStillPlaced() {
        #expect(CardGroup.of("something-new") == .other)
    }

    // MARK: - Permissions
    //
    // The decision itself moved to `PermissionPresentation` in LedgeCore, so
    // the tour and the settings window cannot disagree about it. These are
    // the same promises, asked of the new door.

    @Test("A granted permission offers nothing")
    func grantedOffersNothing() {
        for kind in PermissionKind.allCases {
            let face = PermissionPresentation.face(kind, status: .granted)
            #expect(face.remedy == nil, "\(kind) offered something after being granted")
        }
    }

    /// TCC will not prompt twice, so the only way back from a refusal is the
    /// System Settings pane.
    @Test("A denied permission sends the user to System Settings")
    func deniedOpensSettings() {
        for kind in PermissionKind.allCases {
            let face = PermissionPresentation.face(kind, status: .denied)
            #expect(face.remedy == .openSettings, "\(kind) offered no way back from a denial")
        }
    }

    /// Accessibility's prompt is a courtesy macOS shows at most once per app;
    /// after it has been dismissed the button did nothing at all, forever.
    @Test("Accessibility is granted in System Settings, not by a prompt")
    func accessibilityGoesToSystemSettings() {
        let face = PermissionPresentation.face(.accessibility, status: .notDetermined)
        #expect(face.remedy == .openSettings)
    }

    @Test("Anything else that has never been asked for is asked for")
    func undeterminedAsks() {
        for kind in PermissionKind.allCases where !kind.isGrantedInSystemSettings {
            let face = PermissionPresentation.face(kind, status: .notDetermined)
            #expect(face.remedy == .ask, "\(kind) would never be asked for")
        }
    }

    /// `isRequestable` is true of every permission, so the guard that was
    /// meant to single out Automation singled out nothing: a Calendar row that
    /// reported "not applicable now" offered to open Music.
    @Test("Only Automation offers to open a player")
    func onlyAutomationOpensAPlayer() {
        for kind in PermissionKind.allCases {
            let face = PermissionPresentation.face(kind, status: .notApplicableNow)
            #expect(
                face.remedy == (kind == .automation ? .openPlayer : nil),
                "\(kind) offered \(String(describing: face.remedy)) for a state only Automation reaches"
            )
        }
    }

    @Test("Nothing is offered for a capability this Mac does not have")
    func unavailableOffersNothing() {
        for kind in PermissionKind.allCases {
            #expect(PermissionPresentation.face(kind, status: .unavailable).remedy == nil)
        }
    }


    @Test("Every remedy that opens something says so")
    func remediesAreLabelled() {
        for remedy in [PermissionRemedy.ask, .openPlayer, .openSettings] {
            #expect(!remedy.label.isEmpty)
            #expect(remedy.label.hasSuffix("…"), "\(remedy) opens something but does not say so")
        }
        // Every remedy there is opens something, now that the relaunch is
        // gone: it was offered for a state nothing can detect, and what it
        // actually appeared after was a *revoked* grant.
        #expect(PermissionRemedy.allCases.count == 3)
    }

    // MARK: - Keep Awake's helper

    private static let helperStates: [KeepAwakeHelperInstallation] =
        [.unsignedBuild, .notInstalled, .needsApproval, .installed]

    @Test("Every helper state says where it stands and what it means")
    func everyHelperStateSpeaks() {
        for state in Self.helperStates {
            let setup = KeepAwakeSetupPresentation(state)
            #expect(!setup.headline.isEmpty, "\(state) has no headline")
            #expect(!setup.detail.isEmpty, "\(state) has no sentence")
        }
    }

    /// The pane was rendering the *card's* sentence, which ends "Settings ›
    /// Keep Awake has it" — telling somebody standing in Settings › Keep Awake
    /// to go to Settings › Keep Awake.
    @Test("The setup pane does not send the reader to the pane they are on")
    func paneDoesNotPointAtItself() {
        for state in Self.helperStates {
            let detail = KeepAwakeSetupPresentation(state).detail
            #expect(
                !detail.contains("Settings › Keep Awake"),
                "\(state) tells the reader to go where they already are"
            )
        }
    }

    @Test("Set Up is offered only where pressing it could work")
    func setUpIsOfferedOnce() {
        for state in Self.helperStates {
            let setup = KeepAwakeSetupPresentation(state)
            #expect(
                setup.offersSetUp == (state == .notInstalled),
                "\(state) offered the wrong setup button"
            )
        }
    }

    /// Anything that runs as root has to be removable from the place it went
    /// in — and removing it is the only way to try the setup again.
    @Test("A helper that exists can be taken back out")
    func removalIsAlwaysOffered() {
        #expect(KeepAwakeSetupPresentation(.installed).offersRemoval)
        #expect(KeepAwakeSetupPresentation(.needsApproval).offersRemoval)
        #expect(!KeepAwakeSetupPresentation(.notInstalled).offersRemoval)
        #expect(!KeepAwakeSetupPresentation(.unsignedBuild).offersRemoval)
    }

    @Test("The way to approve is offered from the state, not only from the press")
    func approvalIsOfferedFromTheState() {
        #expect(KeepAwakeSetupPresentation(.needsApproval).offersApproval)
        #expect(!KeepAwakeSetupPresentation(.installed).offersApproval)
        #expect(!KeepAwakeSetupPresentation(.notInstalled).offersApproval)
    }

    /// macOS refuses before it begins on an unsigned build, and a button that
    /// fails every time teaches people the feature is broken rather than
    /// unavailable.
    @Test("An unsigned build offers no button at all")
    func unsignedBuildOffersNothing() {
        let setup = KeepAwakeSetupPresentation(.unsignedBuild)
        #expect(!setup.offersSetUp)
        #expect(!setup.offersApproval)
        #expect(!setup.offersRemoval)
        #expect(setup.tone == .quiet)
    }

    @Test("Only a working helper reads as good news")
    func onlyInstalledIsGreen() {
        for state in Self.helperStates {
            let tone = KeepAwakeSetupPresentation(state).tone
            #expect((tone == .ok) == (state == .installed), "\(state) reads as the wrong news")
        }
    }
}
