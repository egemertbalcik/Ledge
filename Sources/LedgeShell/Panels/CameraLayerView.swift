import AppKit
import QuartzCore
import SwiftUI

/// Draws the camera's own layer, and nothing else.
///
/// The picture never becomes a SwiftUI image: an
/// `AVCaptureVideoPreviewLayer` is handed to the window server and composited
/// there, so the frames never cross into Ledge's address space. That is the
/// cheap way to draw a camera and also the honest one — the app genuinely
/// cannot see what the lens sees.
struct CameraLayerView: NSViewRepresentable {

    /// Which session is running. A new number means a new layer is owed.
    let sessionID: Int

    /// Makes a layer of this view's own. Every view that draws the picture
    /// gets one: a `CALayer` has a single superlayer, so two panels — which
    /// is any Mac with an external display — cannot share one.
    let make: () -> CALayer?

    func makeNSView(context: Context) -> LayerHost {
        let host = LayerHost()
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.show(make(), from: sessionID)
        return host
    }

    func updateNSView(_ host: LayerHost, context: Context) {
        guard host.sessionID != sessionID else { return }
        host.show(make(), from: sessionID)
    }

    /// A plain layer-backed view whose only job is to keep one sublayer the
    /// size of itself. `AVCaptureVideoPreviewLayer` does not resize with its
    /// host, and a camera drawn at the size the card had on its first frame
    /// is the kind of bug that only shows on a deeper month.
    final class LayerHost: NSView {

        private var shown: CALayer?
        private(set) var sessionID = -1

        func show(_ incoming: CALayer?, from sessionID: Int) {
            self.sessionID = sessionID
            guard shown !== incoming else {
                layoutSublayer()
                return
            }
            shown?.removeFromSuperlayer()
            shown = incoming
            if let incoming {
                incoming.frame = bounds
                layer?.addSublayer(incoming)
            }
            layoutSublayer()
        }

        override func layout() {
            super.layout()
            layoutSublayer()
        }

        private func layoutSublayer() {
            guard let shown else { return }
            // No implicit animation: the layer is resized while the card is
            // already animating, and a second, slower animation on the same
            // frame reads as the picture sliding into place.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shown.frame = bounds
            CATransaction.commit()
        }
    }
}
