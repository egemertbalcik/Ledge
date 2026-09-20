import CoreAudio
import CoreMediaIO
import Foundation
import LedgeAudioListen
import os

/// One CoreAudio or CoreMediaIO property listener, for as long as this object
/// is held.
///
/// Registration is ownership: the listener is installed when the object is made
/// and removed when it goes. The shape this replaced — an array of
/// `(object, address, block)` tuples walked by a `stopWatching` — looked
/// balanced and was not, because Swift cannot hand CoreAudio the same block
/// pointer twice and the removal matched nothing. `LedgeAudioListen.h` has the
/// detail.
///
/// Removal is handed to a `ListenerCleanup`, which owns itself until it
/// succeeds or spends its budget. That matters: this wrapper is usually
/// released the instant after `cancel()` — dropped from an array — and a retry
/// that depended on it would find it gone and quietly give up, which is the
/// original leak arriving by another door.
///
/// This class makes *its own* registrations removable. It says nothing about
/// the rest of the app, and it does not promise that no callback is in flight:
/// handlers capture weakly and check their session, because a removal CoreAudio
/// accepted can still be followed by a callback it had already queued.
public final class AudioListener: AudioRegistration, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "audio")

    private struct State: @unchecked Sendable {
        /// nil once removal has been handed over, so a second `cancel` — or a
        /// `deinit` racing one — cannot hand the same token over twice.
        var token: ListenerToken?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let tree: ListenerTree
    private let queue: DispatchQueue
    private let describe: String

    /// - Returns: nil if the hardware refused, which is ordinary for a property
    ///   a device does not have. Callers check `hasProperty` first; this is the
    ///   backstop for the race where it goes away in between.
    public init?(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        // Central admission. A registration that could not be removed is
        // still installed inside CoreAudio, so adding replacements on top of a
        // pile of them is the original runaway in slow motion. Checked here
        // rather than at each caller, because every caller — volume, route,
        // recording, camera — has the same obligation and the one that forgets
        // is the one that leaks.
        guard ListenerQuarantine.shared.acceptsReplacements else {
            Self.log.error("refusing a new listener: earlier removals are stuck")
            return nil
        }

        var status: OSStatus = noErr
        guard let raw = ledge_audio_listen_add(object, address, queue, handler, &status) else {
            Self.log.debug("""
                no listener for object \(object, privacy: .public) \
                selector \(address.mSelector, privacy: .public) \
                (status \(status, privacy: .public))
                """)
            return nil
        }
        self.state = OSAllocatedUnfairLock(initialState: State(token: ListenerToken(raw: raw)))
        self.tree = .audio
        self.queue = queue
        self.describe = "object \(object) selector \(address.mSelector)"
    }

    public init?(
        cmioObject: CMIOObjectID,
        address: CMIOObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        // Central admission. A registration that could not be removed is
        // still installed inside CoreAudio, so adding replacements on top of a
        // pile of them is the original runaway in slow motion. Checked here
        // rather than at each caller, because every caller — volume, route,
        // recording, camera — has the same obligation and the one that forgets
        // is the one that leaks.
        guard ListenerQuarantine.shared.acceptsReplacements else {
            Self.log.error("refusing a new listener: earlier removals are stuck")
            return nil
        }

        var status: OSStatus = noErr
        guard let raw = ledge_cmio_listen_add(cmioObject, address, queue, handler, &status) else {
            Self.log.debug("""
                no camera listener for object \(cmioObject, privacy: .public) \
                (status \(status, privacy: .public))
                """)
            return nil
        }
        self.state = OSAllocatedUnfairLock(initialState: State(token: ListenerToken(raw: raw)))
        self.tree = .camera
        self.queue = queue
        self.describe = "camera object \(cmioObject)"
    }

    /// Takes the listener off. Safe to call more than once and from any thread;
    /// a second call does nothing rather than unregistering something else.
    ///
    /// Returns as soon as the removal has been handed over. Whether it needed
    /// one attempt or four is the cleanup's business, and it will outlive this
    /// object to finish.
    public func cancel() {
        guard let token = takeToken() else { return }
        ListenerCleanup(token: token, tree: tree, queue: queue, describe: describe).begin()
    }

    private func takeToken() -> ListenerToken? {
        state.withLock { s -> ListenerToken? in
            defer { s.token = nil }
            return s.token
        }
    }

    deinit {
        // Identical to `cancel`, and for the same reason: the cleanup holds
        // itself, so nothing here is captured and the retries survive this
        // object's destruction.
        guard let token = takeToken() else { return }
        ListenerCleanup(token: token, tree: tree, queue: queue, describe: describe).begin()
    }
}
