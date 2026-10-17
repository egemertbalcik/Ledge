import Foundation
import Testing

@testable import LedgeCore

/// What a permission row says, and the one thing it offers.
@Suite("How a permission reads")
struct PermissionFaceTests {

    @Test("A grant that has reached the app says so and offers nothing")
    func granted() {
        let face = PermissionPresentation.face(.calendars, status: .granted)
        #expect(face.tone == .ok)
        #expect(face.word == "Granted")
        #expect(face.remedy == nil)
    }

    @Test("A grant is a grant, whatever the probe says a moment later")
    func grantedIsGranted() {
        // There used to be a face here: "Granted, not in effect yet", with
        // Quit and Reopen. It was withdrawn because it cannot be detected —
        // Accessibility's status *is* the probe, so the two readings only
        // disagree between two moments, and the one state that produced it
        // in practice was a grant that had just been revoked. Offering a
        // relaunch for that is offering to restart an app into the same
        // refusal.
        let face = PermissionPresentation.face(.accessibility, status: .granted, isInEffect: false)
        #expect(face.tone == .ok)
        #expect(face.remedy == nil)
    }

    @Test("Never asked offers the prompt, except where there is no prompt")
    func notAsked() {
        let calendar = PermissionPresentation.face(.calendars, status: .notDetermined)
        #expect(calendar.remedy == .ask)

        // Accessibility's prompt shows at most once in an app's life and the
        // switch is in System Settings anyway, so the row goes there instead.
        let accessibility = PermissionPresentation.face(.accessibility, status: .notDetermined)
        #expect(accessibility.remedy == .openSettings)
        #expect(accessibility.note == PermissionCopy.accessibilityIsManual)
    }

    @Test("A refusal says where the switch is")
    func refused() {
        let face = PermissionPresentation.face(.bluetooth, status: .denied)
        #expect(face.tone == .problem)
        #expect(face.remedy == .openSettings)
        #expect(face.note?.contains("Bluetooth") == true)
    }

    @Test("A profile's decision offers nothing, and says who can change it")
    func restricted() {
        let face = PermissionPresentation.face(.location, status: .restricted)
        #expect(face.tone == .quiet)
        #expect(face.remedy == nil, "System Settings would only show a greyed-out switch")
        #expect(face.note == PermissionCopy.restricted)
        #expect(face.word != PermissionStatus.denied.summary, "a managed Mac has not refused anything")
    }

    @Test("Add-only access is not a refusal")
    func addOnly() {
        let face = PermissionPresentation.face(.calendars, status: .addOnly)
        #expect(face.tone == .attention)
        #expect(face.word == "Add-only access")
        #expect(face.remedy == .openSettings)
    }

    @Test("Automation with no player open waits for one")
    func notApplicableNow() {
        let face = PermissionPresentation.face(.automation, status: .notApplicableNow)
        #expect(face.tone == .quiet)
        #expect(face.remedy == .openPlayer)
    }

    @Test("Hardware that isn't there offers nothing")
    func unavailable() {
        let face = PermissionPresentation.face(.bluetooth, status: .unavailable)
        #expect(face.tone == .quiet)
        #expect(face.remedy == nil)
    }

    @Test("A row that is waiting offers nothing, whatever it is waiting on")
    func waiting() {
        for status in [PermissionStatus.notDetermined, .denied, .addOnly] {
            let face = PermissionPresentation.face(
                .calendars, status: status, waitingFor: PermissionCopy.waitingForAnswer
            )
            #expect(face.remedy == nil, "a second prompt must not be offered while one is up")
            #expect(face.word == PermissionCopy.waitingForAnswer)
        }
    }

    @Test("What counts as waiting for the person")
    func waitingCount() {
        let waiting = PermissionKind.allCases.filter {
            PermissionPresentation.isWaitingOnSomebody($0, status: .notDetermined)
        }
        #expect(waiting.count == PermissionKind.allCases.count)
        // A managed Mac and absent hardware are not somebody's homework.
        #expect(PermissionPresentation.isWaitingOnSomebody(.location, status: .restricted) == false)
        #expect(PermissionPresentation.isWaitingOnSomebody(.bluetooth, status: .unavailable) == false)
        #expect(PermissionPresentation.isWaitingOnSomebody(.calendars, status: .granted) == false)
        #expect(
            PermissionPresentation.isWaitingOnSomebody(.accessibility, status: .granted, isInEffect: false) == false,
            "nothing is owed for a state nothing can detect"
        )
    }

    @Test("Every status has a word of its own")
    func everyStatusSpeaks() {
        let words = Set([
            PermissionStatus.granted, .denied, .notDetermined,
            .unavailable, .notApplicableNow, .restricted, .addOnly,
        ].map(\.summary))
        #expect(words.count == 7, "two statuses sharing a word is how denied swallowed restricted")
    }
}
