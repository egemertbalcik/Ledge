import Foundation
import LedgeSystem
import Testing

@testable import LedgeShell

/// Ledge's level readout stands in place of the macOS one, never beside it.
///
/// Most of what decides that is wiring in `HUDCoordinator`: an event tap and
/// CoreAudio cannot run here. The key decision is a plain function and is
/// tested as one; the wiring around it is read from the source, with comments
/// taken out, so a line that was only commented out cannot pass.
@Suite("One readout per key press")
struct NoDoubleReadoutWiringTests {

    private static func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(!text.isEmpty, "\(path) read as empty")
        return text
    }

    /// The source's lines with every `//` comment removed and blank lines
    /// dropped, so the checks below see code and nothing else.
    private static func code(_ path: String) throws -> [String] {
        try source(path)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                guard let comment = text.range(of: "//") else { return text }
                return String(text[..<comment.lowerBound])
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static let hud = "Sources/LedgeShell/Coordinator/HUDCoordinator.swift"

    /// The lines from the first one starting with `start` up to and including
    /// the first one after it containing `end`.
    private static func lines(in code: [String], from start: String, through end: String) throws -> [String] {
        let first = try #require(code.firstIndex { $0.hasPrefix(start) }, "\(start) moved")
        let last = try #require(code[first...].firstIndex { $0.contains(end) }, "\(end) moved")
        return Array(code[first...last])
    }

    @Test("An observed volume change is dropped unless the tap intercepts, before anything is shown")
    func volumeObservedOnlyWhileSuppressing() throws {
        let code = try Self.code(Self.hud)
        let closure = try Self.lines(in: code, from: "volume.onChange = {", through: "self.show(readout)")
        // Exactly these statements, in this order: nothing may show the
        // readout ahead of the guard, and the guard must be real code.
        #expect(closure == [
            "volume.onChange = { [weak self] readout in",
            "guard let self else { return }",
            "guard self.isSuppressing else { return }",
            "self.show(readout)",
        ])
        #expect(code.contains("public var isSuppressing: Bool { interceptor.isRunning }"))
    }

    @Test("Nothing can poll brightness to draw a readout beside the system's")
    func noBrightnessPoll() throws {
        // The watching half of the controller is gone, so there is nothing
        // left to start under any name.
        let controller = try Self.code("Sources/LedgeSystem/Level/BrightnessController.swift")
        #expect(!controller.contains { $0.contains("func startWatching") })
        #expect(!controller.contains { $0.contains("onChange") })
        #expect(!controller.contains { $0.contains("Timer(") })
        // And the HUD owns no brightness controller of its own.
        let hud = try Self.code(Self.hud)
        #expect(!hud.contains { $0.contains(/\bBrightnessController\(/) })
    }

    @Test("Who takes a brightness key", arguments: [
        // Readout on: Ledge, on every display it can dim.
        (true, DisplayBrightnessController.Backend.backlight, true),
        (true, DisplayBrightnessController.Backend.gamma, true),
        // Readout off: the built-in panel goes to macOS, which dims it and
        // draws its own readout.
        (false, DisplayBrightnessController.Backend.backlight, false),
        // Readout off on a display macOS cannot dim: Ledge keeps the key, or
        // the press would dim the MacBook's panel instead.
        (false, DisplayBrightnessController.Backend.gamma, true),
    ])
    func brightnessKeyOwner(readoutEnabled: Bool, backend: DisplayBrightnessController.Backend, ledges: Bool) {
        #expect(HUDCoordinator.brightnessKeyIsLedges(readoutEnabled: readoutEnabled, backend: backend) == ledges)
    }

    @Test("The brightness keys reach that decision, with the live preference and the display's backend")
    func brightnessKeysAreDecidedByThePolicy() throws {
        let code = try Self.code(Self.hud)
        let keyDown = try Self.lines(
            in: code, from: "private func applyKeyDown(", through: "return handleBrightness(key, fine: fine)")
        #expect(keyDown.suffix(2) == ["case .brightnessUp, .brightnessDown:", "return handleBrightness(key, fine: fine)"])

        let handle = try Self.lines(in: code, from: "private func handleBrightness(", through: "else { return false }")
        #expect(handle.contains("Self.brightnessKeyIsLedges(readoutEnabled: preferences.hudBrightnessEnabled,"))
        #expect(handle.contains("backend: display.backend),"))
    }

    @Test("An open Levels card is given a brightness probe, and follows it")
    func levelsCardFollowsBrightness() throws {
        let shell = try Self.code("Sources/LedgeShell/Coordinator/LedgeCoordinator.swift")
        #expect(shell.contains("brightnessProbe: { BrightnessController().level() },"))
        let card = try Self.code("Sources/LedgeUI/Cards/LevelsCardView.swift")
        #expect(card.contains("await followBrightness()"))
    }
}
