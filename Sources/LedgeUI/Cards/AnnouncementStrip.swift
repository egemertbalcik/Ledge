import CoreText
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
        if announcement.style == .device {
            DeviceAnnouncementRow(announcement: announcement, height: height,
                                  bottomRadius: bottomRadius)
        } else {
            line
        }
    }

    /// The height a strip needs below the hardware: the cutout's own for a
    /// line, the device row's for a device.
    static func height(for announcement: NotchAnnouncement, geometry: NotchGeometry) -> CGFloat {
        announcement.style == .device
            ? DeviceAnnouncementMetrics.height
            : NotchLayout.announceExtraHeight(for: geometry)
    }

    private var line: some View {
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

/// A device coming or going, or sound moving, said in full inside the notch.
///
/// The ears beside the cutout had two slots for this — a glyph and a ring —
/// and the news does not fit in them: a name was cut off after a word, and one
/// ring stood for three batteries by showing the lowest. So the notch grows
/// below the hardware and carries the whole sentence on its own black: the
/// device, whether it came or went, and what each cell holds. No material of
/// its own; the shape behind it is the background, as for every stand-up.
struct DeviceAnnouncementRow: View {

    let announcement: NotchAnnouncement
    let height: CGFloat
    let bottomRadius: CGFloat

    var body: some View {
        HStack(spacing: DeviceAnnouncementMetrics.spacing) {
            DeviceAnnouncementGlyph(symbolName: announcement.symbolName,
                                    tint: announcement.accent.color)
                .frame(width: DeviceAnnouncementMetrics.glyphSize,
                       height: DeviceAnnouncementMetrics.glyphSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(announcement.title)
                    .font(Font(DeviceAnnouncementMetrics.nameFont))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = announcement.subtitle {
                    Text(subtitle)
                        .font(Font(DeviceAnnouncementMetrics.subtitleFont))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .frame(
                width: DeviceAnnouncementMetrics.textWidth(for: announcement),
                alignment: .leading
            )

            if !announcement.batteries.isEmpty {
                HStack(spacing: DeviceAnnouncementMetrics.cellSpacing) {
                    ForEach(announcement.batteries, id: \.label) { battery in
                        DeviceAnnouncementCell(battery: battery)
                    }
                }
                .padding(.leading, DeviceAnnouncementMetrics.cellsLead)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .center)
        // The lower corners are the shape's radius; the row sits a touch high
        // in its space so the glyph and the case ring stay off the curve.
        .padding(.bottom, min(bottomRadius, height) * 0.15)
        .animation(Motion.medium, value: announcement.batteries)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [announcement.title]
        if let subtitle = announcement.subtitle { parts.append(subtitle.lowercased()) }
        for battery in announcement.batteries {
            parts.append("\(battery.label) \(Int((battery.level * 100).rounded())) percent")
        }
        return parts.joined(separator: ", ")
    }
}

/// The sizes the device row is drawn at, and what they add up to.
///
/// The shape has to be the row's size before the row is drawn — the panel
/// decides where clicks land from the same number — so the text is measured
/// here with the very fonts the row renders with, not estimated.
enum DeviceAnnouncementMetrics {

    /// Below the hardware: two lines of text and a ring with room around them.
    static let height: CGFloat = 50

    static let glyphSize: CGFloat = 26
    static let spacing: CGFloat = 10
    static let ringSize: CGFloat = 20
    static let ringToNumber: CGFloat = 5
    static let cellSpacing: CGFloat = 10
    static let cellsLead: CGFloat = 4

    /// The widest a name may run before it gives way in the middle, where
    /// "Ali's AirPods Pro" loses the least.
    static let maximumTextWidth: CGFloat = 230

    // CTFont is immutable once made; Swift just cannot see that.
    nonisolated(unsafe) static let nameFont = systemFont(size: 13, weight: 0.3)
    nonisolated(unsafe) static let subtitleFont = systemFont(size: 11, weight: 0)
    nonisolated(unsafe) static let numberFont = systemFont(size: 12, weight: 0.3)

    /// Clear black either side of the row: a margin, and some of the bottom
    /// radius, which narrows the shape at the row's height.
    static func sideInset(bottomRadius: CGFloat) -> CGFloat {
        18 + max(0, bottomRadius.isFinite ? bottomRadius : 0) * 0.3
    }

    static func textWidth(for announcement: NotchAnnouncement) -> CGFloat {
        let name = width(of: announcement.title, font: nameFont)
        let subtitle = announcement.subtitle.map { width(of: $0, font: subtitleFont) } ?? 0
        return min(max(name, subtitle), maximumTextWidth).rounded(.up)
    }

    static func percent(_ level: Double) -> String {
        "\(Int((min(max(level, 0), 1) * 100).rounded()))%"
    }

    static func numberWidth(_ level: Double) -> CGFloat {
        width(of: percent(level), font: numberFont).rounded(.up)
    }

    /// What the shape has to hold below the hardware.
    static func size(for announcement: NotchAnnouncement, bottomRadius: CGFloat) -> CGSize {
        var width = glyphSize + spacing + textWidth(for: announcement)
        if !announcement.batteries.isEmpty {
            width += spacing + cellsLead
            width += announcement.batteries
                .map { ringSize + ringToNumber + numberWidth($0.level) }
                .reduce(0, +)
            width += cellSpacing * CGFloat(announcement.batteries.count - 1)
        }
        width += sideInset(bottomRadius: bottomRadius) * 2
        return CGSize(width: width.rounded(.up), height: height)
    }

    private static func width(of text: String, font: CTFont) -> CGFloat {
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func systemFont(size: CGFloat, weight: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base),
            [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}

/// The device's own artwork where it has one — the exact AirPods model, the
/// glyph the app draws itself — and the plain symbol otherwise.
private struct DeviceAnnouncementGlyph: View {
    let symbolName: String
    let tint: Color

    var body: some View {
        if LedgeSymbol.isCustom(symbolName) {
            BluetoothGlyph()
                .foregroundStyle(tint)
                .frame(height: 17)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(tint)
        }
    }
}

/// One battery: a ring wearing the cell's initial, and the percentage beside
/// it. Green, red under a fifth.
private struct DeviceAnnouncementCell: View {
    let battery: NotchAnnouncement.Battery

    private var tint: Color { battery.level < 0.2 ? .red : .green }

    var body: some View {
        HStack(spacing: DeviceAnnouncementMetrics.ringToNumber) {
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, battery.level))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.slow, value: battery.level)
                mark
            }
            .frame(width: DeviceAnnouncementMetrics.ringSize,
                   height: DeviceAnnouncementMetrics.ringSize)

            Text(DeviceAnnouncementMetrics.percent(battery.level))
                .font(Font(DeviceAnnouncementMetrics.numberFont))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: DeviceAnnouncementMetrics.numberWidth(battery.level),
                       alignment: .leading)
        }
    }

    /// A letter for the two ears, a small case shape for the case, nothing for
    /// a device with a single battery — its ring needs no telling apart.
    @ViewBuilder
    private var mark: some View {
        switch battery.label {
        case "Left", "Right":
            Text(String(battery.label.prefix(1)))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        case "Case":
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.white.opacity(0.6))
                .frame(width: 7, height: 6)
        default:
            EmptyView()
        }
    }
}
