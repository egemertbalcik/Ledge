import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import Testing
@testable import LedgeShell

/// The note window and "Show Ledge in screenshots and recordings".
///
/// Built through the real `warmUp()`, which is how the panel comes to exist in
/// the app: ordered in at alpha zero for a couple of frames and back out.
/// Nothing here makes the window visible or key.
@MainActor
@Suite("Notes window capture", .serialized, .timeLimit(.minutes(10)))
struct NotesCaptureTests {

    private func panel(of controller: NotesWindowController) -> NSPanel? {
        Mirror(reflecting: controller).children.first { $0.label == "panel" }?.value as? NSPanel
    }

    @Test("The note window follows the screenshots setting after it was built")
    func followsSettingAfterWarmUp() async throws {
        _ = NSApplication.shared
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.hideFromScreenCapture = false
        let store = NotesStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-notes-capture-tests/\(UUID().uuidString)", isDirectory: true))
        let controller = NotesWindowController(store: store, preferences: preferences)
        controller.warmUp()
        // Until the warm-up has built it, however long the main thread is
        // held: a fixed 150 ms was a guess. The suite's time limit catches a
        // panel that is never built.
        while panel(of: controller) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let built = try #require(panel(of: controller), "the warm-up built the panel")
        try #require(built.sharingType == .readOnly, "built while Ledge is shown in screenshots")

        // Turned off before a screen share: what the coordinator does when
        // the setting changes.
        preferences.hideFromScreenCapture = true
        controller.applyCapturePreference()
        #expect(built.sharingType == NSWindow.SharingType.none)

        preferences.hideFromScreenCapture = false
        controller.applyCapturePreference()
        #expect(built.sharingType == .readOnly)
        controller.tearDown()
    }
}
