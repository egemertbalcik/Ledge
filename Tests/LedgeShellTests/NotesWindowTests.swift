import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import ObjectiveC
import Testing
@testable import LedgeShell

/// The real note window, writing real files.
///
/// Every other Notes test hosts an editor the way the window controller does
/// and repeats its saving line for line, because the controller's own open puts
/// its window on screen and takes the keyboard from whatever the person at the
/// Mac is typing into. This one drives the controller itself — its load, its
/// switch from one note to the next and its close — with its own window held
/// off the screen and away from the keyboard for the length of the test. What
/// reaches the disk is read back from the files.
///
/// Not driven: the copy commands, which write to the clipboard of the person
/// at the Mac, and Export to Apple Notes, which drives another app.
@MainActor
@Suite("Notes window", .serialized, .timeLimit(.minutes(5)))
struct NotesWindowTests {

    /// The note windows being held back, and nothing else. Only ever read
    /// and changed on the main thread, where AppKit asks its windows these
    /// things.
    nonisolated(unsafe) private static let held = NSHashTable<NSWindow>.weakObjects()

    /// Lets a note window be held back without changing its class.
    ///
    /// `NotesPanel`'s answer to whether it can become key, and its ordering
    /// in, are each put behind a check: a window in `held` is refused, and
    /// every other note window — in this test or any running beside it — is
    /// passed straight to the real one. Made once for the test process and
    /// left in place, since it changes nothing for a window that is not held.
    /// (A class of its own per window was tried first; AppKit's window
    /// properties assert on a class made at run time.)
    private static let gate: Void = {
        let panel: AnyClass = NotesPanel.self
        let keySelector = #selector(getter: NSWindow.canBecomeKey)
        // `NotesPanel` overrides this today. Should it ever stop, it is given
        // its own copy first, as below, so the check never lands on NSWindow's
        // and with it on every window in the process.
        if let inherited = class_getInstanceMethod(NSPanel.self, keySelector) {
            class_addMethod(panel, keySelector, method_getImplementation(inherited),
                            method_getTypeEncoding(inherited))
        }
        guard let key = class_getInstanceMethod(panel, keySelector) else { return }
        typealias Answer = @convention(c) (AnyObject, Selector) -> Bool
        let canBecomeKey = unsafeBitCast(method_getImplementation(key), to: Answer.self)
        method_setImplementation(key, imp_implementationWithBlock({ (window: AnyObject) -> Bool in
            if let window = window as? NSWindow, held.contains(window) { return false }
            return canBecomeKey(window, keySelector)
        } as @convention(block) (AnyObject) -> Bool))

        // `NotesPanel` inherits this one, so it is given its own first, which
        // calls the inherited one; then that is put behind the check.
        let frontSelector = #selector(NSWindow.orderFrontRegardless)
        guard let inherited = class_getMethodImplementation(NSPanel.self, frontSelector) else { return }
        class_addMethod(panel, frontSelector, inherited, "v@:")
        guard let front = class_getInstanceMethod(panel, frontSelector) else { return }
        typealias Order = @convention(c) (AnyObject, Selector) -> Void
        let orderFront = unsafeBitCast(method_getImplementation(front), to: Order.self)
        method_setImplementation(front, imp_implementationWithBlock({ (window: AnyObject) in
            if let window = window as? NSWindow, held.contains(window) { return }
            orderFront(window, frontSelector)
        } as @convention(block) (AnyObject) -> Void))
    }()

    /// Keeps this one window off the screen and unable to become key until
    /// the returned function is called.
    private static func hold(_ window: NSWindow) -> () -> Void {
        _ = gate
        held.add(window)
        return { held.remove(window) }
    }

    private func arrive(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func onDisk(_ dir: URL, _ id: String) -> NoteBody? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")) else { return nil }
        return try? JSONDecoder().decode(NoteBody.self, from: data)
    }

    /// Whether the editor's model has this selection, however that editor
    /// keeps one.
    private func selects(_ model: any NotesEditing, _ range: NSRange) -> Bool {
        if #available(macOS 26.0, *), let model = model as? NotesEditorModel {
            guard case .ranges(let set) = model.selection.indices(in: model.text), let first = set.ranges.first
            else { return false }
            return NSRange(first, in: model.text) == range
        }
        return (model as? LegacyNotesEditorModel)?.selection == [range]
    }

    @Test("The window's own open, switch and close write each note, bold included",
          arguments: NotesEditorKind.available)
    func windowWritesTheNotes(editor: NotesEditorKind) async throws {
        _ = NSApplication.shared
        let capture = (NSHomeDirectory() as NSString).appendingPathComponent(".ledge-notes-capture")
        try #require(!FileManager.default.fileExists(atPath: capture),
                     "the window would write pictures of itself into the home folder")
        try #require(ProcessInfo.processInfo.environment["LEDGE_LEGACY_NOTES"] == nil, """
            LEDGE_LEGACY_NOTES is set for this test run, and it decides which editor the window gets; \
            run the tests without it
            """)

        // The macOS 15 editor on this Mac is the debug switch's to choose,
        // and only at the moment the window controller is made.
        let asked = editor == .appKit
        if #available(macOS 26.0, *), asked { setenv("LEDGE_LEGACY_NOTES", "1", 1) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-notes-window-tests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(directory: dir)
        let controller = NotesWindowController(store: store, preferences: Preferences(store: MemoryPreferenceStore()))
        if asked { unsetenv("LEDGE_LEGACY_NOTES") }
        defer { controller.tearDown() }
        let model = try #require(Mirror(reflecting: controller).children.first { $0.label == "model" }?.value
            as? any NotesEditing)
        try #require((model is LegacyNotesEditorModel) == (editor == .appKit), "the window has the \(editor)")

        // The window is built as the app builds it, by the warm-up — ordered in
        // at alpha zero for a couple of frames and out again — and then held.
        controller.warmUp()
        func panel() -> NSPanel? {
            Mirror(reflecting: controller).children.first { $0.label == "panel" }?.value as? NSPanel
        }
        try #require(await arrive { panel().map { !$0.isVisible } ?? false }, "the warm-up built the window and put it away")
        let window = try #require(panel())
        let release = Self.hold(window)
        defer { release() }
        window.orderFrontRegardless()
        window.makeKey()
        try #require(!window.isVisible && !window.isKeyWindow, "the window cannot be put on screen or made key")
        // And a note window that is not held is not held: one of the paste
        // tests' own, far off every screen and transparent, still orders in.
        let other = NotesPanel(contentRect: NSRect(x: -30000, y: -30000, width: 10, height: 10),
                               styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.alphaValue = 0
        other.orderFrontRegardless()
        let othersFree = other.isVisible
        other.orderOut(nil)
        other.close()
        try #require(othersFree, "every other note window orders in as it always does")
        func stillHeld(_ moment: String) throws {
            try #require(!window.isVisible && !window.isKeyWindow, "\(moment): the window stayed off the screen")
        }

        // Nothing the editor tells the window reaches the store from here on,
        // so the 1.5 second save cannot write what is typed: only the switch
        // to the next note and the close can.
        model.onEdit = { _ in }

        controller.create()
        try #require(await arrive { controller.openNoteID != nil }, "a note was made and opened")
        try stillHeld("after the first open")
        let first = try #require(controller.openNoteID)
        let hosting = try #require(Mirror(reflecting: controller).children.first { $0.label == "hosting" }?.value as? NSView)
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(noteTextView(in: hosting))
        textView.insertText("First note\nits body", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(await arrive { String(model.text.characters) == "First note\nits body" })
        let firstWord = NSRange(location: 0, length: 5)
        textView.setSelectedRange(firstWord)
        try #require(await arrive { selects(model, firstWord) }, "the selection reached the model")
        controller.run(.bold)
        try #require(await arrive {
            model.text.runs.first?.inlinePresentationIntent == .stronglyEmphasized
                && (textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                    .map { NoteAppKitBridge.intent(of: $0) } == .stronglyEmphasized
        }, "⌘B reached the note and the text view")
        try #require(onDisk(dir, first)?.plainText != "First note\nits body", "nothing has written the typing yet")

        // ⌘N in the window: the note being left is written as the next opens.
        controller.create()
        try #require(await arrive { controller.openNoteID != nil && controller.openNoteID != first }, "the next note")
        try stillHeld("after the second open")
        let second = try #require(controller.openNoteID)
        #expect(await arrive { self.onDisk(dir, first)?.plainText == "First note\nits body" }, "the first note was written")
        let firstBody = try #require(onDisk(dir, first))
        #expect(firstBody.text[try #require(firstBody.text.range(of: "First"))].inlinePresentationIntent
                == .stronglyEmphasized, "with its bold")
        for run in firstBody.text.runs {
            var expected = AttributeContainer()
            if let intent = run.inlinePresentationIntent { expected.inlinePresentationIntent = intent }
            #expect(run.attributes == expected, "nothing but intent: \(run.attributes)")
        }

        let next = try #require(noteTextView(in: hosting))
        next.insertText("Second", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(await arrive { String(model.text.characters) == "Second" })
        try #require(onDisk(dir, second)?.plainText != "Second", "nothing has written the second note yet")
        try stillHeld("before the close")
        // Closing writes the note that is open.
        controller.close()
        #expect(await arrive { self.onDisk(dir, second)?.plainText == "Second" }, "the second note was written on close")
        #expect(onDisk(dir, first)?.plainText == "First note\nits body", "and the first one is as it was")
    }
}
