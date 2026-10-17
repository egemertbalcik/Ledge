import Foundation
import Testing

@testable import LedgeSystem

/// What may hold the Bluetooth radio open.
///
/// Attentive scanning is the most expensive mode CoreBluetooth has, and it
/// exists for one situation: a set of the user's own AirPods, in hand, saying
/// something new. Each of the three conditions below was, on its own, enough
/// to keep it running when nothing was waiting on it.
@Suite("Holding the listening window open")
struct ProximityWindowGateTests {

    @Test("The radio is held open only for news, from us, close by")
    func holdingTheWindow() {
        func holds(changed: Bool, isOurs: Bool, rssi: Int) -> Bool {
            AirPodsProximityScanner.holdsTheWindow(
                changed: changed, isOurs: isOurs, rssi: rssi, closeEnough: -55
            )
        }
        #expect(holds(changed: true, isOurs: true, rssi: -40))
        // Repeats of a value nobody is waiting on are what used to keep the
        // most expensive scan mode running all day.
        #expect(!holds(changed: false, isOurs: true, rssi: -40))
        // A stranger's earbuds changing state at the next table extended
        // Ledge's window for readings that were then refused downstream.
        #expect(!holds(changed: true, isOurs: false, rssi: -40))
        // Ours, and saying something, but not here.
        #expect(!holds(changed: true, isOurs: true, rssi: -70))
    }
}
