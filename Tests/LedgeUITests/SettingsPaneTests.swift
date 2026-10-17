import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// The window's own shape: which panes exist, what the debug switch means,
/// and what the sidebar counts.
@Suite("The settings window's panes")
@MainActor
struct SettingsPaneTests {

    @Test("Five panes for everyone, and one more for tuning")
    func thePanes() {
        #expect(SettingsPane.everyday == [.general, .cards, .keepAwake, .devices, .permissions])
        #expect(SettingsPane.tuningPanes == [.tuning])
        // Nothing is in both lists, and nothing is in neither: a pane that
        // exists and is unreachable is a pane nobody can find.
        let listed = Set(SettingsPane.everyday + SettingsPane.tuningPanes)
        #expect(listed == Set(SettingsPane.allCases))
    }

    @Test("Every pane has a name")
    func namesExist() {
        for pane in SettingsPane.allCases {
            #expect(!pane.title.isEmpty)
        }
    }

    @Test("The retired pane names still open something sensible")
    func retiredNames() {
        // Habits and shell scripts outlive panes. About folded into General,
        // the two tuning panes folded into Tuning, and the readout settings
        // moved onto a card's page.
        #expect(SettingsPane.named("about") == .general)
        #expect(SettingsPane.named("appearance") == .tuning)
        #expect(SettingsPane.named("compact") == .tuning)
        #expect(SettingsPane.named("advanced") == .tuning)
        #expect(SettingsPane.named("hud") == .cards)
        #expect(SettingsPane.card(named: "hud") == "levels")
        // And the new one, by either spelling.
        #expect(SettingsPane.named("keep-awake") == .keepAwake)
        #expect(SettingsPane.named("keepawake") == .keepAwake)
    }

    @Test("Naming the Keep Awake card opens its pane, not the card list")
    func keepAwakeCardOpensItsPane() {
        // Its settings are a pane now, so `card:keep-awake` has to land
        // there; pushing a page that no longer exists showed an empty Cards.
        #expect(SettingsPane.named("card:keep-awake") == .keepAwake)
        #expect(SettingsPane.named("card:weather") == .cards)
        #expect(SettingsPane.card(named: "card:weather") == "weather")
    }

    @Test("Nonsense opens nothing")
    func nonsense() {
        #expect(SettingsPane.named(nil) == nil)
        #expect(SettingsPane.named("") == nil)
        #expect(SettingsPane.named("wherever") == nil)
    }

    @Test("The model counts what is waiting, and only what the person can move")
    func waitingCount() {
        let model = SettingsModel()
        model.permissions = [
            PermissionRow(kind: .calendars, status: .notDetermined),
            PermissionRow(kind: .bluetooth, status: .denied),
            PermissionRow(kind: .location, status: .restricted),
            PermissionRow(kind: .automation, status: .granted),
        ]
        #expect(model.waitingOnYou == 2, "a managed Mac and a granted permission are nobody's homework")

        // A grant stays granted. The "not in effect" face was withdrawn:
        // the status and the probe are the same reading, so the combination
        // it needed was unreachable, and what it produced instead was a
        // relaunch offered after a revocation.
        model.permissions.append(PermissionRow(kind: .accessibility, status: .granted))
        model.accessibilityIsInEffect = false
        #expect(model.waitingOnYou == 2)
    }

    @Test("A wait for System Settings ends when Ledge is active again")
    func comingBackEndsTheWait() {
        // Found by review: a refusal opened System Settings, the person came
        // back without touching the switch, and the row went on saying
        // "Waiting for you in System Settings…" — with no button — for the
        // rest of the app's life, because the wait only ended on a status
        // change.
        let model = SettingsModel()
        model.permissions = [PermissionRow(kind: .bluetooth, status: .denied)]
        model.beganWaiting(for: .bluetooth, on: .systemSettings, saying: PermissionCopy.waitingInSettings)
        #expect(model.face(of: .bluetooth).remedy == nil)

        model.cameBackFromSystemSettings()
        #expect(model.face(of: .bluetooth).remedy == .openSettings, "the way back must come back")
    }

    @Test("A prompt's wait ends when the request answers, even if nothing changed")
    func answeringEndsTheWait() {
        let model = SettingsModel()
        model.permissions = [PermissionRow(kind: .calendars, status: .notDetermined)]
        model.beganWaiting(for: .calendars, on: .prompt, saying: PermissionCopy.waitingForAnswer)
        #expect(model.face(of: .calendars).remedy == nil)

        // macOS declined to ask — already refused once, say — so the status
        // is exactly what it was. The press is still answered.
        model.endedWaiting(for: .calendars)
        #expect(model.face(of: .calendars).remedy == .ask)
    }

    @Test("A row that is waiting still counts as waiting on you")
    func waitingRowsAreCounted() {
        let model = SettingsModel()
        model.permissions = [PermissionRow(kind: .calendars, status: .notDetermined)]
        model.beganWaiting(for: .calendars, on: .prompt, saying: PermissionCopy.waitingForAnswer)
        #expect(
            model.waitingOnYou == 1,
            "a spinner over “nothing is waiting for you” is the window disagreeing with itself"
        )
    }

    @Test("Coming back leaves a prompt that is still up alone")
    func comingBackSparesAPrompt() {
        let model = SettingsModel()
        model.permissions = [PermissionRow(kind: .calendars, status: .notDetermined)]
        model.beganWaiting(for: .calendars, on: .prompt, saying: PermissionCopy.waitingForAnswer)
        model.cameBackFromSystemSettings()
        #expect(
            model.face(of: .calendars).remedy == nil,
            "a second prompt must not be offered while the first is up"
        )
    }

    @Test("A row that was pressed waits, and stops waiting when the answer lands")
    func waitingForAnAnswer() {
        let model = SettingsModel()
        model.permissions = [PermissionRow(kind: .calendars, status: .notDetermined)]
        #expect(model.face(of: .calendars).remedy == .ask)

        model.beganWaiting(for: .calendars, on: .prompt, saying: PermissionCopy.waitingForAnswer)
        let waiting = model.face(of: .calendars)
        #expect(waiting.word == PermissionCopy.waitingForAnswer)
        #expect(waiting.remedy == nil, "a second prompt must not be offered while one is up")

        // A refresh that changes nothing leaves the wait alone: somebody in
        // System Settings may take a while.
        model.permissions = [PermissionRow(kind: .calendars, status: .notDetermined)]
        #expect(model.face(of: .calendars).remedy == nil)

        // The answer arrives.
        model.permissions = [PermissionRow(kind: .calendars, status: .granted)]
        #expect(model.face(of: .calendars).word == "Granted")
    }
}
