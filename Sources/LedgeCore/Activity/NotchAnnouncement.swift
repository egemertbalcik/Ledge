import Foundation

/// A thing the notch says out loud, by standing up for a moment.
///
/// Ordinary peeks show a card in the ears for two seconds, which is enough for
/// news you are already half-expecting — a device connecting, a layout
/// switching. It is not enough for the end of something you have been waiting
/// out. A pomodoro finishing is the case that prompted this: twenty-five
/// minutes of not looking at the notch, and the one moment it had something to
/// say went by in the same two-second whisper as everything else. The break
/// had been running for two minutes before it was noticed.
///
/// So this kind of news grows the shape instead — nearly double its resting
/// height, with a strip below the hardware carrying the message, held for a
/// second or two and then gone. Big enough to catch an eye that is elsewhere;
/// far short of opening a card, which would demand attention rather than
/// asking for it.
public struct NotchAnnouncement: Equatable, Sendable {

    /// How long the shape stands up.
    ///
    /// Three seconds. Two was long enough to read *if you were looking*, which
    /// is the one thing that cannot be assumed here: the whole premise is a
    /// person whose eyes are on their work. The point is to be caught by
    /// peripheral vision, and that costs a beat before reading even begins.
    public static let duration: TimeInterval = 3.0

    /// One line. The strip is the height of the cutout and its lower corners
    /// are eaten by the shape's radius, so a second line has nowhere to sit —
    /// the first attempt stacked a title over a subtitle and the subtitle came
    /// out half-swallowed by the curve.
    public var title: String
    public var symbolName: String
    public var accent: AccentColor

    /// Pomodoros finished in this cycle, drawn as the dots the timer card
    /// already uses. Structure that carries something true: at the end of a
    /// session the thing worth knowing besides "stop" is how many you have
    /// done. Zero draws nothing.
    public var completedSessions: Int

    public init(
        title: String,
        symbolName: String,
        accent: AccentColor = .neutral,
        completedSessions: Int = 0
    ) {
        self.title = title
        self.symbolName = symbolName
        self.accent = accent
        self.completedSessions = completedSessions
    }

    /// What a timer card should say when it lands, or nil when it is not the
    /// sort of arrival worth standing up for.
    ///
    /// Only an *ending* qualifies. A timer starting is something the user just
    /// did and is looking at; a timer ending is the thing they stopped
    /// watching for, which is exactly when the notch has to do the noticing on
    /// their behalf.
    public static func forTimer(_ payload: TimerPayload) -> NotchAnnouncement? {
        guard payload.isFinished else { return nil }
        // Named for what happens next rather than what just stopped. Someone
        // who has not looked at the notch for half an hour needs to know what
        // to do, and "Focus done" makes them work that out for themselves.
        if payload.isBreak {
            return NotchAnnouncement(
                title: "Back to work",
                symbolName: "arrow.trianglehead.clockwise",
                accent: .init(red: 0.35, green: 0.62, blue: 1.0),
                completedSessions: payload.completedSessions
            )
        }
        // A one-off countdown is not a pomodoro and gets neither the cup nor
        // the cycle: nothing about it says a break has started, and borrowing
        // the coffee glyph told the user to go and make one.
        if payload.isCustom {
            return NotchAnnouncement(
                title: "Timer done",
                symbolName: "checkmark.circle.fill",
                accent: .init(red: 0.30, green: 0.78, blue: 0.47)
            )
        }
        return NotchAnnouncement(
            title: "Break time",
            symbolName: "cup.and.saucer.fill",
            accent: .init(red: 0.30, green: 0.78, blue: 0.47),
            completedSessions: payload.completedSessions
        )
    }
}
