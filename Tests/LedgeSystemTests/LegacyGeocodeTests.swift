import CoreLocation
import Foundation
import Testing

@testable import LedgeSystem

/// The macOS 15 city lookup under its two-second bound: a cancel is never
/// lost, whether it comes before the request starts or while it runs.
///
/// A lost cancel does not fail on its own: the lookup waits forever, which is
/// the bug, and a test awaiting it would wait with it. So each lookup runs in
/// a task of its own and is only polled, against a deadline, never awaited.
@Suite("Weather city lookup before macOS 26")
struct LegacyGeocodeTests {

    /// A geocoder that answers only when told to, or when cancelled — the way
    /// `CLGeocoder` calls its completion with an error on `cancelGeocode()`.
    final class FakeGeocoder: CLGeocoder, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CLGeocodeCompletionHandler?
        private(set) var calls: [String] = []

        override func reverseGeocodeLocation(_ location: CLLocation,
                                             completionHandler: @escaping CLGeocodeCompletionHandler) {
            lock.withLock {
                calls.append("start")
                pending = completionHandler
            }
        }

        override func cancelGeocode() {
            let handler = lock.withLock {
                calls.append("cancel")
                defer { pending = nil }
                return pending
            }
            handler?(nil, CLError(.geocodeCanceled))
        }

        /// Answers the request in flight with no placemarks.
        func answer() {
            let handler = lock.withLock {
                defer { pending = nil }
                return pending
            }
            handler?([], nil)
        }

        var started: Bool { lock.withLock { calls.contains("start") } }
        var log: [String] { lock.withLock { calls } }
    }

    private let somewhere = CLLocation(latitude: 41.0, longitude: 29.0)

    /// What a lookup returned, once it has.
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ name: String) { lock.withLock { value = name } }
        var name: String? { lock.withLock { value } }
    }

    /// Polls until `condition` holds or two seconds pass, the lookup's own bound.
    private func within2s(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test("A cancel that comes before the request starts keeps it from starting")
    func cancelledFirstNeverStarts() async {
        let fake = FakeGeocoder()
        let location = somewhere
        let outcome = Outcome()
        Task {
            withUnsafeCurrentTask { $0?.cancel() }
            outcome.set(await CoreLocationSource.legacyPlaceName(for: location, geocoder: { fake }))
        }
        #expect(await within2s { outcome.name != nil }, "the lookup returned instead of waiting: \(fake.log)")
        #expect(outcome.name == "")
        #expect(!fake.started, "the request never went out: \(fake.log)")
    }

    @Test("A cancel while the request runs ends it, and the lookup returns at once")
    func cancelledInFlightReturns() async {
        let fake = FakeGeocoder()
        let location = somewhere
        let outcome = Outcome()
        let task = Task {
            outcome.set(await CoreLocationSource.legacyPlaceName(for: location, geocoder: { fake }))
        }
        #expect(await within2s { fake.started }, "the request went out")
        task.cancel()
        #expect(await within2s { outcome.name != nil }, "the lookup returned once cancelled: \(fake.log)")
        #expect(outcome.name == "")
        #expect(fake.log == ["start", "cancel"])
    }

    @Test("An answer with no city gives an untitled forecast, not a wait")
    func answeredWithoutCity() async {
        let fake = FakeGeocoder()
        let location = somewhere
        let outcome = Outcome()
        Task {
            outcome.set(await CoreLocationSource.legacyPlaceName(for: location, geocoder: { fake }))
        }
        #expect(await within2s { fake.started }, "the request went out")
        fake.answer()
        #expect(await within2s { outcome.name != nil }, "the lookup returned with the answer")
        #expect(outcome.name == "")
        #expect(fake.log == ["start"])
    }
}
