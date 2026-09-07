import CoreGraphics
import Foundation

/// What a card actually draws.
///
/// An enum of structs rather than a protocol with existentials: the queue needs
/// value semantics and `Equatable` to diff cheaply, and the view layer gets an
/// exhaustive `switch` that the compiler checks when a new kind is added.
public enum ActivityPayload: Equatable, Sendable {
    case nowPlaying(NowPlayingPayload)
    case device(DevicePayload)
    case power(PowerPayload)
    case focus(FocusPayload)
    case event(EventPayload)
    case message(MessagePayload)
    case weather(WeatherPayload)
    case timer(TimerPayload)
    case shelf(ShelfPayload)
    case privacy(PrivacyPayload)
    case keyboard(KeyboardLayoutPayload)
    case levels(LevelsPayload)
}

/// Which recording hardware is live right now.
public struct PrivacyPayload: Equatable, Sendable, Codable {
    public var cameraActive: Bool
    public var micActive: Bool

    /// The microphone is held by macOS's own speech input — dictation —
    /// rather than by an app.
    ///
    /// Same microphone, same hardware, different sentence. An app listening to
    /// you is a privacy fact and earns the dot. Dictation is something you
    /// started a moment ago by pressing a key, and being told "Microphone" for
    /// it answers a question nobody asked while leaving the obvious one — did
    /// it start? — unanswered.
    public var isSystemSpeech: Bool

    public init(cameraActive: Bool = false, micActive: Bool = false, isSystemSpeech: Bool = false) {
        self.cameraActive = cameraActive
        self.micActive = micActive
        self.isSystemSpeech = isSystemSpeech
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraActive = try c.decodeIfPresent(Bool.self, forKey: .cameraActive) ?? false
        micActive = try c.decodeIfPresent(Bool.self, forKey: .micActive) ?? false
        isSystemSpeech = try c.decodeIfPresent(Bool.self, forKey: .isSystemSpeech) ?? false
    }

    /// What to call it, given what is on.
    public var title: String {
        switch (cameraActive, micActive) {
        case (true, true): "Camera & Mic"
        case (true, false): "Camera"
        case (false, true): isSystemSpeech ? "Dictation" : "Microphone"
        case (false, false): "Idle"
        }
    }
}

/// One file parked in the shelf.
public struct ShelfItem: Equatable, Sendable, Codable, Identifiable {
    /// The path doubles as identity: the same file cannot be in the shelf twice.
    public var id: String { path }

    public var path: String
    public var name: String
    public var isDirectory: Bool

    /// The file's icon as PNG bytes.
    ///
    /// Bytes rather than an image because `LedgeCore` may not see AppKit, and the
    /// icon is produced by `NSWorkspace` in the system layer — the same crossing
    /// `NowPlayingPayload.artworkData` already makes. Excluded from `Codable`
    /// for the same reason artwork is: a base64 blob in a fixture is unreadable.
    public var iconData: Data?

    /// When this entry should leave the shelf on its own, or nil to stay until
    /// it is taken out.
    ///
    /// Only automatic arrivals carry one. A file the user dropped is a
    /// deliberate act and stays until they say otherwise; a screenshot Ledge
    /// picked up on their behalf was never asked for, and a shelf that fills
    /// with a week of them is a mess the user has to tidy rather than a
    /// convenience.
    public var expiresAt: TimeInterval?

    public init(
        path: String,
        name: String,
        isDirectory: Bool = false,
        iconData: Data? = nil,
        expiresAt: TimeInterval? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.iconData = iconData
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case path, name, isDirectory, expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? (path as NSString).lastPathComponent
        isDirectory = try c.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        expiresAt = try c.decodeIfPresent(TimeInterval.self, forKey: .expiresAt)
        iconData = nil
    }

    /// Compares icons by presence, not by bytes — the path already identifies
    /// the file, so a pixel comparison on every diff would be pure waste.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path
            && lhs.name == rhs.name
            && lhs.isDirectory == rhs.isDirectory
            && (lhs.iconData == nil) == (rhs.iconData == nil)
    }
}

/// Files the user has parked in the notch.
public struct ShelfPayload: Equatable, Sendable, Codable {
    public var items: [ShelfItem]

    public init(items: [ShelfItem] = []) {
        self.items = items
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([ShelfItem].self, forKey: .items) ?? []
    }
}

/// A running countdown — a plain timer or one leg of a pomodoro cycle.
public struct TimerPayload: Equatable, Sendable, Codable {
    /// What this leg is called: "Focus", "Break", or a user's own label.
    public var label: String
    /// Seconds left. Recomputed from a deadline by the provider, never
    /// decremented, so sleep and timer coalescing cannot make it drift.
    public var remaining: TimeInterval
    /// The full length of this leg, for the ring.
    public var total: TimeInterval
    /// False while paused.
    public var isRunning: Bool
    /// Set on the one publish that announces the leg is over.
    public var isFinished: Bool
    /// Tints the ring and picks the glyph.
    public var isBreak: Bool
    /// Work sessions completed in this cycle, drawn as a row of dots.
    public var completedSessions: Int

    /// A one-off countdown started from a duration chip, outside the
    /// pomodoro cycle: no auto-advance, no cycle dots, no skip.
    public var isCustom: Bool

    /// True on the standing "ready" card: no countdown exists and the
    /// stopwatch is at zero, so the card offers the presets. This is what
    /// makes the timer startable from the notch at all — the empty-state
    /// hints only render when *no* card is selected, which a machine with
    /// weather or a calendar never reaches.
    public var isIdle: Bool

    /// Which face the running card wears. `.countdown` while a leg or quick
    /// timer exists (the stopwatch may run alongside, in its own segment);
    /// `.stopwatch` when only the stopwatch is going — then `remaining` is the
    /// elapsed time and `total` is zero, so the ears and the satellite read a
    /// count-up through the same fields.
    public var mode: Mode

    /// The stopwatch, carried on every publish so its segment is always live.
    public var stopwatch: StopwatchState

    /// Recently used quick-timer lengths in minutes, freshest first — the
    /// iOS Timer's Recents, offered as chips on the ready card.
    public var recents: [Int]

    public enum Mode: String, Equatable, Sendable, Codable {
        case countdown
        case stopwatch
    }

    public init(
        label: String,
        remaining: TimeInterval,
        total: TimeInterval,
        isRunning: Bool = true,
        isFinished: Bool = false,
        isBreak: Bool = false,
        completedSessions: Int = 0,
        isCustom: Bool = false,
        isIdle: Bool = false,
        mode: Mode = .countdown,
        stopwatch: StopwatchState = StopwatchState(),
        recents: [Int] = []
    ) {
        self.label = label
        self.remaining = max(0, remaining)
        self.total = max(0, total)
        self.isRunning = isRunning
        self.isFinished = isFinished
        self.isBreak = isBreak
        self.completedSessions = max(0, completedSessions)
        self.isCustom = isCustom
        self.isIdle = isIdle
        self.mode = mode
        self.stopwatch = stopwatch
        self.recents = Array(recents.prefix(3))
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        remaining = max(0, try c.decodeIfPresent(TimeInterval.self, forKey: .remaining) ?? 0)
        total = max(0, try c.decodeIfPresent(TimeInterval.self, forKey: .total) ?? 0)
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? true
        isFinished = try c.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        isBreak = try c.decodeIfPresent(Bool.self, forKey: .isBreak) ?? false
        completedSessions = max(0, try c.decodeIfPresent(Int.self, forKey: .completedSessions) ?? 0)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        isIdle = try c.decodeIfPresent(Bool.self, forKey: .isIdle) ?? false
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .countdown
        stopwatch = try c.decodeIfPresent(StopwatchState.self, forKey: .stopwatch) ?? StopwatchState()
        recents = Array((try c.decodeIfPresent([Int].self, forKey: .recents) ?? []).prefix(3))
    }

    /// A countdown leg or quick timer exists (running, paused or finished).
    public var hasCountdown: Bool { !isIdle && mode == .countdown }

    /// 0...1, how much of the leg has elapsed. Guarded against a zero total so
    /// the ring never divides by zero.
    public var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(1 - remaining / total, 0), 1)
    }
}

/// The stopwatch, as pure state: elapsed time is derived from a start
/// instant, never accumulated by ticks, so the card can draw centiseconds
/// from its own clock while the provider republishes only on the second.
public struct StopwatchState: Equatable, Sendable, Codable {
    /// Elapsed seconds banked before the current run (zero when never run).
    public var elapsedBase: TimeInterval
    /// Reference-date instant the current run began; nil while stopped.
    public var runningSince: TimeInterval?
    /// Cumulative elapsed at each lap, oldest first.
    public var laps: [TimeInterval]

    public init(elapsedBase: TimeInterval = 0, runningSince: TimeInterval? = nil, laps: [TimeInterval] = []) {
        self.elapsedBase = elapsedBase.isFinite ? max(0, elapsedBase) : 0
        self.runningSince = runningSince?.isFinite == true ? runningSince : nil
        self.laps = laps.filter(\.isFinite).map { max(0, $0) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = try c.decodeIfPresent(TimeInterval.self, forKey: .elapsedBase) ?? 0
        elapsedBase = base.isFinite ? max(0, base) : 0
        let since = try c.decodeIfPresent(TimeInterval.self, forKey: .runningSince)
        runningSince = since?.isFinite == true ? since : nil
        laps = (try c.decodeIfPresent([TimeInterval].self, forKey: .laps) ?? []).filter(\.isFinite).map { max(0, $0) }
    }

    public var isRunning: Bool { runningSince != nil }
    /// Running, or stopped with time on the clock — anything but a fresh zero.
    public var isActive: Bool { isRunning || elapsedBase > 0 || !laps.isEmpty }

    /// Elapsed seconds at `now`. Clamped so a clock jump backwards never
    /// shows negative time.
    public func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let runningSince else { return elapsedBase }
        return elapsedBase + max(0, now - runningSince)
    }

    /// The current lap's own length at `now` — since the last lap mark, or
    /// since the start.
    public func currentLap(at now: TimeInterval) -> TimeInterval {
        max(0, elapsed(at: now) - (laps.last ?? 0))
    }
}

/// A colour, without importing SwiftUI into the core.
public struct AccentColor: Equatable, Sendable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let neutral = AccentColor(red: 0.62, green: 0.62, blue: 0.66)
}

public struct NowPlayingPayload: Equatable, Sendable, Codable {
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var elapsed: TimeInterval
    public var duration: TimeInterval
    public var sourceName: String
    public var accent: AccentColor

    /// Identity of the artwork, used both for caching and for equality.
    public var artworkKey: String?

    /// Encoded artwork bytes. Not part of `Codable`: fixtures reference no
    /// images, and a base64 blob in a JSON fixture would be unreadable.
    public var artworkData: Data?

    /// Whether the card is a doorway to an application — see `MediaOwner`.
    /// False for a web page, which has no app of its own to open.
    public var ownerIsApp: Bool

    /// Something watched rather than listened to. It gets a card while it
    /// plays, and never a place in the ears — see `Activity.restsInEars`.
    public var kind: MediaKind

    public var isVideo: Bool { kind == .video }

    /// Live: there is no end to count down to.
    ///
    /// A broadcast, a radio station, a match happening now. The card shows
    /// how long you have been watching rather than how long is left, because
    /// how long is left is not a thing that exists.
    public var isLive: Bool

    /// Whether this may hold the ears while it plays.
    ///
    /// Decided by the provider, not here, because it depends on a preference
    /// and on how long the thing runs — and because every surface that draws
    /// the compact view has to agree about it. When they disagreed, the island
    /// opened for a video the ears then refused to draw, and the notch sat
    /// there with two empty ears.
    public var showsInCompact: Bool

    public init(
        title: String,
        artist: String,
        album: String = "",
        isPlaying: Bool = true,
        elapsed: TimeInterval = 0,
        duration: TimeInterval = 0,
        sourceName: String = "",
        accent: AccentColor = .neutral,
        artworkKey: String? = nil,
        artworkData: Data? = nil,
        kind: MediaKind = .audio,
        showsInCompact: Bool = true,
        isLive: Bool = false,
        ownerIsApp: Bool = false
    ) {
        self.ownerIsApp = ownerIsApp
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = duration
        self.sourceName = sourceName
        self.accent = accent
        self.artworkKey = artworkKey
        self.artworkData = artworkData
        self.kind = kind
        self.showsInCompact = showsInCompact
        self.isLive = isLive
    }

    /// Compares the artwork by key rather than by bytes.
    ///
    /// This runs on every poll — several times a second — and a full `Data`
    /// comparison of a cover image on each one would be pure waste. The key
    /// already changes whenever the image does.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.isPlaying == rhs.isPlaying
            && lhs.elapsed == rhs.elapsed
            && lhs.duration == rhs.duration
            && lhs.sourceName == rhs.sourceName
            && lhs.accent == rhs.accent
            && lhs.artworkKey == rhs.artworkKey
            && lhs.kind == rhs.kind
            && lhs.showsInCompact == rhs.showsInCompact
            && lhs.isLive == rhs.isLive
            && lhs.ownerIsApp == rhs.ownerIsApp
            && (lhs.artworkData == nil) == (rhs.artworkData == nil)
    }

    private enum CodingKeys: String, CodingKey {
        case title, artist, album, isPlaying, elapsed, duration, sourceName, accent, artworkKey,
             kind, showsInCompact, isLive, ownerIsApp
    }

    /// 0...1, guarded against a zero or unknown duration so the bar never
    /// divides by zero or runs off the end.
    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? true
        elapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .elapsed) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        accent = try c.decodeIfPresent(AccentColor.self, forKey: .accent) ?? .neutral
        artworkKey = try c.decodeIfPresent(String.self, forKey: .artworkKey)
        artworkData = nil
        kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .audio
        showsInCompact = try c.decodeIfPresent(Bool.self, forKey: .showsInCompact) ?? true
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        // Defaults to "not a doorway": a fixture or an older payload that says
        // nothing must not offer to open an app it never named.
        ownerIsApp = try c.decodeIfPresent(Bool.self, forKey: .ownerIsApp) ?? false
    }
}

public struct DevicePayload: Equatable, Sendable, Codable {
    public var name: String
    public var symbolName: String
    /// 0...1 per component. Empty when the device reports no battery.
    public var batteryLevels: [String: Double]
    public var isConnected: Bool
    /// Apple's own gear keeps the tinted icon; everything else is drawn white.
    /// A third-party mouse rendered in Apple-blue reads as a system component
    /// that it is not.
    public var isApple: Bool

    /// A word for the trailing ear, when there is no battery to draw there.
    ///
    /// The device cards were built around hardware that reports a charge, so
    /// the far ear either held a ring or held nothing. The switches and the
    /// route changes have no charge and still have something to say — "Off",
    /// "On", the name of the thing sound just moved to — and a lone glyph in
    /// one ear left the other side of the notch empty and the message half
    /// told.
    public var statusText: String?

    /// How that word is drawn.
    ///
    /// A switch's state is a *state* and deserves the badge Caps Lock uses —
    /// green when on, quiet when off, unmistakable in a row of rapid toggles.
    /// A device's name is just a name, and a name in a badge reads as a state
    /// it is not.
    public enum StatusStyle: String, Equatable, Sendable, Codable {
        case plain
        case badge
    }

    public var statusStyle: StatusStyle

    public init(
        name: String,
        symbolName: String = "headphones",
        batteryLevels: [String: Double] = [:],
        isConnected: Bool = true,
        isApple: Bool = false,
        statusText: String? = nil,
        statusStyle: StatusStyle = .plain
    ) {
        self.name = name
        self.symbolName = symbolName
        self.batteryLevels = batteryLevels
        self.isConnected = isConnected
        self.isApple = isApple
        self.statusText = statusText
        self.statusStyle = statusStyle
    }

    /// The cell that matters — the one that dies first.
    public var lowestLevel: Double? { batteryLevels.values.min() }

    /// Stable ordering so the labels do not shuffle between renders — a
    /// dictionary's iteration order is not guaranteed.
    public var orderedLevels: [(label: String, level: Double)] {
        batteryLevels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "headphones"
        batteryLevels = try c.decodeIfPresent([String: Double].self, forKey: .batteryLevels) ?? [:]
        isConnected = try c.decodeIfPresent(Bool.self, forKey: .isConnected) ?? true
        isApple = try c.decodeIfPresent(Bool.self, forKey: .isApple) ?? false
        statusText = try c.decodeIfPresent(String.self, forKey: .statusText)
        statusStyle = try c.decodeIfPresent(StatusStyle.self, forKey: .statusStyle) ?? .plain
    }
}

/// The keyboard layout that was just switched to.
public struct KeyboardLayoutPayload: Equatable, Sendable, Codable {
    /// "Turkish", "ABC" — the name System Settings uses.
    public var name: String
    /// Two letters for the compact view: "TR", "EN".
    public var code: String
    /// A specific glyph when the generic keyboard is wrong — Caps Lock wants
    /// its own filled/outlined pair so on and off read at a glance.
    public var symbolName: String?

    public init(name: String, code: String = "", symbolName: String? = nil) {
        self.name = name
        self.code = code
        self.symbolName = symbolName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName)
    }
}

public struct PowerPayload: Equatable, Sendable, Codable {
    public var percentage: Double
    public var isCharging: Bool
    public var isLowPower: Bool
    public var timeRemaining: TimeInterval?

    public init(
        percentage: Double,
        isCharging: Bool = false,
        isLowPower: Bool = false,
        timeRemaining: TimeInterval? = nil
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isLowPower = isLowPower
        self.timeRemaining = timeRemaining
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percentage = try c.decode(Double.self, forKey: .percentage)
        isCharging = try c.decodeIfPresent(Bool.self, forKey: .isCharging) ?? false
        isLowPower = try c.decodeIfPresent(Bool.self, forKey: .isLowPower) ?? false
        timeRemaining = try c.decodeIfPresent(TimeInterval.self, forKey: .timeRemaining)
    }
}

public struct FocusPayload: Equatable, Sendable, Codable {
    public var name: String
    public var symbolName: String
    public var isActive: Bool

    public init(name: String, symbolName: String = "moon.fill", isActive: Bool = true) {
        self.name = name
        self.symbolName = symbolName
        self.isActive = isActive
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "moon.fill"
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

/// One day's events, for the month grid's day detail.
public struct MonthDayEvents: Equatable, Sendable, Codable, Identifiable {
    /// Day of the month, 1...31.
    public var day: Int
    /// Titles and times, in the order they occur.
    public var entries: [MonthDayEntry]

    public var id: Int { day }

    public init(day: Int, entries: [MonthDayEntry] = []) {
        self.day = day
        self.entries = entries
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(Int.self, forKey: .day)
        entries = try c.decodeIfPresent([MonthDayEntry].self, forKey: .entries) ?? []
    }
}

/// One month's worth of event data, so the grid's arrows have something to
/// show beyond the current month without a round-trip to EventKit.
public struct MonthWindow: Equatable, Sendable, Codable, Identifiable {
    public var year: Int
    /// 1...12.
    public var month: Int
    public var eventDays: [Int]
    public var events: [MonthDayEvents]

    /// Stable across years, so navigation cannot confuse two Januaries.
    public var id: Int { year * 100 + month }

    public init(year: Int, month: Int, eventDays: [Int] = [], events: [MonthDayEvents] = []) {
        self.year = year
        self.month = month
        self.eventDays = eventDays
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = try c.decode(Int.self, forKey: .year)
        month = try c.decode(Int.self, forKey: .month)
        eventDays = try c.decodeIfPresent([Int].self, forKey: .eventDays) ?? []
        events = try c.decodeIfPresent([MonthDayEvents].self, forKey: .events) ?? []
    }
}

/// A single event on a day: what it is and when.
public struct MonthDayEntry: Equatable, Sendable, Codable, Identifiable {
    /// EventKit's calendarItemIdentifier, for deep-linking into Calendar.app.
    /// Empty when unknown (fixtures, older payloads) — the row then renders
    /// as plain text instead of a link.
    public var eventID: String

    public var title: String
    /// Pre-formatted local time, or empty for an all-day event.
    public var time: String

    /// The eventID folded in so two same-titled events at the same time (twin
    /// "Birthday" all-day entries) stay distinct rows for SwiftUI's diffing.
    public var id: String { "\(time)-\(title)-\(eventID)" }

    public init(title: String, time: String = "", eventID: String = "") {
        self.title = title
        self.time = time
        self.eventID = eventID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID) ?? ""
    }
}

public struct EventPayload: Equatable, Sendable, Codable {
    public var title: String
    public var location: String
    /// Seconds until it starts. Negative once it has begun.
    public var startsIn: TimeInterval
    public var accent: AccentColor

    /// Whether there is any event at all. When false the card shows the empty
    /// state ("No events") and the other fields are placeholders.
    public var hasEvent: Bool

    /// A video-call link for the shown event, so the card can offer a Join
    /// button as the meeting approaches.
    public var meetingURL: String?

    /// Day numbers in the current month that have events, for the month grid
    /// to dot.
    public var monthEventDays: [Int]

    /// What is on each of those days, so tapping one can say what it was.
    /// Keyed by day number; a day with no entry simply has nothing to show.
    public var monthEvents: [MonthDayEvents]

    /// Adjacent months (previous/current/next) for the grid's arrows. The
    /// current month's data is duplicated here; `monthEventDays`/`monthEvents`
    /// stay as the flat current-month view most of the UI reads.
    public var monthWindows: [MonthWindow]

    public init(
        title: String,
        location: String = "",
        startsIn: TimeInterval,
        accent: AccentColor = .neutral,
        hasEvent: Bool = true,
        meetingURL: String? = nil,
        monthEventDays: [Int] = [],
        monthEvents: [MonthDayEvents] = [],
        monthWindows: [MonthWindow] = []
    ) {
        self.monthWindows = monthWindows
        self.meetingURL = meetingURL
        self.monthEvents = monthEvents
        self.title = title
        self.location = location
        self.startsIn = startsIn
        self.accent = accent
        self.hasEvent = hasEvent
        self.monthEventDays = monthEventDays
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        startsIn = try c.decode(TimeInterval.self, forKey: .startsIn)
        accent = try c.decodeIfPresent(AccentColor.self, forKey: .accent) ?? .neutral
        hasEvent = try c.decodeIfPresent(Bool.self, forKey: .hasEvent) ?? true
        monthEventDays = try c.decodeIfPresent([Int].self, forKey: .monthEventDays) ?? []
        monthEvents = try c.decodeIfPresent([MonthDayEvents].self, forKey: .monthEvents) ?? []
        monthWindows = try c.decodeIfPresent([MonthWindow].self, forKey: .monthWindows) ?? []
        meetingURL = try c.decodeIfPresent(String.self, forKey: .meetingURL)
    }
}

/// One hour of the forecast strip.
public struct WeatherHourPayload: Equatable, Sendable, Codable, Identifiable {
    /// Hour of the day, 0...23, in the user's own time zone.
    public var hour: Int
    public var temperatureCelsius: Double
    public var symbolName: String
    /// True for the hour currently in progress, which the card labels "Now".
    public var isNow: Bool

    public var id: Int { hour }

    public init(
        hour: Int,
        temperatureCelsius: Double,
        symbolName: String = "cloud.fill",
        isNow: Bool = false
    ) {
        self.hour = hour
        self.temperatureCelsius = temperatureCelsius
        self.symbolName = symbolName
        self.isNow = isNow
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = try c.decode(Int.self, forKey: .hour)
        temperatureCelsius = try c.decode(Double.self, forKey: .temperatureCelsius)
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "cloud.fill"
        isNow = try c.decodeIfPresent(Bool.self, forKey: .isNow) ?? false
    }
}

public struct WeatherPayload: Equatable, Sendable, Codable {
    public var temperatureCelsius: Double
    /// SF Symbol chosen from the condition code, day/night aware.
    public var symbolName: String
    /// Human name of the condition ("Clear", "Rain").
    public var condition: String
    public var city: String
    public var isDay: Bool
    /// Today's range, when the service reports it.
    public var highCelsius: Double?
    public var lowCelsius: Double?
    /// The hours ahead, earliest first. Empty is fine — the card then shows
    /// current conditions alone.
    public var hourly: [WeatherHourPayload]

    /// When this reading was fetched, as a reference-date interval. Zero means
    /// unknown (old payloads, fixtures) and the card shows no freshness line.
    public var fetchedAt: TimeInterval

    /// Minutes until rain starts, when the forecast sees it coming inside two
    /// hours. Nil means dry, already raining, or no minutely data.
    public var rainSoonMinutes: Int?

    /// Whether this reading came from the device's own location.
    ///
    /// The card's location arrow is a claim about *where the numbers came
    /// from*, not decoration: showing it beside a city the user typed says
    /// Ledge is following them around when it is doing nothing of the kind,
    /// and says it loudest to someone who deliberately withheld the
    /// permission.
    public var usesDeviceLocation: Bool

    public init(
        temperatureCelsius: Double,
        symbolName: String = "cloud.fill",
        condition: String = "",
        city: String = "",
        isDay: Bool = true,
        highCelsius: Double? = nil,
        lowCelsius: Double? = nil,
        hourly: [WeatherHourPayload] = [],
        fetchedAt: TimeInterval = 0,
        rainSoonMinutes: Int? = nil,
        usesDeviceLocation: Bool = false
    ) {
        self.usesDeviceLocation = usesDeviceLocation
        self.rainSoonMinutes = rainSoonMinutes
        self.fetchedAt = fetchedAt
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.hourly = hourly
        self.temperatureCelsius = temperatureCelsius
        self.symbolName = symbolName
        self.condition = condition
        self.city = city
        self.isDay = isDay
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperatureCelsius = try c.decode(Double.self, forKey: .temperatureCelsius)
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "cloud.fill"
        condition = try c.decodeIfPresent(String.self, forKey: .condition) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        isDay = try c.decodeIfPresent(Bool.self, forKey: .isDay) ?? true
        highCelsius = try c.decodeIfPresent(Double.self, forKey: .highCelsius)
        lowCelsius = try c.decodeIfPresent(Double.self, forKey: .lowCelsius)
        hourly = try c.decodeIfPresent([WeatherHourPayload].self, forKey: .hourly) ?? []
        fetchedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .fetchedAt) ?? 0
        rainSoonMinutes = try c.decodeIfPresent(Int.self, forKey: .rainSoonMinutes)
        usesDeviceLocation = try c.decodeIfPresent(Bool.self, forKey: .usesDeviceLocation) ?? false
    }
}

public struct MessagePayload: Equatable, Sendable, Codable {
    public var title: String
    public var body: String
    public var symbolName: String

    public init(title: String, body: String = "", symbolName: String = "bell.fill") {
        self.title = title
        self.body = body
        self.symbolName = symbolName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "bell.fill"
    }
}


/// The mouse-driven control card: current sound and brightness, as a place in
/// the cycle rather than a keyboard-summoned HUD.
///
/// The payload is a snapshot for the compact ears; the card itself pulls live
/// values and device lists through its actions, the same way the equalizer
/// pulls its levels — republishing on every hardware tick would churn the
/// queue for numbers only the open card can show.
public struct LevelsPayload: Equatable, Sendable, Codable {
    /// 0...1, the current output's volume at last publish.
    public var volume: Double
    /// 0...1, the primary display's brightness at last publish.
    public var brightness: Double
    /// Whether that output is muted. Carried separately because macOS keeps
    /// the scalar volume at its pre-mute value: a muted Mac still reports 60%,
    /// and a card that believed it drew a bar at 60% over silence.
    public var isMuted: Bool

    public init(volume: Double = 0.5, brightness: Double = 0.5, isMuted: Bool = false) {
        self.volume = volume
        self.brightness = brightness
        self.isMuted = isMuted
    }

    /// What the sound bar should actually show: nothing while muted.
    public var displayedVolume: Double { isMuted ? 0 : volume }

    enum CodingKeys: String, CodingKey {
        case volume
        case brightness
        case isMuted
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.5
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}
