import Foundation
import LedgeCore
import LedgeSystem
import os

/// Turns power state into activities.
///
/// The design decision here generalises to every event-driven provider:
/// **publish transitions, not state.** A permanent battery card would sit in
/// the queue forever and cycle in front of whatever the user actually wants to
/// see. Battery is news when it crosses a line — plugged in, unplugged, running
/// low, full — and silence the rest of the time.
@MainActor
public final class BatteryProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "battery")

    public let identifier = "battery"

    /// What just happened that is worth showing.
    ///
    /// Pure and static so the whole rule can be tested against invented
    /// snapshots — no IOKit, no clock, no battery in the machine.
    public enum Transition: Equatable, Sendable {
        case pluggedIn
        case unplugged
        case fullyCharged
        case low
        case critical
        case lowPowerMode(Bool)
    }

    /// Whether a warning has already been given on this discharge.
    ///
    /// A crossing test alone is not enough: charge wobbles by a fraction of a
    /// percent constantly, so 20.1% → 19.9% is a fresh "crossing" every time it
    /// happens and the user gets warned repeatedly. The latch says it once.
    public struct Warnings: Equatable, Sendable {
        var low = false
        var critical = false
        public init() {}
    }

    /// Crossing points, matching the levels macOS itself warns at.
    static let lowThreshold = 0.20
    static let criticalThreshold = 0.10

    /// How far back above a threshold the charge must climb before that warning
    /// is armed again. Wide enough to clear ordinary fluctuation.
    static let rearmMargin = 0.05

    /// How long the card stays up. Long enough to read, short enough that it
    /// does not linger over the thing it interrupted.
    static let lifetime: TimeInterval = 6

    /// Whether the charger changed its mind while the plug stayed put.
    ///
    /// Not a transition, deliberately: it is the same event the card is already
    /// showing, seen a moment later. Two things happen a second apart on a real
    /// Mac — the plug is reported before charging begins, and charging stops
    /// below full when the system decides to hold at 80% — and neither is worth
    /// a second card. What they are worth is the card on screen telling the
    /// truth.
    static func chargingChanged(from old: PowerSnapshot?, to new: PowerSnapshot) -> Bool {
        guard let old else { return false }
        return old.isPluggedIn == new.isPluggedIn && old.isCharging != new.isCharging
    }

    static func transitions(
        from old: PowerSnapshot?,
        to new: PowerSnapshot,
        warnings: inout Warnings
    ) -> [Transition] {
        // Plugging in ends the discharge, so both warnings re-arm for next time.
        if new.isPluggedIn {
            warnings = Warnings()
        } else {
            if new.percentage > Self.lowThreshold + Self.rearmMargin { warnings.low = false }
            if new.percentage > Self.criticalThreshold + Self.rearmMargin { warnings.critical = false }
        }

        // The first reading after launch establishes a baseline. Treating it as
        // a transition would pop a card every time the app starts.
        guard let old else { return [] }

        var result: [Transition] = []

        if old.isPluggedIn != new.isPluggedIn {
            result.append(new.isPluggedIn ? .pluggedIn : .unplugged)
        }

        // Charging stops at 100% while still plugged in, which is the moment
        // worth reporting — not every subsequent reading at 100%.
        if old.isCharging, !new.isCharging, new.isPluggedIn, new.percentage >= 0.99 {
            result.append(.fullyCharged)
        }

        if old.isLowPower != new.isLowPower {
            result.append(.lowPowerMode(new.isLowPower))
        }

        // Only on the way down, once per discharge, and never while charging —
        // draining below 20% on a charger that cannot keep up is not worth
        // interrupting anyone about.
        if !new.isPluggedIn {
            if !warnings.critical, new.percentage <= Self.criticalThreshold {
                warnings.critical = true
                // A critical warning subsumes the low one; two cards for one
                // event would be noise.
                warnings.low = true
                result.append(.critical)
            } else if !warnings.low, new.percentage <= Self.lowThreshold {
                warnings.low = true
                result.append(.low)
            }
        }

        return result
    }

    private let source: any PowerSource
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var previous: PowerSnapshot?
    private var warnings = Warnings()

    public init(
        source: any PowerSource,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            // Seed the baseline so the first real change is measured against
            // reality rather than against nothing.
            self.previous = self.source.snapshot()
            // Seed the latch from the starting level, so launching at 15%
            // does not immediately warn about a level the user already knows.
            if let start = self.previous, !start.isPluggedIn {
                self.warnings.low = start.percentage <= Self.lowThreshold
                self.warnings.critical = start.percentage <= Self.criticalThreshold
            }
            self.source.startWatching { [weak self] snapshot in
                self?.handle(snapshot)
            }
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
        previous = nil
        warnings = Warnings()
        liveHeadline = nil
        liveTransitions = []
        liveSince = nil
    }

    private func handle(_ snapshot: PowerSnapshot) {
        Self.log.debug("""
            power reading: pct=\(snapshot.percentage, privacy: .public) \
            plugged=\(snapshot.isPluggedIn, privacy: .public) \
            charging=\(snapshot.isCharging, privacy: .public)
            """)
        let transitions = Self.transitions(from: previous, to: snapshot, warnings: &warnings)
        let chargingMoved = Self.chargingChanged(from: previous, to: snapshot)
        previous = snapshot

        guard let headline = transitions.first else {
            // Nothing to announce. But the plug's own story is often told in
            // two readings — connected, then charging, a second later; or
            // charging, then holding at 80% — and a card that said "not
            // charging" a second ago was left saying it for its whole life
            // while the bolt was on in the menu bar.
            //
            // So the card on screen is refreshed in place: same activity, same
            // headline, new numbers. Not extended — it keeps the deadline it
            // was published with, so a charger that flickers cannot hold the
            // island open, and with no card up this does nothing at all.
            guard chargingMoved,
                  let liveHeadline, let liveSince,
                  case let age = now() - liveSince, age < Self.lifetime
            else { return }
            Self.log.debug("battery: refreshing the live card, charging=\(snapshot.isCharging, privacy: .public)")
            announce(liveHeadline, transitions: liveTransitions, snapshot: snapshot, lifetime: Self.lifetime - age)
            return
        }

        Self.log.debug("battery transition \(String(describing: headline), privacy: .public)")
        liveHeadline = headline
        liveTransitions = transitions
        liveSince = now()
        announce(headline, transitions: transitions, snapshot: snapshot, lifetime: Self.lifetime)
    }

    /// The card on screen, if one is: what it is saying, and since when.
    private var liveHeadline: Transition?
    private var liveTransitions: [Transition] = []
    private var liveSince: TimeInterval?

    private func announce(
        _ headline: Transition,
        transitions: [Transition],
        snapshot: PowerSnapshot,
        lifetime: TimeInterval
    ) {
        _ = headline
        continuation?.yield(.publish(Activity(
            id: ActivityID(kind: .power, source: "internal"),
            // A critical warning should outrank a routine plug-in, and both
            // should outrank whatever is playing.
            priority: transitions.contains(.critical)
                ? ActivityKind.power.defaultPriority + 20
                : nil,
            createdAt: now(),
            expiresAfter: lifetime,
            payload: .power(PowerPayload(
                percentage: snapshot.percentage,
                isCharging: snapshot.isCharging,
                isLowPower: snapshot.isLowPower,
                timeRemaining: snapshot.timeRemaining
            ))
        )))
    }
}
