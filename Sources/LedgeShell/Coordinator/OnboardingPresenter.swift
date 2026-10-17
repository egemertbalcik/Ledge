import AppKit
import LedgeCore
import LedgeUI
import SwiftUI
import os

/// Owns the welcome tour's window: putting it up, keeping exactly one of it,
/// and noticing every way it can be finished.
///
/// Split out of the coordinator because it is all window: a pinned size, a
/// close observer, and the distinction between finishing and deferring it.
/// What *happens* when the tour is done — permissions, providers,
/// the welcome card — stays with the coordinator, which is the only thing that
/// knows about any of those, and arrives here as one closure.
@MainActor
final class OnboardingPresenter {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "onboarding")

    /// The tour is pinned to this. A step must not be able to resize the
    /// window under the reader — see `show()`.
    private static let windowSize = NSSize(
        width: OnboardingView.contentSize.width,
        height: OnboardingView.contentSize.height
    )

    /// How far under the menu bar the window hangs. The notch is in that bar,
    /// so this is the gap between the thing being taught and the words about
    /// it.
    static let gapUnderTheMenuBar: CGFloat = 14

    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

    /// Whether Ledge itself is going away.
    ///
    /// The close observer treats a close as an answer — "closing is an
    /// answer" is the whole of the tour's exit policy — and a quit closes
    /// every window. Without this, quitting mid-tour would record the tour as
    /// read, which is the one case that *should* bring it back.
    private var isQuitting = false

    var isVisible: Bool { window?.isVisible == true }

    /// Builds the tour's view. A closure because everything it needs — the
    /// settings model, the actions, the links — belongs to the coordinator.
    private let makeView: (@escaping () -> Void) -> OnboardingView

    /// Called once, when the tour is answered — Done, or the close button,
    /// which does the same thing.
    private let onFinish: () -> Void

    /// Puts the window where it belongs: centred on the notch, just under the
    /// menu bar. The coordinator owns the geometry, so it does the placing.
    private let place: (NSWindow) -> Void

    /// The title. A first visit welcomes; a second says what it is, because
    /// by then it is a reference and not an introduction.
    private let title: () -> String

    init(
        makeView: @escaping (@escaping () -> Void) -> OnboardingView,
        place: @escaping (NSWindow) -> Void = { $0.center() },
        title: @escaping () -> String = { TourCopy.title },
        onFinish: @escaping () -> Void
    ) {
        self.makeView = makeView
        self.place = place
        self.title = title
        self.onFinish = onFinish
    }

    /// Ledge is quitting. A window closing from here on is not an answer.
    func appIsQuitting() { isQuitting = true }

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
        window.title = title()
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
        place(window)
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        // Closing is an answer, and the same answer as Done. The opposite
        // rule used to hold — a close left the tour unfinished, so it came
        // back on every launch until somebody reached the end — and that is
        // nagging. It also left Automation shut for good, because the player
        // gate opened only on Done. What the fear behind it was really about,
        // losing the only explanation of an app that lives in a notch, is met
        // by the welcome card the notch plays once and by Settings › General
        // › New to Ledge?.
        //
        // The exception is Ledge itself stopping: see `isQuitting`.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isQuitting else { return }
                self.finish()
            }
        }
    }

    /// Centres the window on the notch, hung just under the menu bar.
    ///
    /// Static so the coordinator can hand it over as the `place` closure
    /// without owning a copy of the arithmetic.
    static func hangUnderTheNotch(_ window: NSWindow, on screen: NSScreen, notchCenterX: CGFloat) {
        window.setFrameOrigin(originUnderTheNotch(
            size: window.frame.size,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            notchCenterX: notchCenterX
        ))
    }

    /// The arithmetic on its own, so it can be checked without a window.
    ///
    /// - Parameters:
    ///   - visibleFrame: the screen minus the menu bar, which is where the
    ///     notch is — so the gap is measured from its top edge.
    static func originUnderTheNotch(
        size: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        notchCenterX: CGFloat,
        gap: CGFloat = OnboardingPresenter.gapUnderTheMenuBar
    ) -> NSPoint {
        let wanted = screenFrame.minX + notchCenterX - size.width / 2
        // A window hanging off the side of the screen is worse than one a
        // little off-centre, which is what a narrow display or an off-centre
        // simulated notch would otherwise produce.
        let lowest = visibleFrame.minX
        let highest = visibleFrame.maxX - size.width
        let x = highest >= lowest ? min(max(wanted, lowest), highest) : wanted
        let y = visibleFrame.maxY - gap - size.height
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// Brings the tour back in front.
    ///
    /// The window stands aside for System Settings while somebody is granting
    /// something, and nothing but an app activation floats it again — so after
    /// a grant made from the tour it sat behind System Settings, in an app
    /// with no Dock icon to go looking for.
    func raise() {
        guard let window else { return }
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Lifts the tour above other applications, or lets it sit among them.
    ///
    /// It floats so it cannot be lost behind whatever the user was doing. It
    /// stops floating while they are answering a system dialog or working in
    /// System Settings, because a permission prompt drawn *underneath* the
    /// window that asked for it is a button that does nothing.
    func setFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
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

/// Lets the Focus folder panel choose one folder and nothing else.
///
/// The grant here is macOS's "user intent" over a protected folder, and the
/// intent Ledge asks for is about `~/Library/DoNotDisturb/DB` — not about
/// whatever folder somebody happened to be looking at when they pressed
/// Grant Access.
final class FocusFolderPanelDelegate: NSObject, NSOpenSavePanelDelegate {

    private let allowed: URL

    init(allowed: URL) {
        self.allowed = allowed
        super.init()
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        Self.isTheFocusFolder(url, allowed: allowed)
    }

    /// Whether a picked folder is the one Ledge asked for.
    ///
    /// Symlinks resolved and paths standardised on both sides: `/Users/me` and
    /// `/System/Volumes/Data/Users/me` are the same folder, and a comparison
    /// of raw strings would reject the right answer.
    static func isTheFocusFolder(_ url: URL, allowed: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL
            == allowed.resolvingSymlinksInPath().standardizedFileURL
    }
}
