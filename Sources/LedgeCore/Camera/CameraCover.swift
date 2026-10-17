import Foundation

/// Which running cameras are worth telling the user about while Ledge is
/// showing one itself.
///
/// Ledge's privacy card exists to answer "is my camera on?", and the
/// self-view would otherwise answer it badly in both directions. Left alone,
/// it announces itself — a card reading "Camera in use" over a live picture
/// of the person reading it. Covered with a flag, it hides everybody: an
/// application reaching for a camera *while* the preview is open is exactly
/// the moment the card is for.
///
/// So the rule is identity, not arithmetic. Ledge knows which device it
/// opened, by the same unique ID macOS uses, and that one device is taken out
/// of the reading. Everything else is reported as it always was, whether it
/// started before the preview, during it, or on another camera entirely.
///
/// The one case identity alone cannot answer is a second application reading
/// the *same* device Ledge has open: macOS reports a device as running, never
/// who is reading it. There is one more piece of evidence for that —
/// `AVCaptureDevice.isInUseByAnotherApplication` — and when it says somebody
/// else is on this camera, nothing is subtracted at all. Reporting a camera
/// that turns out to be only Ledge's is noise; failing to report one that is
/// somebody else's is the thing this card exists to prevent.
public struct CameraCover: Equatable, Sendable {

    /// The device Ledge itself opened, while it has one open.
    private var ours: String?

    public init() {}

    public var isCovering: Bool { ours != nil }

    /// The self-view opened on this device.
    ///
    /// Taken at the press, before the session has started: the identity is a
    /// property of the camera Ledge chose, not of when the hardware happens
    /// to appear in a reading. That is what makes a camera started by
    /// somebody else in the same second reportable rather than invisible.
    public mutating func opened(ours device: String?) {
        self.ours = device
    }

    /// The self-view left the screen.
    public mutating func closed() {
        ours = nil
    }

    /// The cameras this reading should be reported as.
    ///
    /// - Parameter oursIsShared: whether another application is also reading
    ///   the device Ledge opened. Then nothing is covered: the picture in the
    ///   notch is not an explanation for somebody else's use of the same
    ///   camera.
    public func reportable(running: Set<String>, oursIsShared: Bool = false) -> Set<String> {
        guard let ours, !oursIsShared else { return running }
        return running.subtracting([ours])
    }
}
