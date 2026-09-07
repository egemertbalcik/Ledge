import SwiftUI

/// The type scale the cards are actually drawn in.
///
/// Not an invention: every value here is one that was already written out by
/// hand, in some cases eleven times. Naming them costs nothing at runtime and
/// buys two things — a card can be read without decoding point sizes, and a
/// change to "the title size" is one edit rather than eleven scattered across
/// six files, none of which can be checked against the others.
///
/// The names describe the *role*, and the comment keeps the number visible,
/// because the number is what somebody comparing two cards will want.
///
/// Sizes used once or twice are left as literals where they are: the
/// stopwatch's 42pt face and the countdown's 32pt are that card's own voice,
/// not part of a shared scale.
extension Font {

    /// A card's headline — the track, the event, the mode. 13/semibold.
    public static let cardTitle = Font.system(size: 13, weight: .semibold)

    /// The line under it, and the labels in the compact ears. 11/semibold.
    public static let cardLabel = Font.system(size: 11, weight: .semibold)

    /// Body text that is not a label: hints, descriptions, secondary rows.
    /// 11/medium.
    public static let cardBody = Font.system(size: 11, weight: .medium)

    /// Buttons and row headings inside a card. 12/semibold.
    public static let cardControl = Font.system(size: 12, weight: .semibold)

    /// Small print: units, counts, the smaller half of a pair. 10/semibold.
    public static let cardCaption = Font.system(size: 10, weight: .semibold)

    /// Smaller still, where a caption would crowd. 9/semibold.
    public static let cardFootnote = Font.system(size: 9, weight: .semibold)

    /// The largest thing on a card that is still text rather than a figure —
    /// a temperature, a battery percentage. 15/semibold.
    public static let cardHeadline = Font.system(size: 15, weight: .semibold)

    /// Numbers that should read as a readout rather than as prose: the
    /// countdown, elapsed time, a day number. 13/semibold rounded.
    public static let cardFigure = Font.system(size: 13, weight: .semibold, design: .rounded)

    /// The same, one step down. 11/semibold rounded.
    public static let cardSmallFigure = Font.system(size: 11, weight: .semibold, design: .rounded)

    /// A badge: caps lock's ON, a count in a pill. 10/bold.
    public static let cardBadge = Font.system(size: 10, weight: .bold)
}
