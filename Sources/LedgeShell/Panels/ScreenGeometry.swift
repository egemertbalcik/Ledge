import AppKit
import LedgeCore

/// Turns an `NSScreen` into the pure `NotchGeometry` the rest of the app uses.
public enum ScreenGeometry {

    /// Measures the notch from public API only.
    ///
    /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are the two menu-bar
    /// strips either side of the cutout. The gap between them *is* the notch, and
    /// it is the only public way to get its width. `safeAreaInsets.top` gives its
    /// height. Both are nil/zero on a display without a cutout.
    /// Pretends this Mac is another model, so a geometry that cannot be tested
    /// here can at least be looked at.
    ///
    /// `LEDGE_SIM_DISPLAY=14` (or `16`, or `15`) forces that model's cutout and
    /// panel width. The point is the two things that differ between Macs and
    /// that nobody with one Mac can otherwise see: a taller notch, and a wider
    /// panel.
    private static func simulatedModel() -> (notch: CGSize, millimetres: CGFloat)? {
        switch DebugSwitches.value("LEDGE_SIM_DISPLAY") {
        case "14": (CGSize(width: 190, height: 38), 301)
        case "15": (CGSize(width: 180, height: 32), 325)
        case "16": (CGSize(width: 200, height: 38), 344)
        default: nil
        }
    }

    public static func measure(_ screen: NSScreen) -> NotchGeometry {
        let screenSize = screen.frame.size

        if let model = simulatedModel() {
            return NotchGeometry(
                screenSize: screenSize,
                notchSize: model.notch,
                notchCenterX: screenSize.width / 2,
                isHardwareNotch: true,
                displayScale: (min(max(model.millimetres / referenceWidthMillimetres, 1), 1.20) * 100)
                    .rounded() / 100
            )
        }

        guard
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea,
            screen.safeAreaInsets.top > 0
        else {
            return .simulated(screenSize: screenSize)
        }

        let notchWidth = right.minX - left.maxX
        let notchHeight = screen.safeAreaInsets.top

        // A hardware notch is a few hundred points wide. If the arithmetic gives
        // something implausible the API has changed shape — fall back rather
        // than render a broken silhouette.
        guard notchWidth > 40, notchWidth < screenSize.width * 0.6 else {
            return .simulated(screenSize: screenSize)
        }

        // `auxiliaryTopLeftArea`, like every other NSRect on NSScreen, is in the
        // *global* display coordinate space — AppKit has no per-screen space.
        // `notchCenterX` is documented as being measured from this display's
        // left edge, and all three consumers add `screen.frame.minX` back, so
        // the origin has to come off here or it is counted twice. On the
        // built-in display alone `minX` is 0 and the bug is invisible; put an
        // external monitor to the left and the overlay lands off-screen.
        let centerX = left.maxX - screen.frame.minX + notchWidth / 2

        return NotchGeometry(
            screenSize: screenSize,
            notchSize: CGSize(width: notchWidth, height: notchHeight),
            notchCenterX: centerX,
            isHardwareNotch: true,
            displayScale: displayScale(of: screen)
        )
    }

    /// The reference panel these cards were drawn against: the 13-inch Air,
    /// 291mm wide.
    private static let referenceWidthMillimetres: CGFloat = 291

    /// Bigger Macs get proportionally bigger cards — up to a point.
    ///
    /// Measured physically rather than in points on purpose. Every notched Mac
    /// is about 128 points to the inch at its default resolution, so points
    /// track the panel *until* someone picks "More Space", at which point a
    /// 14-inch would report 1800 points and out-scale a 16-inch running its
    /// default. Millimetres cannot be talked into that.
    ///
    /// The ceiling is 1.20: past that the card stops reading as something that
    /// belongs to the notch and starts reading as a window hanging off it.
    static func displayScale(of screen: NSScreen) -> CGFloat {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 1 }

        let millimetres = CGDisplayScreenSize(number.uint32Value).width
        // Zero comes back for a display the WindowServer cannot measure — a
        // virtual one, or a session where EDID is missing. Reference size, not
        // a divide by zero.
        guard millimetres.isFinite, millimetres > 1 else { return 1 }

        let raw = CGFloat(millimetres) / referenceWidthMillimetres
        // Rounded to whole percent so two Macs of the same size cannot disagree
        // by a fraction of a point, and so the number in a log reads cleanly.
        return (min(max(raw, 1), 1.20) * 100).rounded() / 100
    }

    /// The primary display: the notched one when there is one, else the main.
    /// Still the answer for anything that needs a single display — the Settings
    /// window's geometry, the startup log.
    public static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { measure($0).isHardwareNotch }) ?? NSScreen.main
    }

    /// The WindowServer's id for a display.
    ///
    /// `NSScreen` instances are recreated on every reconfiguration and must
    /// never be used as a key. This survives for as long as the display stays
    /// connected — but it is *re-issued* on reconnect, so it is right for an
    /// in-memory panel map and wrong for anything persisted.
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The displays to draw on: only those with a hardware notch.
    ///
    /// Ledge is a MacBook thing by decision. External displays come in every
    /// size, resolution and ratio, and a shape tuned to the built-in cutout
    /// cannot keep its proportions on them; a floating pill was tried and
    /// never looked like the same app. A Mac with no notched display gets
    /// no panel at all — Settings and the menu bar still work, and say so.
    public static func targetScreens() -> [NSScreen] {
        NSScreen.screens.filter { measure($0).isHardwareNotch }
    }
}
