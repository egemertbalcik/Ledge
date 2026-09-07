import Foundation
import os

/// Notices that playback changed, without asking anyone.
///
/// The now-playing source has to poll — AppleScript offers no change
/// notification — and the idle interval is deliberately slow so a paused
/// machine is not spawning a subprocess every second. That leaves a gap: press
/// play and the notch can take the better part of the idle interval to react,
/// which reads as the app being laggy rather than thrifty.
///
/// Both players broadcast their own state changes on the *distributed*
/// notification centre, and listening costs nothing until one fires. So the poll
/// stays slow and this wakes it the instant something actually happens.
@MainActor
public final class PlaybackChangeWatcher {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "nowplaying")

    /// Posted by the players themselves on every play, pause and track change.
    private static let names = [
        "com.spotify.client.PlaybackStateChanged",
        "com.apple.iTunes.playerInfo",
    ]

    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func startWatching(_ onChange: @escaping @MainActor () -> Void) {
        stopWatching()
        for name in Self.names {
            let observer = DistributedNotificationCenter.default.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { _ in
                // The player posts as it changes state, and answers AppleScript
                // with the *new* state a moment later. Reading on the next turn
                // of the run loop avoids catching the old one.
                Task { @MainActor in onChange() }
            }
            observers.append(observer)
        }
        Self.log.debug("playback: watching \(Self.names.count, privacy: .public) notifications")
    }

    public func stopWatching() {
        for observer in observers {
            DistributedNotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
