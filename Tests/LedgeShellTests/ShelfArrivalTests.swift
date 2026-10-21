import Foundation
import LedgeCore
import LedgeProviders
import LedgeSystem
import LedgeUI
import Testing

@testable import LedgeShell

@MainActor
private final class Scratch {
    let root: URL
    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-shelf-arrival-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String) -> URL {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }
}

/// The pieces the coordinator wires together, real except for the peek.
@MainActor
private struct Rig {
    let backing = MemoryPreferenceStore()
    let preferences: Preferences
    let shelf: ShelfStore
    let activities: ActivityCoordinator
    let arrival: ShelfArrival
    let announced: Counter

    final class Counter { var count = 0 }

    init() {
        let preferences = Preferences(store: backing)
        let shelf = ShelfStore(
            load: { preferences.shelfPaths },
            save: { preferences.shelfPaths = $0 }
        )
        let activities = ActivityCoordinator(
            presentation: NotchPresentation(), preferences: preferences
        )
        // The registration ProviderRegistry builds for the shelf.
        activities.register(ProviderRegistration(
            id: "shelf", displayName: "File Shelf", kind: .shelf,
            permission: nil, make: { ShelfProvider(store: shelf) }
        ))
        activities.startEnabled()
        let announced = Counter()
        self.preferences = preferences
        self.shelf = shelf
        self.activities = activities
        self.announced = announced
        self.arrival = ShelfArrival(
            preferences: preferences,
            shelf: shelf,
            enableShelf: { activities.setProvider("shelf", enabled: true) },
            announce: { announced.count += 1 }
        )
    }

    /// Until the hub has put the Shelf card in the queue, for as long as that
    /// takes. Twenty yields and a short sleep stood in for it, and a held main
    /// thread outlasted them; the suite's time limit catches a card that never
    /// comes.
    func shelfCardArrived() async throws {
        while activities.activity(withID: ShelfProvider.activityID) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite("A Shelf the user switched off stays off", .timeLimit(.minutes(10)))
@MainActor
struct ShelfArrivalTests {

    @Test("A screenshot does not switch a disabled Shelf back on")
    func screenshotKeepsShelfOff() async throws {
        let rig = Rig()
        let scratch = Scratch()
        rig.activities.setProvider("shelf", enabled: false)

        // The card is off, and "Save screenshots" is at its shipped default.
        try #require(rig.preferences.isProviderEnabled("shelf") == false)
        try #require(rig.activities.isProviderRunning("shelf") == false)
        try #require(rig.preferences.shelfAutoScreenshots == true)
        try #require(Prefs.shelfAutoScreenshots.defaultValue == true)

        rig.arrival.screenshotTaken(scratch.file("Screenshot 2026-10-20 at 10.00.00.png"))
        // Nothing to wait for. A card can only reach the queue from a running
        // provider, and whether one is running is read synchronously below —
        // as is every other way the switch-off could have been undone.

        #expect(rig.preferences.isProviderEnabled("shelf") == false, "the user's switch-off was overwritten")
        #expect(rig.activities.isProviderRunning("shelf") == false, "the switched-off provider was started")
        #expect(rig.activities.activity(withID: ShelfProvider.activityID) == nil)
        #expect(rig.announced.count == 0, "the notch peeked a card that is off")
        #expect(rig.shelf.items.isEmpty, "the screenshot was parked on a Shelf nobody can see")
        // What the next launch reads.
        #expect(Preferences(store: rig.backing).isProviderEnabled("shelf") == false)
    }

    @Test("Screenshots are not watched while the Shelf card is off")
    func noScreenshotQueryWhileOff() throws {
        let rig = Rig()
        try #require(rig.preferences.shelfAutoScreenshots == true)
        #expect(rig.arrival.watchesScreenshots, "on by default, with the card on")

        rig.activities.setProvider("shelf", enabled: false)
        try #require(rig.preferences.isProviderEnabled("shelf") == false)
        #expect(!rig.arrival.watchesScreenshots)

        rig.activities.setProvider("shelf", enabled: true)
        rig.preferences.shelfAutoScreenshots = false
        #expect(!rig.arrival.watchesScreenshots)
    }

    @Test("A screenshot still lands on a Shelf that is on")
    func screenshotLandsWhenOn() throws {
        let rig = Rig()
        let scratch = Scratch()
        try #require(rig.preferences.isProviderEnabled("shelf"))

        rig.arrival.screenshotTaken(scratch.file("Screenshot.png"))

        #expect(rig.shelf.items.count == 1)
        #expect(rig.announced.count == 1)
    }

    /// The one exception, and a deliberate one: a drop is the user's own
    /// gesture on the notch, so it is never silently discarded.
    @Test("A drop still switches a disabled Shelf back on")
    func dropEnablesShelf() async throws {
        let rig = Rig()
        let scratch = Scratch()
        rig.activities.setProvider("shelf", enabled: false)
        try #require(rig.preferences.isProviderEnabled("shelf") == false)

        rig.arrival.dropped([scratch.file("parked.pdf")])
        try await rig.shelfCardArrived()

        #expect(rig.preferences.isProviderEnabled("shelf"))
        #expect(rig.activities.isProviderRunning("shelf"))
        #expect(rig.shelf.items.count == 1)
        #expect(rig.announced.count == 1)
    }
}
