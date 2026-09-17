import CoreAudio
import Foundation
import Testing

@testable import LedgeSystem

/// The regression that matters, written the way the bug was found.
///
/// CoreAudio keeps its listeners in a list it scans linearly, so a registration
/// that is never really removed shows up as a *cost that grows* long before it
/// shows up as anything a user would report. The old code leaked one listener
/// per cycle here and each cycle after it got slower; the shipped app reached
/// 1.5 million of them and spent the main thread entirely on the scan.
///
/// So the assertion is about the shape of the cost, not about a return value:
/// every removal in the broken version returned noErr.
@Suite("Audio listener registration")
struct AudioListenerTests {

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func cycles(_ count: Int, queue: DispatchQueue) -> TimeInterval {
        let start = Date()
        for _ in 0..<count {
            let listener = AudioListener(
                object: systemObject, address: address, queue: queue, handler: {}
            )
            listener?.cancel()
        }
        return Date().timeIntervalSince(start) / Double(count)
    }

    @Test("Registering and unregistering does not get slower")
    func registrationDoesNotAccumulate() {
        let queue = DispatchQueue(label: "test.audio.listener")
        // Warm the HAL connection, whose first call is far dearer than the rest.
        _ = Self.cycles(200, queue: queue)

        let first = Self.cycles(2000, queue: queue)
        _ = Self.cycles(12000, queue: queue)
        let last = Self.cycles(2000, queue: queue)

        // Measured on the leaking version: 13.7us per cycle at the start and
        // 46us sixteen thousand cycles later, still climbing linearly — a
        // ratio above 3 and rising with every cycle added. Holding the
        // registration properly, the cost does not move at all and the ratio
        // sits at 1, so a threshold of 3 has room for a busy machine without
        // ever letting the leak back through.
        #expect(
            last < first * 3,
            "per-cycle cost grew from \(first * 1e6)us to \(last * 1e6)us — listeners are accumulating"
        )
    }

    @Test("A listener comes off cleanly, and twice is not an error")
    func cancelIsIdempotent() {
        let queue = DispatchQueue(label: "test.audio.listener.once")
        let listener = AudioListener(
            object: Self.systemObject, address: Self.address, queue: queue, handler: {}
        )
        #expect(listener != nil)
        listener?.cancel()
        listener?.cancel()
    }
}

/// The shape the volume watcher has to keep: arming twice is arming once, and
/// stopping lets everything go.
///
/// The hang came from `startWatching()` being the *response* to a notification
/// it had itself registered for, so each output change tore the whole set down
/// and built it again. These do not test that CoreAudio is happy; they test
/// that the app asks it for a bounded number of things.
@Suite("Volume watching is bounded")
@MainActor
struct VolumeWatchingTests {

    @Test("Arming twice installs one set, not two")
    func startIsIdempotent() {
        let controller = VolumeController()
        controller.startWatching()
        let first = controller.installedListenerCount
        #expect(first >= 1, "at least the default-device listener")

        controller.startWatching()
        #expect(
            controller.installedListenerCount == first,
            "a second arm added listeners: \(controller.installedListenerCount) vs \(first)"
        )

        controller.stopWatching()
        #expect(controller.installedListenerCount == 0)
    }

    @Test("Stopping and starting again does not accumulate")
    func stopStartDoesNotAccumulate() {
        let controller = VolumeController()
        controller.startWatching()
        let first = controller.installedListenerCount
        for _ in 0..<20 {
            controller.stopWatching()
            controller.startWatching()
        }
        #expect(
            controller.installedListenerCount == first,
            "twenty stop/start rounds changed the count: \(controller.installedListenerCount) vs \(first)"
        )
        controller.stopWatching()
    }
}
