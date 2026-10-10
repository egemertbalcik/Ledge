import Foundation
import CoreGraphics

/// Where a note window goes, and how big it is.
///
/// This used to describe a flight as well: the island grew a blob out of its
/// corner, drew it into a neck, pinched it off, and the blob became the window.
/// That is gone. It was a liquid-morph effect with no counterpart anywhere in
/// macOS and it read as one; the window now opens where this says, and its own
/// content springs in from the corner nearest the notch.
public enum NotesGeometry {

    public static let editorSize = CGSize(width: 360, height: 420)

    /// Clamped to the range a notched display can actually have, so a reported
    /// scale that is absurd cannot move the window off the desktop.
    public static func scale(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(1.2, max(1, value)) : 1
    }

    /// Screen coordinates (bottom-up). Place the note near the emitting
    /// corner, with a gap below it, and fit it to the visible desktop.
    public static func landing(island: CGRect, visible: CGRect, scale rawScale: CGFloat = 1) -> CGRect {
        let s = scale(rawScale)
        let margin = min(16 * s, min(visible.width, visible.height) / 4)
        let room = visible.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: min(editorSize.width, room.width), height: min(editorSize.height, room.height))
        let x = min(max(island.midX + 24 * s, room.minX), room.maxX - size.width)
        let y = min(max(island.minY - 16 * s - size.height, room.minY), room.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    public static func local(_ screenRect: CGRect, in panel: CGRect) -> CGRect {
        CGRect(x: screenRect.minX - panel.minX, y: panel.maxY - screenRect.maxY,
               width: screenRect.width, height: screenRect.height)
    }

}
