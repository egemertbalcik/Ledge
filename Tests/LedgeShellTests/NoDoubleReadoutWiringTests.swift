import Foundation
import Testing

/// Ledge's level readout stands in place of the macOS one, never beside it.
///
/// What decides that is wiring in `HUDCoordinator` — an event tap and CoreAudio
/// cannot run here — so it is checked by how it is wired, like the other
/// coordinator guards.
@Suite("One readout per key press, wired")
struct NoDoubleReadoutWiringTests {

    private static var hudSource: String {
        (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/LedgeShell/Coordinator/HUDCoordinator.swift"),
            encoding: .utf8
        )) ?? ""
    }

    private static func body(after marker: String, length: Int = 900) -> Substring? {
        let source = hudSource
        guard let start = source.range(of: marker) else { return nil }
        return source[start.lowerBound...].prefix(length)
    }

    @Test("An observed volume change shows a readout only while the tap intercepts")
    func volumeObservedOnlyWhileSuppressing() throws {
        let body = try #require(Self.body(after: "volume.onChange = {"),
                                "volume.onChange moved; this guard needs rewriting")
        #expect(body.contains("guard self.isSuppressing else { return }"))
    }

    @Test("No brightness poll draws a readout next to the system's")
    func noBrightnessPoll() {
        #expect(!Self.hudSource.contains("let brightness = BrightnessController()"))
        #expect(!Self.hudSource.contains("brightness.onChange"))
    }

    @Test("Brightness readout off hands the brightness keys back to macOS")
    func brightnessKeysRespectThePreference() throws {
        let body = try #require(Self.body(after: "private func applyKeyDown("),
                                "applyKeyDown moved; this guard needs rewriting")
        #expect(body.contains("guard preferences.hudBrightnessEnabled else { return false }"))
    }
}
