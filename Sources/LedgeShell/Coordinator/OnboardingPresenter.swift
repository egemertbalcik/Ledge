import AppKit
import LedgeCore
import LedgeUI
import SwiftUI
import os

/// Owns the welcome tour's window: putting it up, keeping exactly one of it,
/// and noticing every way it can be finished.
///
/// Split out of the coordinator because it is all window: a pinned size, a
/// close observer, and the fact that closing with the title-bar button counts
/// as an answer. What *happens* when the tour is done — permissions, providers,
/// the welcome card — stays with the coordinator, which is the only thing that
/// knows about any of those, and arrives here as one closure.
@MainActor
final class OnboardingPresenter {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "onboarding")

    /// The tour is pinned to this. A page must not be able to resize the
    /// window under the reader — see `show()`.
    private static let windowSize = NSSize(width: 480, height: 596)

    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

    /// Builds the tour's view. A closure because everything it needs — the
    /// settings model, the actions, the links — belongs to the coordinator.
    private let makeView: (@escaping () -> Void) -> OnboardingView

    /// Called once, whichever way the tour ends.
    private let onFinish: () -> Void

    init(
        makeView: @escaping (@escaping () -> Void) -> OnboardingView,
        onFinish: @escaping () -> Void
    ) {
        self.makeView = makeView
        self.onFinish = onFinish
    }

    /// First launch only, and never in the middle of development.
    ///
    /// - Returns: whether the tour was actually put up. The caller needs to
    ///   know, because a first launch that shows nothing at all looks like a
    ///   launch that failed — see `introduceIfNeeded()`.
    @discardableResult
    func showIfNeeded(hasCompletedOnboarding: Bool) -> Bool {
        guard !hasCompletedOnboarding else {
            Self.log.debug("onboarding: already completed")
            return false
        }
        // Suppressed under debug launches so it does not interrupt development.
        guard !DebugSwitches.isOn("LEDGE_DEBUG") else {
            Self.log.debug("onboarding: suppressed under LEDGE_DEBUG")
            return false
        }
        show()
        return true
    }

    /// Presents the tour: at first launch, and again on request from Settings.
    /// A second request while it is up just brings it forward.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Self.log.notice("onboarding: presenting welcome window")

        let view = makeView { [weak self] in self?.finish() }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Ledge"
        window.isReleasedWhenClosed = false
        // The hosting view is told not to impose its own size on the window,
        // and the window is pinned to one. Between them, no page can make the
        // window grow or shrink as it is stepped through — which it did,
        // because SwiftUI hands a hosting view's ideal size up to its window
        // by default.
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(Self.windowSize)
        window.contentMinSize = Self.windowSize
        window.contentMaxSize = Self.windowSize
        window.center()
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        // Closing with the title-bar button is also a decision: the tour was
        // offered and declined. Without this only "Done" recorded completion
        // and the window re-appeared on every launch.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    /// Tears the window down and tells the coordinator, once.
    func finish() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window?.close()
        window = nil
        onFinish()
    }
}
