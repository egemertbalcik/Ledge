import Foundation
import LedgeCore
import LedgeSystem
import Testing

@testable import LedgeProviders

/// Where a reading goes, and how far away it may be.
///
/// Ledge used to throw away every advertisement weaker than −55 dBm before
/// anything saw it, so a set of AirPods on the other side of the room stopped
/// reporting a battery level at all. Strength answers one question — is this
/// about *here* — and that question belongs to the card, not to the radio.
@Suite("How far away a reading may be")
struct ProximityRangeTests {

    private static func advert(rssi: Int?) -> AirPodsProximity {
        var proximity = AirPodsProximity(
            model: 0x2420,
            leftBattery: 0.7, rightBattery: 0.8, caseBattery: 0.5,
            isChargingLeft: false, isChargingRight: false, isChargingCase: true,
            lidCounter: 3
        )
        proximity.peripheralID = UUID()
        proximity.rssi = rssi
        return proximity
    }

    @Test("A card is for something on this desk")
    func cardsAreNear() {
        #expect(AirPodsProximityProvider.isCloseEnough(Self.advert(rssi: -40)))
        #expect(AirPodsProximityProvider.isCloseEnough(
            Self.advert(rssi: AirPodsProximityProvider.closeEnoughForACard)
        ))
        #expect(!AirPodsProximityProvider.isCloseEnough(Self.advert(rssi: -70)))
    }

    @Test("An unread paired list is an exception with an end")
    func ownershipGraceIsBounded() {
        // The exception is deliberate: a card is transient, and withholding
        // the owner's own case-open in the seconds before the first reading
        // lands is the worse failure.
        #expect(AirPodsProximityProvider.isWorthShowing(
            Self.advert(rssi: -40), paired: nil, unansweredFor: 1
        ))
        // But the list is read by the Bluetooth card provider, which the user
        // can switch off while leaving this card on. Unbounded, "the first
        // few seconds" became for ever, and every stranger's earbuds passed
        // as the user's.
        #expect(!AirPodsProximityProvider.isWorthShowing(
            Self.advert(rssi: -40),
            paired: nil,
            unansweredFor: AirPodsProximityProvider.ownershipGrace + 1
        ))
    }

    @Test("A reading with no strength on it is not treated as distant")
    func unstampedReadingsPass() {
        // Nothing stamps a strength but the scanner, so this is a fixture or
        // a test — not a device across the room.
        #expect(AirPodsProximityProvider.isCloseEnough(Self.advert(rssi: nil)))
    }
}
