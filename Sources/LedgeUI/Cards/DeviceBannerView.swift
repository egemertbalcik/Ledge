import LedgeCore
import SwiftUI

/// A device connecting or leaving, said in full below the island.
///
/// The ears had two slots for this — a glyph and a ring — and the news does
/// not fit in them. A name beside the cutout is cut off after a word, and one
/// ring stands for three batteries by showing the lowest. So the ears keep the
/// glance, and this carries the sentence: which device, whether it is attached,
/// and what each cell holds.
///
/// It is glass rather than the island's black because it is not the island. It
/// hangs below the hardware as a separate object, the way the system's own
/// connection banner does, and takes its tone from whatever is behind it.
struct DeviceBannerView: View {

    let payload: DevicePayload

    /// Clear air between the island's lower edge and the capsule.
    static let gap: CGFloat = 8

    /// The widest a name may run before it is shortened in the middle, where
    /// "Ali Emre's AirPods Pro" loses the least.
    private static let nameWidth: CGFloat = 230

    var body: some View {
        HStack(spacing: 10) {
            DeviceGlyph(symbolName: payload.symbolName)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(payload.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: Self.nameWidth, alignment: .leading)

            if !cells.isEmpty {
                HStack(spacing: 10) {
                    ForEach(cells, id: \.label) { cell in
                        DeviceBannerCell(label: cell.label, level: cell.level)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .fixedSize()
        .modifier(BannerGlass())
        .animation(Motion.medium, value: payload.batteryLevels)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The line under the name: what the banner was given to say — a route
    /// change's "Sound Output" — or else whether the device came or went.
    private var caption: String? {
        if let status = payload.statusText, !status.isEmpty { return status }
        return payload.isConnected.map { $0 ? "Connected" : "Disconnected" }
    }

    /// Left, Right, Case — the order the earbuds are worn and read in, rather
    /// than the alphabet's, which put the case first.
    private var cells: [(label: String, level: Double)] {
        let order = ["Left": 0, "Right": 1, "Battery": 2, "Case": 3]
        return payload.orderedLevels.sorted {
            (order[$0.label] ?? 9, $0.label) < (order[$1.label] ?? 9, $1.label)
        }
    }

    private var accessibilityDescription: String {
        var parts = [payload.name]
        if let caption { parts.append(caption.lowercased()) }
        for cell in cells {
            parts.append("\(cell.label) \(Int((cell.level * 100).rounded())) percent")
        }
        return parts.joined(separator: ", ")
    }
}

/// The device's glyph, including the one the app draws itself.
private struct DeviceGlyph: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(.primary)
    }
}

/// One battery: a ring wearing the cell's initial, and the number beside it.
private struct DeviceBannerCell: View {
    let label: String
    let level: Double

    private var clamped: Double { level.isFinite ? min(max(level, 0), 1) : 0 }
    private var tint: Color { clamped < 0.2 ? .red : .green }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(.primary.opacity(0.16), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, clamped))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.slow, value: clamped)
                mark
            }
            .frame(width: 20, height: 20)

            Text("\(Int((clamped * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// What the ring wears. A letter for the two ears, a bolt-less case shape
    /// for the case, nothing for a device with a single battery — its ring
    /// needs no telling apart.
    @ViewBuilder
    private var mark: some View {
        switch label {
        case "Left", "Right":
            Text(String(label.prefix(1)))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        case "Case":
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.secondary)
                .frame(width: 7, height: 6)
        default:
            EmptyView()
        }
    }
}

/// Liquid Glass where the system has it, the nearest material where it does
/// not.
private struct BannerGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }
}
