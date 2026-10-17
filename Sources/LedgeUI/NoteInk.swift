import SwiftUI

/// The ink three surfaces share: the notes card, the note window, and the
/// palette over it.
///
/// Everything is an opacity of white over the island's own black except one
/// amber, which marks the row the keys are pointed at and nothing else — a
/// window that is otherwise colourless can say "here" with very little.
///
/// In `LedgeUI` rather than beside the window it was written for, because the
/// card is drawn here and the window is drawn a layer up. Copied into both, the
/// one feature had two ambers and a card that stroked its open note in
/// `.yellow` while the window marked the same note in this one.
public enum NoteInk {
    public static let text = Color.white.opacity(0.92)
    public static let muted = Color.white.opacity(0.45)
    public static let faint = Color.white.opacity(0.28)
    public static let raised = Color.white.opacity(0.055)
    public static let edge = Color.white.opacity(0.10)
    public static let mark = Color(red: 0.95, green: 0.72, blue: 0.38)

    /// The same values at Increase Contrast, where a 28% time stamp on black
    /// is not a time stamp.
    public static func muted(_ increased: Bool) -> Color {
        Color.white.opacity(increased ? 0.7 : 0.45)
    }
    public static func faint(_ increased: Bool) -> Color {
        Color.white.opacity(increased ? 0.55 : 0.28)
    }
    public static func edge(_ increased: Bool) -> Color {
        Color.white.opacity(increased ? 0.3 : 0.10)
    }
}
