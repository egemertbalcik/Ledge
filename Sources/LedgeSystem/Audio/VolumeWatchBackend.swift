import CoreAudio
import Foundation
import LedgeCore
import os

/// Owns the volume listeners, off the main thread.
///
/// Registering and unregistering a CoreAudio property listener is synchronous
/// work that talks to coreaudiod, and the queue handed to the Add call governs
/// only where *callbacks* arrive — not where the Add itself runs. Doing that on
/// the main actor is what turned a listener problem into a frozen interface, so
/// every registration, removal, reconciliation and hardware read happens on
/// this object's own serial queue. Nothing here touches the main actor except
/// the delivery of a finished readout.
///
/// Three rules hold it together:
///
/// - **A generation per watching session.** Stop bumps it. A callback queued by
///   the HAL before a stop can still arrive after it — cancellation cannot
///   reach into CoreAudio's own queue — so every entry point compares the
///   generation it was made with against the current one and drops if stale.
/// - **One pending reconcile, with a dirty flag.** A burst of notifications
///   sets the flag; it does not create work per notification. A sustained
///   stream cannot postpone the reconcile indefinitely, because the flag is
///   cleared before the pass rather than after it.
/// - **A mailbox of one for the UI.** The latest readout replaces any unsent
///   one, so a stalled main thread accumulates a single pending delivery
///   rather than a queue of them.
final class VolumeWatchBackend: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "volume")

    /// At most one system listener plus this many device listeners: mute, and
    /// the volume scalar for the main element and two channels.
    static let maximumDeviceListeners = 4

    /// A property address, as something that can key a dictionary.
    struct AddressKey: Hashable, Sendable {
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: UInt32

        init(_ address: AudioObjectPropertyAddress) {
            selector = address.mSelector
            scope = address.mScope
            element = address.mElement
        }
    }

    private let queue = DispatchQueue(label: "com.egemert.ledge.volume.watch")

    /// Which lifecycle command is the latest one asked for.
    ///
    /// `start` and `stop` both hand their real work to the queue, so a stop
    /// issued before a queued start has run would otherwise be *overtaken*: the
    /// start block executes afterwards, opens a fresh mailbox session, installs
    /// listeners and publishes — after the caller has already stopped. Held
    /// under a lock rather than on the queue, because the point is to be
    /// readable from outside the queue, at the moment the command is issued.
    private let lifecycle = OSAllocatedUnfairLock(initialState: 0)

    /// Claims the next command number. Anything queued under an older one is
    /// superseded and must do nothing.
    private func nextCommand() -> Int {
        lifecycle.withLock { command in
            command &+= 1
            return command
        }
    }

    private func isCurrent(_ command: Int) -> Bool {
        lifecycle.withLock { $0 } == command
    }
    private let hardware: any AudioHardware

    // MARK: State, touched only on `queue`

    private var generation = 0
    private var isWatching = false
    private var systemListener: (any AudioRegistration)?
    /// Kept per address rather than as a flat list, so a bind that is refused
    /// one property keeps the listeners it already has instead of discarding
    /// healthy registrations to try the whole set again.
    private var deviceListeners: [AddressKey: any AudioRegistration] = [:]
    private var boundDevice: AudioObjectID?

    /// Repair attempts spent on the current device. Not reset by a repeated
    /// start or by a notification about an unchanged device — those are exactly
    /// the events a stuck binding produces in quantity, and letting them refill
    /// the budget is how "bounded recovery" becomes an unbounded retry.
    private var repairAttempts = 0
    private static let maximumRepairAttempts = 3
    /// Set when a bind left the device without the listeners it should have —
    /// a property that vanished mid-arm, a registration the hardware refused.
    /// An unchanged device ID is not on its own proof that a binding is sound,
    /// so a known-incomplete one is allowed one bounded repair per notification
    /// rather than being skipped forever.
    private var bindingIncomplete = false

    private var reconcilePending = false
    private var dirty = false
    /// A level notification sets this; the read happens once per window rather
    /// than once per callback. Four registrations on one device mean one volume
    /// step arrives as several notifications, each of which used to cost a
    /// full trip to the hardware.
    private var levelDirty = false
    private var levelReadPending = false
    /// One pending wait for a self-write ramp to finish, never one per
    /// notification — a ramp produces a stream of them.
    private var settlePending = false

    /// Carries readouts to the main actor, one outstanding delivery at a time,
    /// with the session checked again at the far end.
    private let mailbox: MainMailbox<HUDReadout>

    /// - Parameter deliveryQueue: where finished readouts are handed over.
    ///   The main queue in the app; tests pass one they own, so proving the
    ///   delivery bound does not mean blocking the queue every other test needs.
    init(
        hardware: any AudioHardware = SystemAudioHardware(),
        deliveryQueue: DispatchQueue = .main
    ) {
        self.hardware = hardware
        self.mailbox = MainMailbox(isEqual: ==, deliveryQueue: deliveryQueue)
    }

    // MARK: - Starting and stopping

    /// Arms the watch. Calling it again while already watching does nothing at
    /// all — no Add, no Remove — unless a previous bind is known to be
    /// incomplete, in which case it gets one repair.
    /// - Parameter deliver: run on `deliveryQueue`. The backend does not
    ///   assume an isolation it was not given — the caller that chose the queue
    ///   is the one that knows what runs there.
    func start(deliver: @escaping @Sendable (HUDReadout) -> Void) {
        let command = nextCommand()
        queue.async { [self] in
            // A stop issued after this was queued wins: nothing is opened and
            // nothing is registered.
            guard isCurrent(command) else { return }
            guard !isWatching else {
                // Already watching. Take the new closure, but do *not* open a
                // new mailbox session: every live listener is holding the
                // current generation, and bumping it would make all their
                // future updates look stale and silently stop the readout.
                // `HUDCoordinator` calls this again on settings and permission
                // changes, so this is the ordinary path, not an edge case.
                mailbox.setDeliver(deliver)
                // Repair what is missing and nothing else — a repeated start
                // must not touch a healthy registration, and must not refill
                // the repair budget either.
                repairIfNeeded()
                return
            }
            isWatching = true
            generation = mailbox.open(deliver: deliver)
            repairAttempts = 0
            installSystemListener()
            bind(to: hardware.defaultOutputDevice())
        }
    }

    func stop() {
        // Claimed before anything else, so a start already queued behind this
        // sees itself superseded rather than reopening the session.
        _ = nextCommand()
        // Closing disqualifies anything already on its way to the consumer; the
        // generation bump is what an enqueued delivery is checked against.
        mailbox.close()
        queue.async { [self] in
            // Cleanup still runs even if nothing was watching: a superseded
            // start may have been skipped, and this is what leaves the state
            // consistent either way.
            guard isWatching else { return }
            isWatching = false
            generation &+= 1
            deviceListeners.removeAll()
            systemListener = nil
            boundDevice = nil
            repairAttempts = 0
            reconcilePending = false
            dirty = false
            levelDirty = false
            levelReadPending = false
            settlePending = false
        }
    }

    /// Reads the current state and offers it to the UI, without touching any
    /// registration. For the caller that has just written a level itself.
    func refresh() {
        queue.async { [self] in
            guard isWatching, let device = boundDevice ?? hardware.defaultOutputDevice() else { return }
            publish(hardware.readout(for: device))
        }
    }

    /// Puts back whatever is missing: the system listener, or listeners for
    /// properties the device has but this binding does not cover.
    ///
    /// Bounded per device. An unchanged device ID is not proof a binding is
    /// sound, so a repair is allowed — but a binding the hardware keeps
    /// refusing gets a fixed number of tries and is then left alone, rather
    /// than retried on every start and every notification forever.
    private func repairIfNeeded() {
        guard isWatching else { return }

        if systemListener == nil {
            guard repairAttempts < Self.maximumRepairAttempts else { return }
            repairAttempts += 1
            installSystemListener()
        }

        guard let device = boundDevice, !missingAddresses(for: device).isEmpty else { return }
        guard repairAttempts < Self.maximumRepairAttempts else { return }
        guard ListenerQuarantine.shared.acceptsReplacements else {
            Self.log.error("not replacing volume listeners: earlier removals are stuck")
            return
        }
        repairAttempts += 1
        addListeners(for: device, addresses: missingAddresses(for: device))
    }

    /// Test and diagnostic seams. They wait on the queue, so they belong in
    /// tests and in nothing the interface is waiting for.
    func registrationCount() -> Int {
        queue.sync { deviceListeners.count + (systemListener == nil ? 0 : 1) }
    }

    func boundDeviceForTesting() -> AudioObjectID? {
        queue.sync { boundDevice }
    }

    /// Waits for everything already queued to finish. Tests use it instead of
    /// sleeping.
    func settleForTesting() {
        queue.sync {}
    }

    // MARK: - The system listener

    /// Installed once per watching session and kept through every device
    /// change: it is what reports the device changing, so removing it in order
    /// to answer its own notification — which is what the app used to do — is
    /// upside down, and with removal silently failing it also leaked.
    private func installSystemListener() {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let session = generation
        systemListener = hardware.listen(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            queue: queue
        ) { [weak self] in
            self?.noteDefaultDeviceChanged(session: session)
        }
        if systemListener == nil {
            // Left missing, nothing would ever notice a device change again.
            // `repairIfNeeded` is what puts it back, within its budget.
            Self.log.error("could not watch the default output device")
        }
    }

    /// The callback. Deliberately does almost nothing: sets a flag and makes
    /// sure a pass is scheduled. No task per notification, no work inline.
    private func noteDefaultDeviceChanged(session: Int) {
        // Already on `queue` — this is the queue the listener was registered
        // with — so the state below is safe to touch directly.
        guard isWatching, session == generation else { return }
        dirty = true
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        let session = generation
        queue.asyncAfter(deadline: .now() + Self.coalesceInterval) { [self] in
            reconcilePending = false
            guard isWatching, session == generation else { return }
            // Cleared *before* the pass: a notification arriving during it sets
            // the flag again and earns another pass, so a sustained stream
            // cannot starve one.
            dirty = false
            bind(to: hardware.defaultOutputDevice())
        }
    }

    /// Long enough to swallow the several notifications one plug produces,
    /// short enough that nobody waits for it.
    private static let coalesceInterval: TimeInterval = 0.033

    // MARK: - Binding to a device

    /// Points the per-device listeners at `device`.
    ///
    /// Does nothing when the device is the one already bound and that binding
    /// is sound. That is the common case by a wide margin: CoreAudio fires the
    /// default-device property for more than a change of destination.
    private func bind(to device: AudioObjectID?) {
        guard isWatching else { return }

        if device == boundDevice {
            // Same device. Repair anything missing — bounded — and take a
            // reading, but do not touch a healthy registration.
            repairIfNeeded()
            if let device { publish(hardware.readout(for: device)) }
            return
        }

        // A genuine switch. Only the device listeners go.
        deviceListeners.removeAll()
        boundDevice = device
        repairAttempts = 0

        guard let device else {
            // No output at all. The system listener stays, and it is what
            // notices one coming back.
            Self.log.notice("no default output device to watch")
            return
        }

        addListeners(for: device, addresses: Self.watchedAddresses)
        Self.log.debug("watching \(self.deviceListeners.count) volume properties")
        publish(hardware.readout(for: device))
    }

    /// Mute, and the volume scalar for the main element and two channels: a
    /// device that answers only per channel would otherwise change without ever
    /// notifying.
    private static let watchedAddresses: [AudioObjectPropertyAddress] = {
        var addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
        ]
        for element in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            addresses.append(AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            ))
        }
        return addresses
    }()

    /// Addresses the device has that this binding is not listening to.
    private func missingAddresses(for device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        Self.watchedAddresses.filter { address in
            deviceListeners[AddressKey(address)] == nil && hardware.hasProperty(device, address)
        }
    }

    private func addListeners(for device: AudioObjectID, addresses: [AudioObjectPropertyAddress]) {
        let session = generation
        for address in addresses {
            guard hardware.hasProperty(device, address) else { continue }
            let listener = hardware.listen(object: device, address: address, queue: queue) { [weak self] in
                self?.noteLevelChanged(session: session)
            }
            if let listener { deviceListeners[AddressKey(address)] = listener }
        }
    }

    /// A level notification. Sets a flag and makes sure one read is scheduled;
    /// it does not read the hardware itself. One volume step arrives as several
    /// notifications — one per registered element — and reading per callback
    /// meant three trips to the hardware for every step.
    private func noteLevelChanged(session: Int) {
        guard isWatching, session == generation, boundDevice != nil else { return }
        levelDirty = true
        scheduleLevelRead(session: session)
    }

    private func scheduleLevelRead(session: Int) {
        guard !levelReadPending, !settlePending else { return }

        // macOS ramps a volume change rather than stepping it, so one write of
        // our own comes back as a stream of intermediate values. We already
        // know where it is going — we sent it there and drew it — so the ramp
        // is redraw with nothing to say. Wait it out and take one reading at
        // the end, which is also what catches a device clamping the value we
        // asked for.
        let remaining = VolumeController.selfWriteRemaining()
        if remaining > 0 {
            settlePending = true
            queue.asyncAfter(deadline: .now() + remaining) { [self] in
                settlePending = false
                guard isWatching, session == generation else { return }
                readLevelIfDirty(session: session)
            }
            return
        }

        levelReadPending = true
        queue.asyncAfter(deadline: .now() + Self.coalesceInterval) { [self] in
            levelReadPending = false
            guard isWatching, session == generation else { return }
            readLevelIfDirty(session: session)
        }
    }

    private func readLevelIfDirty(session: Int) {
        guard levelDirty, let device = boundDevice else { return }
        levelDirty = false
        publish(hardware.readout(for: device))
        // A notification that arrived during the read earns another pass.
        if levelDirty { scheduleLevelRead(session: session) }
    }

    // MARK: - Getting a readout to the main actor

    /// Puts a reading in the mailbox and makes sure exactly one delivery is on
    /// its way. A reading identical to the last one delivered is dropped.
    private func publish(_ readout: HUDReadout?) {
        guard let readout else { return }
        mailbox.post(readout, generation: generation)
    }
}
