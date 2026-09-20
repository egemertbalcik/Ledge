import Foundation
import Testing

@testable import LedgeSystem

/// What `current()` actually costs on this machine.
///
/// The figure quoted for it has been an estimate from a comment about the
/// safety poll re-enumerating both device trees. It runs on the main actor on
/// every privacy notification, so it is worth a number rather than a guess.
@Suite("Recording read cost", .serialized)
struct RecordingReadCostTests {

    @Test(
        "Measure the synchronous HAL work behind current()",
        .enabled(if: ProcessInfo.processInfo.environment["LEDGE_TIMING_TESTS"] == "1")
    )
    @MainActor
    func measureCurrent() {
        let source = SystemRecordingSource()
        let clock = ContinuousClock()

        // Warm the HAL connection; the first call is far dearer than the rest.
        _ = source.current()

        var samples: [Duration] = []
        for _ in 0..<20 {
            samples.append(clock.measure { _ = source.current() })
        }
        let sorted = samples.sorted()
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000
                + Double(d.components.attoseconds) / 1e15
        }
        print(String(
            format: "CURRENT() ms  min=%.2f  median=%.2f  max=%.2f  processes=%d cameras=%d",
            ms(sorted.first!), ms(sorted[sorted.count / 2]), ms(sorted.last!),
            SystemRecordingSource.processObjects().count,
            SystemRecordingSource.videoDevices().count
        ))
        #expect(!samples.isEmpty)
    }
}
