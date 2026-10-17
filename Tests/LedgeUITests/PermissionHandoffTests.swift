import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// What the row says while somebody is in System Settings on Ledge's behalf,
/// and what ends it.
@MainActor
@Suite("A permission granted somewhere else")
struct PermissionHandoffTests {

    private func model(_ status: PermissionStatus = .notDetermined) -> SettingsModel {
        let model = SettingsModel()
        model.permissions = PermissionKind.allCases.map {
            PermissionRow(kind: $0, status: $0 == .accessibility ? status : .granted)
        }
        return model
    }

    @Test("A press says what it is waiting for, and offers nothing else")
    func waiting() {
        let model = model()
        model.beganHandoff(for: .accessibility, isFirstTime: true)
        #expect(model.handoff == PermissionHandoff(kind: .accessibility, phase: .waiting, isFirstTime: true))
        let face = model.face(of: .accessibility)
        #expect(face.word == PermissionCopy.waitingInSettings)
        #expect(face.remedy == nil)
    }

    @Test("Coming back with the switch still off keeps the guide and says so")
    func cameBackStillOff() {
        let model = model()
        model.beganHandoff(for: .accessibility)
        model.cameBackFromSystemSettings()
        // The watch is still running, so the handoff survives — what changes
        // is what the row says while it waits, and that the button is back.
        #expect(model.handoff?.phase == .back)
        let face = model.face(of: .accessibility)
        #expect(face.word == PermissionGuideCopy.stillOff)
        #expect(face.remedy == .openSettings)
    }

    @Test("Coming back to an answer folds the guide away")
    func cameBackToAnAnswer() {
        let model = model()
        model.beganHandoff(for: .accessibility)
        // The switch was flipped: the row's own face now says more than a
        // diagram of where to look.
        model.permissions = PermissionKind.allCases.map {
            PermissionRow(kind: $0, status: .granted)
        }
        model.cameBackFromSystemSettings()
        #expect(model.handoff == nil)
        #expect(model.face(of: .accessibility).tone == .ok)
    }

    @Test("An answer that arrives while they are still away ends the wait")
    func answerArrivesWhileAway() {
        let model = model()
        model.beganHandoff(for: .accessibility)
        #expect(model.face(of: .accessibility).word == PermissionCopy.waitingInSettings)
        // The coordinator's watch re-reads the permissions, which is what
        // reaches the model.
        model.permissions = PermissionKind.allCases.map {
            PermissionRow(kind: $0, status: .granted)
        }
        #expect(model.handoff == nil)
        #expect(model.face(of: .accessibility).word != PermissionCopy.waitingInSettings)
    }

    @Test("Ending it takes the guide, the wait and any drag report with it")
    func ended() {
        let model = model()
        model.beganHandoff(for: .accessibility)
        model.appDragEnded = .missed
        model.endedHandoff()
        #expect(model.handoff == nil)
        #expect(model.appDragEnded == nil)
        // And the button comes back: Stop Waiting must not leave a row that
        // can no longer be pressed.
        #expect(model.face(of: .accessibility).remedy != nil)
    }

    @Test("A fresh press clears the last drag's report")
    func pressClearsTheDragReport() {
        let model = model()
        model.appDragEnded = .landedElsewhere
        model.beganHandoff(for: .accessibility)
        #expect(model.appDragEnded == nil)
    }

    @Test("A second press while the first is still out replaces it, cleanly")
    func secondPress() {
        let model = model()
        model.beganHandoff(for: .accessibility)
        model.beganHandoff(for: .calendars)
        #expect(model.handoff?.kind == .calendars)
        // The row it replaced must stop saying it is waiting: it has no
        // button while it waits, so a wait that never ends is a row that can
        // never be pressed again.
        #expect(model.face(of: .accessibility).word != PermissionCopy.waitingInSettings)
        #expect(model.face(of: .accessibility).remedy != nil)
        #expect(model.face(of: .calendars).word == PermissionCopy.waitingInSettings)
    }

    @Test("Nothing is waiting for a handoff that was never started")
    func noHandoff() {
        let model = model()
        model.endedHandoff()
        #expect(model.handoff == nil)
        #expect(model.face(of: .accessibility).word != PermissionGuideCopy.stillOff)
    }
}

@MainActor
@Suite("Where the Focus folder stands")
struct FocusFolderStateTests {

    @Test("The panel being up outranks every other reading")
    func panelWins() {
        let model = SettingsModel()
        model.focusFolderGranted = true
        model.focusFolderPanelIsUp = true
        #expect(model.focusFolderState == .waiting)
    }

    @Test("A folder that does not exist yet is not a refusal")
    func noFolder() {
        let model = SettingsModel()
        model.focusFolderExists = false
        #expect(model.focusFolderState == .noFolderYet)
        #expect(model.focusFolderFace.button == nil)
    }

    @Test("A wrong pick is remembered until the next one")
    func wrongPick() {
        let model = SettingsModel()
        model.focusFolderWrongPick = "Desktop"
        #expect(model.focusFolderState == .wrongFolder(picked: "Desktop"))
        model.focusFolderGranted = true
        // Granted outranks it: the right folder arrived in the end.
        #expect(model.focusFolderState == .granted)
    }

    @Test("Nothing given, folder there: the plain offer")
    func plain() {
        let model = SettingsModel()
        #expect(model.focusFolderState == .notGranted)
        #expect(model.focusFolderFace.button == FocusFolderCopy.choose)
    }
}
