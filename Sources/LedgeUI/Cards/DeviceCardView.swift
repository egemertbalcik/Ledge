import LedgeCore
import SwiftUI

/// A Bluetooth device, laid out the way iOS lays out its AirPods battery sheet:
/// the product artwork large on the left, the name and connection state beside
/// it, and each battery cell as its own labelled pill.
///
/// The generic activity row put the device in a small tinted box with the cells
/// as an afterthought underneath. For AirPods in particular that is the wrong
/// emphasis — the artwork *is* the recognition, and the per-cell levels are the
/// reason the card is worth showing at all.
public struct DeviceCardView: View {

    private let payload: DevicePayload
    private let isCompactWidth: Bool

    public init(payload: DevicePayload, isCompactWidth: Bool = false) {
        self.payload = payload
        self.isCompactWidth = isCompactWidth
    }

    /// Apple's own gear gets the drawn product artwork; everything else gets its
    /// glyph plain and white.
    private var isAppleAudio: Bool {
        payload.isApple && payload.symbolName.contains("airpods")
    }

    public var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(payload.name)
                    .font(.cardHeadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(payload.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)

                if !payload.orderedLevels.isEmpty {
                    cells
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var artwork: some View {
        Group {
            if isAppleAudio {
                // Top-lit gradient, the way the system's own pairing sheet
                // presents the product.
                Image(systemName: payload.symbolName)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color(white: 0.68)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            } else {
                Image(systemName: payload.symbolName)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(payload.isApple ? AnyShapeStyle(.cyan) : AnyShapeStyle(.white))
            }
        }
        .frame(width: 44, height: 46)
    }

    /// One pill per cell — Case, Left, Right — each with its own level.
    private var cells: some View {
        HStack(spacing: 7) {
            ForEach(payload.orderedLevels, id: \.label) { cell in
                DeviceBatteryPill(label: cell.label, level: cell.level)
            }
        }
    }
}

/// A cell's label above a short level bar, sized for a row of two or three.
///
/// Red below a fifth, green otherwise — the only two states worth
/// distinguishing at this size, and the pair the user asked for.
struct DeviceBatteryPill: View {
    let label: String
    let level: Double

    private var tint: Color { level < 0.2 ? .red : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)

            HStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, 26 * min(max(level, 0), 1)))
                }
                .frame(width: 26, height: 4)

                Text("\(Int((level * 100).rounded()))")
                    .font(.cardCaption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Int((level * 100).rounded())) percent")
    }
}
