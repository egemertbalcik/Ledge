import Foundation
import Testing

@testable import LedgeCore

/// What Ledge's privacy card may say while Ledge itself is showing a camera.
@Suite("Covering Ledge's own camera")
struct CameraCoverTests {

    private let built_in = "built-in.front"
    private let external = "studio.display"

    @Test("With nothing covered, every camera is reported")
    func passesThrough() {
        let cover = CameraCover()
        #expect(cover.reportable(running: []) == [])
        #expect(cover.reportable(running: [built_in]) == [built_in])
        #expect(cover.reportable(running: [built_in, external]) == [built_in, external])
    }

    @Test("The camera Ledge opened says nothing")
    func ownCameraIsQuiet() {
        var cover = CameraCover()
        cover.opened(ours: built_in)
        // Nothing has started yet: the identity is known from the press.
        #expect(cover.reportable(running: []) == [])
        #expect(cover.reportable(running: [built_in]) == [])
    }

    @Test("A camera somebody else already had is still reported")
    func foreignCameraSurvives() {
        var cover = CameraCover()
        cover.opened(ours: built_in)
        #expect(cover.reportable(running: [external]) == [external])
        #expect(cover.reportable(running: [built_in, external]) == [external])
    }

    @Test("A camera that starts first, before Ledge's own, is still reported")
    func foreignCameraWinsTheRace() {
        // The case a count could not survive: the self-view is pressed, and
        // another application's camera appears in the reading before Ledge's
        // own does. Counting, that first camera looks like Ledge's.
        var cover = CameraCover()
        cover.opened(ours: built_in)
        #expect(cover.reportable(running: [external]) == [external])
        #expect(cover.reportable(running: [external, built_in]) == [external])
    }

    @Test("Closing and reopening quickly does not make Ledge a stranger")
    func rapidReopen() {
        // The other direction a count got wrong: a preview closed and
        // reopened before the watcher saw the gap. The identity does not
        // care about the gap.
        var cover = CameraCover()
        cover.opened(ours: built_in)
        #expect(cover.reportable(running: [built_in]) == [])
        cover.closed()
        cover.opened(ours: built_in)
        #expect(cover.reportable(running: [built_in]) == [])
    }

    @Test("A camera Ledge cannot name is a camera Ledge cannot claim")
    func unnamedDeviceIsReported() {
        var cover = CameraCover()
        cover.opened(ours: nil)
        #expect(cover.isCovering == false)
        #expect(cover.reportable(running: [built_in]) == [built_in])
    }

    @Test("A camera Ledge shares with another application is reported")
    func sharedDevice() {
        var cover = CameraCover()
        cover.opened(ours: built_in)
        #expect(cover.reportable(running: [built_in], oursIsShared: true) == [built_in])
        // And the moment the other application lets go, it is Ledge's again.
        #expect(cover.reportable(running: [built_in], oursIsShared: false) == [])
    }

    @Test("Closing reports everything again")
    func closingRestores() {
        var cover = CameraCover()
        cover.opened(ours: built_in)
        cover.closed()
        #expect(cover.reportable(running: [built_in]) == [built_in])
    }
}
