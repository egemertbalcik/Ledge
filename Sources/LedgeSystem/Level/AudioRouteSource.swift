import CoreAudio
import Foundation
import LedgeCore
import os

/// Watches which output device the Mac is sending sound to.
@MainActor
public protocol AudioRouteWatching: AnyObject {
    /// Reports the new destination's name whenever it changes. Never fired for
    /// the device already in use when watching began.
    func startWatching(_ onChange: @escaping @MainActor (_ name: String) -> Void)
    func stopWatching()
}

/// Notices sound moving from one device to another.
///
/// "Where is my sound going?" is the most common thing a Mac fails to answer:
/// plug in headphones, join a call, wake at a desk with a monitor attached,
/// and the destination changes with nothing to say so. macOS knows — it just
/// keeps the answer in Control Centre, behind a click, at the moment you are
/// least likely to look.
///
/// The route is a single CoreAudio property with a listener, so this costs one
/// registration and nothing at all until sound actually moves.
@MainActor
public final class AudioRouteSource: AudioRouteWatching {

    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "audioroute")

    /// The listener, the device it last reported, and the session it belongs
    /// to all live on this queue. Registration and the device reads behind a
    /// name are synchronous CoreAudio calls, and the queue handed to the Add
    /// governs only where callbacks arrive, so doing them on the main actor
    /// would put HAL work in front of the interface.
    private let queue = DispatchQueue(label: "com.egemert.ledge.audioroute")

    private nonisolated(unsafe) var onChange: (@MainActor (String) -> Void)?
    private nonisolated(unsafe) var listener: (any AudioRegistration)?
    /// The device in use, so a property notification that reports the same one
    /// — CoreAudio fires on more than just a change of destination — says
    /// nothing.
    private nonisolated(unsafe) var currentDevice: AudioObjectID?
    /// Bumped on every start and stop. A callback the HAL had already queued
    /// can arrive after a stop; cancellation cannot reach into CoreAudio's own
    /// queue, so the session it was made with is what disqualifies it.
    private nonisolated(unsafe) var generation = 0
    private nonisolated(unsafe) var pending = false

    /// Carries the name to the main actor with the session checked *there*.
    /// Checking it only before enqueueing leaves a hop already on the main
    /// queue that a stop cannot reach, and that hop arrives after stopWatching.
    private let mailbox = MainMailbox<String>(isEqual: ==)

    /// Which lifecycle command is the latest. A stop issued before a queued
    /// start has run must win, or the start reopens the session and registers
    /// a listener after the caller has stopped.
    private let lifecycle = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    public func startWatching(_ onChange: @escaping @MainActor (_ name: String) -> Void) {
        stopWatching()
        let command = lifecycle.withLock { c -> Int in c &+= 1; return c }
        let session = mailbox.open { name in MainActor.assumeIsolated { onChange(name) } }
        queue.async { [self] in
            guard lifecycle.withLock({ $0 }) == command else { return }
            self.onChange = onChange
            generation = session
            currentDevice = VolumeController.defaultOutputDevice()

            let address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            listener = AudioListener(
                object: AudioObjectID(kAudioObjectSystemObject),
                address: address,
                queue: queue
            ) { [weak self] in
                self?.noteRouteChanged(session: session)
            }
            if listener == nil {
                Self.log.notice("could not watch the output route")
            }
        }
    }

    public func stopWatching() {
        _ = lifecycle.withLock { c -> Int in c &+= 1; return c }
        // Disqualifies anything already on its way to main.
        mailbox.close()
        queue.async { [self] in
            generation &+= 1
            // Releasing the listener is what unregisters it; there is no
            // address to reconstruct and no way to get it wrong.
            listener = nil
            onChange = nil
            currentDevice = nil
            pending = false
        }
    }

    /// The callback. Sets a flag and asks for one pass; it does not create work
    /// per notification, and a burst leaves one pass rather than a queue.
    private nonisolated func noteRouteChanged(session: Int) {
        // Already on `queue`: this is the queue the listener was registered
        // with.
        guard session == generation, onChange != nil else { return }
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            pending = false
            guard session == generation else { return }
            routeChanged(session: session)
        }
    }

    private nonisolated func routeChanged(session: Int) {
        guard let device = VolumeController.defaultOutputDevice() else { return }
        guard device != currentDevice else { return }
        currentDevice = device
        let name = VolumeController.outputDevices()
            .first { $0.id == device }?
            .name
        guard let name, !name.isEmpty else { return }
        Self.log.debug("output route: \(name, privacy: .public)")
        mailbox.post(name, generation: session)
    }
}
