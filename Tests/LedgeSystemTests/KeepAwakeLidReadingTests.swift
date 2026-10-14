import Foundation
import LedgeCore
import LedgeHelperKit
import Testing

@testable import LedgeSystem

/// The one place the daemon's vocabulary becomes the app's.
///
/// `KeepAwakeHelperClientTests` already pins what the client does with each
/// answer; these are about what the *card* is then told, which is a different
/// question with a different way of going wrong: a code that falls through the
/// mapping is a refusal the user is never given a reason for.
@Suite("What the lid-closed mode reads")
struct KeepAwakeLidReadingTests {

    private static func status(sleepDisabled: Int = 0, ours: Bool = false,
                               otherLedgeHolds: Bool = false) -> KeepAwakeHelperStatus {
        KeepAwakeHelperStatus(build: "test", sleepDisabled: sleepDisabled, ours: ours,
                              clean: !ours, cleanupPending: false,
                              otherLedgeHolds: otherLedgeHolds, lowPowerClaimed: false)
    }

    // MARK: - The nine codes

    @Test("Every code the wire can carry has somewhere to land")
    func everyCodeMaps() {
        var landed: Set<KeepAwakeLidCode> = []
        for code in KeepAwakeHelperCode.allCases {
            guard let mapped = KeepAwakeLidCode(code) else {
                #expect(code == .ok, "\(code) is a refusal with no sentence behind it")
                continue
            }
            #expect(landed.insert(mapped).inserted,
                    "\(code) shares a meaning with another code, so one of them is unreachable")
        }
        #expect(landed.count == KeepAwakeLidCode.allCases.count,
                "a sentence exists for a refusal the daemon can never send")
        #expect(KeepAwakeHelperCode.allCases.count == 9, "nine answers, one of them ok")
    }

    @Test("ok is not a refusal")
    func okIsNotARefusal() {
        #expect(KeepAwakeLidCode(.ok) == nil)
    }

    @Test("A refusal keeps its own reason all the way to the card")
    func refusalsKeepTheirReason() {
        for code in KeepAwakeHelperCode.allCases where code != .ok {
            let reading = KeepAwakeLidState.reading(
                installation: .installed, client: .refused(code), status: nil
            )
            #expect(reading == .refused(KeepAwakeLidCode(code)!),
                    "\(code) arrived at the card as something else")
        }
    }

    // MARK: - Silence

    /// The headline rule. The daemon drops a hold on its own lease, not on our
    /// inability to reach it, so an unanswered heartbeat means "probably still
    /// held, we just cannot confirm". Turning that into a refusal would have
    /// the card tell the user their Mac is about to sleep when it is not.
    @Test("A silent daemon is unconfirmed, never refused")
    func silenceIsNotARefusal() {
        let reading = KeepAwakeLidState.reading(
            installation: .installed, client: .temporarilyUnavailable, status: nil
        )
        #expect(reading == .unconfirmed)
        #expect(reading.isLive, "the hold is still standing as far as anything here knows")
        #expect(!reading.isRefusal)
    }

    @Test("A hold the daemon confirmed is simply held")
    func holdingIsHolding() {
        #expect(KeepAwakeLidState.reading(installation: .installed, client: .holding,
                                          status: nil) == .holding)
    }

    // MARK: - Nothing asked for yet

    /// Sleep disabled with no Ledge claim to explain it is a standing fact
    /// about the Mac, not the answer to a press. The card has to say so
    /// *before* the user reaches for the mode, or the first thing the feature
    /// ever does is fail.
    @Test("Somebody else's setting is read as foreign before anything is asked")
    func foreignIsReadFromTheStatus() {
        let reading = KeepAwakeLidState.reading(
            installation: .installed, client: .idle,
            status: Self.status(sleepDisabled: 1)
        )
        #expect(reading == .refused(.foreign))
        #expect(!reading.mayArm, "no press will change somebody else's choice")
    }

    @Test("The other build holding it is said to be the other build")
    func otherLedgeIsReadFromTheStatus() {
        let reading = KeepAwakeLidState.reading(
            installation: .installed, client: .idle,
            status: Self.status(sleepDisabled: 1, otherLedgeHolds: true)
        )
        #expect(reading == .refused(.inUseByOtherLedge))
    }

    @Test("Our own claim is not somebody else's")
    func ourOwnClaimIsNotForeign() {
        let reading = KeepAwakeLidState.reading(
            installation: .installed, client: .idle,
            status: Self.status(sleepDisabled: 1, ours: true)
        )
        #expect(reading == .off, "Ledge's own claim is not a reason to refuse Ledge")
    }

    @Test("Nothing set and nothing held is simply off")
    func quietMacIsOff() {
        #expect(KeepAwakeLidState.reading(installation: .installed, client: .idle,
                                          status: Self.status()) == .off)
        #expect(KeepAwakeLidState.reading(installation: .installed, client: .idle,
                                          status: nil) == .off,
                "a daemon that has not spoken yet is not a daemon refusing")
    }

    // MARK: - The installation outranks everything

    /// A helper that cannot exist here, or does not yet, is the larger fact:
    /// there is nothing behind the client for any of its states to have come
    /// from, and a stale `holding` would promise a hold nothing is keeping.
    @Test("What the build can do outranks what the client last said")
    func installationOutranks() {
        for client: KeepAwakeHelperState in [.idle, .holding, .temporarilyUnavailable,
                                             .refused(.busy)] {
            #expect(KeepAwakeLidState.reading(installation: .unsignedBuild, client: client,
                                              status: Self.status(sleepDisabled: 1)) == .unsignedBuild)
            #expect(KeepAwakeLidState.reading(installation: .notInstalled, client: client,
                                              status: Self.status(sleepDisabled: 1)) == .notInstalled)
        }
    }
}

/// A daemon that answers by hand, for the wrapper rather than the client.
private final class ScriptedLink: @unchecked Sendable, KeepAwakeHelperLink {

    private let lock = NSLock()
    private var calls = 0
    private var answer: KeepAwakeHelperCode = .ok
    /// A real daemon answers a hold once the lease is on disk and only then
    /// runs the privileged write. This models that: the status starts saying
    /// nothing is held and begins saying so once a hold has been accepted.
    private var applied = false
    private var reported: KeepAwakeHelperStatus?

    /// Every call that reached the daemon. Zero is the interesting number:
    /// a helper that is not installed must not be spoken to at all.
    var reached: Int { lock.withLock { calls } }

    func answers(_ code: KeepAwakeHelperCode) { lock.withLock { answer = code } }
    func reports(_ status: KeepAwakeHelperStatus) { lock.withLock { reported = status } }

    func status() async throws -> KeepAwakeHelperStatus {
        lock.withLock {
            calls += 1
            if let reported { return reported }
            return KeepAwakeHelperStatus(
                build: "test", sleepDisabled: applied ? 1 : 0, ours: applied,
                clean: !applied, cleanupPending: false,
                otherLedgeHolds: false, lowPowerClaimed: false)
        }
    }

    func hold(session: String, generation: Int, until deadline: Date?,
              leaseSeconds: Double) async throws -> KeepAwakeHelperCode {
        lock.withLock {
            calls += 1
            if answer == .ok { applied = true }
            return answer
        }
    }

    func release(session: String, generation: Int) async throws -> KeepAwakeHelperCode {
        lock.withLock { calls += 1 }
        return .ok
    }

    func setLowPowerMode(_ on: Bool, session: String,
                         generation: Int) async throws -> KeepAwakeHelperCode {
        lock.withLock { calls += 1; return answer }
    }
}

@Suite("The lid-closed hold over the helper")
struct KeepAwakeHelperLidTests {

    private static let deadline = Date(timeIntervalSince1970: 1_003_600)

    private static func lid(_ link: ScriptedLink,
                            _ installation: @escaping @Sendable () -> KeepAwakeHelperInstallation)
        -> KeepAwakeHelperLid {
        KeepAwakeHelperLid(
            client: KeepAwakeHelperClient(
                link: link,
                // Never fires: these are about one call and its answer, not
                // about the heartbeat, which the client's own suite owns.
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
            ),
            installation: installation
        )
    }

    @Test("An accepted hold reads as held")
    func acceptedHoldIsHeld() async {
        let link = ScriptedLink()
        let lid = Self.lid(link) { .installed }
        #expect(await lid.arm(session: "s1", until: Self.deadline) == .holding)
        await lid.disarm(session: nil)
    }

    @Test("A refused hold carries the daemon's own reason")
    func refusedHoldKeepsItsReason() async {
        let link = ScriptedLink()
        link.answers(.pmsetFailed)
        let lid = Self.lid(link) { .installed }
        #expect(await lid.arm(session: "s1", until: Self.deadline) == .refused(.pmsetFailed))
        await lid.disarm(session: nil)
    }

    /// Nothing privileged is spoken to on a Mac where nothing privileged is
    /// installed. Asking anyway would mean an XPC connection attempt — and a
    /// launchd error in the system log — every time somebody opened the card.
    @Test("A helper that is not installed is never spoken to")
    func uninstalledIsNeverCalled() async {
        let link = ScriptedLink()
        let lid = Self.lid(link) { .notInstalled }
        #expect(await lid.arm(session: "s1", until: Self.deadline) == .notInstalled)
        #expect(await lid.state() == .notInstalled)
        #expect(link.reached == 0, "a daemon that cannot be there was called anyway")
    }

    @Test("An unsigned build is never spoken to either")
    func unsignedIsNeverCalled() async {
        let link = ScriptedLink()
        let lid = Self.lid(link) { .unsignedBuild }
        #expect(await lid.arm(session: "s1", until: Self.deadline) == .unsignedBuild)
        #expect(link.reached == 0)
    }

    /// Asked every time, not captured once: a helper installed while Ledge is
    /// running must not need a relaunch to be noticed.
    @Test("The installation is re-read, not remembered")
    func installationIsReRead() async {
        let link = ScriptedLink()
        let installed = Mutable(false)
        let lid = Self.lid(link) { installed.value ? .installed : .notInstalled }
        #expect(await lid.state() == .notInstalled)
        installed.value = true
        #expect(await lid.state() == .off, "the helper appeared and nothing noticed")
    }

    @Test("A status call is how foreign is learnt without asking for anything")
    func stateReadsForeign() async {
        let link = ScriptedLink()
        link.reports(KeepAwakeHelperStatus(
            build: "test", sleepDisabled: 1, ours: false, clean: true,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false))
        let lid = Self.lid(link) { .installed }
        #expect(await lid.state() == .refused(.foreign))
    }
}

/// A box a `@Sendable` closure can read and a test can write.
private final class Mutable: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
