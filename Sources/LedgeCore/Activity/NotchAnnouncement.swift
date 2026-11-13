import Foundation

/// A thing the notch says out loud, by standing up for a moment.
///
/// Ordinary peeks show a card in the ears for two seconds, which is enough for
/// news you are already half-expecting — a device connecting, a layout
/// switching. It is not enough for the end of something you have been waiting
/// out. A pomodoro finishing is the case that prompted this: twenty-five
/// minutes of not looking at the notch, and the one moment it had something to
/// say went by in the same two-second whisper as everything else. The break
/// had been running for two minutes before it was noticed.
///
/// So this kind of news grows the shape instead — nearly double its resting
/// height, with a strip below the hardware carrying the message, held for a
/// second or two and then gone. Big enough to catch an eye that is elsewhere;
/// far short of opening a card, which would demand attention rather than
/// asking for it.
public struct NotchAnnouncement: Equatable, Sendable {

    /// How long the shape stands up.
    ///
    /// Three seconds. Two was long enough to read *if you were looking*, which
    /// is the one thing that cannot be assumed here: the whole premise is a
    /// person whose eyes are on their work. The point is to be caught by
    /// peripheral vision, and that costs a beat before reading even begins.
    public static let duration: TimeInterval = 3.0

    /// One line. The strip is the height of the cutout and its lower corners
    /// are eaten by the shape's radius, so a second line has nowhere to sit —
    /// the first attempt stacked a title over a subtitle and the subtitle came
    /// out half-swallowed by the curve.
    public var title: String
    public var symbolName: String
    public var accent: AccentColor

    /// Pomodoros finished in this cycle, drawn as the dots the timer card
    /// already uses. Structure that carries something true: at the end of a
    /// session the thing worth knowing besides "stop" is how many you have
    /// done. Zero draws nothing.
    public var completedSessions: Int

    /// A quieter word after the title — a device's "Disconnected". Nil draws
    /// nothing.
    public var detail: String?

    /// One battery a device reports, drawn after the title as a small ring
    /// and its number.
    public struct Battery: Equatable, Sendable {
        public var label: String
        public var level: Double

        public init(label: String, level: Double) {
            self.label = label
            self.level = level
        }
    }

    /// Every battery the device reports, in the order they are worn and read.
    /// Empty draws nothing.
    public var batteries: [Battery]

    /// Whether the shape stands up wider than the peek as well as taller.
    ///
    /// A device's name and up to three batteries are a longer line than
    /// anything the timer says, and at the peek's own width the name was cut
    /// after a word — the complaint the device news started from.
    public var isWide: Bool

    /// Whether the stand-up lasts as long as the user's peek setting rather
    /// than `duration`.
    ///
    /// The end of a pomodoro has to catch eyes that are elsewhere, which is
    /// what the fixed three seconds are for. A device or a sound output is
    /// news the user mostly caused, and it was holding the notch for longer
    /// than "Announcement" in the settings said whatever that was set to.
    public var followsPeekDuration: Bool

    public init(
        title: String,
        symbolName: String,
        accent: AccentColor = .neutral,
        completedSessions: Int = 0,
        detail: String? = nil,
        batteries: [Battery] = [],
        isWide: Bool = false,
        followsPeekDuration: Bool = false
    ) {
        self.title = title
        self.symbolName = symbolName
        self.accent = accent
        self.completedSessions = completedSessions
        self.detail = detail
        self.batteries = batteries
        self.isWide = isWide
        self.followsPeekDuration = followsPeekDuration
    }

    /// How long this stand-up lasts, given the user's peek setting.
    public func duration(peek: TimeInterval) -> TimeInterval {
        followsPeekDuration ? peek : Self.duration
    }

    /// What a device attaching or leaving should say, or nil when the card is
    /// not that news.
    ///
    /// The full name, and either every battery or — with none to show —
    /// whether it came or went. Only cards that say they are a connection
    /// qualify; see `DevicePayload.announcesConnection` for the two that only
    /// look like one.
    public static func forDevice(_ payload: DevicePayload) -> NotchAnnouncement? {
        guard payload.announcesConnection,
              let connected = payload.isConnected,
              !payload.name.isEmpty
        else { return nil }
        let batteries = connected ? orderedBatteries(payload.batteryLevels) : []
        return NotchAnnouncement(
            title: payload.name,
            symbolName: payload.symbolName,
            // Lit while attached, the quiet grey once it has gone.
            accent: connected ? deviceAccent : .neutral,
            detail: connected ? (batteries.isEmpty ? "Connected" : nil) : "Disconnected",
            batteries: batteries,
            isWide: true,
            followsPeekDuration: true
        )
    }

    /// What a change of sound output should say: the full name of where sound
    /// went. The ears used to carry a shortened name beside the cutout, and a
    /// long one still ran out past the shape.
    public static func forSoundOutput(_ payload: DevicePayload) -> NotchAnnouncement? {
        guard !payload.name.isEmpty else { return nil }
        return NotchAnnouncement(
            title: payload.name,
            symbolName: payload.symbolName,
            accent: deviceAccent,
            isWide: true,
            followsPeekDuration: true
        )
    }

    /// Near-white, as the ears draw a device: hardware is not a status.
    private static let deviceAccent = AccentColor(red: 0.93, green: 0.93, blue: 0.95)

    /// Left, Right, Case — the order earbuds are worn and read in, rather than
    /// the alphabet's, which put the case first. Anything else after them.
    static func orderedBatteries(_ levels: [String: Double]) -> [Battery] {
        let order = ["Left": 0, "Right": 1, "Battery": 2, "Case": 3]
        return levels
            .filter { $0.value.isFinite }
            .sorted { (order[$0.key] ?? 9, $0.key) < (order[$1.key] ?? 9, $1.key) }
            .map { Battery(label: $0.key, level: min(max($0.value, 0), 1)) }
    }

    /// What a timer card should say when it lands, or nil when it is not the
    /// sort of arrival worth standing up for.
    ///
    /// Only an *ending* qualifies. A timer starting is something the user just
    /// did and is looking at; a timer ending is the thing they stopped
    /// watching for, which is exactly when the notch has to do the noticing on
    /// their behalf.
    public static func forTimer(_ payload: TimerPayload) -> NotchAnnouncement? {
        guard payload.isFinished else { return nil }
        // Named for what happens next rather than what just stopped. Someone
        // who has not looked at the notch for half an hour needs to know what
        // to do, and "Focus done" makes them work that out for themselves.
        if payload.isBreak {
            return NotchAnnouncement(
                title: "Back to work",
                symbolName: "arrow.trianglehead.clockwise",
                accent: .init(red: 0.35, green: 0.62, blue: 1.0),
                completedSessions: payload.completedSessions
            )
        }
        // A one-off countdown is not a pomodoro and gets neither the cup nor
        // the cycle: nothing about it says a break has started, and borrowing
        // the coffee glyph told the user to go and make one.
        if payload.isCustom {
            return NotchAnnouncement(
                title: "Timer done",
                symbolName: "checkmark.circle.fill",
                accent: .init(red: 0.30, green: 0.78, blue: 0.47)
            )
        }
        return NotchAnnouncement(
            title: "Break time",
            symbolName: "cup.and.saucer.fill",
            accent: .init(red: 0.30, green: 0.78, blue: 0.47),
            completedSessions: payload.completedSessions
        )
    }

    /// What a Keep Awake card should say when it lands, or nil when it is not
    /// worth standing up for.
    ///
    /// Two arrivals qualify, and they are the two the user did not ask for at
    /// that moment. A session that *ended* is a power change: the Mac can
    /// sleep again, and `KeepAwakeCopy` has a sentence saying so for every
    /// reason it can happen for. A session picked up again after a relaunch is
    /// the other: it comes back on its own, and the notch saying so is how the
    /// user learns their Mac is being held awake. Pressing Start is neither —
    /// they are looking at the card they pressed it on.
    public static func forKeepAwake(_ payload: KeepAwakePayload) -> NotchAnnouncement? {
        switch payload.phase {
        case .ready:
            return nil
        case .running:
            guard payload.resumed else { return nil }
            return NotchAnnouncement(
                title: payload.isIndefinite
                    ? KeepAwakeCopy.resumedIndefinitely
                    : KeepAwakeCopy.resumed(
                        remaining: SatelliteContent.keepAwakeLabel(remaining: payload.remaining),
                        until: payload.until
                    ),
                symbolName: "cup.and.saucer.fill",
                accent: keepAwakeAccent
            )
        case .finished(let reason):
            guard reason.isVisible else { return nil }
            return NotchAnnouncement(
                title: KeepAwakeCopy.finished(
                    reason,
                    at: payload.until,
                    floor: payload.batteryFloor,
                    lidClosed: payload.lidClosed
                ),
                symbolName: "cup.and.saucer.fill",
                accent: keepAwakeAccent
            )
        }
    }

    /// Keep Awake's tan, the same one its card and ears wear. Warm rather than
    /// alarming: nothing is wrong, the Mac is simply being held open.
    private static let keepAwakeAccent = AccentColor(red: 0.72, green: 0.56, blue: 0.38)
}
