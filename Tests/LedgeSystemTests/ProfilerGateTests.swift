import Foundation
import Testing
import os

@testable import LedgeSystem

/// A burst of callers must not become a burst of processes.
///
/// `system_profiler` is slow and is asked for from both the periodic read and
/// every Bluetooth connect notification. A wake reconnects every paired device
/// at once, so without this each of those would have spawned its own copy of a
/// slow system tool to compute the same answer.
@Suite("Profiler gate")
struct ProfilerGateTests {

    private final class Counter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (runs: 0, peak: 0, live: 0))
        var runs: Int { lock.withLock { $0.runs } }
        var peak: Int { lock.withLock { $0.peak } }

        func enter() {
            lock.withLock { s in
                s.runs += 1
                s.live += 1
                s.peak = max(s.peak, s.live)
            }
        }
        func leave() { lock.withLock { $0.live -= 1 } }
    }

    @Test("Fifty simultaneous callers run the work once")
    func burstSharesOneRun() async {
        let counter = Counter()
        let gate = ProfilerGate<Int>(freshness: 0) {
            counter.enter()
            try? await Task.sleep(for: .milliseconds(80))
            counter.leave()
            return 7
        }

        let results = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<50 { group.addTask { await gate.value() } }
            var all: [Int] = []
            for await value in group { all.append(value) }
            return all
        }

        #expect(results.count == 50)
        #expect(results.allSatisfy { $0 == 7 }, "callers got different answers")
        #expect(counter.peak == 1, "\(counter.peak) runs were in flight at once")
        #expect(counter.runs == 1, "the work ran \(counter.runs) times for one burst")
    }

    @Test("A recent answer is reused rather than recomputed")
    func freshnessCollapsesRepeats() async {
        let counter = Counter()
        let clock = OSAllocatedUnfairLock(initialState: 0.0)
        let gate = ProfilerGate<Int>(
            freshness: 2,
            now: { clock.withLock { $0 } }
        ) {
            counter.enter()
            counter.leave()
            return 1
        }

        _ = await gate.value()
        for _ in 0..<20 { _ = await gate.value() }
        #expect(counter.runs == 1, "ran \(counter.runs) times inside the freshness window")

        // Past the window, it asks again.
        clock.withLock { $0 = 5 }
        _ = await gate.value()
        #expect(counter.runs == 2)
    }

    @Test("Sequential callers outside the window each get a fresh run")
    func sequentialRunsAreNotBlocked() async {
        let counter = Counter()
        let gate = ProfilerGate<Int>(freshness: 0) {
            counter.enter()
            counter.leave()
            return 3
        }
        for _ in 0..<5 { _ = await gate.value() }
        #expect(counter.runs == 5, "the gate wedged shut after the first run")
    }
}
