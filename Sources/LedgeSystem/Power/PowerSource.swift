import Foundation
import IOKit.ps
import os

/// Charge state of the machine's own battery.
public struct PowerSnapshot: Equatable, Sendable {

    /// 0...1.
    public var percentage: Double

    public var isCharging: Bool

    /// On external power, whether or not the battery is taking a charge — a
    /// full battery on the wall is plugged in but not charging.
    public var isPluggedIn: Bool

    public var isLowPower: Bool

    /// Seconds until empty, or until full while charging. Nil whenever the
    /// system has no estimate, which is the case for the first several seconds
    /// after every wake, plug, and unplug.
    public var timeRemaining: TimeInterval?

    public init(
        percentage: Double,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        isLowPower: Bool = false,
        timeRemaining: TimeInterval? = nil
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isLowPower = isLowPower
        self.timeRemaining = timeRemaining
    }
}

/// A place battery state can come from.
@MainActor
public protocol PowerSource: AnyObject {

    var identifier: String { get }

    /// False on a Mac with no internal battery, where the card should never
    /// appear at all rather than appear empty.
    var isAvailable: Bool { get }

    /// The current state, or nil when there is no battery to describe.
    func snapshot() -> PowerSnapshot?

    /// Delivers a snapshot on the main actor whenever the battery changes.
    /// Replaces any previous registration.
    func startWatching(_ onChange: @escaping (PowerSnapshot) -> Void)

    func stopWatching()
}

/// The `void *` handed to IOKit's C callback.
///
/// `MediaKeyInterceptor` passes `self` unretained and relies on `stop()` being
/// called; that is correct only for something the app owns for its whole
/// lifetime. A power source is created and dropped by whichever coordinator
/// owns the card, so the callback is aimed at this box instead. The box is
/// retained for exactly as long as the run loop source exists and holds its
/// owner *weakly*, so a notification arriving after the source deallocated
/// reads nil, unhooks itself, and returns. The worst case is one leaked
/// registration that heals on the next power event; there is no case where the
/// callback touches freed memory.
private final class PowerNotificationContext {

    weak var owner: IOKitPowerSource?

    /// Held here rather than on the owner because the self-healing path has to
    /// remove the source after the owner is already gone.
    var source: CFRunLoopSource?

    func detach() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        self.source = nil
    }
}

/// Reads and watches the internal battery through public IOKit power sources.
///
/// Event-driven rather than polled: IOKit posts a notification whenever charge
/// or time-remaining moves, which on a discharging laptop is often enough that
/// a timer would only ever be worse — slower to react and more wakeups.
///
/// Everything the API reports is advisory. Capacities can be published in mAh
/// rather than percent, the time estimates spend real stretches saying "I don't
/// know", and a desktop Mac publishes no battery at all. `parse` is where all
/// of that is turned into something the UI can trust.
@MainActor
public final class IOKitPowerSource: PowerSource {

    // Nonisolated: read from the IOKit callback, which is not on an actor.
    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "power")

    public let identifier = "iokit"

    private var context: PowerNotificationContext?
    private var onChange: ((PowerSnapshot) -> Void)?

    /// Last value delivered, so the frequent notifications while charging do
    /// not push identical snapshots through the card.
    private var last: PowerSnapshot?

    public init() {}

    // MARK: - Reading

    public var isAvailable: Bool {
        Self.internalBattery() != nil
    }

    public func snapshot() -> PowerSnapshot? {
        guard let description = Self.internalBattery() else { return nil }
        return Self.parse(description)
    }

    /// The description of the first present internal battery.
    ///
    /// Filtered by type: a UPS or a Bluetooth peripheral also shows up in the
    /// power sources list, and neither is the machine's own charge.
    private static func internalBattery() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }

            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return description
        }
        return nil
    }

    // MARK: - Parsing

    /// Turns one power source description into a snapshot, or nil if it does
    /// not describe a usable battery.
    ///
    /// Split out so every key name and every sentinel can be tested with a
    /// hand-written dictionary, on a machine with no battery.
    // Nonisolated: pure, and tested directly with invented dictionaries.
    public nonisolated static func parse(_ description: [String: Any]) -> PowerSnapshot? {
        // A portable with two battery bays publishes a dictionary for the empty
        // one too, distinguished only by this key.
        if let isPresent = description[kIOPSIsPresentKey] as? Bool, !isPresent { return nil }

        // Divided rather than read straight off "Current Capacity": the units
        // are the power source's choice, and only Apple's own sources promise
        // percent.
        guard let current = number(description, kIOPSCurrentCapacityKey),
              let maximum = number(description, kIOPSMaxCapacityKey),
              maximum > 0
        else { return nil }

        let percentage = current / maximum
        guard percentage.isFinite else { return nil }

        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let state = description[kIOPSPowerSourceStateKey] as? String
        let isPluggedIn = state == kIOPSACPowerValue

        // Each estimate is only defined in one direction — "Time to Full
        // Charge" while charging, "Time to Empty" while actually running down
        // the battery. Reading the other one gives a stale or invented number.
        let key: String? = if isCharging {
            kIOPSTimeToFullChargeKey
        } else if isPluggedIn {
            nil
        } else {
            kIOPSTimeToEmptyKey
        }

        // -1 means "still calculating", and the gauge also emits 0 and other
        // non-positive values while it settles after a wake or an unplug. All
        // of them mean unknown. Nothing non-positive or non-finite may reach
        // the UI as a duration.
        var timeRemaining: TimeInterval?
        if let key, let minutes = number(description, key), minutes.isFinite, minutes > 0 {
            timeRemaining = minutes * 60
        }

        return PowerSnapshot(
            percentage: min(max(percentage, 0), 1),
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            // Process-wide, not a property of the power source, so it is read
            // here rather than threaded through the description.
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            timeRemaining: timeRemaining
        )
    }

    /// IOKit publishes these as `CFNumber`, but tests write Swift literals;
    /// `NSNumber` is the one type both bridge to.
    private nonisolated static func number(_ description: [String: Any], _ key: String) -> Double? {
        (description[key] as? NSNumber)?.doubleValue
    }

    // MARK: - Watching

    public func startWatching(_ onChange: @escaping (PowerSnapshot) -> Void) {
        stopWatching()
        self.onChange = onChange

        let context = PowerNotificationContext()
        context.owner = self

        let callback: IOPowerSourceCallbackType = { pointer in
            guard let pointer else { return }
            IOKitPowerSource.notified(pointer)
        }

        // Retained here and balanced either by `stopWatching` or by the
        // self-healing branch in `notified`.
        let pointer = Unmanaged.passRetained(context).toOpaque()

        guard let source = IOPSNotificationCreateRunLoopSource(callback, pointer)?
            .takeRetainedValue()
        else {
            Unmanaged<PowerNotificationContext>.fromOpaque(pointer).release()
            self.onChange = nil
            Self.log.error("failed to create power source notification")
            return
        }

        context.source = source
        self.context = context
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    public func stopWatching() {
        onChange = nil
        last = nil

        guard let context else { return }
        self.context = nil
        // Cleared first: the callback treats a nil owner as "tear yourself
        // down", and the source must not be able to reach a stopped watcher.
        context.owner = nil
        context.detach()
        Unmanaged.passUnretained(context).release()
    }

    /// Runs on the run loop the source was added to — the main one.
    ///
    /// Deliberately `nonisolated`: this is reached from C, where no actor is
    /// in effect. Only the raw pointer crosses into the isolated closure.
    private nonisolated static func notified(_ pointer: UnsafeMutableRawPointer) {
        // `assumeIsolated` runs synchronously on this very thread, so the
        // pointer never actually crosses an isolation boundary — but Swift 6
        // cannot see that through the closure and flags the capture.
        nonisolated(unsafe) let pointer = pointer
        MainActor.assumeIsolated {
            let unmanaged = Unmanaged<PowerNotificationContext>.fromOpaque(pointer)
            let context = unmanaged.takeUnretainedValue()

            guard let owner = context.owner else {
                // The source deallocated without stopping. Nothing else will
                // ever remove this run loop source, so it removes itself and
                // gives up the retain the context pointer was holding.
                log.debug("power notification outlived its source — detaching")
                context.detach()
                unmanaged.release()
                return
            }
            owner.deliver()
        }
    }

    private func deliver() {
        guard let onChange, let snapshot = snapshot(), snapshot != last else { return }
        last = snapshot
        onChange(snapshot)
    }

    deinit {
        // Nothing safe to do from here: teardown touches main-actor state.
        // The context's weak owner is what makes that survivable — see
        // `PowerNotificationContext`.
    }
}

/// Fixed data, for tests and for developing the card on a machine whose battery
/// refuses to be in the interesting state.
@MainActor
public final class StubPowerSource: PowerSource {

    public let identifier = "stub"

    /// Settable, so a desktop Mac can be simulated.
    public var isAvailable: Bool

    private var value: PowerSnapshot?
    private var onChange: ((PowerSnapshot) -> Void)?

    public init(value: PowerSnapshot? = nil, isAvailable: Bool = true) {
        self.value = value
        self.isAvailable = isAvailable
    }

    /// Also notifies a watcher, so the watching path can be driven without
    /// IOKit.
    public func set(_ value: PowerSnapshot?) {
        self.value = value
        if let value { onChange?(value) }
    }

    public func snapshot() -> PowerSnapshot? { value }

    public func startWatching(_ onChange: @escaping (PowerSnapshot) -> Void) {
        self.onChange = onChange
    }

    public func stopWatching() {
        onChange = nil
    }
}
