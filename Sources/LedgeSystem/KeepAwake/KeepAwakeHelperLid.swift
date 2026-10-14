import Foundation
import LedgeCore
import LedgeHelperKit

/// The daemon's vocabulary, in the app's.
///
/// One function, in one place, with one test that walks every code the wire
/// can carry. The mapping is the only thing that must not drift: a code the
/// app does not recognise is a refusal the user is never told the reason for,
/// which is the exact failure the nine codes exist to prevent.
extension KeepAwakeLidCode {

    /// Every answer but `ok`, which is not a refusal and so has no sentence.
    public init?(_ code: KeepAwakeHelperCode) {
        switch code {
        case .ok: return nil
        case .foreign: self = .foreign
        case .inUseByOtherLedge: self = .inUseByOtherLedge
        case .stale: self = .stale
        case .busy: self = .busy
        case .persistFailed: self = .persistFailed
        case .pmsetFailed: self = .pmsetFailed
        case .notHolder: self = .notHolder
        case .invalidArgument: self = .invalidArgument
        }
    }
}

extension KeepAwakeLidState {

    /// What the card should say, given everything known at once.
    ///
    /// Three readings, in order of how much they settle:
    ///
    /// 1. The installation. A helper that cannot exist here, or does not yet,
    ///    outranks whatever the client last managed to say — there is nothing
    ///    behind it for any of that to have come from.
    /// 2. What the client is doing. `temporarilyUnavailable` becomes
    ///    `unconfirmed`, never a refusal: the daemon drops a hold on its own
    ///    lease and not on our silence, so the hold is almost certainly still
    ///    standing and saying otherwise would be telling the user their Mac is
    ///    about to sleep when it is not. `pending` lands there too: the daemon
    ///    answers a hold once the lease is on disk and before it runs the
    ///    privileged write, so an `ok` is an acceptance and not yet a hold.
    /// 3. The last status, which is the only place `foreign` can be read from
    ///    while nothing has been asked for. Sleep disabled with no Ledge claim
    ///    to explain it is a standing fact about the Mac, and the card has to
    ///    say so *before* a press rather than as the answer to one.
    public static func reading(
        installation: KeepAwakeHelperInstallation,
        client: KeepAwakeHelperState,
        status: KeepAwakeHelperStatus?
    ) -> KeepAwakeLidState {
        switch installation {
        case .unsignedBuild: return .unsignedBuild
        case .notInstalled: return .notInstalled
        case .installed: break
        }

        switch client {
        case .holding:
            return .holding
        case .pending, .temporarilyUnavailable:
            // Both are "the lease is taken and we cannot say the setting is".
            // `pending` is the daemon having accepted the lease and not yet
            // confirmed the privileged write; `temporarilyUnavailable` is the
            // daemon having gone quiet. Neither is a failure and neither is a
            // confirmed hold, and the card's sentence for that — the Mac is
            // very probably held, we cannot prove it — is true of both.
            return .unconfirmed
        case .refused(let code):
            // `ok` never reaches here — the client turns it into `.holding` —
            // but a code the mapping cannot name must not become silence, so
            // the fallback is the one refusal that says "Ledge's fault, try
            // again" rather than nothing at all.
            return .refused(KeepAwakeLidCode(code) ?? .invalidArgument)
        case .idle:
            guard let status else { return .off }
            if status.isForeign { return .refused(.foreign) }
            if status.otherLedgeHolds { return .refused(.inUseByOtherLedge) }
            return .off
        }
    }
}

/// The lid-closed hold, over the real daemon.
///
/// An actor around the client's actor rather than inside it: the client knows
/// about leases and generations and nothing about installation, and keeping it
/// that way is what lets the whole of its behaviour be tested against a link
/// that answers by hand.
public actor KeepAwakeHelperLid: KeepAwakeLidHolding {

    private let client: KeepAwakeHelperClient
    /// Asked every time rather than captured once: a helper installed while
    /// Ledge is running must not need a relaunch to be noticed, and one
    /// removed underneath us must not leave the card offering a mode that is
    /// gone.
    private let installation: @Sendable () -> KeepAwakeHelperInstallation

    public init(client: KeepAwakeHelperClient,
                installation: @escaping @Sendable () -> KeepAwakeHelperInstallation) {
        self.client = client
        self.installation = installation
    }

    public func state() async -> KeepAwakeLidState {
        let now = installation()
        guard now == .installed else { return Self.reading(now) }
        // The status call is answered from the daemon's memory and spawns
        // nothing, so it is cheap enough to ask on every reading — and it is
        // the only way `foreign` is ever learnt without first being refused.
        var status = await client.refreshStatus()
        if status == nil { status = await client.status }
        return KeepAwakeLidState.reading(
            installation: now, client: await client.currentState, status: status
        )
    }

    public func arm(session: String, until deadline: Date) async -> KeepAwakeLidState {
        let now = installation()
        guard now == .installed else { return Self.reading(now) }
        let outcome = await client.begin(session: session, until: deadline)
        return KeepAwakeLidState.reading(
            installation: now, client: outcome, status: await client.status
        )
    }

    public func disarm(session: String?) async {
        await client.end(session: session)
    }

    private static func reading(_ installation: KeepAwakeHelperInstallation) -> KeepAwakeLidState {
        installation == .unsignedBuild ? .unsignedBuild : .notInstalled
    }
}
