import Foundation
import LedgeCore

/// Replays a `Scenario` as if it were a real source.
///
/// The whole point: the queue, the gestures, the cycling and the cards all
/// get built and proven against this, before a single private Apple API is
/// touched. If MediaRemote turns out to be dead on some future macOS, that costs
/// one provider — not the interaction model.
@MainActor
public final class FakeActivityProvider: ActivityProvider {

    public let identifier: String

    private let scenario: Scenario
    private let loops: Bool
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var pending: [DispatchWorkItem] = []
    private var isRunning = false

    /// Injected so tests can run without wall-clock time.
    private let now: () -> TimeInterval

    public init(
        scenario: Scenario,
        loops: Bool = false,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.identifier = "fake.\(scenario.name)"
        self.scenario = scenario
        self.loops = loops
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                // Termination can arrive on any thread; hop back before touching
                // this actor's state.
                Task { @MainActor [weak self] in self?.stop() }
            }
            self.isRunning = true
            self.schedule()
        }
    }

    public func stop() {
        isRunning = false
        for item in pending { item.cancel() }
        pending.removeAll()
        continuation?.finish()
        continuation = nil
    }

    private func schedule() {
        guard isRunning else { return }
        pending.removeAll()

        for step in scenario.steps {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.emit(step.action)
                }
            }
            pending.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + step.at, execute: item)
        }

        guard loops, let last = scenario.steps.map(\.at).max() else { return }
        let restart = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.schedule()
            }
        }
        pending.append(restart)
        DispatchQueue.main.asyncAfter(deadline: .now() + last + 2, execute: restart)
    }

    private func emit(_ action: Scenario.Action) {
        switch action {
        case .publish(let scenarioActivity):
            guard let activity = try? scenarioActivity.activity(createdAt: now()) else { return }
            continuation?.yield(.publish(activity))
        case .retract(let id):
            continuation?.yield(.retract(id))
        }
    }
}
