import CoreGraphics
import Foundation
import IOKit
import LedgeCore
import os

/// Something that can say where the lid is.
public protocol LidSensing: AnyObject, Sendable {
    func read() -> LidReading
    /// Starts reporting changes. The handler is also called once with the
    /// reading at the time of the call, so a caller never has to ask twice.
    func observe(_ onChange: @escaping @Sendable (LidReading) -> Void)
    func stop()
}

/// The real one, from IOKit.
///
/// `AppleClamshellState` on `IOPMrootDomain` is the only place macOS says this,
/// and it is a property rather than an API: present on a laptop, absent on a
/// desktop, and absent means no lid rather than an open one.
///
/// Changes arrive as a registry interest notification rather than a poll. A
/// poll would be wrong in both directions here — too slow and the panel stays
/// lit for seconds inside a closed machine, too fast and the thing meant to
/// save power spends it.
public final class ClamshellSensor: @unchecked Sendable, LidSensing {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "lid")

    private let lock = NSLock()
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var handler: (@Sendable (LidReading) -> Void)?
    private var displaysWatched = false

    public init() {}

    deinit { stop() }

    // MARK: - Reading

    public func read() -> LidReading {
        LidReading(state: Self.clamshell(), builtInIsOnlyDisplay: Self.builtInIsOnlyDisplay())
    }

    /// `kIOMainPortDefault` is 0; passing it directly keeps this free of the
    /// renamed-constant problem between SDKs.
    private static func rootDomain() -> io_service_t {
        IOServiceGetMatchingService(0, IOServiceMatching("IOPMrootDomain"))
    }

    private static func clamshell() -> LidState {
        let root = rootDomain()
        guard root != 0 else { return .unknown }
        defer { IOObjectRelease(root) }

        guard let raw = IORegistryEntryCreateCFProperty(
            root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool else {
            // No such property: a Mac with no lid. Not a failure, and not a
            // closed lid either.
            return .unknown
        }
        return raw ? .closed : .open
    }

    /// Whether the built-in panel is the only display attached.
    ///
    /// The **online** list, not the active one. Active means drawable right
    /// now; a monitor that has gone to sleep drops off it while staying very
    /// much attached — and a Mac in clamshell on a desk with a sleeping
    /// external is the one case where everything this mode does would be an
    /// unpleasant surprise rather than a saving. Online is the attachment
    /// question, which is the question actually being asked.
    ///
    /// Asked of CoreGraphics rather than `NSScreen` because this is read from
    /// whatever thread a registry notification arrives on.
    ///
    /// A list nobody could read, and an empty one, both answer `false` — see
    /// `LidDisplays.builtInIsOnly`, which owns that rule and can be tested
    /// without a monitor to unplug.
    private static func builtInIsOnlyDisplay() -> Bool {
        LidDisplays.builtInIsOnly(online: onlineDisplays())
    }

    /// For each display attached to this Mac, whether it is the built-in one.
    /// Nil when CoreGraphics would not say.
    /// One function pointer, named once.
    ///
    /// CoreGraphics matches a reconfiguration callback for removal by its
    /// address, and two closure literals with the same body are not promised
    /// to be the same address. The same mistake with CoreAudio listeners is
    /// what `Scripts/lint-imports.sh` exists to prevent, and it ended in a
    /// shipped build holding a million and a half live registrations.
    private static let displaysChanged: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard let context else { return }
        // Only the ones that change the topology. Moves, mirroring and
        // resolution changes say nothing about what is attached.
        let interesting: CGDisplayChangeSummaryFlags = [
            .addFlag, .removeFlag, .enabledFlag, .disabledFlag,
        ]
        guard !flags.intersection(interesting).isEmpty else { return }
        Unmanaged<ClamshellSensor>.fromOpaque(context).takeUnretainedValue().changed()
    }

    private static func onlineDisplays() -> [Bool]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).map { CGDisplayIsBuiltin($0) != 0 }
    }

    // MARK: - Watching

    public func observe(_ onChange: @escaping @Sendable (LidReading) -> Void) {
        lock.withLock {
            handler = onChange
            guard port == nil else { return }

            let root = Self.rootDomain()
            guard root != 0 else {
                Self.log.notice("lid: no IOPMrootDomain — this Mac's lid cannot be watched")
                return
            }
            defer { IOObjectRelease(root) }

            guard let made = IONotificationPortCreate(0) else {
                Self.log.error("lid: could not create a notification port")
                return
            }
            port = made
            IONotificationPortSetDispatchQueue(made, DispatchQueue.main)

            let context = Unmanaged.passUnretained(self).toOpaque()
            // Displays are watched too, and separately. A monitor plugged in
            // or unplugged while the lid is already shut changes what the
            // closed lid *means* without producing a power event, so a watch
            // on the hinge alone would keep conserving a Mac somebody had
            // just sat down at — until the next unrelated power event
            // happened to come along.
            CGDisplayRegisterReconfigurationCallback(Self.displaysChanged, context)
            displaysWatched = true

            let status = IOServiceAddInterestNotification(
                made, root, kIOGeneralInterest,
                { context, _, _, _ in
                    guard let context else { return }
                    Unmanaged<ClamshellSensor>.fromOpaque(context)
                        .takeUnretainedValue()
                        .changed()
                },
                context, &notification
            )
            if status != KERN_SUCCESS {
                Self.log.error("lid: could not watch the lid (\(status, privacy: .public))")
                IONotificationPortDestroy(made)
                port = nil
                return
            }
        }
        // Outside the lock, and always: a caller that got no notification port
        // still needs the reading it asked for, and a lid that is already shut
        // when a session starts never produces a change to hear about.
        onChange(read())
    }

    /// The registry says something about power changed. It says nothing about
    /// *what*, so the lid is simply read again — the reading is two cheap
    /// lookups, and the alternative is decoding a message type that Apple does
    /// not document for this.
    private func changed() {
        let announce = lock.withLock { handler }
        announce?(read())
    }

    public func stop() {
        lock.withLock {
            handler = nil
            if displaysWatched {
                let context = Unmanaged.passUnretained(self).toOpaque()
                CGDisplayRemoveReconfigurationCallback(Self.displaysChanged, context)
                displaysWatched = false
            }
            if notification != 0 {
                IOObjectRelease(notification)
                notification = 0
            }
            if let port {
                IONotificationPortDestroy(port)
                self.port = nil
            }
        }
    }
}

/// A Mac with no lid to watch.
///
/// The shipping stand-in wherever a sensor is optional, so no caller is written
/// against an optional and every caller gets the one safe answer: unknown, and
/// therefore never put away.
public final class NoLidSensor: LidSensing {
    public init() {}
    public func read() -> LidReading { .unknown }
    public func observe(_ onChange: @escaping @Sendable (LidReading) -> Void) { onChange(.unknown) }
    public func stop() {}
}
