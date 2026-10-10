import Foundation
import LedgeCore
import OSLog

/// Hands a note to Apple's Notes, formatting and all.
///
/// Through Apple Events, because it is the only route that is both faithful and
/// silent. Notes' own scripting dictionary describes a note's `body` as "the
/// HTML content of the note", so writing HTML is writing the note's real
/// format — bold and italic arrive as bold and italic, not as a best effort.
/// The share sheet would also carry formatting but opens a panel the user has
/// to confirm, and a pasteboard-and-keystrokes approach needs Accessibility
/// and steals the front window.
///
/// `osascript` is spawned rather than `NSAppleScript` run in-process, for the
/// same reason the now-playing reads do: a script waiting on a TCC decision
/// blocks forever, and a child can be given a deadline and killed.
public enum NotesExport {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "notes-export")

    /// Generous, and deliberately longer than the playback reads. This may be
    /// the launch of Notes itself, which on a cold Mac with an iCloud account
    /// to reconcile is seconds rather than milliseconds.
    static let timeout: TimeInterval = 20

    public enum Failure: Equatable, Sendable {
        /// The user has refused Ledge control of Notes.
        case notPermitted
        /// Notes never answered.
        case timedOut
        case failed(String)
    }

    /// The script that makes the note.
    ///
    /// `default account` and `default folder`, never a named one: a Mac with no
    /// iCloud account still has somewhere to put a note, and naming "iCloud"
    /// would fail outright on one that does not.
    static func script(title: String, html: String) -> String {
        let body = NoteHTML.appleScriptLiteral(
            title.isEmpty ? html : "<div><b>\(title)</b></div>" + html
        )
        return """
        tell application "Notes"
        set theAccount to default account
        make new note at default folder of theAccount with properties {body:\(body)}
        end tell
        """
    }

    public static func send(title: String, text: AttributedString) async -> Failure? {
        let html = NoteHTML.render(text)
        guard !html.isEmpty else { return .failed("the note is empty") }

        let outcome = await ChildProcess.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script(title: title, html: html)],
            timeout: timeout
        )

        if outcome.timedOut { return .timedOut }
        if outcome.failedToLaunch { return .failed("osascript did not start") }
        if outcome.cancelled { return nil }
        guard outcome.status != 0 else { return nil }

        let detail = outcome.errorText
        // -1743 is the Apple Event refusal, which is a decision rather than a
        // fault: it means the user said no, and saying it again by prompting is
        // not ours to do.
        if detail.contains("-1743") || detail.lowercased().contains("not authorized") {
            return .notPermitted
        }
        log.error("notes export failed: \(detail, privacy: .private)")
        return .failed(detail)
    }
}
