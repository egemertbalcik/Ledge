import SwiftUI

/// What the overlay shows when the queue is empty.
///
/// The queue being empty is the *normal* resting state — most providers are
/// event-driven and say nothing until something happens. "Nothing to show" is
/// accurate but useless: it is the only screen a curious user reliably reaches,
/// and it taught them that the app does nothing.
///
/// So this is the one place features get named. Deliberately hints rather than
/// controls: the overlay is a status surface, and turning it into a launcher
/// would mean it steals clicks from whatever is underneath.
public struct EmptyHintsView: View {

    /// Starts a focus session. The timer is the one feature whose "how" was a
    /// different surface entirely (the menu bar) — the biggest deficit this
    /// screen had. Everything else here stays a hint: the shelf needs a drag
    /// and weather needs Settings, but the timer can just start.
    private let onStartTimer: () -> Void

    /// A thing Ledge can do, and where to reach it.
    struct Hint: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let how: String
    }

    /// Ordered by how likely someone is to want it, not alphabetically. Four
    /// fits the expanded card without scrolling; a fifth would crowd it.
    private static let hints: [Hint] = [
        Hint(symbol: "tray.full.fill", title: "File shelf", how: "Drag files here"),
        Hint(symbol: "cloud.sun.fill", title: "Weather & Calendar", how: "Set up in Settings"),
        Hint(symbol: "gearshape.fill", title: "All features", how: "In the menu bar"),
    ]

    public init(onStartTimer: @escaping () -> Void = {}) {
        self.onStartTimer = onStartTimer
    }

    /// The timer row: same silhouette as the hints, but it acts.
    private var timerRow: some View {
        Button(action: onStartTimer) {
            HStack(spacing: 9) {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(.white.opacity(0.75))

                Text("Timer & Pomodoro")
                    .font(.cardBody)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Dressed as the action it is, where the hints wear plain text.
                Text("Start")
                    .font(.cardLabel)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.14)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start focus timer")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            timerRow
            ForEach(Self.hints) { hint in
                HStack(spacing: 9) {
                    Image(systemName: hint.symbol)
                        .font(.system(size: 12, weight: .medium))
                        // Fixed width so the titles line up into a column
                        // regardless of each glyph's own width.
                        .frame(width: 17)
                        .foregroundStyle(.white.opacity(0.75))

                    Text(hint.title)
                        .font(.cardBody)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(hint.how)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        // No vertical padding: on a notchless display the cutout stand-in is
        // taller than the MacBook's, so the card has less room and the last row
        // is the first thing to be clipped.
        .fixedSize(horizontal: false, vertical: true)
    }
}
