import Foundation
import Testing

@testable import LedgeCore

@Suite("Proximity scan window")
struct ProximityScanWindowTests {

    @Test("A change holds the window open")
    func changeHolds() {
        var window = ProximityScanWindow()
        #expect(window.advertisement(changed: true, now: 0) == .hold(until: ProximityScanWindow.hold))
        #expect(window.isAttentive)
    }

    @Test("Repeats of the same reading do not extend anything")
    func repeatsDoNotExtend() {
        var window = ProximityScanWindow()
        _ = window.advertisement(changed: true, now: 0)
        let closesAt = window.closesAt

        // AirPods advertise many times a second; in attentive mode every one of
        // them is delivered. This is the loop that kept the radio on.
        for i in 1...500 {
            let decision = window.advertisement(changed: false, now: Double(i) * 0.02)
            #expect(decision == .leave)
        }
        #expect(window.closesAt == closesAt, "unchanged traffic pushed the window out")
    }

    @Test("A stream of real changes still cannot run past the ceiling")
    func ceilingWins() {
        var window = ProximityScanWindow()
        var now: TimeInterval = 0
        var released = false
        // Something changing on every advertisement, forever.
        for _ in 0..<2000 {
            if window.advertisement(changed: true, now: now) == .release {
                released = true
                break
            }
            now += 0.05
        }
        #expect(released, "attentive scanning ran past its ceiling")
        #expect(now <= ProximityScanWindow.ceiling + 0.05)
        #expect(!window.isAttentive)
    }

    @Test("After releasing, a later change opens a fresh window")
    func releaseThenReopen() {
        var window = ProximityScanWindow()
        _ = window.advertisement(changed: true, now: 0)
        #expect(window.advertisement(changed: true, now: ProximityScanWindow.ceiling) == .release)
        let next = window.advertisement(changed: true, now: ProximityScanWindow.ceiling + 1)
        #expect(next == .hold(until: ProximityScanWindow.ceiling + 1 + ProximityScanWindow.hold))
        #expect(window.isAttentive)
    }

    @Test("Closing forgets the run, so the ceiling measures one window")
    func closingResets() {
        var window = ProximityScanWindow()
        _ = window.advertisement(changed: true, now: 0)
        window.closed()
        #expect(!window.isAttentive)
        _ = window.advertisement(changed: true, now: 100)
        #expect(window.advertisement(changed: true, now: 120) == .leave || window.isAttentive)
    }
}
