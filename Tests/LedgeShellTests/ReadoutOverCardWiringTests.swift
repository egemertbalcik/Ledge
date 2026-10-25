import Foundation
import Testing

/// How the coordinator wires `ReadoutOverCard` in. The rule itself is tested
/// against real layouts in LedgeCoreTests; what cannot be run here — the
/// tracker, the pointer, the panels — is checked by how it is wired, the same
/// way the self-view's teardown is.
@Suite("A readout in front of an open card, wired")
struct ReadoutOverCardWiringTests {

    private static var coordinatorSource: String {
        (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/LedgeShell/Coordinator/LedgeCoordinator.swift"),
            encoding: .utf8
        )) ?? ""
    }

    private static func body(after marker: String, length: Int = 900) -> Substring? {
        let source = coordinatorSource
        guard let start = source.range(of: marker) else { return nil }
        return source[start.lowerBound...].prefix(length)
    }

    @Test("The tracker's region keeps the covered card")
    func trackerRegion() throws {
        let body = try #require(Self.body(after: "private func openRegion(_ key: CGDirectDisplayID) -> CGRect? {"),
                                "openRegion was renamed; this guard needs rewriting")
        #expect(body.contains("ReadoutOverCard.trackingRegion(readout: drawn, card: coveredCardRegion(key))"))
    }

    @Test("The parked-pointer release counts a pointer resting on the card")
    func parkedRelease() throws {
        let body = try #require(Self.body(after: "private func scheduleParkedHUDRelease() {", length: 2400))
        #expect(body.contains("ReadoutOverCard.restsOnCard(pointer: pointer, card: self.coveredCardRegion())"))
    }

    @Test("The hand-back watch follows every event, sleeps with the screens, and stops with the app")
    func handBackWired() throws {
        let follow = try #require(Self.body(after: "let heldHUD = state.phase == .hud", length: 400))
        #expect(follow.contains("readoutHandBack.follow(event)"))
        let dark = try #require(Self.body(after: "private func setScreensDark(", length: 1600))
        #expect(dark.contains("readoutHandBack.setDormant(true)"))
        #expect(dark.contains("readoutHandBack.setDormant(false)"))
        let stop = try #require(Self.body(after: "    public func stop() {", length: 200))
        #expect(stop.contains("readoutHandBack.cancel()"))
        let watch = try #require(Self.body(after: "private lazy var readoutHandBack = ReadoutHandBack(", length: 500))
        #expect(watch.contains("self?.readoutHandsCardBack()"))
        #expect(watch.contains("self?.send(.hudReleased)"))
    }
}
