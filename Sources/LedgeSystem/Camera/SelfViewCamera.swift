import AVFoundation
import Foundation
import LedgeCore
import QuartzCore
import os

/// What the shell needs from a camera.
///
/// A protocol so the whole self-view state machine can be driven in a test
/// without a Mac, a lens, or a person in front of one: the fake answers
/// `access()` with whatever the case under test is about, and hands first
/// frames and failures over by hand.
@MainActor
public protocol SelfViewCapturing: AnyObject {
    var isRunning: Bool { get }
    /// Called once, on the main actor, when the first frame lands.
    var onFirstFrame: (() -> Void)? { get set }
    /// Called when the session gives up on its own.
    var onFailure: (() -> Void)? { get set }
    func access() -> CameraAccess
    func requestAccess() async -> CameraAccess
    /// The unique ID of the camera this would open, or has open. Nil when
    /// there is no front camera to name.
    var deviceID: String? { get }

    /// Whether another application is also reading that camera.
    var isSharedWithAnotherApp: Bool { get }
    /// Starts a session. False when there was nothing to start.
    @discardableResult func start() -> Bool
    /// A layer drawing the running session, or nil when none is running.
    ///
    /// One per view that draws it. A `CALayer` has exactly one superlayer, so
    /// handing the same one to two panels — which is what every Mac with an
    /// external display does — means the second takes it and the first goes
    /// black.
    func makePreviewLayer() -> CALayer?
    func stop()
}

/// The built-in front camera, as a picture and nothing else.
///
/// Ledge never reads a frame. The only thing that leaves this file is a layer
/// for the window server to draw, and the one fact the card is waiting on:
/// that a first frame arrived. The sample buffers that answer that question
/// are counted and dropped on the spot.
///
/// Deliberately narrow: `.builtInWideAngleCamera` at `.front`, never
/// `AVCaptureDevice.default(for: .video)`, which on recent macOS can hand back
/// a Continuity Camera iPhone sitting on the desk. The point of this feature
/// is the camera you are already looking into.
@MainActor
public final class SelfViewCamera: SelfViewCapturing {

    /// Nonisolated: the capture queue writes to it too, and a log line that
    /// can only be written from the main actor is a log line missing from
    /// exactly the failures worth reading about.
    nonisolated private static let log = Logger(subsystem: "com.egemert.ledge", category: "selfview")

    /// Everything AVFoundation touches happens here. `startRunning` blocks for
    /// as long as the hardware takes to wake, which on a cold camera is most
    /// of a second — on the main thread that is the notch frozen mid-press.
    private let queue = DispatchQueue(label: "com.egemert.ledge.selfview", qos: .userInitiated)

    private var session: AVCaptureSession?
    private var sink: FirstFrameSink?

    /// Counts the sessions, so an answer can say which one it is about.
    private var generation = 0
    private var runtimeErrorToken: NSObjectProtocol?

    /// Called once, on the main actor, when the first frame lands.
    public var onFirstFrame: (() -> Void)?

    /// Called on the main actor when the session gives up on its own —
    /// a runtime error, or a device yanked out mid-session.
    public var onFailure: (() -> Void)?

    public init() {}

    /// Whether a session is up. `true` from the moment `start` is called, not
    /// from the first frame: the camera light is on for all of it.
    public private(set) var isRunning = false

    /// Which camera Ledge opens: the built-in front one, by the same unique
    /// ID macOS reports for it everywhere else.
    ///
    /// Read rather than remembered, and available before anything starts:
    /// Ledge's own privacy card needs to know the identity at the press, not
    /// at the first frame, or a camera somebody else starts in between is
    /// mistaken for this one.
    ///
    /// The two frameworks do agree on the string — checked on the hardware:
    /// `AVCaptureDevice.uniqueID` and CoreMediaIO's
    /// `kCMIODevicePropertyDeviceUID` report the same UUID for the built-in
    /// camera, which is what makes the privacy rule in `CameraCover` work on
    /// a real Mac rather than only in a test.
    public var deviceID: String? { Self.frontCamera()?.uniqueID }

    /// Whether another application is also reading the camera Ledge shows.
    ///
    /// The one question a device's running state cannot answer, and the
    /// reason Ledge's privacy card can keep quiet about its own preview
    /// without keeping quiet about anybody else's use of the same lens.
    public var isSharedWithAnotherApp: Bool {
        Self.frontCamera()?.isInUseByAnotherApplication ?? false
    }

    /// What macOS says, right now.
    ///
    /// Asked on every press rather than cached: the answer is changed in
    /// System Settings, where Ledge is not, and a reading taken at launch is
    /// a reading about a different afternoon.
    public func access() -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // Only once allowed: an unasked Mac may not list devices at all,
            // and "No camera found" is a worse lie than asking first.
            return Self.frontCamera() == nil ? .missing : .allowed
        case .notDetermined:
            return .notAsked
        case .denied:
            return .refused
        case .restricted:
            return .blocked
        @unknown default:
            return .refused
        }
    }

    /// Puts macOS's own dialog up, and answers with the reading afterwards.
    public func requestAccess() async -> CameraAccess {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return access()
    }

    /// Starts the camera.
    ///
    /// False when there is nothing to start — no camera on this Mac. The
    /// caller is expected to have checked `access()` first; this is the
    /// second line, not the first.
    @discardableResult
    public func start() -> Bool {
        if session != nil { return true }
        guard Self.frontCamera() != nil else {
            Self.log.notice("selfview: no front camera")
            return false
        }

        // The session is made here, empty, and filled in on the capture
        // queue. Building an input and committing a configuration takes a
        // tenth of a second or so on a cold camera, and the press that starts
        // all this happens on the main thread — the notch would freeze
        // mid-animation for exactly as long as the hardware felt like taking.
        let session = AVCaptureSession()

        // Which session this is. Every answer that comes back from the queue
        // or from a notification carries it, because a frame that was already
        // in flight when a session was closed must not certify the *next*
        // one: it would arrive as "live" for a session that has not yet shown
        // anything, and the ten seconds that would otherwise have given up
        // on it are only counted while it is still waking.
        generation += 1
        let generation = generation

        // The sink delivers on the main queue, so this is already there.
        let sink = FirstFrameSink { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.generation == generation else { return }
                self.onFirstFrame?()
            }
        }

        self.session = session
        self.sink = sink
        self.isRunning = true
        watchForRuntimeErrors(on: session, generation: generation)

        queue.async { [weak self] in
            // Anything that goes wrong down here is reported on the main
            // actor. `assumeIsolated` would not have got it there: it asserts
            // that the caller is already on the main actor rather than moving
            // it, so a camera unplugged between discovery and input would
            // have been a crash instead of a sentence.
            func giveUp(_ why: StaticString) {
                Self.log.error("selfview: \(why, privacy: .public)")
                Task { @MainActor [weak self] in
                    self?.reportFailure(generation: generation)
                }
            }
            guard let device = Self.frontCamera(),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                giveUp("the camera refused an input")
                return
            }
            session.beginConfiguration()
            // A notch-sized picture. Asking for more is heat and battery
            // spent on pixels a 126-point frame throws away.
            session.sessionPreset = .vga640x480
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                giveUp("the session refused the camera")
                return
            }
            session.addInput(input)

            // The first-frame signal. Frames are dropped late and never read:
            // the delegate counts one and says so.
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(sink, queue: self?.queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()

            // A layer made before the input existed got its connection from
            // `addInput`, with the system's default: unmirrored. On a cold
            // camera that is the first press every time. After the commit, so
            // a connection formed by the commit itself is mirrored too.
            for connection in session.connections where connection.videoPreviewLayer != nil {
                Self.mirror(connection)
            }

            session.startRunning()
        }

        Self.log.notice("selfview: starting")
        return true
    }

    /// A layer for one view to draw, bound to the running session.
    ///
    /// Mirrored, always, and never by the system's own judgement. Unmirrored,
    /// your hair parts on the wrong side and the person in the notch reads as
    /// a stranger rather than as you.
    public func makePreviewLayer() -> CALayer? {
        guard let session else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Only there when the input already is; otherwise the capture queue
        // mirrors it once the input arrives.
        if let connection = layer.connection { Self.mirror(connection) }
        return layer
    }

    nonisolated private static func mirror(_ connection: AVCaptureConnection) {
        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    /// The session could not be built. Treated exactly as a session that
    /// never produced a frame, because from the card that is what it is.
    private func reportFailure(generation: Int) {
        guard isRunning, self.generation == generation else { return }
        stop()
        onFailure?()
    }

    /// Lets the camera go.
    ///
    /// Called before anything on screen moves, so the green light goes out at
    /// the moment of the press rather than at the end of an animation.
    public func stop() {
        guard let session else { return }
        isRunning = false
        if let runtimeErrorToken {
            NotificationCenter.default.removeObserver(runtimeErrorToken)
        }
        runtimeErrorToken = nil
        self.session = nil
        sink = nil
        // Off the main thread for the same reason as starting: stopping waits
        // for the hardware too.
        queue.async { session.stopRunning() }
        Self.log.notice("selfview: stopped")
    }

    private func watchForRuntimeErrors(on session: AVCaptureSession, generation: Int) {
        runtimeErrorToken = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.generation == generation else { return }
                Self.log.error("selfview: the session failed while running")
                self.onFailure?()
            }
        }
    }

    /// Nonisolated: the capture queue looks the camera up for itself, so the
    /// main thread never waits on a device enumeration.
    nonisolated private static func frontCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        ).devices.first
    }
}

/// Counts exactly one frame and says so.
///
/// Its own object because a sample-buffer delegate is called on a background
/// queue, and the camera is main-actor. `@unchecked Sendable` is carried by
/// the one rule that makes it true: the only mutable thing here is the flag,
/// and it is only ever touched on the delivery queue.
private final class FirstFrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    private var reported = false
    private let announce: @Sendable () -> Void

    init(announce: @escaping @Sendable () -> Void) {
        self.announce = announce
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !reported else { return }
        reported = true
        DispatchQueue.main.async { [announce] in announce() }
    }
}
