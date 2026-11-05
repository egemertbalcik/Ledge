import AppKit
import Foundation
import LedgeCore
import SwiftUI
import Testing
@testable import LedgeShell

/// The two editors the note window can show, for tests that hold both to the
/// same behaviour.
///
/// SwiftUI's is macOS 26 and later and is what 26 users have. AppKit's is what
/// macOS 15 users have, and it runs on 26 too, so on this Mac every such test
/// runs against both, and on a 15 Mac against the one there is.
enum NotesEditorKind: String, Sendable, CustomTestStringConvertible {
    case swiftUI
    case appKit

    var testDescription: String {
        switch self {
        case .swiftUI: "SwiftUI editor"
        case .appKit: "AppKit editor"
        }
    }

    /// Every editor this Mac can run.
    static var available: [NotesEditorKind] {
        if #available(macOS 26.0, *) { return [.swiftUI, .appKit] }
        return [.appKit]
    }

    /// The model and its view, hosted the way `NotesWindowController.makePanel`
    /// hosts them.
    @MainActor func host() -> (model: any NotesEditing, hosting: NSView) {
        if self == .swiftUI, #available(macOS 26.0, *) {
            let model = NotesEditorModel()
            let hosting = NSHostingView(rootView: NotesEditorView(model: model, onClose: {}))
            hosting.sizingOptions = []
            return (model, hosting)
        }
        precondition(self == .appKit, "the SwiftUI editor needs macOS 26")
        let model = LegacyNotesEditorModel()
        let hosting = NSHostingView(rootView: LegacyNotesEditorView(model: model, onClose: {}))
        hosting.sizingOptions = []
        return (model, hosting)
    }
}

/// The note's text view, not a search field's: a field being edited has an
/// `NSTextView` of its own in the window.
@MainActor func noteTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView, !textView.isFieldEditor { return textView }
    for sub in view.subviews { if let found = noteTextView(in: sub) { return found } }
    return nil
}
