import Foundation
import LedgeCore
import Testing

/// The two steps that are done rather than read.
@Suite("What the tour has seen the notch do")
struct TourProgressTests {

    @Test("A hover is both halves: it opened, then it closed")
    func hoverNeedsBoth() {
        var progress = TourProgress()
        #expect(!progress.hoverIsDone)
        progress.saw(.opened)
        #expect(progress.hasOpened)
        // Still not done: nothing has been shown to close yet.
        #expect(!progress.hoverIsDone)
        progress.saw(.closed)
        #expect(progress.hoverIsDone)
    }

    @Test("A close nobody opened is the notch's own business, not yours")
    func closeAloneProvesNothing() {
        var progress = TourProgress()
        // An announcement retiring closes the notch. Crediting that to the
        // reader would tell them they did something they did not do.
        progress.saw(.closed)
        #expect(!progress.hoverIsDone)
        #expect(!progress.hasClosedAgain)
    }

    @Test("A file landing on the notch is the drop step, whatever else happened")
    func dropStandsAlone() {
        var progress = TourProgress()
        #expect(!progress.dropIsDone)
        progress.saw(.fileDropped)
        #expect(progress.dropIsDone)
        // And it does not pretend the hover was done too.
        #expect(!progress.hoverIsDone)
    }
}

@Suite("The four steps")
struct TourStepTests {

    @Test("They are a sequence, numbered from one")
    func order() {
        #expect(TourStep.allCases == [.hover, .drop, .permissions, .done])
        #expect(TourStep.allCases.map(\.number) == [1, 2, 3, 4])
        #expect(TourStep.allCases.map(\.name) == ["Hover", "Drop", "Permissions", "Done"])
    }

    @Test("The ends of the sequence have nothing past them")
    func ends() {
        #expect(TourStep.hover.previous == nil)
        #expect(TourStep.hover.next == .drop)
        #expect(TourStep.done.next == nil)
        #expect(TourStep.done.previous == .permissions)
    }

    @Test("A stored step survives the round trip through the preference")
    func storedAsADouble() {
        // `general.tourPage` is a Double, and the view reads it back through
        // `TourStep(rawValue:)`. A step that could not come back would send
        // somebody to step one after a crash.
        for step in TourStep.allCases {
            let stored = Double(step.rawValue)
            #expect(TourStep(rawValue: Int(stored)) == step)
        }
        // Anything else is not a step, and the caller falls back to the first.
        #expect(TourStep(rawValue: 9) == nil)
    }
}

/// The page whose whole job is to be true.
@Suite("What the tour says about privacy")
struct TourPrivacyCopyTests {

    @Test("It does not deny the capture code that exists")
    func doesNotDenyTheCamera() {
        let all = [
            TourCopy.privacyCamera, TourCopy.privacyCalendar,
            TourCopy.privacyNetwork, TourCopy.privacyDisk,
        ].joined(separator: " ")
        // The Calendar card runs an AVCaptureSession for its mirror, and the
        // app declares the camera entitlement. The old page said "There is no
        // capture code in Ledge".
        #expect(!all.lowercased().contains("no capture code"))
        #expect(TourCopy.privacyCamera.contains("camera"))
        #expect(TourCopy.privacyCamera.contains("Nothing it sees is recorded or saved"))
    }

    @Test("Reading the calendar is described as more than titles and times")
    func calendarIsHonest() {
        #expect(!TourCopy.privacyCalendar.contains("Titles and times only"))
        // The source reads each event's location, URL and notes to find a
        // meeting link, which is what this has to admit to.
        #expect(TourCopy.privacyCalendar.contains("meeting link"))
    }

    @Test("What is written to disk names everything that is written")
    func diskIsHonest() {
        let disk = TourCopy.privacyDisk
        #expect(!disk.contains("Nothing else"))
        for thing in ["settings", "shelf", "notes", "battery history", "Keep Awake"] {
            #expect(disk.localizedCaseInsensitiveContains(thing), "\(thing) is written and must be named")
        }
    }
}
