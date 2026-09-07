import LedgeCore
import SwiftUI

/// The strip that appears below the hardware when the notch stands up.
///
/// It fills the space the shape has just grown into and carries no background
/// or divider of its own — the shape behind it is the background, so the two
/// halves read as one object rather than a banner that has appeared beneath a
/// notch.
///
/// Everything about the layout is dictated by the space, which is hostile: as
/// tall as the cutout and no taller, with both lower corners eaten by the
/// shape's bottom radius — thirty points of it on this Mac, against a strip of
/// thirty-two. So the content is one line, centred, and held clear of the
/// curve. A two-line block put its second line straight into the corner
/// radius, where it could not be read at all.
struct AnnouncementStrip: View {

    let announcement: NotchAnnouncement
    /// Matches the space the shape grew by, so the strip fills it exactly.
    let height: CGFloat
    /// The shape's bottom corner radius, which is what the content has to keep
    /// out of. Passed in rather than assumed: it is a preference, and on a
    /// generous setting it claims most of the strip's lower half.
    let bottomRadius: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: announcement.symbolName)
                .font(.cardTitle)
                .foregroundStyle(announcement.accent.color)

            Text(announcement.title)
                .font(.cardFigure)
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()

            if announcement.completedSessions > 0 {
                CycleDots(
                    completed: announcement.completedSessions,
                    tint: announcement.accent.color
                )
                .padding(.leading, 2)
            }
        }
        // Centred, because the shape is at its widest across the middle and
        // narrows into both corners. Leading alignment put the glyph in the
        // curve, where it read as falling out of the notch.
        .frame(maxWidth: .infinity)
        // Held off the curve rather than centred in the raw box: the radius
        // takes the bottom, so the content sits high in the space it has.
        .frame(height: height, alignment: .center)
        .padding(.bottom, min(bottomRadius, height) * 0.22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(announcement.title)
    }
}
