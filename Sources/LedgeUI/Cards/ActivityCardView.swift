import LedgeCore
import SwiftUI

extension AccentColor {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension Color {
    /// Apple's Focus/Do-Not-Disturb violet. SwiftUI's own `.purple` is a
    /// pinkish magenta; the system Focus glyph is a bluer, deeper violet.
    static let focusAccent = Color(red: 0.48, green: 0.40, blue: 0.93)
}

/// The full card, shown below the cutout when the overlay is open.
public struct ActivityCardView: View {

    private let activity: Activity
    private let isCompactWidth: Bool
    private let nowPlayingActions: NowPlayingActions
    private let timerActions: TimerActions
    private let shelfActions: ShelfActions
    private let levelsActions: LevelsActions
    private let liveLevel: HUDReadout?

    /// Passed to the Clock card, which measures itself — see `TimerCardView`.
    private let onTimerHeight: (CGFloat) -> Void

    /// The spring the shell resizes the shape with, so a card that turns over
    /// inside it moves on the same curve.
    private let swapResponse: Double
    private let swapDamping: Double

    @Environment(\.weatherUnits) private var weatherUnits

    public init(
        activity: Activity,
        isCompactWidth: Bool = false,
        nowPlayingActions: NowPlayingActions = NowPlayingActions(),
        timerActions: TimerActions = TimerActions(),
        shelfActions: ShelfActions = ShelfActions(),
        levelsActions: LevelsActions = LevelsActions(),
        liveLevel: HUDReadout? = nil,
        onTimerHeight: @escaping (CGFloat) -> Void = { _ in },
        swapResponse: Double = 0.38,
        swapDamping: Double = 0.68
    ) {
        self.activity = activity
        self.isCompactWidth = isCompactWidth
        self.nowPlayingActions = nowPlayingActions
        self.timerActions = timerActions
        self.shelfActions = shelfActions
        self.levelsActions = levelsActions
        self.liveLevel = liveLevel
        self.onTimerHeight = onTimerHeight
        self.swapResponse = swapResponse
        self.swapDamping = swapDamping
    }

    public var body: some View {
        switch activity.payload {
        case .nowPlaying(let payload):
            // Now playing gets its own card: artwork, marquee, scrubbing and
            // transport have nothing in common with the generic row.
            NowPlayingCardView(
                payload: payload,
                actions: nowPlayingActions,
                isCompactWidth: isCompactWidth,
                swapResponse: swapResponse,
                swapDamping: swapDamping
            )
        case .timer(let payload):
            TimerCardView(
                payload: payload,
                onContentHeight: onTimerHeight,
                actions: timerActions,
                isCompactWidth: isCompactWidth
            )
        case .levels:
            LevelsCardView(actions: levelsActions, isCompactWidth: isCompactWidth, liveLevel: liveLevel)
        case .shelf(let payload):
            ShelfCardView(payload: payload, actions: shelfActions, isCompactWidth: isCompactWidth)
        case .device(let payload) where !isCompactWidth:
            // Bluetooth gear gets its own card for the same reason weather does:
            // the generic row buries the product and its battery cells.
            DeviceCardView(payload: payload, isCompactWidth: isCompactWidth)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
        case .focus(let payload) where !isCompactWidth:
            FocusCardView(payload: payload)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
        case .weather(let payload) where !isCompactWidth:
            // The generic row reads as a notification *about* the weather; the
            // weather itself wants the Weather app's own header layout. Duo mode
            // still uses the generic row, which is all that fits there.
            WeatherCardView(payload: payload)
                // Ten, not fifteen: the card sits inside the shape's own
                // gutter inset as well, so fifteen here put the content
                // twenty-six points from the edge — a sixth of a three-hundred
                // point card spent on margins, which is what made this one and
                // the two below look pinched next to the media card.
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        default:
            genericCard
        }
    }

    private var genericCard: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                detail
            }
            Spacer(minLength: 0)
            if !isCompactWidth, let trailing = trailingText {
                Text(trailing)
                    .font(.cardBody)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(accent.opacity(0.25))
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(accent)
        }
        // 44, the shared leading-slot width: with the 12 gap and 15 inset,
        // every full card's title starts at x = 71.
        .frame(width: 44, height: 44)
    }

    @ViewBuilder
    private var detail: some View {
        switch activity.payload {
        case .nowPlaying(let payload):
            ProgressBar(progress: payload.progress, tint: accent)
                .frame(height: 3)
                .padding(.top, 2)

        case .device(let payload):
            if !payload.orderedLevels.isEmpty {
                HStack(spacing: 8) {
                    ForEach(payload.orderedLevels, id: \.label) { level in
                        BatteryPill(label: level.label, level: level.level)
                    }
                }
                .padding(.top, 2)
            }

        case .power(let payload):
            ProgressBar(progress: payload.percentage, tint: accent)
                .frame(height: 3)
                .padding(.top, 2)

        case .focus, .event, .message, .weather, .timer, .shelf, .privacy, .keyboard, .levels:
            EmptyView()
        }
    }

    // MARK: - Content

    private var title: String {
        switch activity.payload {
        case .nowPlaying(let payload): payload.title
        case .device(let payload): payload.name
        case .power(let payload): payload.isCharging ? "Charging" : "Battery"
        case .focus(let payload): payload.name
        case .event(let payload): payload.hasEvent ? payload.title : "Calendar"
        case .message(let payload): payload.title
        case .weather(let payload):
            "\(WeatherUnits.displayDegrees(celsius: payload.temperatureCelsius, units: weatherUnits))°"
        case .timer(let payload): payload.label
        case .shelf(let payload): payload.items.count == 1 ? "1 item" : "\(payload.items.count) items"
        case .privacy(let payload): payload.title
        case .keyboard(let payload): payload.name
        case .levels: "Levels"
        }
    }

    private var subtitle: String {
        switch activity.payload {
        case .nowPlaying(let payload): payload.artist
        case .device(let payload): payload.isConnected ? "Connected" : "Disconnected"
        case .power(let payload): payload.isLowPower ? "Low Power Mode" : ""
        case .focus(let payload): payload.isActive ? "Focus On" : "Focus Off"
        case .event(let payload): payload.hasEvent ? payload.location : "No events today"
        case .message(let payload): payload.body
        case .weather(let payload):
            payload.city.isEmpty ? payload.condition : "\(payload.condition) — \(payload.city)"
        case .timer(let payload): TimerCardView.clock(payload.remaining)
        case .shelf(let payload): payload.items.first?.name ?? ""
        case .privacy: "In use"
        case .keyboard: "Input source"
        case .levels: "Sound & display"
        }
    }

    private var trailingText: String? {
        switch activity.payload {
        case .nowPlaying(let payload):
            payload.duration > 0 ? Self.clock(payload.duration - payload.elapsed) : nil
        case .power(let payload):
            "\(Int((payload.percentage * 100).rounded()))%"
        case .event(let payload):
            payload.hasEvent ? Self.relative(payload.startsIn) : nil
        case .timer(let payload):
            TimerCardView.clock(payload.remaining)
        case .device(let payload):
            // Battery belongs on the right, beside the name, not buried under it.
            payload.lowestLevel.map { "\(Int(($0 * 100).rounded()))%" }
        case .keyboard(let payload):
            payload.code.isEmpty ? nil : payload.code
        case .focus, .message, .weather, .shelf, .privacy, .levels:
            nil
        }
    }

    private var symbolName: String {
        switch activity.payload {
        case .nowPlaying(let payload): payload.isPlaying ? "waveform" : "pause.fill"
        case .device(let payload): payload.symbolName
        case .power(let payload):
            payload.isCharging ? "battery.100.bolt"
                : (payload.percentage < 0.2 ? "battery.25" : "battery.100")
        case .focus(let payload): payload.symbolName
        case .event: "calendar"
        case .message(let payload): payload.symbolName
        case .weather(let payload): payload.symbolName
        case .timer(let payload):
            payload.mode == .stopwatch ? "stopwatch" : (payload.isBreak ? "cup.and.saucer.fill" : "timer")
        case .shelf: "tray.full.fill"
        case .privacy(let payload): payload.cameraActive ? "video.fill" : "mic.fill"
        case .keyboard(let payload): payload.symbolName ?? "keyboard"
        case .levels: "slider.horizontal.3"
        }
    }

    private var accent: Color {
        switch activity.payload {
        case .nowPlaying(let payload): payload.accent.color
        case .event(let payload): payload.accent.color
        case .power(let payload): payload.percentage < 0.2 ? .red : .green
        case .device(let payload): payload.isApple ? .cyan : .white
        case .focus: .focusAccent
        case .message: .orange
        case .weather(let payload): payload.isDay ? .yellow : .indigo
        case .timer(let payload): payload.isBreak ? .green : .orange
        case .shelf: .teal
        // Apple's own colour language: green for the camera, amber for the mic.
        case .privacy(let payload): payload.cameraActive ? .green : .orange
        case .keyboard: .white
        case .levels: .white
        }
    }

    // MARK: - Formatting

    /// `m:ss`, with the seconds always two digits.
    static func clock(_ seconds: TimeInterval) -> String {
        // Clamped before `Int()`, which traps past 2^63 — and a duration is
        // whatever a media file's tags claim it is. A year of seconds is
        // already beyond anything the label can honestly display.
        let sane = seconds.isFinite ? min(max(0, seconds), 31_536_000) : 0
        let total = Int(sane.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Compact "in 15m" / "in 2h" / "now", for how far off an event is.
    static func relative(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "now" }
        let sane = seconds.isFinite ? min(seconds, 31_536_000) : 0
        let minutes = Int((sane / 60).rounded())
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "in \(hours)h" : "in \(hours)h \(remainder)m"
    }
}

struct ProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    // Clamped: a provider reporting elapsed past duration must
                    // not draw a bar wider than its track.
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
    }
}

struct BatteryPill: View {
    let label: String
    let level: Double

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("\(Int((level * 100).rounded()))%")
                .font(.cardFootnote)
                .monospacedDigit()
                .foregroundStyle(level < 0.2 ? .red : .white.opacity(0.8))
        }
    }
}
