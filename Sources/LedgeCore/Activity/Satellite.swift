import Foundation

/// What the detached satellite beside the resting island is showing.
///
/// The satellite is one seat with several tenants: a transient level readout
/// or device announcement holds it for a few seconds, a running timer or an
/// active recording indicator stands in it for as long as they last.
public enum SatelliteContent: Equatable, Sendable {

    /// A volume/brightness readout, for its dwell.
    case level(HUDReadout)

    /// A running (or paused) timer session: the standing tenant while music
    /// keeps the main island.
    case timer(remaining: TimeInterval, total: TimeInterval, isBreak: Bool, isRunning: Bool)

    /// The recording indicator: camera and/or microphone in use.
    case privacy(camera: Bool, microphone: Bool)

    /// Dictation, listening. Standing while it lasts, so a glance says
    /// whether the key press took.
    case dictation

    /// A transient device announcement — AirPods connected — shown for the
    /// card's own lifetime instead of a peek.
    case device(symbolName: String, tint: DeviceTint)

    /// The charge flash: plugging in shows a green ring filling to the current
    /// level with the percentage inside — the iPhone's charging moment.
    case charging(level: Double)

    public enum DeviceTint: Equatable, Sendable {
        case neutral
        case charging
    }
}

extension SatelliteContent {

    /// The countdown label the timer blob shows.
    ///
    /// Under an hour it is m:ss; at an hour or more the seconds go and the
    /// units are spelled — "1h 30m", not "1:30", which reads as minutes and
    /// seconds beside the m:ss form. Exact hours drop the " 0m". The boundary
    /// is exact: 3600 reads "1h" and 3599 reads "59:59", so the tick across
    /// the hour never shows a nonsense "0:59".
    public static func timerLabel(remaining: TimeInterval) -> String {
        let sane = remaining.isFinite ? min(max(remaining, 0), 359_940) : 0
        let total = Int(sane.rounded())
        if total >= 3600 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Decides who gets the satellite seat.
///
/// Pure and dumb on purpose: the freshest transient holds the seat for its
/// dwell, then the standing tenants take over. The timer outranks the
/// recording indicator — not because recording matters less, but because
/// macOS already draws its own mic/camera dot in the menu bar, and a browser
/// holding the microphone for an afternoon would otherwise starve the
/// countdown the user actually asked to see behind a redundant signal. A
/// tenant that is also the main island's content never gets the seat (the
/// timer must not orbit itself).
public enum SatelliteArbiter {

    public static func resolve(
        transient: SatelliteContent?,
        privacy: SatelliteContent?,
        timer: SatelliteContent?,
        timerIsMainIsland: Bool,
        dictation: SatelliteContent? = nil
    ) -> SatelliteContent? {
        if let transient { return transient }
        if let timer, !timerIsMainIsland { return timer }
        if let privacy { return privacy }
        // Last of the standing tenants. A recording light is urgent and a
        // countdown is running out; dictation is a few seconds of the user's
        // own doing, so it yields the seat to either.
        if let dictation { return dictation }
        return nil
    }
}
