/// What a level row says when it is not simply a number.
///
/// Every sentence belongs to one row and sits under that row's line. There is
/// no card-level message, because every fact here is about one device.
public enum LevelCopy {

    public static func note(_ note: LevelRow.Note) -> String {
        switch note {
        case .refused: "macOS didn't take that change."
        case .partial: "Only some channels changed."
        case .gamma(let floor):
            // Short enough for one line at 275pt. The long version — "Dims the
            // picture, not the backlight. Lowest is 18%." — took two, and two
            // lines of caveat under a row is a card explaining itself rather
            // than a card.
            "Dims the picture. Lowest \(Int((floor * 100).rounded()))%."
        case .fixedElsewhere: "This output's volume is set on the device itself."
        case .unreadable: "Can't read this display's brightness."
        case .setsItsOwn: "This screen sets its own brightness."
        case .unavailable: "Not available on this version of macOS."
        case .noOutput: "No sound output."
        }
    }

    /// Shown beside a muted output in place of its number, so the state has a
    /// word as well as a colour.
    public static let muted = "Muted"

    /// The group headings are deliberately absent: two rows under a hairline
    /// gap read as two groups without a label, and a notch card has no room
    /// for words that name what the glyphs already say.

    public static let sound = "Sound"
    public static let keyboard = "Keyboard"

    /// How long a refusal stays on the row.
    ///
    /// Four seconds: long enough to be read by somebody who was looking at
    /// the thing they just pressed, short enough that it is gone before they
    /// come back to the card for something else.
    public static let noteSeconds: Double = 4
}
