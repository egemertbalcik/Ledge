import AppKit
import LedgeCore
import LedgeUI
import SwiftUI

/// Ledge's own icon, as something you can drag into the Accessibility list.
///
/// The case it exists for is the one nothing else in the app can fix: Ledge is
/// not in that list, or the list holds an older copy of it, which looks
/// switched on and grants nothing. macOS lets an application be dragged into
/// that list, and this is that drag.
///
/// `.link` is the only operation it will ever report. A copy-capable drag that
/// missed could leave a second Ledge.app on somebody's desktop — a second copy
/// of a menu-bar app is a thing that would then launch, run beside this one,
/// and be impossible to tell apart. With link only, the worst a stray drop can
/// leave anywhere is an alias.
///
/// AppKit, and in the shell, because `LedgeUI` cannot import it; the guide
/// takes the tile as an opaque view.
@MainActor
final class AppTileView: NSView, NSDraggingSource {

    /// 92 × 92, 12pt corners, a hairline outline that takes the accent under
    /// the pointer.
    static let side: CGFloat = 92

    private let url: URL
    private let name: String
    private let onDragEnded: (AppDragOutcome?) -> Void
    private let onCopyLocation: () -> Void

    private let icon = NSImageView()
    private var mouseDownAt: NSPoint?
    private var isUnderThePointer = false

    /// How far the pointer travels before this becomes a drag rather than a
    /// click. Without it, the smallest shake while pressing the tile started a
    /// drag nobody asked for.
    private static let travelBeforeADrag: CGFloat = 3

    init(
        url: URL,
        name: String,
        onDragEnded: @escaping (AppDragOutcome?) -> Void,
        onCopyLocation: @escaping () -> Void
    ) {
        self.url = url
        self.name = name
        self.onDragEnded = onDragEnded
        self.onCopyLocation = onCopyLocation
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        applyBorder()

        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
        ])

        // The keyboard's and VoiceOver's equal path. The drag cannot be
        // performed without a pointer, so a press here does what Copy
        // Location does — which is the other half of the same instruction.
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(name), \(PermissionGuideCopy.tileHint). Press to copy its location.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func accessibilityPerformPress() -> Bool {
        onCopyLocation()
        return true
    }

    // MARK: - The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isUnderThePointer = true
        applyBorder()
    }

    override func mouseExited(with event: NSEvent) {
        isUnderThePointer = false
        applyBorder()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    private func applyBorder() {
        let accent = NSColor.controlAccentColor
        layer?.borderColor = (isUnderThePointer ? accent : NSColor.tertiaryLabelColor).cgColor
        // Said in the icon as well as the outline: a tile that only changes
        // its hairline is a tile nobody notices is live.
        icon.alphaValue = isUnderThePointer ? 0.88 : 1
    }

    // MARK: - The drag

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownAt = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let here = convert(event.locationInWindow, from: nil)
        let travelled = hypot(here.x - start.x, here.y - start.y)
        guard travelled >= Self.travelBeforeADrag else { return }
        mouseDownAt = nil

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon.image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // A drag that lands nowhere flies home rather than vanishing: the
        // tile is still the thing to try again with. Not with Reduce Motion
        // on, where it simply stops being dragged.
        session.animatesToStartingPositionsOnCancelOrFail =
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Both contexts. Inside the app there is nothing to drop on, and
        // outside it the answer must be link and nothing else.
        .link
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // A drop on the list needs nothing said about it: the grant says it,
        // and the notch announces it. These are the two endings that leave
        // somebody looking at a tile wondering what happened.
        if operation.isEmpty {
            onDragEnded(.missed)
            return
        }
        // Where it landed is not knowable, but which application took it
        // is — at the moment it was taken.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        onDragEnded(front == "com.apple.systempreferences" ? nil : .landedElsewhere)
    }

    /// The tile is a drag source, not a place to pick the window up by.
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The tile, as something SwiftUI can place.
struct AppTile: NSViewRepresentable {

    let url: URL
    let name: String
    let onDragEnded: (AppDragOutcome?) -> Void
    let onCopyLocation: () -> Void

    func makeNSView(context: Context) -> AppTileView {
        AppTileView(
            url: url,
            name: name,
            onDragEnded: onDragEnded,
            onCopyLocation: onCopyLocation
        )
    }

    func updateNSView(_ view: AppTileView, context: Context) {}
}
