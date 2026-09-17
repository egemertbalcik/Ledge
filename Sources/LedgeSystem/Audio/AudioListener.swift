import CoreAudio
import CoreMediaIO
import Foundation
import LedgeAudioListen
import os

/// One CoreAudio or CoreMediaIO property listener, for as long as this object
/// is held.
///
/// Registration is ownership here: the listener is installed when the object is
/// made and removed when it goes, so the only way to leak one is to keep the
/// object forever, which is visible in the code that keeps it. The previous
/// shape — an array of `(object, address, block)` tuples and a `stopWatching`
/// that walked it — looked balanced and was not, because the removal never
/// matched. See `LedgeAudioListen.h` for why.
///
/// A failed removal is logged rather than swallowed. It should now be
/// impossible: the pointer handed to CoreAudio for removal is the pointer it
/// was registered with. If it ever appears in the log, this file is wrong.
public final class AudioListener {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "audio")

    /// What kind of tree the registration lives in — the two APIs are
    /// separate and a token from one must never be handed to the other.
    private enum Tree { case audio, camera }

    private var token: OpaquePointer?
    private let tree: Tree
    private let describe: String

    /// - Returns: nil if CoreAudio refused the registration, which is normal
    ///   for a property a device does not have. Callers check `HasProperty`
    ///   first; this is the backstop for the race where it goes away between.
    public init?(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        var status: OSStatus = noErr
        guard let token = ledge_audio_listen_add(object, address, queue, handler, &status) else {
            Self.log.debug("""
                no listener for object \(object, privacy: .public) \
                selector \(address.mSelector, privacy: .public) \
                (status \(status, privacy: .public))
                """)
            return nil
        }
        self.token = token
        self.tree = .audio
        self.describe = "object \(object) selector \(address.mSelector)"
    }

    public init?(
        cmioObject: CMIOObjectID,
        address: CMIOObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        var status: OSStatus = noErr
        guard let token = ledge_cmio_listen_add(cmioObject, address, queue, handler, &status) else {
            Self.log.debug("""
                no camera listener for object \(cmioObject, privacy: .public) \
                (status \(status, privacy: .public))
                """)
            return nil
        }
        self.token = token
        self.tree = .camera
        self.describe = "camera object \(cmioObject)"
    }

    /// Takes the listener off. Safe to call more than once; the second call
    /// does nothing rather than unregistering something else.
    public func cancel() {
        guard let token else { return }
        self.token = nil
        let status = switch tree {
        case .audio: ledge_audio_listen_remove(token)
        case .camera: ledge_cmio_listen_remove(token)
        }
        if status != noErr {
            Self.log.error("""
                listener would not come off — \(self.describe, privacy: .public) \
                status \(status, privacy: .public)
                """)
        }
    }

    deinit { cancel() }
}
