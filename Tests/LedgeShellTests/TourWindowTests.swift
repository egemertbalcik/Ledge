import AppKit
import Foundation
import LedgeCore
import Testing

@testable import LedgeShell

/// Where the tour's window hangs.
///
/// The arithmetic only, without a window: the thing being taught is directly
/// above the words, so a window that is centred on the screen instead of on
/// the notch, or that hangs off the side of a narrow one, is the whole design
/// undone.
@MainActor
@Suite("The tour hangs under the notch")
struct TourWindowPlacementTests {

    private let size = NSSize(
        width: 540,
        height: 660
    )

    /// A 14-inch MacBook Pro, menu bar included.
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)

    @Test("Centred on the notch, not on the screen")
    func centredOnTheNotch() {
        // A simulated notch need not be in the middle of the display.
        let origin = OnboardingPresenter.originUnderTheNotch(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            notchCenterX: 600
        )
        #expect(origin.x == (600 - size.width / 2).rounded())
    }

    @Test("Hung just under the menu bar, which is where the notch is")
    func underTheMenuBar() {
        let origin = OnboardingPresenter.originUnderTheNotch(
            size: size,
            screenFrame: screen,
            visibleFrame: visible,
            notchCenterX: 756,
            gap: 14
        )
        // The window's top edge sits the gap below the visible top.
        #expect(origin.y + size.height == visible.maxY - 14)
    }

    @Test("A screen too narrow to centre it keeps it on the screen")
    func clampedToTheScreen() {
        let narrow = NSRect(x: 0, y: 0, width: 900, height: 600)
        let origin = OnboardingPresenter.originUnderTheNotch(
            size: size,
            screenFrame: narrow,
            visibleFrame: narrow,
            notchCenterX: 860
        )
        // Wanted 860 - 270 = 590, which would hang 230pt off the right edge.
        #expect(origin.x == narrow.maxX - size.width)
        #expect(origin.x >= narrow.minX)
    }

    @Test("A second display's own origin is kept")
    func notThePrimaryScreen() {
        // A display to the right of the built-in one: its frame does not
        // start at zero, and the notch's x is measured from its own left edge.
        let right = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let origin = OnboardingPresenter.originUnderTheNotch(
            size: size,
            screenFrame: right,
            visibleFrame: right,
            notchCenterX: 960
        )
        #expect(origin.x == 1512 + 960 - size.width / 2)
    }

    @Test("A screen narrower than the window still produces a usable origin")
    func absurdlyNarrow() {
        let tiny = NSRect(x: 0, y: 0, width: 400, height: 400)
        let origin = OnboardingPresenter.originUnderTheNotch(
            size: size,
            screenFrame: tiny,
            visibleFrame: tiny,
            notchCenterX: 200
        )
        // Nothing can fit, so it is centred rather than clamped to a range
        // that has run backwards.
        #expect(origin.x == (200 - size.width / 2).rounded())
    }
}

/// The one folder the Focus panel may hand over.
@Suite("The Focus folder panel")
struct FocusFolderPanelTests {

    @Test("Only the Focus database folder")
    func onlyTheOneFolder() {
        let allowed = URL(fileURLWithPath: NSHomeDirectory() + "/Library/DoNotDisturb/DB")
        #expect(FocusFolderPanelDelegate.isTheFocusFolder(allowed, allowed: allowed))
        let desktop = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        #expect(!FocusFolderPanelDelegate.isTheFocusFolder(desktop, allowed: allowed))
        // Its own parent is not it either: `~/Library/DoNotDisturb` holds the
        // folder but is not the thing Ledge asked for.
        #expect(!FocusFolderPanelDelegate.isTheFocusFolder(
            allowed.deletingLastPathComponent(), allowed: allowed
        ))
    }

    @Test("The same folder said two ways is the same folder")
    func pathsAreNormalised() {
        let allowed = URL(fileURLWithPath: NSHomeDirectory() + "/Library/DoNotDisturb/DB")
        // What an open panel hands back is not always spelled the way the app
        // spelled it: trailing slashes, `..`, and a symlinked home directory
        // all name the same folder, and a string comparison would reject the
        // right answer.
        let roundabout = URL(fileURLWithPath: NSHomeDirectory() + "/Library/DoNotDisturb/../DoNotDisturb/DB/")
        #expect(FocusFolderPanelDelegate.isTheFocusFolder(roundabout, allowed: allowed))
    }
}
