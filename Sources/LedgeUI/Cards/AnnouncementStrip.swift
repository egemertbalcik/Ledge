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
            glyph

            // A device's name is the one title here that can be longer than
            // the strip. It gives way in the middle, where "Ali's AirPods
            // Pro" loses the least, and only after the batteries have their
            // room. Everything else keeps its full width as it always has.
            if announcement.isWide {
                Text(announcement.title)
                    .font(.cardFigure)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(announcement.title)
                    .font(.cardFigure)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }

            if let detail = announcement.detail {
                Text(detail)
                    .font(.cardFigure)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .fixedSize()
            }

            if !announcement.batteries.isEmpty {
                HStack(spacing: 8) {
                    ForEach(announcement.batteries, id: \.label) { battery in
                        AnnouncementBattery(battery: battery)
                    }
                }
                .padding(.leading, 3)
                .fixedSize()
                .layoutPriority(1)
            }

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
        // Wide strips are the device's: the name, the batteries arriving a
        // moment after the connection, all inside the shape's own margins.
        .padding(.horizontal, announcement.isWide ? min(bottomRadius, height) * 0.6 : 0)
        .animation(Motion.medium, value: announcement.batteries)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The device's own artwork where it has one — the exact AirPods model,
    /// the glyph the app draws itself — and the plain symbol otherwise.
    @ViewBuilder
    private var glyph: some View {
        if announcement.symbolName.contains("airpods") {
            Image(systemName: announcement.symbolName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(announcement.accent.color)
        } else if LedgeSymbol.isCustom(announcement.symbolName) {
            BluetoothGlyph()
                .foregroundStyle(announcement.accent.color)
                .frame(height: 13)
        } else {
            Image(systemName: announcement.symbolName)
                .font(.cardTitle)
                .foregroundStyle(announcement.accent.color)
        }
    }

    private var accessibilityDescription: String {
        var parts = [announcement.title]
        if let detail = announcement.detail { parts.append(detail.lowercased()) }
        for battery in announcement.batteries {
            parts.append("\(battery.label) \(Int((battery.level * 100).rounded())) percent")
        }
        return parts.joined(separator: ", ")
    }
}

/// One battery in the strip: a small ring wearing the cell's initial, and the
/// number beside it. Green, red under a fifth — the colours the device card's
/// own rings use.
private struct AnnouncementBattery: View {
    let battery: NotchAnnouncement.Battery

    private var tint: Color { battery.level < 0.2 ? .red : .green }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, battery.level))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                mark
            }
            .frame(width: 15, height: 15)

            Text("\(Int((battery.level * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    /// A letter for the two ears, a small case shape for the case, nothing for
    /// a device with a single battery — its ring needs no telling apart.
    @ViewBuilder
    private var mark: some View {
        switch battery.label {
        case "Left", "Right":
            Text(String(battery.label.prefix(1)))
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        case "Case":
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.white.opacity(0.6))
                .frame(width: 5.5, height: 4.5)
        default:
            EmptyView()
        }
    }
}
