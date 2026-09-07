import Foundation
import LedgeCore

/// Executes `NotchEffect`s.
///
/// The reducer stays pure by expressing timing as data; this is the only place
/// that owns a clock for phase transitions.
@MainActor
public final class EffectRunner {

    private let timers = TimerBank<NotchTimer>()

    /// Called when a timer elapses. Set by the coordinator to feed the reducer.
    public var onTimer: (NotchTimer) -> Void = { _ in } {
        didSet { timers.onFire = onTimer }
    }

    public init() {
        timers.onFire = { [weak self] timer in self?.onTimer(timer) }
    }

    public func run(_ effects: [NotchEffect]) {
        for effect in effects {
            switch effect {
            case .startTimer(let timer, let duration):
                timers.schedule(timer, after: duration)
            case .cancelTimer(let timer):
                timers.cancel(timer)
            }
        }
    }

    public func cancelAll() {
        timers.cancelAll()
    }
}
