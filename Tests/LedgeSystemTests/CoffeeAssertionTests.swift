import Foundation
import IOKit.pwr_mgt
import Testing

@testable import LedgeSystem

/// What coffee holds, checked against a fake powerd.
///
/// The owner uses Raycast's Coffee, which runs `caffeinate -u -dmi`. Ledge
/// held only the first of those, so the Mac stayed awake while the screen
/// went dark on its own timer — and a dark screen is what a sleeping Mac
/// looks like.
@Suite("Coffee holds what Raycast's Coffee holds")
@MainActor
struct CoffeeAssertionTests {

    /// A powerd that records everything and refuses what it is told to.
    @MainActor
    private final class FakePower {
        var nextID: IOPMAssertionID = 1
        var live: [IOPMAssertionID: String] = [:]
        var events: [String] = []
        var refuse: Set<String> = []
        var userActivity = 0
        /// Work scheduled for later, run when the test says so.
        var later: [@MainActor () -> Void] = []
        /// powerd's elapsed-time clock, moved by hand.
        var elapsed: TimeInterval = 0

        var power: IOPMSleepAssertion.Power {
            IOPMSleepAssertion.Power(
                create: { [unowned self] kind, _, _, _ in
                    guard !self.refuse.contains(kind) else { return nil }
                    let id = self.nextID
                    self.nextID += 1
                    self.live[id] = kind
                    self.events.append("+\(kind)")
                    return id
                },
                release: { [unowned self] id in
                    let kind = self.live.removeValue(forKey: id) ?? "?"
                    self.events.append("-\(kind)")
                },
                declareUserActivity: { [unowned self] _ in
                    self.userActivity += 1
                    let id = self.nextID
                    self.nextID += 1
                    self.live[id] = "UserIsActive"
                    self.events.append("+UserIsActive")
                    return id
                },
                after: { [unowned self] _, work in self.later.append(work) },
                elapsed: { [unowned self] in self.elapsed }
            )
        }

        var heldKinds: Set<String> { Set(live.values).subtracting(["UserIsActive"]) }
        var userActive: Bool { live.values.contains("UserIsActive") }

        func runLater() {
            let work = later
            later.removeAll()
            for job in work { job() }
        }
    }

    private let system = kIOPMAssertPreventUserIdleSystemSleep
    private let display = kIOPMAssertPreventUserIdleDisplaySleep
    private let disk = kIOPMAssertPreventDiskIdle

    @Test("Starting coffee keeps the Mac, the screen and the disk awake")
    func allThree() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        #expect(coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600))
        #expect(fake.heldKinds == [system, display, disk])
        #expect(coffee.isHeld)
        #expect(coffee.isComplete)
    }

    @Test("Starting coffee wakes a screen that had already gone dark, once")
    func declaresUserActivity() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        _ = coffee.rearm(timeout: 600)
        #expect(fake.userActivity == 1)
    }

    @Test("Stopping coffee lets go of all of it")
    func releasesEverything() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        coffee.release()
        #expect(fake.live.isEmpty)
        #expect(!coffee.isHeld)
    }

    /// Measured on the owner's Mac: the user-activity declaration was still
    /// held two minutes after it was made. Left alone it would outlive the
    /// session and keep the screen awake after coffee was switched off.
    @Test("The start-of-session nudge lapses after five seconds, as caffeinate -u does")
    func userActivityLapses() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        #expect(fake.userActive)
        fake.runLater()
        #expect(!fake.userActive)
        // The session itself carries on.
        #expect(fake.heldKinds == [system, display, disk])
    }

    @Test("Switching coffee off inside those five seconds ends the nudge too")
    func releaseEndsTheNudge() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        coffee.release()
        #expect(!fake.userActive)
        // And the timer firing afterwards releases nothing twice.
        let before = fake.events.count
        fake.runLater()
        #expect(fake.events.count == before)
    }

    /// The reason a re-arm takes before it drops: in between, nothing would
    /// be held, and on a Mac set to sleep after a minute that is enough.
    @Test("A re-arm never leaves a gap for any of the three")
    func rearmHasNoGap() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        fake.events.removeAll()
        #expect(coffee.rearm(timeout: 600))
        for kind in [system, display, disk] {
            let taken = fake.events.firstIndex(of: "+\(kind)")
            let dropped = fake.events.firstIndex(of: "-\(kind)")
            #expect(taken != nil && dropped != nil)
            if let taken, let dropped { #expect(taken < dropped) }
        }
        #expect(fake.heldKinds == [system, display, disk])
        // One of each, not an old one left beside its replacement.
        #expect(fake.live.values.filter { $0 != "UserIsActive" }.count == 3)
    }

    /// The screen staying on is the point of this change — but not at the
    /// price of the Mac being free to sleep because the screen was refused.
    @Test("A refused display assertion still keeps the Mac awake")
    func displayRefusalIsNotFatal() {
        let fake = FakePower()
        fake.refuse = [display]
        let coffee = IOPMSleepAssertion(power: fake.power)
        #expect(coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600))
        #expect(fake.heldKinds == [system, disk])
        // Held, and honest that it is not all of it.
        #expect(coffee.isHeld)
        #expect(!coffee.isComplete)
    }

    @Test("A refused part is asked for again at the next re-arm")
    func refusedPartIsRetried() {
        let fake = FakePower()
        fake.refuse = [display]
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        fake.refuse = []
        #expect(coffee.rearm(timeout: 600))
        #expect(fake.heldKinds == [system, display, disk])
        #expect(coffee.isComplete)
    }

    @Test("A renewed assertion counts from its renewal, not from the start")
    func renewalRestartsTheClock() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        fake.elapsed += 300
        _ = coffee.rearm(timeout: 600)
        // Past the first assertion's timeout, inside the renewed one's.
        fake.elapsed += 400
        #expect(coffee.isComplete)
    }

    /// Codex's finding: keeping the old assertion after a refused renewal is
    /// only protection until powerd's own timeout for it, and nothing used to
    /// notice when that passed.
    @Test("A kept assertion stops counting once powerd's timeout for it has passed")
    func keptAssertionLapses() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        fake.refuse = [display]

        fake.elapsed += 300
        #expect(coffee.rearm(timeout: 600))
        #expect(coffee.isComplete, "the first display assertion still has 300 s left")

        fake.elapsed += 400
        #expect(!coffee.isComplete, "powerd has let it go by now")
        #expect(coffee.rearm(timeout: 600), "the Mac itself is still held")
        #expect(!coffee.isComplete)
        // Never given back on Ledge's own reckoning: if that reckoning were
        // off, letting go would end protection that still had time left.
        #expect(fake.heldKinds == [system, display, disk])
    }

    /// Codex, round two: a renewal refused while the old assertion still
    /// covers it was left to the next half-hour — the moment the old one ran
    /// out.
    @Test("A refused renewal is retried soon, while the old assertion still covers it")
    func refusedRenewalWantsARetry() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        #expect(!coffee.needsRetry)

        fake.refuse = [display]
        _ = coffee.rearm(timeout: 600)
        #expect(coffee.isComplete, "the old display assertion still covers it")
        #expect(coffee.needsRetry)

        fake.refuse = []
        _ = coffee.rearm(timeout: 600)
        #expect(!coffee.needsRetry)
    }

    @Test("A part refused at the start wants a retry")
    func refusedAtStartWantsARetry() {
        let fake = FakePower()
        fake.refuse = [disk]
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        #expect(coffee.needsRetry)
        coffee.release()
        #expect(!coffee.needsRetry)
    }

    @Test("A refused system assertion is a failed start, and leaves nothing behind")
    func systemRefusalFailsCleanly() {
        let fake = FakePower()
        fake.refuse = [system]
        let coffee = IOPMSleepAssertion(power: fake.power)
        #expect(!coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600))
        #expect(fake.live.isEmpty)
        #expect(!coffee.isHeld)
    }

    @Test("A kind that cannot be re-armed keeps the one it had")
    func failedRearmKeepsThePrevious() {
        let fake = FakePower()
        let coffee = IOPMSleepAssertion(power: fake.power)
        _ = coffee.acquire(name: "Ledge Keep Awake", details: "", timeout: 600)
        fake.refuse = [display]
        #expect(coffee.rearm(timeout: 600))
        #expect(fake.heldKinds == [system, display, disk])
    }
}
