import Foundation
import LedgeCore
import Testing

/// The face for somebody who came back from System Settings with the switch
/// still off.
@Suite("Back, still off")
struct StillOffFaceTests {

    @Test("It replaces the state they started in, and keeps the way back")
    func replacesNotRequested() {
        let plain = PermissionPresentation.face(.accessibility, status: .notDetermined)
        let back = PermissionPresentation.face(
            .accessibility, status: .notDetermined, cameBackStillOff: true
        )
        #expect(plain.word != back.word)
        #expect(back.word == PermissionGuideCopy.stillOff)
        // "Not requested" is wrong twice over by then: they did request it,
        // and the commonest reason it is still off is a list holding an older
        // copy of Ledge.
        #expect(back.note == PermissionGuideCopy.stillOffNote)
        #expect(back.remedy == .openSettings)
        #expect(back.tone == .attention)
    }

    @Test("An answer outranks it, whichever answer arrived")
    func answersWin() {
        let granted = PermissionPresentation.face(
            .accessibility, status: .granted, cameBackStillOff: true
        )
        #expect(granted.tone == .ok)
        #expect(granted.word != PermissionGuideCopy.stillOff)

        let denied = PermissionPresentation.face(
            .calendars, status: .denied, cameBackStillOff: true
        )
        #expect(denied.tone == .problem)
        #expect(denied.word != PermissionGuideCopy.stillOff)
        // A profile deciding it is not something a drag can fix either.
        let managed = PermissionPresentation.face(
            .calendars, status: .restricted, cameBackStillOff: true
        )
        #expect(managed.note == PermissionCopy.restricted)
    }

    @Test("A prompt that is up outranks everything")
    func waitingWins() {
        let waiting = PermissionPresentation.face(
            .accessibility,
            status: .notDetermined,
            waitingFor: PermissionCopy.waitingInSettings,
            cameBackStillOff: true
        )
        #expect(waiting.word == PermissionCopy.waitingInSettings)
        // Nothing to press while something is already up.
        #expect(waiting.remedy == nil)
    }
}

@Suite("The guide's words")
struct PermissionGuideCopyTests {

    @Test("The caption names the list the switch is actually in")
    func captionNamesTheList() {
        #expect(PermissionGuideCopy.caption(.calendars).contains("Calendars"))
        #expect(PermissionGuideCopy.caption(.location).contains("Location Services"))
        // Accessibility's is the one that mentions the password, because it is
        // the one list macOS locks.
        let accessibility = PermissionGuideCopy.caption(.accessibility)
        #expect(accessibility.contains("password") || accessibility.contains("Touch ID"))
    }

    @Test("Every caption ends by saying Ledge notices on its own")
    func noSecondStep() {
        for kind in PermissionKind.allCases {
            #expect(
                PermissionGuideCopy.caption(kind).contains("Ledge notices by itself"),
                "\(kind) must not ask for a second step Ledge does itself"
            )
        }
    }

    @Test("Only Accessibility has anything to show the moment it lands")
    func arrivalDetail() {
        #expect(PermissionGuideCopy.arrivedDetail(.accessibility).contains("readout"))
        for kind in PermissionKind.allCases where kind != .accessibility {
            #expect(PermissionGuideCopy.arrivedDetail(kind) == PermissionGuideCopy.arrivedDetail(.calendars))
        }
    }

    @Test("The arrival card holds longer when motion is reduced")
    func arrivalHold() {
        // It neither springs in nor springs out, so it is read rather than
        // watched.
        #expect(
            PermissionGuideCopy.arrivalHold(reduceMotion: true)
                > PermissionGuideCopy.arrivalHold(reduceMotion: false)
        )
    }
}

/// One folder, five states, and no modal alert anywhere in them.
@Suite("The Focus folder's faces")
struct FocusFolderFaceTests {

    @Test("Nothing to grant yet offers no button")
    func noFolderYet() {
        let face = FocusFolderCopy.face(.noFolderYet)
        #expect(face.button == nil)
        #expect(face.word == "Turn a Focus on first")
        // It used to be an alert over the pane, raised by pressing the button
        // that should not have been there.
        #expect(face.note.contains("first time a Focus is used"))
    }

    @Test("While the panel is up the row says so and offers nothing")
    func waiting() {
        let face = FocusFolderCopy.face(.waiting)
        #expect(face.button == nil)
        #expect(face.tone == .quiet)
        #expect(face.note.contains(FocusFolderCopy.panelPrompt))
    }

    @Test("A different folder says what was kept: nothing")
    func wrongFolder() {
        let face = FocusFolderCopy.face(.wrongFolder(picked: "Desktop"))
        #expect(face.note.contains("Desktop"))
        #expect(face.note.contains("kept nothing"))
        #expect(face.button == FocusFolderCopy.choose)
    }

    @Test("Granted still offers the way to point Ledge somewhere else")
    func granted() {
        let face = FocusFolderCopy.face(.granted)
        #expect(face.tone == .ok)
        #expect(face.button == FocusFolderCopy.chooseAnother)
    }

    @Test("Not granted says it is optional, and what is lost without it")
    func notGranted() {
        let face = FocusFolderCopy.face(.notGranted)
        #expect(face.button == FocusFolderCopy.choose)
        #expect(face.note.contains("Optional"))
    }
}
