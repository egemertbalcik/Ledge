import AppKit
import LedgeCore
import LedgeUI
import SwiftUI
import os

/// The overlay window.
///
/// It is created once at the maximum size the content will ever need and is
/// never resized. Animating an `NSWindow` frame in step with SwiftUI content
/// desyncs — `setFrame` is committed by the WindowServer on its own schedule
/// while the spring runs in the app's CA transaction, and they come apart at
/// exactly the overshoot. Keeping the window fixed makes the whole animation a
/// pure `Shape` size change.
@MainActor
public final class LedgePanel: NSPanel {

    public init(contentRect: NSRect, hideFromCapture: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        // Never take focus: the app is an accessory and must not interrupt
        // whatever the user is typing into.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false

        // Click-through by default. The coordinator flips this on only while the
        // cursor is actually over the drawn shape — see `LedgePanelController`.
        ignoresMouseEvents = true

        // The window's position is the notch's position — it must never be
        // draggable. NSPanel is movable by default, and a drag that started on
        // the card's background picked the whole overlay up and carried it off
        // the hardware cutout.
        isMovable = false
        isMovableByWindowBackground = false

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
        ]

        // Keeps the panel out of screenshots and screen shares. That also hides
        // it from any tooling used to check how it looks, so there is an opt-out
        // for development.
        setHideFromCapture(hideFromCapture)
    }

    /// Applied at construction and again when the preference changes — the
    /// panel outlives the settings window, so a toggle must reach it live.
    public func setHideFromCapture(_ hide: Bool) {
        let allowCapture = DebugSwitches.isOn("LEDGE_ALLOW_CAPTURE")
        sharingType = (hide && !allowCapture) ? .none : .readOnly
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Installs the SwiftUI content, pinned to the top of the panel so the shape
    /// hangs down from the screen edge.
    public func install<Content: View>(_ view: Content) {
        // The notch is hardware: its leading ear is on the physical left in
        // every language. SwiftUI would mirror the ears' HStack and the
        // satellite's leading alignment under an RTL system language while
        // the shape path and the hit zones stay put — the satellite drawn on
        // the side the shape did not inset for. Pin the overlay to LTR.
        let hosting = NotchHostingView(rootView: view.environment(\.layoutDirection, .leftToRight))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

/// A hosting view that refuses the safe area.
///
/// On a notched display AppKit hands any window overlapping the top of the
/// screen a safe-area top inset equal to the notch height, and SwiftUI dutifully
/// lays the content out *below* the cutout — which is exactly the region this
/// app exists to draw in. `NSHostingView.safeAreaRegions` and `.ignoresSafeArea()`
/// both operate a level above this; the inset itself comes from `NSView`, so it
/// has to be overridden here.
@MainActor
final class NotchHostingView<Content: View>: NSHostingView<Content> {

    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// The panel deliberately never becomes key, which means every click into
    /// it is a "first mouse" click. AppKit delivers those only to views that
    /// opt in — otherwise the click is consumed as an activation click and the
    /// transport buttons and scrubber would silently do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Owns the panel for one display: sizing, placement, hit regions, and
/// re-placement when the display configuration changes.
@MainActor
public final class LedgePanelController {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "panel")

    public private(set) var geometry: NotchGeometry
    private let preferences: Preferences
    private let presentation: NotchPresentation
    private let onTap: () -> Void
    private let nowPlayingActions: NowPlayingActions
    private let timerActions: TimerActions
    private let shelfActions: ShelfActions
    private let levelsActions: LevelsActions
    private let onDropFiles: ([URL]) -> Bool
    private let onHUDAdjust: (HUDReadout.Kind, Double) -> Void
    private let onHUDAdjustDisplay: (UInt32, Double) -> Void
    private let onHUDDragging: (Bool) -> Void
    private var panel: LedgePanel?
    private var screen: NSScreen?

    /// Watches for the moments a panel can silently drop out of the window
    /// list — a Space change, an app activation, sleep/wake — so it can be
    /// put back. See `reassert()`.
    private var spaceToken: (any NSObjectProtocol)?
    private var activationToken: (any NSObjectProtocol)?

    /// The display this controller owns, keyed by the WindowServer's id.
    public let displayID: CGDirectDisplayID

    public init(
        displayID: CGDirectDisplayID,
        screen: NSScreen,
        preferences: Preferences,
        presentation: NotchPresentation,
        onTap: @escaping () -> Void,
        nowPlayingActions: NowPlayingActions = NowPlayingActions(),
        timerActions: TimerActions = TimerActions(),
        shelfActions: ShelfActions = ShelfActions(),
        levelsActions: LevelsActions = LevelsActions(),
        onDropFiles: @escaping ([URL]) -> Bool = { _ in false },
        onHUDAdjust: @escaping (HUDReadout.Kind, Double) -> Void = { _, _ in },
        onHUDAdjustDisplay: @escaping (UInt32, Double) -> Void = { _, _ in },
        onHUDDragging: @escaping (Bool) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.presentation = presentation
        self.onTap = onTap
        self.nowPlayingActions = nowPlayingActions
        self.timerActions = timerActions
        self.shelfActions = shelfActions
        self.levelsActions = levelsActions
        self.onDropFiles = onDropFiles
        self.onHUDAdjust = onHUDAdjust
        self.onHUDAdjustDisplay = onHUDAdjustDisplay
        self.onHUDDragging = onHUDDragging
        self.displayID = displayID
        self.screen = screen
        self.geometry = ScreenGeometry.measure(screen)
    }

    /// Sized for the largest state the content can reach, plus headroom for the
    /// spring's overshoot, so nothing is ever clipped.
    private func panelSize(for geometry: NotchGeometry) -> CGSize {
        CGSize(
            width: geometry.screenSize.width,
            height: min(geometry.screenSize.height * 0.6, 520)
        )
    }

    private func panelFrame(on screen: NSScreen, geometry: NotchGeometry) -> NSRect {
        let size = panelSize(for: geometry)
        return NSRect(
            x: screen.frame.minX + geometry.notchCenterX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func overlayView(_ geometry: NotchGeometry) -> NotchOverlayView {
        NotchOverlayView(
            geometry: geometry,
            preferences: preferences,
            presentation: presentation,
            onTap: onTap,
            nowPlayingActions: nowPlayingActions,
            timerActions: timerActions,
            shelfActions: shelfActions,
            levelsActions: levelsActions,
            onDropFiles: onDropFiles,
            onHUDAdjust: onHUDAdjust,
            onHUDAdjustDisplay: onHUDAdjustDisplay,
            displayID: displayID,
            onHUDDragging: onHUDDragging
        )
    }

    public func show() {
        guard let screen else { return }
        geometry = ScreenGeometry.measure(screen)

        let panel = LedgePanel(
            contentRect: panelFrame(on: screen, geometry: geometry),
            hideFromCapture: preferences.hideFromScreenCapture
        )
        panel.install(overlayView(geometry))
        panel.orderFrontRegardless()
        self.panel = panel

        Self.log.notice("""
            panel: frame=\(panel.frame.debugDescription, privacy: .public) \
            screen=\(screen.frame.debugDescription, privacy: .public) \
            hardware=\(self.geometry.isHardwareNotch, privacy: .public) \
            hideFromCapture=\(self.preferences.hideFromScreenCapture, privacy: .public)
            """)

        startReassertion()
    }

    /// Ledge stays on screen whatever else is running — including over a
    /// full-screen app, which `.canJoinAllSpaces` allows. It used to order
    /// itself out there, and a notch that vanished under a full-screen window
    /// read as the app having crashed.
    ///
    /// What is left is the repair: a panel can silently drop out of the window
    /// list across Space churn or a long sleep, with nothing to bring it back
    /// before the next relaunch. Both notifications simply re-assert it.
    private func startReassertion() {
        stopReassertion()
        let centre = NSWorkspace.shared.notificationCenter
        spaceToken = centre.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reassert() } }
        activationToken = centre.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reassert() } }
    }

    private func stopReassertion() {
        let centre = NSWorkspace.shared.notificationCenter
        if let spaceToken { centre.removeObserver(spaceToken) }
        spaceToken = nil
        if let activationToken { centre.removeObserver(activationToken) }
        activationToken = nil
    }

    /// Ordering an already-front panel is a no-op, so this is safe to call on
    /// every notification.
    private func reassert() {
        panel?.orderFrontRegardless()
    }

    /// Re-reads the screenshot-hiding preference onto the live panel.
    public func applyCapturePreference() {
        panel?.setHideFromCapture(preferences.hideFromScreenCapture)
    }

    /// Re-measures and repositions after a display change, sleep/wake, or a
    /// resolution switch.
    /// Tears the panel down for good — the display it lived on is gone.
    ///
    /// Nothing used to destroy a controller, which was harmless with exactly one
    /// of them and a leak per hot-plug with several.
    public func tearDown() {
        stopReassertion()
        panel?.orderOut(nil)
        panel = nil
        screen = nil
    }

    public func reposition(on screen: NSScreen) {
        self.screen = screen
        reposition()
    }

    public func reposition() {
        // If the panel was never created — no display existed at launch, which
        // happens with a login item starting before the WindowServer session is
        // ready, or with the lid shut — this is the moment to create it. Without
        // this the app runs headless for the rest of its life, since `show()` is
        // only ever called once.
        guard panel != nil else {
            show()
            return
        }
        guard let panel, let screen else { return }
        let measured = ScreenGeometry.measure(screen)
        let frame = panelFrame(on: screen, geometry: measured)

        // Nothing actually moved. Reinstalling the hosting view here would
        // reset SwiftUI's animation state mid-spring, and a screen-parameter
        // burst fires this several times for one change — so plugging in a
        // second display must not disturb the built-in display's panel.
        guard measured != geometry || panel.frame != frame else { return }

        geometry = measured
        panel.setFrame(frame, display: true)
        panel.install(overlayView(measured))
        panel.orderFrontRegardless()
    }

    /// Whether clicks land on the panel or pass through to whatever is beneath.
    ///
    /// Returning `nil` from `hitTest` does not forward an event downward — the
    /// WindowServer has already routed it here — so `ignoresMouseEvents` is the
    /// only real mechanism. The panel spans the full screen width, so leaving it
    /// interactive would swallow clicks across a wide empty strip.
    public func setInteractive(_ interactive: Bool) {
        guard let panel, panel.ignoresMouseEvents == interactive else { return }
        panel.ignoresMouseEvents = !interactive
        Self.log.debug("interactive=\(interactive, privacy: .public)")
    }

    /// The drawn shape, in global screen coordinates, for a given phase.
    /// This is both the hover region and the click region.
    private func expandedSize(for phase: NotchPhase) -> CGSize {
        presentation.cardSize(preferences: preferences, geometry: geometry, phase: phase)
    }

    /// The panel's CG window number, for excluding the overlay from a screen
    /// capture of what lies behind it.
    public var windowNumber: UInt32? {
        panel.map { UInt32($0.windowNumber) }
    }

    public func shapeRect(for phase: NotchPhase, hudHovered: Bool = false, hudExtraHeight: CGFloat = 0) -> CGRect? {
        guard let screen else { return nil }
        let layout = NotchLayout.layout(
            for: phase,
            geometry: geometry,
            // Must match `NotchOverlayView`: the calendar's expanded month grid
            // grows the shape, so the hit region has to grow with it or a click
            // near the grid's edge would fall through.
            expandedSize: expandedSize(for: phase),
            bottomRadius: preferences.bottomRadius,
            closedBottomRadius: preferences.closedBottomRadius,
            gutterRadius: preferences.gutterRadius,
            // The hovered HUD grows downward for its adjustment bar; the hit
            // region must include that or dragging the bar would fall through.
            isHudInteractive: hudHovered,
            hudExtraHeight: hudExtraHeight
        )
        let size = layout.boundingSize
        let rect = CGRect(
            x: screen.frame.minX + geometry.notchCenterX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        return rect
    }
}
