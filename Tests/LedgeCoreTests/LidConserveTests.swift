import Foundation
import LedgeCore
import Testing

/// The value restored is not the value readable when it is needed.
///
/// This is the subtlety the whole feature turns on. The lid covers the ambient
/// light sensor on its way down, so by the time macOS reports the close,
/// auto-brightness has already pulled the panel towards nothing — and the
/// number sitting there is the one a naive implementation would hand back to
/// the user. Every test here is about keeping the *other* number.
@Suite("Which brightness gets kept")
struct LidBrightnessSamplerTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func open(_ external: Bool = false) -> LidReading {
        LidReading(state: .open, builtInIsOnlyDisplay: !external)
    }
    private var closed: LidReading { LidReading(state: .closed, builtInIsOnlyDisplay: true) }

    @Test("A session starting samples at once, not a cadence later")
    func samplesAtSessionStart() {
        var sampler = LidBrightnessSampler()
        sampler.sessionBegan(at: start)
        #expect(sampler.isDue(open(), at: start))
    }

    @Test("Nothing is sampled until a session asks for it")
    func nothingBeforeASession() {
        var sampler = LidBrightnessSampler()
        // The very first reading is itself a reason to sample: there is no
        // open to wait out, the lid is simply where it is.
        #expect(!sampler.isDue(open(), at: start))
        sampler.observed(open(), at: start)
        #expect(sampler.isDue(open(), at: start))
    }

    @Test("The cadence is thirty seconds")
    func cadence() {
        var sampler = LidBrightnessSampler()
        sampler.sessionBegan(at: start)
        sampler.took(0.6, at: start)
        #expect(!sampler.isDue(open(), at: start.addingTimeInterval(29)))
        #expect(sampler.isDue(open(), at: start.addingTimeInterval(30)))
    }

    /// The panel is still on its way back up at the instant the hinge reports
    /// an open. Sampling then keeps the dimmed value, which is the exact
    /// mistake this delay exists to avoid.
    @Test("An open is given three seconds before it is believed")
    func waitsAfterAnOpen() {
        var sampler = LidBrightnessSampler()
        sampler.observed(open(), at: start)
        sampler.took(0.6, at: start)
        sampler.observed(closed, at: start.addingTimeInterval(10))
        sampler.observed(open(), at: start.addingTimeInterval(100))

        #expect(!sampler.isDue(open(), at: start.addingTimeInterval(102)))
        #expect(sampler.isDue(open(), at: start.addingTimeInterval(103)))
    }

    /// The headline rule. A reading taken under a closed lid is the reading
    /// this type exists to refuse.
    @Test("Nothing is ever sampled with the lid down")
    func neverSamplesShut() {
        var sampler = LidBrightnessSampler()
        sampler.sessionBegan(at: start)
        #expect(!sampler.isDue(closed, at: start.addingTimeInterval(1000)))
        #expect(!sampler.isDue(.unknown, at: start.addingTimeInterval(1000)))
    }

    @Test("Closing the lid cancels a sample that was due")
    func closingCancels() {
        var sampler = LidBrightnessSampler()
        sampler.observed(open(), at: start)
        sampler.observed(closed, at: start.addingTimeInterval(1))
        // Even back open, nothing is due until the next open reschedules it.
        #expect(!sampler.isDue(open(), at: start.addingTimeInterval(1)))
    }

    /// The registry notification behind the lid fires for every power event.
    /// A repeat of the same position is not an open and must not restart the
    /// three-second wait, or a Mac that wakes repeatedly never samples at all.
    @Test("A repeated reading is not a new open")
    func repeatsAreNotOpens() {
        var sampler = LidBrightnessSampler()
        sampler.observed(open(), at: start)
        sampler.observed(open(), at: start.addingTimeInterval(1))
        sampler.observed(open(), at: start.addingTimeInterval(2))
        #expect(sampler.isDue(open(), at: start))
    }

    @Test("A level that could not be read leaves the last one standing")
    func unreadableKeepsTheOldValue() {
        var sampler = LidBrightnessSampler()
        sampler.took(0.6, at: start)
        sampler.took(nil, at: start.addingTimeInterval(30))
        #expect(sampler.held == 0.6)
    }

    @Test("A level outside 0...1, or not a number, never becomes the held value")
    func clampsAndRefusesNonsense() {
        var sampler = LidBrightnessSampler()
        sampler.took(1.4, at: start)
        #expect(sampler.held == 1)
        sampler.took(-0.2, at: start)
        #expect(sampler.held == 0)
        sampler.took(0.5, at: start)
        sampler.took(Double.nan, at: start)
        #expect(sampler.held == 0.5)
    }

    @Test("A session ending keeps the value and drops the schedule")
    func sessionEndKeepsTheValue() {
        var sampler = LidBrightnessSampler()
        sampler.sessionBegan(at: start)
        sampler.took(0.6, at: start)
        sampler.sessionEnded()
        #expect(sampler.held == 0.6)
        #expect(!sampler.isDue(open(), at: start.addingTimeInterval(1000)))
    }
}

@Suite("What goes back when the lid comes up")
struct LidRestoreTests {

    private let entry = LidConserveRecord.Audio(
        uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", volume: 0.42, muted: false,
        governed: [0]
    )

    @Test("A device still muted gets its mute back")
    func restoresTheDevice() {
        #expect(LidRestore.audio(entry, isPresent: true, isMutedNow: true)
                == .put(muted: false))
    }

    /// The user reached for the mute key themselves. The silence Ledge made is
    /// already gone, and whatever they chose is theirs.
    @Test("A device the user unmuted is left alone")
    func unmutedIsLeftAlone() {
        #expect(LidRestore.audio(entry, isPresent: true, isMutedNow: false) == .leaveAlone)
    }

    /// macOS remembers a device's volume across unplugging, so a headset
    /// pulled while the lid was down comes back muted unless the entry
    /// survives to meet it.
    @Test("A device that is not attached keeps its entry")
    func absentKeepsTheEntry() {
        #expect(LidRestore.audio(entry, isPresent: false, isMutedNow: nil) == .deviceAbsent)
        #expect(LidRestore.audio(entry, isPresent: false, isMutedNow: true) == .deviceAbsent)
    }

    /// An unreadable mute is not evidence that the user did anything, and the
    /// entry is the only account of what was there before.
    @Test("A device that will not say whether it is muted is still restored")
    func unreadableMuteRestores() {
        #expect(LidRestore.audio(entry, isPresent: true, isMutedNow: nil)
                == .put(muted: false))
    }

    /// The level is not part of the answer at all. The conserve mutes and
    /// nothing else, so the restore unmutes and nothing else — a remembered
    /// level written back is a control Ledge never moved.
    @Test("What goes back is the mute, whatever the level was")
    func onlyTheMuteGoesBack() {
        let quiet = LidConserveRecord.Audio(uid: "x", volume: nil, muted: true, governed: [0])
        #expect(LidRestore.audio(quiet, isPresent: true, isMutedNow: true) == .put(muted: true))

        let loud = LidConserveRecord.Audio(uid: "x", volume: 0.9, muted: true, governed: [0])
        #expect(LidRestore.audio(loud, isPresent: true, isMutedNow: true)
                == LidRestore.audio(quiet, isPresent: true, isMutedNow: true),
                "a remembered level changed what the restore would do")
    }

    @Test("Low Power Mode goes back off, unless it was on before")
    func lowPowerGoesBack() {
        #expect(!LidRestore.lowPower(.init(wasOn: false), floorWantsIt: false))
        #expect(LidRestore.lowPower(.init(wasOn: true), floorWantsIt: false))
    }

    /// Turning it off and straight back on is a flicker in the menu bar for no
    /// gain, and a moment of full power on a Mac something else wants quiet.
    @Test("A floor that still wants Low Power Mode keeps it on")
    func floorKeepsLowPowerOn() {
        #expect(LidRestore.lowPower(.init(wasOn: false), floorWantsIt: true))
    }
}

/// A private class is not safe because its selector is still there.
///
/// `dlsym` returning nil is a failure you can see. A selector that survives
/// with different argument types is not: it is found, it is called, and the
/// bytes in the registers are not the ones it wants. The encoding is the only
/// evidence there is.
@Suite("Whether a private class may be called at all")
struct PrivateMethodGateTests {

    private let expected = [
        "brightnessForKeyboard:": "f24@0:8Q16",
        "setBrightness:forKeyboard:": "B28@0:8f16Q20",
    ]

    @Test("Everything present and unchanged is the only way through")
    func matchingPasses() {
        #expect(PrivateMethodGate.check(className: "K", expected: expected, found: expected) == .ok)
    }

    @Test("Extra methods on the class are nobody's business")
    func extrasAreIgnored() {
        var found = expected
        found["somethingNew:"] = "v24@0:8@16"
        #expect(PrivateMethodGate.check(className: "K", expected: expected, found: found) == .ok)
    }

    @Test("A class that is not there refuses, and says so by name")
    func missingClassRefuses() {
        #expect(PrivateMethodGate.check(className: "K", expected: expected, found: nil)
                == .noSuchClass("K"))
    }

    @Test("A method that has gone refuses")
    func missingMethodRefuses() {
        var found = expected
        found["setBrightness:forKeyboard:"] = nil
        #expect(PrivateMethodGate.check(className: "K", expected: expected, found: found)
                == .missing(method: "setBrightness:forKeyboard:"))
    }

    /// The dangerous case, and the reason existence is not enough: the method
    /// is right there, and it now takes a double where it used to take a float.
    @Test("A method whose signature changed refuses")
    func changedEncodingRefuses() {
        var found = expected
        found["setBrightness:forKeyboard:"] = "B32@0:8d16Q24"
        #expect(PrivateMethodGate.check(className: "K", expected: expected, found: found)
                == .changed(method: "setBrightness:forKeyboard:",
                            expected: "B28@0:8f16Q20", found: "B32@0:8d16Q24"))
    }

    @Test("Every refusal has a sentence a log can carry")
    func refusalsExplainThemselves() {
        let verdicts: [PrivateMethodGate.Verdict] = [
            .noSuchClass("K"), .missing(method: "a"),
            .changed(method: "a", expected: "x", found: "y"),
        ]
        for verdict in verdicts {
            #expect(!verdict.isOK)
            #expect(!verdict.reason.isEmpty)
            #expect(verdict.reason != "ok")
        }
        #expect(PrivateMethodGate.Verdict.ok.isOK)
    }

    /// Two methods gone must always name the same one, and which one must not
    /// depend on how a dictionary felt about hashing that morning.
    ///
    /// A log line that names a different method on different launches is a log
    /// line nobody can search for, and the whole value of this gate is the one
    /// sentence it leaves behind when a feature goes quiet. So the answer is
    /// pinned to something that cannot drift: the first method in order.
    ///
    /// Checked over many different name sets rather than one, because a single
    /// dictionary iterates the same way all day inside one process — which is
    /// exactly how an unordered walk passes a test that was meant to catch it.
    @Test("A refusal always names the first method in order, never the first hashed")
    func refusalNamesTheFirstInOrder() {
        var seed: UInt64 = 0x5EED
        func nextName() -> String {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return "m\(seed % 1_000_000):"
        }

        for _ in 0..<200 {
            var names: [String: String] = [:]
            for _ in 0..<6 { names[nextName()] = "v16@0:8" }
            guard let first = names.keys.sorted().first else { continue }
            #expect(PrivateMethodGate.check(className: "K", expected: names, found: [:])
                    == .missing(method: first),
                    "the refusal named whichever method the dictionary happened to reach first")
        }
    }

    /// The same, for an encoding that changed rather than a method that went.
    @Test("A changed encoding is reported for the first method in order too")
    func changeNamesTheFirstInOrder() {
        var expectedMany: [String: String] = [:]
        for index in 0..<12 { expectedMany["m\(index):"] = "f24@0:8Q16" }
        let broken = expectedMany.mapValues { _ in "d24@0:8Q16" }
        let first = expectedMany.keys.sorted()[0]

        #expect(PrivateMethodGate.check(className: "K", expected: expectedMany, found: broken)
                == .changed(method: first, expected: "f24@0:8Q16", found: "d24@0:8Q16"))
    }
}

@Suite("The record of what was changed")
struct LidConserveRecordTests {

    @Test("A record with nothing in it is nothing to put back")
    func emptiness() {
        let stamp = Date(timeIntervalSince1970: 1)
        #expect(LidConserveRecord(writtenAt: stamp).isEmpty)
        #expect(!LidConserveRecord(writtenAt: stamp, panel: .init(level: 0.5)).isEmpty)
        #expect(!LidConserveRecord(writtenAt: stamp, keyboard: .init(level: 0.5)).isEmpty)
        #expect(!LidConserveRecord(writtenAt: stamp,
                                   audio: .init(uid: "u", muted: false)).isEmpty)
        #expect(!LidConserveRecord(writtenAt: stamp, lowPower: .init(wasOn: false)).isEmpty)
    }

    @Test("A level outside the range never reaches the disk")
    func levelsAreClamped() {
        #expect(LidConserveRecord.Level(level: 4).level == 1)
        #expect(LidConserveRecord.Level(level: -4).level == 0)
    }

    /// The record outlives the process that wrote it — that is its whole job —
    /// so it has to survive a round trip through the disk unchanged.
    @Test("A record survives being written down and read back")
    func roundTrips() throws {
        let record = LidConserveRecord(
            boot: "BOOT-1", sessionID: "S1", writtenAt: Date(timeIntervalSince1970: 1_700_000),
            panel: .init(level: 0.63), keyboard: .init(level: 0.2),
            audio: .init(uid: "uid", name: "Speakers", volume: 0.4, muted: false),
            lowPower: .init(wasOn: false)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(
            LidConserveRecord.self, from: try encoder.encode(record)
        )
        #expect(back == record)
    }
}

/// What counts as evidence that nobody is looking at this Mac.
///
/// Both ways of getting this wrong are about absence. A monitor that has gone
/// to sleep is still attached and still the screen somebody is sitting at; a
/// list nobody could read is not an empty one. Answering "built-in only" to
/// either of those turns on every saving — a dark screen and silent audio —
/// for a Mac in clamshell on a desk with somebody working at it.
@Suite("Whether the built-in panel is the only screen")
struct LidDisplaysTests {

    @Test("A Mac with only its own panel is built-in only")
    func builtInAlone() {
        #expect(LidDisplays.builtInIsOnly(online: [true]))
    }

    /// The case that matters. `CGGetActiveDisplayList` drops a sleeping
    /// external; the online list does not, which is why the decision is asked
    /// of what is attached rather than of what is awake.
    @Test("An external that is merely asleep still counts")
    func sleepingExternalCounts() {
        #expect(!LidDisplays.builtInIsOnly(online: [true, false]))
        #expect(!LidDisplays.builtInIsOnly(online: [false, true]))
    }

    /// Not conservative-looking, conservative: the cost of not conserving a
    /// Mac that was put away is a warm battery, and the cost of conserving one
    /// somebody is working at is their screen going black while they use it.
    @Test("A list nobody could read is never built-in only")
    func unreadableIsNotEvidence() {
        #expect(!LidDisplays.builtInIsOnly(online: nil))
    }

    @Test("A Mac that reports no displays at all is never built-in only")
    func emptyIsNotEvidence() {
        #expect(!LidDisplays.builtInIsOnly(online: []))
    }

    @Test("An external alone is not the built-in panel either")
    func externalOnly() {
        #expect(!LidDisplays.builtInIsOnly(online: [false]))
    }

    /// The whole reason this exists: it decides whether a closed lid conserves.
    @Test("The answer is what a closed lid is judged against")
    func feedsTheReading() {
        let putAway = LidReading(state: .closed,
                                 builtInIsOnlyDisplay: LidDisplays.builtInIsOnly(online: [true]))
        #expect(putAway.isPutAway)

        let onADesk = LidReading(state: .closed,
                                 builtInIsOnlyDisplay: LidDisplays.builtInIsOnly(online: [true, false]))
        #expect(!onADesk.isPutAway)

        let unsure = LidReading(state: .closed,
                                builtInIsOnlyDisplay: LidDisplays.builtInIsOnly(online: nil))
        #expect(!unsure.isPutAway)
    }
}
