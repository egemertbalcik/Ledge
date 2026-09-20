import CoreAudio
import Foundation
import Testing

@testable import LedgeSystem

/// Tests against the real CoreAudio, for the things a fake cannot tell you.
///
/// The deterministic cover for the watcher's behaviour is in
/// `VolumeWatchBackendTests`, against a fake that counts what crossed the
/// boundary. What is left here needs the actual HAL: whether a registration
/// this process made can really be taken off again, and whether the block and
/// everything it captured are released when it is.
///
/// Serialized, because they share one global listener list.
@Suite("Audio listener against CoreAudio", .serialized)
struct AudioListenerTests {

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    @Test("A registration can be taken off again, and twice is not an error")
    func removalWorks() {
        let queue = DispatchQueue(label: "test.audio.listener.remove")
        let listener = AudioListener(
            object: Self.systemObject, address: Self.address, queue: queue, handler: {}
        )
        #expect(listener != nil, "CoreAudio refused the registration — the rest proves nothing")
        listener?.cancel()
        listener?.cancel()
    }

    /// The thing that actually leaked was not an object on this side; it was the
    /// block CoreAudio had copied, and everything it captured. So this holds a
    /// sentinel by capture and checks it is gone once the listener is cancelled
    /// and the queue has drained.
    @Test("Cancelling releases the block and what it captured")
    func cancellationReleasesCaptures() {
        final class Sentinel: @unchecked Sendable {}
        let queue = DispatchQueue(label: "test.audio.listener.sentinel")
        weak var weakSentinel: Sentinel?

        do {
            let sentinel = Sentinel()
            weakSentinel = sentinel
            let listener = AudioListener(
                object: Self.systemObject, address: Self.address, queue: queue
            ) { _ = sentinel }
            #expect(listener != nil, "CoreAudio refused the registration")
            #expect(weakSentinel != nil, "the handler should be holding it")
            listener?.cancel()
        }

        queue.sync {}   // let anything already queued finish
        #expect(
            weakSentinel == nil,
            "the listener block outlived its cancellation — CoreAudio is still holding it"
        )
    }

    /// Supplementary evidence, not the primary guard: the deterministic
    /// version is `unchangedNotificationsDoNotChurn`, which counts operations
    /// instead of timing them. This one is kept because it is the shape in
    /// which the original bug was found — a cost that grew — and because it
    /// exercises the real HAL rather than a fake.
    ///
    /// Off by default. A ratio measured while the rest of the suite runs in
    /// parallel is measuring the machine, not the code: it reported 19x on a
    /// loaded run and 1x on a quiet one. Run it deliberately, on an idle
    /// machine:
    ///
    ///     LEDGE_TIMING_TESTS=1 swift test --filter registrationDoesNotAccumulate
    ///
    /// Monotonic clock, whole-duration arithmetic, and it fails rather than
    /// passes if the registrations never succeeded — a run where everything is
    /// refused does no work at all and would otherwise look beautifully flat.
    @Test(
        "Registering and unregistering does not get slower",
        .enabled(if: ProcessInfo.processInfo.environment["LEDGE_TIMING_TESTS"] == "1")
    )
    func registrationDoesNotAccumulate() {
        let queue = DispatchQueue(label: "test.audio.listener.growth")
        var refused = 0

        func cycles(_ count: Int) -> Duration {
            let clock = ContinuousClock()
            return clock.measure {
                for _ in 0..<count {
                    let listener = AudioListener(
                        object: Self.systemObject, address: Self.address, queue: queue, handler: {}
                    )
                    if listener == nil { refused += 1 }
                    listener?.cancel()
                }
            }
        }

        _ = cycles(200)                 // warm the HAL connection
        let first = cycles(2000)
        _ = cycles(12000)
        let last = cycles(2000)

        #expect(refused == 0, "\(refused) registrations were refused; this measured nothing")

        // Leaking, this ratio passed 3 by sixteen thousand cycles and kept
        // climbing linearly. Holding the registration properly it sits at 1,
        // so 4 leaves room for a busy machine without letting the leak back.
        // Whole duration arithmetic: `.attoseconds` alone drops the seconds
        // component, so a run slow enough to cross a second would compare the
        // wrong numbers entirely.
        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let ratio = seconds(last) / max(seconds(first), 1e-9)
        #expect(ratio < 4, "per-cycle cost grew by \(ratio)x — registrations are accumulating")
    }
}
