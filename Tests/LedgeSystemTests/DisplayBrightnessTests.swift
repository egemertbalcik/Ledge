import Foundation
import Testing

@testable import LedgeSystem

/// The parts of per-display brightness that are pure: how levels are encoded for
/// persistence and how they are clamped coming back.
///
/// The rest of the controller talks to real hardware — enumerating screens,
/// writing gamma ramps — and is verified live rather than here.
@Suite("Display brightness")
@MainActor
struct DisplayBrightnessTests {

    @Test("Levels survive a round trip through the preference string")
    func roundTrip() {
        let controller = DisplayBrightnessController()
        controller.loadLevels("1234-5678-9=0.5,42-7-1=0.75")
        let encoded = controller.encodedLevels()
        // Sorted, so the preference does not churn between launches purely
        // because a dictionary enumerated in a different order.
        #expect(encoded == "1234-5678-9=0.5,42-7-1=0.75")
    }

    @Test("A stored level below the floor is raised on load")
    func floorOnLoad() {
        // A level written by an older build — or a hand-edited preference —
        // must not be able to leave a screen too dark to fix from that screen.
        let controller = DisplayBrightnessController()
        controller.loadLevels("1-2-3=0.0")
        #expect(controller.encodedLevels() == "1-2-3=\(DisplayBrightnessController.gammaFloor)")
    }

    @Test("Malformed entries are skipped without discarding the good ones")
    func malformed() {
        let controller = DisplayBrightnessController()
        controller.loadLevels("good-1-1=0.4,garbage,also=bad,,missingvalue=")
        #expect(controller.encodedLevels() == "good-1-1=0.4")
    }

    @Test("An empty preference loads as no remembered levels")
    func empty() {
        let controller = DisplayBrightnessController()
        controller.loadLevels("")
        #expect(controller.encodedLevels().isEmpty)
    }

    @Test("Levels above 1 are clamped rather than trusted")
    func clampsHigh() {
        let controller = DisplayBrightnessController()
        controller.loadLevels("1-1-1=4.2")
        #expect(controller.encodedLevels() == "1-1-1=1.0")
    }
}

/// Reverse geocoding answers with a street or a business; the card wants a city.
@Suite("Place naming")
struct LocalityTests {

    @Test("The title is the city")
    func keepsCity() {
        #expect(CoreLocationSource.placeTitle(city: "İstanbul") == "İstanbul")
        #expect(CoreLocationSource.placeTitle(city: " Boston\n") == "Boston")
    }

    @Test("Without a city the title is empty, never a finer place")
    func noFinerPlace() {
        // Empty lets the card fall back to the typed city or "Current Location".
        #expect(CoreLocationSource.placeTitle(city: nil) == "")
        #expect(CoreLocationSource.placeTitle(city: "  ") == "")
    }
}
