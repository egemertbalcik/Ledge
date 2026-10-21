import AppKit
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeShell
@testable import LedgeUI

/// The settings window is built the way System Settings is, and hosting the
/// settings in it leaves it the size it was made.
@Suite("Settings window", .serialized)
@MainActor
struct SettingsWindowTests {

    private func settings() -> SettingsView {
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
                copyToClipboard: { _ in }, quit: {}
            )
        )
    }

    @Test func runsUnderAUnifiedTransparentToolbar() {
        let window = LedgeCoordinator.makeSettingsWindow()
        defer { window.close() }
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.toolbar != nil)
        #expect(window.toolbarStyle == .unified)
    }

    /// The content runs under the bar, so SwiftUI's frame measures only what
    /// lies below it. A minimum taller than that space made AppKit stretch the
    /// window to fit, 26pt taller than it was built.
    @Test func hostingTheSettingsKeepsTheWindowsSize() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = LedgeCoordinator.makeSettingsWindow()
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.contentView = NSHostingView(rootView: settings())
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        // The bar is really there, and the content runs under it.
        #expect(window.contentLayoutRect.height < window.frame.height, "a toolbar takes the top: \(window.contentLayoutRect)")
        #expect(window.frame.size == CGSize(width: 700, height: 626), "the window keeps its size: \(window.frame.size)")
    }
}
