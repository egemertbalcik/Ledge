import AppKit
import Foundation
import LedgeCore
import Synchronization
import SwiftUI
import Testing

@testable import LedgeShell
@testable import LedgeUI

/// Closing Settings has to stop what Settings was running.
///
/// Found by review: the window is kept and only hidden, and a hidden window's
/// SwiftUI `.task` keeps running. After one visit to Settings, the two-second
/// permission re-read ran on the main thread until quit — in the field, 768
/// more ticks after the window closed, ~94 ms each.
///
/// The real `SettingsView` (it opens on General, whose pane polls) in the real
/// window, off screen, closed the way the red button closes it. Bounded: one
/// window, a counter, about nine seconds of run loop.
@Suite("Closing Settings", .serialized)
@MainActor
struct SettingsCloseTests {

    final class Counter { var refreshes = 0 }

    private static func view(_ counter: Counter, model: SettingsModel) -> SettingsView {
        SettingsView(
            preferences: Preferences(store: MemoryPreferenceStore()),
            geometry: NotchGeometry(
                screenSize: CGSize(width: 1470, height: 956),
                notchSize: CGSize(width: 180, height: 32),
                notchCenterX: 735,
                isHardwareNotch: true
            ),
            actions: SettingsActions(
                setLaunchAtLogin: { _ in true }, loginItemStatus: { "Enabled" },
                copyToClipboard: { _ in }, quit: {},
                refreshPermissions: { counter.refreshes += 1 }
            ),
            model: model
        )
    }

    private static func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Pumps until `condition` holds or `limit` seconds pass. The main actor
    /// is shared with every other suite, so a rate cannot be assumed — only
    /// waited for.
    private static func pump(until limit: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(limit)
        while !condition(), Date() < end {
            spin(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Gives both the run loop and the main actor's jobs their turns.
    private static func pump(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            spin(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("The permission poll stops when the window closes, and starts again when it opens")
    func pollFollowsTheWindow() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let counter = Counter()
        let model = SettingsModel()
        let window = LedgeCoordinator.makeSettingsWindow()
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        var closes = 0
        let token = LedgeCoordinator.releasingContentOnClose(window) { closes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        window.contentView = NSHostingView(rootView: Self.view(counter, model: model))
        window.orderFrontRegardless()
        await Self.pump(until: 15) { counter.refreshes >= 2 }
        // Reached: the pane is General and its poll really runs (on appear,
        // then every two seconds).
        try #require(counter.refreshes >= 2, "the poll ran while open: \(counter.refreshes)")
        try #require(model.shownPane == "general", "the window remembers the pane it shows")

        window.performClose(nil)
        try #require(!window.isVisible)
        #expect(closes == 1)
        #expect(window.contentView == nil, "nothing is left hosted to keep running")
        #expect(LedgeCoordinator.settingsNeedContent(window, geometryChanged: false, paneRequested: false))
        await Self.pump(0.3)
        let atClose = counter.refreshes
        await Self.pump(4.5)
        #expect(counter.refreshes == atClose, "\(counter.refreshes - atClose) refreshes with no window on screen")

        // Opened again, as `showSettings` does: fresh content, same pane.
        window.contentView = NSHostingView(
            rootView: SettingsView(
                preferences: Preferences(store: MemoryPreferenceStore()),
                geometry: NotchGeometry(
                    screenSize: CGSize(width: 1470, height: 956),
                    notchSize: CGSize(width: 180, height: 32),
                    notchCenterX: 735,
                    isHardwareNotch: true
                ),
                actions: SettingsActions(
                    setLaunchAtLogin: { _ in true }, loginItemStatus: { "Enabled" },
                    copyToClipboard: { _ in }, quit: {},
                    refreshPermissions: { counter.refreshes += 1 }
                ),
                model: model,
                startPane: model.shownPane
            )
        )
        window.orderFrontRegardless()
        await Self.pump(until: 15) { counter.refreshes >= atClose + 2 }
        #expect(counter.refreshes >= atClose + 2, "the poll is back while the window is open")
        window.orderOut(nil)
        window.contentView = nil
    }

    final class Loads: Sendable {
        let count = Mutex(0)
    }

    @Test("The Devices pane stops reloading its catalogue when the window closes")
    func devicesStopWithTheWindow() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let loads = Loads()
        let model = SettingsModel()
        model.devices = DevicesSettingsModel(actions: .init(load: {
            loads.count.withLock { $0 += 1 }
            return DeviceCatalogue()
        }))
        let window = LedgeCoordinator.makeSettingsWindow()
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        // What the coordinator passes: the pane is told directly as well.
        let token = LedgeCoordinator.releasingContentOnClose(window) { model.devices?.endWatching() }
        defer { NotificationCenter.default.removeObserver(token) }
        window.contentView = NSHostingView(rootView: SettingsView(
            preferences: Preferences(store: MemoryPreferenceStore()),
            geometry: NotchGeometry(
                screenSize: CGSize(width: 1470, height: 956),
                notchSize: CGSize(width: 180, height: 32),
                notchCenterX: 735,
                isHardwareNotch: true
            ),
            actions: SettingsActions(
                setLaunchAtLogin: { _ in true }, loginItemStatus: { "Enabled" },
                copyToClipboard: { _ in }, quit: {}
            ),
            model: model,
            startPane: "devices"
        ))
        window.orderFrontRegardless()
        await Self.pump(until: 15) { loads.count.withLock { $0 } >= 1 }
        try #require(model.shownPane == "devices")
        try #require(loads.count.withLock { $0 } >= 1, "the pane read the catalogue on opening")

        window.performClose(nil)
        await Self.pump(0.2)
        let atClose = loads.count.withLock { $0 }
        // One refresh interval and a little more.
        await Self.pump(DevicesSettingsModel.refreshInterval + 0.8)
        #expect(loads.count.withLock { $0 } == atClose, "the catalogue kept reloading behind a closed window")
    }

    @Test("Content is rebuilt only when it is missing, the display changed, or a pane was asked for")
    func whenToRebuild() {
        let window = LedgeCoordinator.makeSettingsWindow()
        defer { window.close() }
        window.contentView = NSView()
        #expect(!LedgeCoordinator.settingsNeedContent(window, geometryChanged: false, paneRequested: false),
                "reopening an intact window keeps the pane exactly as it was")
        #expect(LedgeCoordinator.settingsNeedContent(window, geometryChanged: true, paneRequested: false))
        #expect(LedgeCoordinator.settingsNeedContent(window, geometryChanged: false, paneRequested: true))
        window.contentView = nil
        #expect(LedgeCoordinator.settingsNeedContent(window, geometryChanged: false, paneRequested: false))
    }
}
