import Foundation
import LedgeCore

/// How hot the Mac says it is.
///
/// Event-driven: `ProcessInfo` posts when the state changes, so nothing here
/// polls. Ledge had no thermal reading before Keep Awake, which is why this is
/// a new adapter rather than a use of an existing one.
@MainActor
public protocol ThermalSource: AnyObject {
    var state: KeepAwakeThermal { get }
    func startWatching(_ onChange: @escaping (KeepAwakeThermal) -> Void)
    func stopWatching()
}

@MainActor
public final class ProcessInfoThermalSource: ThermalSource {

    private var observer: NSObjectProtocol?
    private var onChange: ((KeepAwakeThermal) -> Void)?

    public init() {}

    public var state: KeepAwakeThermal {
        Self.map(ProcessInfo.processInfo.thermalState)
    }

    public func startWatching(_ onChange: @escaping (KeepAwakeThermal) -> Void) {
        stopWatching()
        self.onChange = onChange
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Read back off `self` rather than captured: the notification block
            // is `@Sendable`, and the handler is a main-actor closure that has
            // no business crossing into it.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange?(Self.map(ProcessInfo.processInfo.thermalState))
            }
        }
    }

    public func stopWatching() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        onChange = nil
    }

    static func map(_ state: ProcessInfo.ThermalState) -> KeepAwakeThermal {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}

/// A thermal state the tests can set, public like `StubPowerSource` so the
/// provider's floors can be driven without a Mac that is actually hot.
@MainActor
public final class StubThermalSource: ThermalSource {

    public private(set) var state: KeepAwakeThermal
    private var onChange: ((KeepAwakeThermal) -> Void)?
    public private(set) var isWatching = false

    public init(state: KeepAwakeThermal = .nominal) {
        self.state = state
    }

    public func set(_ state: KeepAwakeThermal) {
        self.state = state
        onChange?(state)
    }

    public func startWatching(_ onChange: @escaping (KeepAwakeThermal) -> Void) {
        self.onChange = onChange
        isWatching = true
    }

    public func stopWatching() {
        onChange = nil
        isWatching = false
    }
}
