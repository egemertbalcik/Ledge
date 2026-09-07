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

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "audioroute")

    private var onChange: (@MainActor (String) -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?
    /// The device in use, so a property notification that reports the same one
    /// — CoreAudio fires on more than just a change of destination — says
    /// nothing.
    private var currentDevice: AudioObjectID?

    public init() {}

    public func startWatching(_ onChange: @escaping @MainActor (_ name: String) -> Void) {
        stopWatching()
        self.onChange = onChange
        currentDevice = VolumeController.defaultOutputDevice()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in self?.routeChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        )
        guard status == noErr else {
            Self.log.notice("could not watch the output route (status \(status, privacy: .public))")
            return
        }
        listener = block
    }

    public func stopWatching() {
        if let listener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
        }
        listener = nil
        onChange = nil
        currentDevice = nil
    }

    private func routeChanged() {
        guard let device = VolumeController.defaultOutputDevice() else { return }
        guard device != currentDevice else { return }
        currentDevice = device
        let name = VolumeController.outputDevices()
            .first { $0.id == device }?
            .name
        guard let name, !name.isEmpty else { return }
        Self.log.debug("output route: \(name, privacy: .public)")
        onChange?(name)
    }
}
