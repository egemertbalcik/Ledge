import Foundation
import LedgeCore

/// A scripted sequence of provider events, loaded from JSON.
///
/// This is what makes the whole interaction model developable without AirPods to
/// connect, a calendar event to wait for, or music playing: the same events the
/// real providers will eventually emit, on demand and reproducibly.
public struct Scenario: Codable, Sendable {
    public var name: String
    public var steps: [Step]

    public init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }

    public struct Step: Codable, Sendable {
        /// Seconds after the scenario starts.
        public var at: TimeInterval
        public var action: Action

        public init(at: TimeInterval, action: Action) {
            self.at = at
            self.action = action
        }
    }

    public enum Action: Codable, Sendable {
        case publish(ScenarioActivity)
        case retract(ActivityID)

        private enum CodingKeys: String, CodingKey { case type, activity, id }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "publish":
                self = .publish(try container.decode(ScenarioActivity.self, forKey: .activity))
            case "retract":
                self = .retract(try container.decode(ActivityID.self, forKey: .id))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "unknown action \"\(other)\""
                )
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .publish(let activity):
                try container.encode("publish", forKey: .type)
                try container.encode(activity, forKey: .activity)
            case .retract(let id):
                try container.encode("retract", forKey: .type)
                try container.encode(id, forKey: .id)
            }
        }
    }
}

/// An activity as written in a fixture. Separate from `Activity` so the JSON
/// stays readable and does not have to carry a timestamp.
public struct ScenarioActivity: Codable, Sendable {
    public var kind: ActivityKind
    public var source: String
    public var priority: Int?
    public var expiresAfter: TimeInterval?
    public var nowPlaying: NowPlayingPayload?
    public var device: DevicePayload?
    public var power: PowerPayload?
    public var focus: FocusPayload?
    public var event: EventPayload?
    public var message: MessagePayload?
    public var weather: WeatherPayload?
    public var timer: TimerPayload?
    public var shelf: ShelfPayload?
    public var privacy: PrivacyPayload?
    public var keyboard: KeyboardLayoutPayload?
    public var levels: LevelsPayload?

    public init(
        kind: ActivityKind,
        source: String,
        priority: Int? = nil,
        expiresAfter: TimeInterval? = nil,
        nowPlaying: NowPlayingPayload? = nil,
        device: DevicePayload? = nil,
        power: PowerPayload? = nil,
        focus: FocusPayload? = nil,
        event: EventPayload? = nil,
        message: MessagePayload? = nil,
        weather: WeatherPayload? = nil,
        timer: TimerPayload? = nil,
        shelf: ShelfPayload? = nil,
        privacy: PrivacyPayload? = nil,
        keyboard: KeyboardLayoutPayload? = nil,
        levels: LevelsPayload? = nil
    ) {
        self.kind = kind
        self.source = source
        self.priority = priority
        self.expiresAfter = expiresAfter
        self.nowPlaying = nowPlaying
        self.device = device
        self.power = power
        self.focus = focus
        self.event = event
        self.message = message
        self.weather = weather
        self.timer = timer
        self.shelf = shelf
        self.privacy = privacy
        self.keyboard = keyboard
        self.levels = levels
    }

    public func activity(createdAt: TimeInterval) throws -> Activity {
        let payload: ActivityPayload
        switch kind {
        case .nowPlaying:
            guard let nowPlaying else { throw ScenarioError.missingPayload(kind, source) }
            payload = .nowPlaying(nowPlaying)
        case .device:
            guard let device else { throw ScenarioError.missingPayload(kind, source) }
            payload = .device(device)
        case .power:
            guard let power else { throw ScenarioError.missingPayload(kind, source) }
            payload = .power(power)
        case .focus:
            guard let focus else { throw ScenarioError.missingPayload(kind, source) }
            payload = .focus(focus)
        case .event:
            guard let event else { throw ScenarioError.missingPayload(kind, source) }
            payload = .event(event)
        case .message:
            guard let message else { throw ScenarioError.missingPayload(kind, source) }
            payload = .message(message)
        case .weather:
            guard let weather else { throw ScenarioError.missingPayload(kind, source) }
            payload = .weather(weather)
        case .timer:
            guard let timer else { throw ScenarioError.missingPayload(kind, source) }
            payload = .timer(timer)
        case .shelf:
            guard let shelf else { throw ScenarioError.missingPayload(kind, source) }
            payload = .shelf(shelf)
        case .privacy:
            guard let privacy else { throw ScenarioError.missingPayload(kind, source) }
            payload = .privacy(privacy)
        case .keyboard:
            guard let keyboard else { throw ScenarioError.missingPayload(kind, source) }
            payload = .keyboard(keyboard)
        case .levels:
            payload = .levels(levels ?? LevelsPayload())
        }

        return Activity(
            id: ActivityID(kind: kind, source: source),
            priority: priority,
            createdAt: createdAt,
            expiresAfter: expiresAfter,
            payload: payload
        )
    }
}

public enum ScenarioError: Error, CustomStringConvertible {
    case missingPayload(ActivityKind, String)

    public var description: String {
        switch self {
        case .missingPayload(let kind, let source):
            "scenario activity \(kind.rawValue)/\(source) has no \(kind.rawValue) payload"
        }
    }
}

public enum ScenarioLoader {

    public static func load(contentsOf url: URL) throws -> Scenario {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Scenario.self, from: data)
    }

    /// Every `.json` in a directory, sorted by name so the order is predictable.
    public static func loadAll(in directory: URL) -> [Scenario] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? load(contentsOf: $0) }
    }
}
