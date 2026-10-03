import Foundation
import LedgeCore
import Observation

/// What the Devices pane needs, and nothing it does not.
///
/// The catalogue itself is an actor in LedgeSystem, which this layer may not
/// import. So the pane talks to this, and the shell hands it closures that
/// reach the store. That keeps the reading and writing of a file off the main
/// actor while the view stays a plain observer of values.
@MainActor
@Observable
public final class DevicesSettingsModel {

    /// One row, already reduced to what is drawn.
    public struct Row: Identifiable, Hashable, Sendable {
        public var id: DeviceIdentity
        public var name: String
        public var symbolName: String
        public var isApple: Bool
        public var presence: DevicePresence
        public var lowestLevel: Double?
        /// Whether the level shown describes now, or the last time we heard.
        public var isStale: Bool
        public var lastSeen: Date
        public var isPinned: Bool

        public init(
            id: DeviceIdentity, name: String, symbolName: String, isApple: Bool,
            presence: DevicePresence, lowestLevel: Double?, isStale: Bool,
            lastSeen: Date, isPinned: Bool
        ) {
            self.id = id
            self.name = name
            self.symbolName = symbolName
            self.isApple = isApple
            self.presence = presence
            self.lowestLevel = lowestLevel
            self.isStale = isStale
            self.lastSeen = lastSeen
            self.isPinned = isPinned
        }
    }

    public private(set) var rows: [Row] = []
    public private(set) var selected: DeviceRecord?
    public private(set) var history: [BatterySample] = []
    public private(set) var isLoading = false
    /// True once a load has completed, so an empty list can be told from one
    /// that has not arrived — "no devices yet" and "not looked" read alike
    /// otherwise.
    public private(set) var hasLoaded = false

    /// Everything that touches the store. Injected, so the pane can be driven
    /// from fake data in a test or a preview without a store existing.
    public struct Actions: Sendable {
        public var load: @Sendable () async -> DeviceCatalogue
        public var history: @Sendable (DeviceIdentity) async -> [BatterySample]
        public var setPinned: @Sendable (DeviceIdentity, Bool) async -> Void
        public var setHidden: @Sendable (DeviceIdentity, Bool) async -> Void
        public var setAlerts: @Sendable (DeviceIdentity, DeviceAlertConfiguration) async -> Void
        /// Removes the record, and clears the mailbox's memory of the device
        /// so a later sighting is reported at once rather than waiting out the
        /// coalescing heartbeat.
        public var forget: @Sendable (DeviceIdentity, Bool) async -> Void
        public var deleteAllHistory: @Sendable () async -> Void
        public var requestNotificationAuthorization: @Sendable () async -> Bool
        public var preview: @Sendable (BatteryAlertRule, String) -> Void

        public init(
            load: @escaping @Sendable () async -> DeviceCatalogue,
            history: @escaping @Sendable (DeviceIdentity) async -> [BatterySample] = { _ in [] },
            setPinned: @escaping @Sendable (DeviceIdentity, Bool) async -> Void = { _, _ in },
            setHidden: @escaping @Sendable (DeviceIdentity, Bool) async -> Void = { _, _ in },
            setAlerts: @escaping @Sendable (DeviceIdentity, DeviceAlertConfiguration) async -> Void = { _, _ in },
            forget: @escaping @Sendable (DeviceIdentity, Bool) async -> Void = { _, _ in },
            deleteAllHistory: @escaping @Sendable () async -> Void = {},
            requestNotificationAuthorization: @escaping @Sendable () async -> Bool = { false },
            preview: @escaping @Sendable (BatteryAlertRule, String) -> Void = { _, _ in }
        ) {
            self.load = load
            self.history = history
            self.setPinned = setPinned
            self.setHidden = setHidden
            self.setAlerts = setAlerts
            self.forget = forget
            self.deleteAllHistory = deleteAllHistory
            self.requestNotificationAuthorization = requestNotificationAuthorization
            self.preview = preview
        }
    }

    private let actions: Actions
    private let now: @MainActor () -> Date

    /// The list's own read. Cancelled by another list read or by closing.
    private var listWork: Task<Void, Never>?

    /// The detail view's read, kept apart from the list's.
    ///
    /// They shared one handle, so the five-second refresh cancelled a
    /// selection that was still loading its history — the click did nothing
    /// and looked broken.
    private var detailWork: Task<Void, Never>?

    /// Which selection a detail read belongs to. A history read that finishes
    /// after the user has moved on is dropped rather than applied to whatever
    /// is now open.
    private var selectionToken = 0

    /// Writes: serialised, coalesced by device, and **not** cancelled when the
    /// pane closes.
    ///
    /// Dragging a threshold slider produces a mutation per frame. Cancelling
    /// the previous task did not stop its write — cancellation was only
    /// checked after the store call had already happened — so an older value
    /// could land after a newer one and become what was saved. Now the latest
    /// configuration per device is what gets written, once, in order.
    private var writeWork: Task<Void, Never>?
    private var pendingAlertWrites: [DeviceIdentity: DeviceAlertConfiguration] = [:]

    /// Bumped whenever notification delivery is switched off. An outstanding
    /// permission request from before that must not switch it back on.
    private var notificationRevision = 0

    public init(actions: Actions, now: @escaping @MainActor () -> Date = { Date() }) {
        self.actions = actions
        self.now = now
    }

    /// How often an open pane re-reads the catalogue.
    ///
    /// The pane used to load once on appearance and then only after a local
    /// edit, so a device connecting, a level changing or a reading going stale
    /// while Settings sat open showed nothing until it was closed and
    /// reopened. Slow on purpose: this is a settings window, and the catalogue
    /// only changes when something was observed anyway.
    public static let refreshInterval: TimeInterval = 5

    private var refresh: Task<Void, Never>?

    /// Loads, then keeps the pane current for as long as it is open.
    public func beginWatching() {
        load()
        refresh?.cancel()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DevicesSettingsModel.refreshInterval))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    // Quietly: no spinner, and the selection is preserved.
                    self.load(showingProgress: false)
                }
            }
        }
    }

    /// Stops refreshing and cancels any read. Writes are left to finish.
    public func endWatching() {
        refresh?.cancel()
        refresh = nil
        cancel()
    }

    public func load(showingProgress: Bool = true) {
        listWork?.cancel()
        if showingProgress { isLoading = true }
        listWork = Task { [weak self, actions] in
            let catalogue = await actions.load()
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.apply(catalogue) }
        }
    }

    /// Called when the pane goes away.
    ///
    /// Reads are cancelled — nobody is waiting for them. Writes are *not*: a
    /// rule the user just changed must still reach the disk even though they
    /// closed the window a moment later.
    public func cancel() {
        listWork?.cancel()
        listWork = nil
        detailWork?.cancel()
        detailWork = nil
    }

    private func apply(_ catalogue: DeviceCatalogue) {
        let at = now()
        rows = catalogue.devices
            .filter { !$0.isHidden }
            .map { record -> Row in
                let shown = record.displayedLowestInUse(now: at)
                return Row(
                    id: record.id,
                    name: record.name,
                    symbolName: record.symbolName,
                    isApple: record.isApple,
                    presence: record.presence,
                    lowestLevel: shown.level,
                    // Whether the *level shown* is historical — which a
                    // disconnect makes true at once, and which the record's
                    // own freshness alone could not express.
                    isStale: shown.isHistorical || record.isStale(now: at),
                    lastSeen: record.lastSeen,
                    isPinned: record.isPinned
                )
            }
            // Pinned first, then whatever we heard from most recently. A list
            // that reorders itself as devices come and go is a list nobody can
            // click in.
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.lastSeen > $1.lastSeen
            }
        isLoading = false
        hasLoaded = true
        if let selected, let fresh = catalogue.devices.first(where: { $0.id == selected.id }) {
            self.selected = fresh
            // The detail view's history is refreshed too, or an open device
            // would show a chart frozen at the moment it was opened. Tracked
            // and tokened like any other detail read: an untracked one could
            // finish out of order and overwrite a newer selection's history.
            let id = fresh.id
            let token = selectionToken
            let actions = actions
            detailWork?.cancel()
            detailWork = Task { [weak self] in
                let samples = await actions.history(id)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.selectionToken == token,
                          self.selected?.id == id
                    else { return }
                    self.history = samples
                }
            }
        }
    }

    /// Opens a device. History is fetched only now, and only for this one —
    /// the list never loads charts it is not showing.
    public func select(_ id: DeviceIdentity) {
        selectionToken &+= 1
        let token = selectionToken
        detailWork?.cancel()
        detailWork = Task { [weak self, actions] in
            let catalogue = await actions.load()
            let samples = await actions.history(id)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.selectionToken == token else { return }
                self.selected = catalogue.devices.first { $0.id == id }
                self.history = samples
            }
        }
    }

    public func clearSelection() {
        selectionToken &+= 1
        detailWork?.cancel()
        detailWork = nil
        selected = nil
        history = []
    }

    // MARK: - Edits

    public func setPinned(_ pinned: Bool, for id: DeviceIdentity) {
        let actions = actions
        mutate { await actions.setPinned(id, pinned) }
    }

    public func hide(_ id: DeviceIdentity) {
        let actions = actions
        mutate { await actions.setHidden(id, true) }
    }

    public func forget(_ id: DeviceIdentity, keepingHistory: Bool) {
        clearSelection()
        let actions = actions
        mutate { await actions.forget(id, keepingHistory) }
    }

    public func deleteAllHistory() {
        let actions = actions
        mutate { await actions.deleteAllHistory() }
    }

    /// Queues a rule change. The newest configuration per device wins, and
    /// they are written in order, one at a time.
    public func setAlerts(_ configuration: DeviceAlertConfiguration, for id: DeviceIdentity) {
        selected?.alerts = configuration
        pendingAlertWrites[id] = configuration
        drainAlertWrites()
    }

    private func drainAlertWrites() {
        guard writeWork == nil else { return }
        guard !pendingAlertWrites.isEmpty else { return }
        let actions = actions
        writeWork = Task { [weak self] in
            while true {
                let next: (DeviceIdentity, DeviceAlertConfiguration)? = await MainActor.run {
                    guard let self, let entry = self.pendingAlertWrites.first else { return nil }
                    self.pendingAlertWrites.removeValue(forKey: entry.key)
                    return (entry.key, entry.value)
                }
                guard let (id, configuration) = next else { break }
                await actions.setAlerts(id, configuration)
            }
            await MainActor.run {
                guard let self else { return }
                self.writeWork = nil
                // Anything queued while the last write was in flight.
                self.drainAlertWrites()
                self.resumeIfDrained()
            }
        }
    }

    /// Waits for every queued rule write to reach the store.
    ///
    /// Called on the way out. A rule the user changed a moment before quitting
    /// is still sitting in this model's mailbox, and no amount of flushing the
    /// store would find it there.
    public func drainPendingWrites() async {
        // Rule writes first, which are a chain.
        while !pendingAlertWrites.isEmpty || writeWork != nil {
            await writeWork?.value
            if writeWork == nil, pendingAlertWrites.isEmpty { break }
            await Task.yield()
        }
        // Then the durable edits — pin, hide, forget, delete history — which
        // run as one serial chain.
        guard !edits.isEmpty || editWork != nil else { return }
        await withCheckedContinuation { continuation in
            drainContinuations.append(continuation)
        }
    }

    /// Asks for notification permission. The only path that does.
    ///
    /// - Returns: whether it was granted *and* still wanted. A user who turns
    ///   the switch back off while the system prompt is up must not have it
    ///   turned on again when they answer.
    public func requestNotificationAuthorization() async -> Bool {
        let revision = notificationRevision
        let granted = await actions.requestNotificationAuthorization()
        guard revision == notificationRevision else { return false }
        return granted
    }

    /// Called when notification delivery is switched off, so any outstanding
    /// request is disowned.
    public func notificationDeliveryWasDisabled() {
        notificationRevision &+= 1
    }

    public func preview(_ rule: BatteryAlertRule, deviceName: String) {
        actions.preview(rule, deviceName)
    }

    /// Durable edits waiting to be applied, in the order they were made.
    ///
    /// One serial queue rather than a task each. Independent tasks reach the
    /// store in whatever order the runtime chooses, so pinning and then
    /// un-pinning quickly could persist the pin — the older choice landing
    /// last. Order is the whole correctness property here.
    private var edits: [@Sendable () async -> Void] = []
    private var editWork: Task<Void, Never>?
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    /// For the edits that are one-shot rather than continuous — pin, hide,
    /// forget. Not cancelled on close: the change must land.
    private func mutate(_ body: @escaping @Sendable () async -> Void) {
        edits.append(body)
        drainEdits()
    }

    private func drainEdits() {
        guard editWork == nil, !edits.isEmpty else { return }
        let actions = actions
        editWork = Task { [weak self] in
            while true {
                let next: (@Sendable () async -> Void)? = await MainActor.run {
                    guard let self, !self.edits.isEmpty else { return nil }
                    return self.edits.removeFirst()
                }
                guard let next else { break }
                await next()
            }
            let catalogue = await actions.load()
            await MainActor.run {
                guard let self else { return }
                self.apply(catalogue)
                self.editWork = nil
                // Anything queued while the last edit was in flight.
                self.drainEdits()
                self.resumeIfDrained()
            }
        }
    }

    private func resumeIfDrained() {
        guard edits.isEmpty, editWork == nil,
              pendingAlertWrites.isEmpty, writeWork == nil
        else { return }
        let waiting = drainContinuations
        drainContinuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
