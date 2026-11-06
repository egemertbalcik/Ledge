import AppKit
import LedgeCore
import LedgeUI
import SwiftUI

/// What the companion needs from a window. A protocol so everything about when
/// it shows can be tested without one appearing on anybody's screen.
@MainActor
protocol PermissionCompanionSurface: AnyObject {
    var isShown: Bool { get }
    /// How tall the panel wants to be with what it is currently saying.
    var contentHeight: CGFloat { get }
    func say(_ content: PermissionCompanionContent)
    func show(at frame: CGRect)
    func hide()
    func announce(_ text: String)
}

/// The panel beside System Settings, for as long as a handoff lasts.
///
/// It has no state of its own about the handoff. The model's `handoff` is the
/// only thing that opens and closes it, so it opens only in answer to a press,
/// and the row, the guide, the notch and this cannot disagree about whether
/// somebody is out granting something.
///
/// Polling is the only way to learn where another application's window is
/// without Accessibility, which is the thing being asked for. It runs only
/// while a handoff is waiting, and the watch behind that ends after four
/// minutes at most.
@MainActor
final class PermissionCompanion {

    private let model: SettingsModel
    private let surface: any PermissionCompanionSurface
    private let read: @MainActor (_ panelHeight: CGFloat) -> PermissionCompanionDock.Reading
    private let sleep: @MainActor (Duration) async -> Void
    private let arrivalHold: @MainActor () -> TimeInterval
    private let arrivalStaysUp: @MainActor () -> Bool

    private var dock = PermissionCompanionDock()
    private var ticking: Task<Void, Never>?
    private var arrival: Task<Void, Never>?
    /// Which permission the panel is out for. Outlives the handoff by one
    /// step, which is how a grant is told from somebody pressing Stop Waiting.
    private var outFor: PermissionKind?
    private var isRunning = false

    /// Four readings a second. A frame still from one reading to the next has
    /// been still for the 200 ms the panel waits before coming back.
    private static let interval: Duration = .milliseconds(250)

    init(
        model: SettingsModel,
        surface: any PermissionCompanionSurface,
        read: @escaping @MainActor (_ panelHeight: CGFloat) -> PermissionCompanionDock.Reading =
            SystemSettingsWindow.reading(panelHeight:),
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        arrivalHold: @escaping @MainActor () -> TimeInterval = {
            PermissionGuideCopy.arrivalHold(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        },
        arrivalStaysUp: @escaping @MainActor () -> Bool = { false }
    ) {
        self.model = model
        self.surface = surface
        self.read = read
        self.sleep = sleep
        self.arrivalHold = arrivalHold
        self.arrivalStaysUp = arrivalStaysUp
    }

    /// Whether the panel is on screen right now, so whoever else might say the
    /// same thing can leave it to the panel.
    var isUp: Bool { surface.isShown }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observe()
        apply()
    }

    func stop() {
        isRunning = false
        ticking?.cancel()
        ticking = nil
        arrival?.cancel()
        arrival = nil
        outFor = nil
        surface.hide()
    }

    /// `withObservationTracking` fires once, so it re-arms itself each time.
    private func observe() {
        withObservationTracking {
            _ = model.handoff
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.apply()
                self.observe()
            }
        }
    }

    private func apply() {
        if let handoff = model.handoff, handoff.phase == .waiting {
            arrival?.cancel()
            arrival = nil
            outFor = handoff.kind
            surface.say(.waiting(handoff))
            startTicking()
            return
        }

        // `.back` is Ledge in front again, with the inline guide and "Still
        // off". Nil is the handoff over, for whatever reason.
        let left = outFor
        outFor = nil
        if let left, surface.isShown, model.handoff == nil, model.status(of: left) == .granted {
            holdArrival(of: left)
        } else if arrival == nil {
            ticking?.cancel()
            ticking = nil
            surface.hide()
        }
    }

    /// The person has gone back, so there is nothing left to say here.
    func endArrival() {
        guard arrival != nil else { return }
        arrival?.cancel()
        arrival = nil
        ticking?.cancel()
        ticking = nil
        surface.hide()
    }

    private func startTicking() {
        guard ticking == nil else { return }
        dock = PermissionCompanionDock()
        ticking = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let pause = self?.tick() else { return }
                await self?.sleep(pause)
            }
        }
    }

    private func tick() -> Duration {
        switch dock.read(read(surface.contentHeight)) {
        case .shown(let frame): surface.show(at: frame)
        case .hidden: surface.hide()
        }
        return Self.interval
    }

    /// Says it is on, for as long as the notch would have, and then goes. Stays
    /// on past that while the asking window is still waiting behind System
    /// Settings, because then this is the way back to it. Keeps following the
    /// window meanwhile, under the same rules as before the grant.
    private func holdArrival(of kind: PermissionKind) {
        surface.say(.arrived(kind))
        surface.announce(PermissionGuideCopy.arrivedTitle(kind.displayName))
        let hold = arrivalHold()
        arrival = Task { @MainActor [weak self] in
            await self?.sleep(.seconds(hold))
            guard let self, !Task.isCancelled, !self.arrivalStaysUp() else { return }
            self.endArrival()
        }
    }
}

/// Where System Settings is, read from outside.
enum SystemSettingsWindow {

    static let bundleIdentifier = "com.apple.systempreferences"

    @MainActor
    static func reading(panelHeight: CGFloat) -> PermissionCompanionDock.Reading {
        let window = frame()
        return PermissionCompanionDock.Reading(
            front: front(),
            window: window,
            visible: window.flatMap(visibleFrame(of:)),
            panelHeight: panelHeight
        )
    }

    @MainActor
    private static func front() -> PermissionCompanionDock.Front {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .passing }
        return classify(
            bundleIdentifier: app.bundleIdentifier,
            isRegular: app.activationPolicy == .regular,
            isSelf: app.processIdentifier == ProcessInfo.processInfo.processIdentifier
        )
    }

    /// Whether somebody is still at System Settings as far as Ledge can tell.
    /// The Touch ID dialog is often still closing when a grant is noticed.
    @MainActor
    static func holdsTheFront() -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
              !NSApp.isActive
        else { return false }
        return front() != .regularApp
    }

    /// Only an application somebody chose to go to counts as leaving. The
    /// Touch ID and password dialogs and macOS's one-time Accessibility
    /// message are not regular applications. Ledge itself is the model's
    /// business: becoming active is what moves the handoff on.
    static func classify(bundleIdentifier: String?, isRegular: Bool, isSelf: Bool) -> PermissionCompanionDock.Front {
        if bundleIdentifier == Self.bundleIdentifier { return .systemSettings }
        return isRegular && !isSelf ? .regularApp : .passing
    }

    /// System Settings' main window, in AppKit coordinates.
    ///
    /// Found by the process, not by the owner name, which is localised. Only
    /// bounds are read: titles would need Screen Recording.
    private static func frame() -> CGRect? {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier,
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        let frames = list.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any]
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        guard let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }),
              let primary = NSScreen.screens.first
        else { return nil }
        return appKitFrame(fromWindowServer: largest, primaryHeight: primary.frame.height)
    }

    /// The window server counts down from the top of the primary display.
    static func appKitFrame(fromWindowServer frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    @MainActor
    private static func visibleFrame(of window: CGRect) -> CGRect? {
        let middle = CGPoint(x: window.midX, y: window.midY)
        return NSScreen.screens.first { $0.frame.contains(middle) }?.visibleFrame
    }
}

/// The real panel.
///
/// `.nonactivatingPanel` is the one thing here that everything depends on.
/// Ledge treats becoming active as somebody coming back from System Settings,
/// so a normal window would end the wait on its first click. It never becomes
/// key either: System Settings keeps the keyboard, and every click here is a
/// first click, which the hosting view and the tile both accept.
@MainActor
final class PermissionCompanionPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PermissionCompanionDock.panelWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        // Ledge is not active for the whole of this panel's life.
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        // On whichever Space System Settings is on, and left out of Mission
        // Control and the window cycle.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The surface, on screen.
@MainActor
final class PermissionCompanionWindow: PermissionCompanionSurface {

    private let makeContent: (PermissionCompanionContent) -> AnyView
    private let hidesFromCapture: () -> Bool

    private lazy var panel = PermissionCompanionPanel()
    private var hosting: NotchHostingView<AnyView>?
    private var said: PermissionCompanionContent?

    private(set) var isShown = false

    /// Long enough to read as arriving, not as popping in, and short enough
    /// not to be watched.
    private static let fade: TimeInterval = 0.18

    init(
        hidesFromCapture: @escaping () -> Bool,
        makeContent: @escaping (PermissionCompanionContent) -> AnyView
    ) {
        self.hidesFromCapture = hidesFromCapture
        self.makeContent = makeContent
    }

    var contentHeight: CGFloat { hosting?.fittingSize.height ?? 0 }

    func say(_ content: PermissionCompanionContent) {
        guard content != said else { return }
        said = content
        if let hosting {
            hosting.rootView = makeContent(content)
        } else {
            let view = NotchHostingView(rootView: makeContent(content))
            // Size is asked for, never pushed to the window: the dock decides
            // the frame, and min and max sizes would fight it.
            view.sizingOptions = [.intrinsicContentSize]
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            hosting = view
        }
    }

    func show(at frame: CGRect) {
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        guard !isShown else { return }
        isShown = true
        let allowCapture = DebugSwitches.isOn("LEDGE_ALLOW_CAPTURE")
        panel.sharingType = (hidesFromCapture() && !allowCapture) ? .none : .readOnly
        fade(to: 1) { [weak panel] in panel?.orderFrontRegardless() }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        fade(to: 0) { }
    }

    func announce(_ text: String) {
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func fade(to alpha: CGFloat, before: () -> Void) {
        let showing = alpha > 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            if showing { before() } else { panel.orderOut(nil) }
            return
        }
        if showing {
            panel.alphaValue = 0
            before()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again while this was fading out: leave it up.
                guard let self, !showing, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
