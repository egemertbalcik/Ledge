import Foundation
import Testing
@testable import LedgeCore

@Suite("Keep Awake floors")
struct KeepAwakeFloorsTests {

    private func decide(
        percentage: Int? = 80,
        charging: Bool? = false,
        present: Bool = true,
        floor: Int = 15,
        miss: Int = 0,
        thermal: KeepAwakeThermal = .nominal,
        lidClosed: Bool = false,
        enforcesUnreadable: Bool = true
    ) -> KeepAwakeFloors.Decision {
        KeepAwakeFloors.decide(
            battery: KeepAwakeBattery(percentage: percentage, charging: charging, isPresent: present),
            floor: floor, missCount: miss, thermal: thermal,
            lidClosed: lidClosed, enforcesUnreadable: enforcesUnreadable
        )
    }

    @Test("Critical heat ends a session whatever the lid is doing")
    func critical() {
        #expect(decide(thermal: .critical) == .end(.thermal))
        #expect(decide(thermal: .critical, lidClosed: true) == .end(.thermal))
    }

    @Test("Serious heat ends it only with the lid closed")
    func serious() {
        // With the lid open the Mac can shed heat and the user can see it; a
        // long compile reaching .serious is not a reason to cut their session.
        #expect(decide(thermal: .serious) == .keepGoing)
        #expect(decide(thermal: .serious, lidClosed: true) == .end(.thermal))
        #expect(decide(thermal: .fair, lidClosed: true) == .keepGoing)
    }

    @Test("The battery floor applies on battery, and an unknown charger counts as battery")
    func batteryFloor() {
        #expect(decide(percentage: 16) == .keepGoing)
        #expect(decide(percentage: 15) == .end(.batteryFloor))
        #expect(decide(percentage: 5) == .end(.batteryFloor))
        // Plugged in, so the floor does not apply.
        #expect(decide(percentage: 5, charging: true) == .keepGoing)
        // "We could not tell" is not "it is plugged in": treating it as
        // charging is how a laptop runs to empty.
        #expect(decide(percentage: 5, charging: nil) == .end(.batteryFloor))
    }

    @Test("A Mac with no battery has no floor to hit")
    func desktop() {
        #expect(decide(percentage: nil, present: false, miss: 9) == .keepGoing)
        #expect(decide(percentage: 0, present: false) == .keepGoing)
    }

    @Test("An unreadable battery ends it only after two misses, and only when it matters")
    func unreadable() {
        #expect(decide(percentage: nil, miss: 1) == .keepGoing)
        #expect(decide(percentage: nil, miss: 2) == .end(.batteryUnreadable))
        // With the lid open the user can read their own battery; ending their
        // session over a failed read would be Ledge being jumpy.
        #expect(decide(percentage: nil, miss: 5, enforcesUnreadable: false) == .keepGoing)
    }

    @Test("Heat is decided before anything else")
    func thermalFirst() {
        // Both floors are tripped; the sentence the user gets should be about
        // the hardware, which is the more urgent fact.
        #expect(decide(percentage: 2, thermal: .critical) == .end(.thermal))
    }

    @Test("A healthy Mac keeps going across the whole table")
    func healthy() {
        for charging in [true, false, nil] as [Bool?] {
            for thermal in [KeepAwakeThermal.nominal, .fair] {
                for lid in [true, false] {
                    #expect(decide(percentage: 80, charging: charging,
                                   thermal: thermal, lidClosed: lid) == .keepGoing)
                }
            }
        }
    }
}
