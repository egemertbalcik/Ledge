import Foundation
import Testing
import os

@testable import LedgeSystem

/// The real watcher against the real audio system.
///
/// The safety poll fires once a minute in the app, and a crash on its very
/// first tick therefore looked like a crash out of nowhere a minute after
/// launch. An earlier version of this suite started the watcher and waited
/// three seconds, which never reached the tick and so proved nothing. The poll
/// interval is injectable now for exactly that reason.
@Suite("Recording watcher live", .serialized)
struct RecordingWatcherLiveTests {

    @Test("The safety poll can fire without tripping an isolation assertion")
    @MainActor
    func pollTickIsSafe() async throws {
        // Fast enough to tick several times inside the test.
        let source = SystemRecordingSource(pollInterval: 0.2)
        let fired = Counter()
        source.startWatching { fired.bump() }

        // If the timer handler inherits an isolation it cannot honour, the
        // first tick takes the process down with SIGTRAP — the test crashes
        // rather than fails, which is the loudest possible signal.
        try await Task.sleep(for: .seconds(2))
        source.stopWatching()
        try await Task.sleep(for: .milliseconds(300))

        #expect(
            fired.count > 0,
            "the poll never delivered — the timer may not be running at all"
        )
    }

    @Test("Starting and stopping repeatedly against the real audio system is safe")
    @MainActor
    func repeatedStartStop() async throws {
        let source = SystemRecordingSource(pollInterval: 0.2)
        for _ in 0..<10 {
            source.startWatching {}
            source.stopWatching()
        }
        source.startWatching {}
        try await Task.sleep(for: .milliseconds(600))
        source.stopWatching()
        try await Task.sleep(for: .milliseconds(200))
        #expect(true, "reached the end without trapping")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func bump() { lock.withLock { $0 += 1 } }
    var count: Int { lock.withLock { $0 } }
}

/// Dictation has no interface in Ledge and no indicator either: the system
/// transcribing at the user's own keystroke, with the menu bar already saying
/// so, is not an app listening to them. The exclusion is internal — nothing
/// downstream knows it exists — so this is where it is held in place.
@Suite("The system's own speech input is not an indicator")
struct SystemSpeechExclusionTests {

    @Test("Apple's speech processes are recognised", arguments: [
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech.recognitionserver",
        "com.apple.corespeechd",
        "com.apple.DictationIM",
        "com.apple.siri.embeddedspeech",
        "com.apple.assistantd",
    ])
    func speechProcesses(bundleID: String) {
        #expect(SystemRecordingSource.isSystemSpeech(bundleID))
    }

    /// Apple's own identifiers only. An app with "speech" in its name is an
    /// app recording you, and gets the dot it has earned.
    @Test("Everything else is an app recording you", arguments: [
        "com.apple.Music",
        "com.apple.FaceTime",
        "us.zoom.xos",
        "com.hegenberg.BetterSpeech",
        "org.speech.recorder",
        "(unnamed)",
        "",
    ])
    func otherProcesses(bundleID: String) {
        #expect(SystemRecordingSource.isSystemSpeech(bundleID) == false)
    }

    @Test("Dictation alone lights nothing")
    func dictationAloneIsSilent() {
        #expect(SystemRecordingSource.microphoneHeld(by: []) == false)
        #expect(SystemRecordingSource.microphoneHeld(by: ["com.apple.corespeechd"]) == false)
        #expect(SystemRecordingSource.microphoneHeld(
            by: ["com.apple.corespeechd", "com.apple.SpeechRecognitionCore"]
        ) == false)
    }

    /// A filter, not a short circuit: dictation running is no excuse for
    /// missing the call that is recording at the same time.
    @Test("An app recording alongside dictation still lights the dot")
    func appAlongsideDictation() {
        #expect(SystemRecordingSource.microphoneHeld(by: ["us.zoom.xos"]))
        #expect(SystemRecordingSource.microphoneHeld(by: ["com.apple.corespeechd", "us.zoom.xos"]))
        #expect(SystemRecordingSource.microphoneHeld(by: ["(unnamed)"]))
    }
}
