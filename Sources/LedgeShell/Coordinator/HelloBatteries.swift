import Foundation
import LedgeCore

/// What devices that have just said hello showed of a low battery, held for
/// the alert that would only say it again.
///
/// Earbuds that connect already under a fifth set off two things at once: the
/// hello and the low battery alert. The hello draws that battery in red, so
/// the notch stood up twice in a row for one arrival, "Connected" and then
/// "Battery Low". The hello alone is told.
///
/// Only a battery the hello drew in red counts. A hello that came without
/// levels showed nothing. A rule set above a fifth fires on a ring that is
/// still green. A battery that runs down a moment later was not red at the
/// hello. Each of those alerts is still told, because dropping it would spend
/// the alert on something nobody saw.
struct HelloBatteries {

    /// How long after a hello was shown an alert about a battery it drew is
    /// the same news.
    static let window: TimeInterval = 8

    private var hellos: [(id: ActivityID, payload: DevicePayload, at: TimeInterval)] = []

    /// A hello has been put on screen. Never one that is only waiting its
    /// turn: it may not get one. A device saying hello again takes the place
    /// of what it said before.
    mutating func note(_ hello: DevicePayload, id: ActivityID, at moment: TimeInterval) {
        hellos.removeAll { $0.id == id || moment - $0.at >= Self.window }
        hellos.append((id, hello, moment))
    }

    /// Whether a hello in the last few seconds has shown what this alert is
    /// about. Asking uses nothing up: both earbuds can be low on one arrival
    /// and each sets off its own alert.
    func told(_ alert: DevicePayload, at moment: TimeInterval) -> Bool {
        hellos.contains { hello in
            let elapsed = moment - hello.at
            return elapsed >= 0 && elapsed < Self.window && Self.tells(hello.payload, alert)
        }
    }

    /// Whether the row `hello` stands up with draws in red the battery
    /// `alert` is about.
    ///
    /// The names have to be the same name. The looser rule a sound output is
    /// matched by, where one name may contain the other, would let "AirPods"
    /// answer for "AirPods Pro" and a wrong answer here loses a warning that
    /// does not come back until the battery has been charged.
    static func tells(_ hello: DevicePayload, _ alert: DevicePayload) -> Bool {
        guard let news = alert.alert, news.kind == .low,
              // The row of a goodbye carries no rings, so only a hello passes.
              let row = NotchAnnouncement.forDevice(hello),
              DeviceNameKey.of(hello.name) == DeviceNameKey.of(alert.name)
        else { return false }
        // Bluetooth calls a single battery "Battery" and the alert calls it
        // "Main": the same battery under two labels.
        let about = BatteryComponent(label: news.component)
        return row.batteries.contains {
            BatteryComponent(label: $0.label) == about && $0.level < NotchAnnouncement.Battery.redBelow
        }
    }
}
