import Foundation
import LedgeCore
import Testing

@testable import LedgeShell
@testable import LedgeSystem

/// The stepping rule is a plain function and is tested as one in
/// `LevelStepTests`. The key handlers cannot run here: they need CoreAudio, a
/// display and an event tap. What they call is read from the source, with
/// comments taken out, so a line that was only commented out cannot pass.
@Suite("The keys go through the stepping rule")
struct KeyStepWiringTests {

    private static func code() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/LedgeShell/Coordinator/HUDCoordinator.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(!text.isEmpty)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                guard let comment = text.range(of: "//") else { return text }
                return String(text[..<comment.lowerBound])
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func body(of function: String, in code: [String]) throws -> [String] {
        let first = try #require(code.firstIndex { $0.hasPrefix(function) }, "\(function) moved")
        let next = code[(first + 1)...].firstIndex { $0.hasPrefix("private func ") || $0.hasPrefix("public func ") }
        return Array(code[first..<(next ?? code.endIndex)])
    }

    @Test("The fine flag of a press reaches both handlers")
    func fineReachesTheHandlers() throws {
        let code = try Self.code()
        #expect(code.contains("let handled = applyKeyDown(press.key, fine: press.isFine)"))
        #expect(code.contains("return handleVolume(key, fine: fine)"))
        #expect(code.contains("return handleBrightness(key, fine: fine)"))
    }

    @Test("A volume key steps by the rule, from where the last press was sent while it settles")
    func volumeUsesTheRule() throws {
        let volume = try Self.body(of: "private func handleVolume(", in: Self.code())
        #expect(volume.contains("reading: current, last: volumeLandings[device],"))
        #expect(volume.contains(
            "settling: VolumeController.selfWriteRemaining(on: device) > 0, step: step, direction: key.delta)"))
        #expect(volume.contains("var target = LevelStep.target(from: start, direction: key.delta, step: step, fine: fine)"))
        #expect(volume.contains("if let again = LevelStep.secondTry("))
        #expect(volume.contains("reading: current, shown: result.shownLevel, target: target,"))
        #expect(volume.contains("let retried = VolumeController.apply(level: again, on: device), retried.didSomething {"))
        #expect(volume.contains("direction: key.delta, target: target, shown: result.shownLevel)]"))
        #expect(!volume.contains { $0.contains("current + Double(key.delta)") }, "the old sum is gone")
    }

    @Test("A brightness key steps by the rule, with the floor of the display it is for")
    func brightnessUsesTheRule() throws {
        let brightness = try Self.body(of: "private func handleBrightness(", in: Self.code())
        #expect(brightness.contains(
            "let floor = display.backend == .gamma ? DisplayBrightnessController.gammaFloor : 0"))
        #expect(brightness.contains(
            "let target = LevelStep.target(from: start, direction: key.delta, step: step, fine: fine, floor: floor)"))
        #expect(!brightness.contains { $0.contains("current + Double(key.delta)") }, "the old sum is gone")
    }

    /// The floor is 0.0075 under a line. If either number moves, this says
    /// what a press from the floor does then.
    @Test("An external display goes from its floor to a quarter and back")
    @MainActor
    func realGammaFloor() {
        let floor = DisplayBrightnessController.gammaFloor
        let step = Prefs.hudBrightnessStep.defaultValue
        #expect(LevelStep.target(from: floor, direction: 1, step: step, floor: floor) == 0.25)
        #expect(LevelStep.target(from: 0.25, direction: -1, step: step, floor: floor) == floor)
        #expect(LevelStep.target(from: floor, direction: -1, step: step, floor: floor) == floor)
    }

    @Test("One step is one segment unless the user changed it")
    func stepIsASegment() {
        #expect(Prefs.hudVolumeStep.defaultValue == 1.0 / Double(HUDRowMetrics.segmentCount))
        #expect(Prefs.hudBrightnessStep.defaultValue == 1.0 / Double(HUDRowMetrics.segmentCount))
    }
}
