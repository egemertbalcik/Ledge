import LedgeCore
import SwiftUI

/// A Focus change, in the shape iOS gives it: the mode's glyph in a large
/// tinted circle, the mode's name, and whether it just turned on or off.
///
/// The generic activity row rendered this as a small squared-off icon with
/// "On"/"Off" as trailing text, which read like a settings row rather than an
/// announcement. Focus is a *state change* — the card exists for the moment it
/// happens — so the state is the largest thing on it.
public struct FocusCardView: View {

    private let payload: FocusPayload

    public init(payload: FocusPayload) {
        self.payload = payload
    }

    private var tint: Color { payload.isActive ? .focusAccent : .white.opacity(0.5) }

    public var body: some View {
        HStack(spacing: 12) {
            // A circle rather than a rounded square: Focus is a mode, and iOS
            // draws modes as circles throughout — Control Centre, the lock
            // screen, the Focus picker.
            ZStack {
                Circle()
                    .fill(tint.opacity(payload.isActive ? 0.25 : 0.12))
                Image(systemName: payload.symbolName)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(payload.name)
                    .font(.cardHeadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(payload.isActive ? "Focus On" : "Focus Off")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // A filled dot when on, a hollow ring when off: readable at a
            // glance without reading the words.
            Circle()
                .strokeBorder(tint.opacity(payload.isActive ? 0 : 0.5), lineWidth: 1.5)
                .background(Circle().fill(payload.isActive ? tint : .clear))
                .frame(width: 11, height: 11)
        }
    }
}
