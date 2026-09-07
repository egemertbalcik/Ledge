import AppKit
import Foundation
import LedgeCore
import os

/// Owns one `LedgePanelController` per display and keeps that set in step with
/// the hardware.
///
/// The model is N panels, one brain: a single `NotchState`, a single
/// `NotchPresentation` and a single queue are mirrored onto every display. N
/// state machines would multiply every timer, hover race and phase bug by the
/// display count for no benefit — the user wants Ledge *available* everywhere,
/// not independent islands.
@MainActor
public final class DisplayPanels {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "panel")

    /// Screen-order list of live displays. An array rather than a dictionary's
    /// keys because the hit-test scan order must be deterministic.
    public private(set) var order: [CGDirectDisplayID] = []
    private var controllers: [CGDirectDisplayID: LedgePanelController] = [:]

    private let make: (CGDirectDisplayID, NSScreen) -> LedgePanelController
    private var pending: Task<Void, Never>?

    public init(make: @escaping (CGDirectDisplayID, NSScreen) -> LedgePanelController) {
        self.make = make
    }

    public var all: [LedgePanelController] {
        order.compactMap { controllers[$0] }
    }

    /// Fired after every reconcile that changed the panel set, so the
    /// coordinator can drop state that names a display which just left —
    /// the stale hover owner, above all.
    public var onPanelsChanged: () -> Void = {}

    public func controller(for id: CGDirectDisplayID) -> LedgePanelController? {
        controllers[id]
    }

    /// The display Settings and the startup log speak for: the notched one when
    /// there is one, else the first.
    public var primary: LedgePanelController? {
        let preferred = ScreenGeometry.preferredScreen().flatMap(ScreenGeometry.displayID(of:))
        if let preferred, let controller = controllers[preferred] { return controller }
        return order.first.flatMap { controllers[$0] }
    }

    /// Coalesced reconcile.
    ///
    /// `didChangeScreenParameters` fires several times for a single resolution
    /// change, and each one would otherwise rebuild every hosting view and reset
    /// SwiftUI's animation mid-spring.
    public func scheduleReconcile() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.reconcile()
        }
    }

    public func reconcile() {
        var wanted: [(id: CGDirectDisplayID, screen: NSScreen)] = []
        for screen in ScreenGeometry.targetScreens() {
            guard let id = ScreenGeometry.displayID(of: screen) else { continue }
            // Mirrored displays report the same id; one panel is right.
            guard !wanted.contains(where: { $0.id == id }) else { continue }
            wanted.append((id, screen))
        }

        let plan = DisplayReconciler.plan(current: order, wanted: wanted.map(\.id))

        for id in plan.removed {
            controllers[id]?.tearDown()
            controllers[id] = nil
        }
        // Survivors re-measure against a *fresh* `NSScreen`: the old instance is
        // invalid after a reconfiguration. `reposition` no-ops if nothing moved.
        for id in plan.kept {
            guard let screen = wanted.first(where: { $0.id == id })?.screen else { continue }
            controllers[id]?.reposition(on: screen)
        }
        for id in plan.added {
            guard let screen = wanted.first(where: { $0.id == id })?.screen else { continue }
            let controller = make(id, screen)
            controller.show()
            controllers[id] = controller
        }

        order = wanted.map(\.id)

        if !plan.added.isEmpty || !plan.removed.isEmpty {
            Self.log.notice("""
                displays: \(self.order.count, privacy: .public) panel(s) \
                (+\(plan.added.count, privacy: .public) \
                -\(plan.removed.count, privacy: .public))
                """)
            onPanelsChanged()
        }
    }

    public func tearDownAll() {
        pending?.cancel()
        pending = nil
        for controller in controllers.values { controller.tearDown() }
        controllers.removeAll()
        order.removeAll()
    }
}
