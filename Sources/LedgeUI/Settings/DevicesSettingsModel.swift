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

    /// Which kinds of source were reporting when the catalogue was last read.
    /// The detail pane asks this the same way the list does.
    public private(set) var liveSources: Set<DeviceIdentity.Source> = []

    /// Whether the provider behind this device is running.
    public func sourceIsLive(_ id: DeviceIdentity) -> Bool {
        liveSources.contains(id.source)
    }

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

    /// The pane's row order. Pure and total, so two refreshes of the same
    /// devices produce the same list.
    static func rowOrder(_ a: Row, _ b: Row) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        let aHere = a.presence == .connected
        let bHere = b.presence == .connected
        if aHere != bHere { return aHere }
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        // Two devices with the same name — two sets of the same earbuds —
        // still need a settled order.
        return a.id.value < b.id.value
    }

    private func apply(_ catalogue: DeviceCatalogue) {
        let at = now()
        liveSources = catalogue.liveSources
        rows = catalogue.devices
            .filter { !$0.isHidden }
            .map { record -> Row in
                // Whether the provider behind this device is running. Only a
                // source that reports on change — this Mac's battery — is
                // judged by it; everything else goes by elapsed time.
                let live = catalogue.sourceIsLive(record.id)
                let shown = record.displayedLowestInUse(now: at, sourceIsLive: live)
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
                    isStale: shown.isHistorical || record.isStale(now: at, sourceIsLive: live),
                    lastSeen: record.lastSeen,
                    isPinned: record.isPinned
                )
            }
            // Pinned first, then the devices that are here, then by name.
            //
            // Deliberately *not* by when each was last heard from: the pane
            // re-reads every five seconds, and sorting on a timestamp that
            // moves meant rows swapped places under the pointer — a list
            // nobody can click in. Name is stable between refreshes, and the
            // "last seen" line still says what it says.
            .sorted(by: Self.rowOrder)
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
    ///
    /// Concurrent askers share one request. Ticking the box, previewing, and
    /// ticking a second rule's box used to be three prompts queued behind each
    /// other — the system shows one and silently denies the rest, which reads
    /// as permission being refused.
    public func requestNotificationAuthorization() async -> Bool {
        let revision = notificationRevision
        if let existing = authorizationWork {
            // Join the request in flight. Waiters never clear it: only the
            // asker that created it does, and only if it is still the one
            // registered — an older waiter clearing a newer request left the
            // next caller starting a second system prompt behind the first.
            let granted = await existing.task.value
            return revision == notificationRevision && granted
        }
        let actions = actions
        authorizationToken &+= 1
        let token = authorizationToken
        let work = Task<Bool, Never> { await actions.requestNotificationAuthorization() }
        authorizationWork = (token, work)
        let granted = await work.value
        if authorizationWork?.token == token { authorizationWork = nil }
        guard revision == notificationRevision else { return false }
        return granted
    }

    /// The one outstanding permission request, so several askers cannot queue
    /// prompts behind each other — tagged, so only its owner may retire it.
    private var authorizationWork: (token: Int, task: Task<Bool, Never>)?
    private var authorizationToken = 0

    /// Whether a permission request is in flight. A test seam.
    var hasAuthorizationRequestInFlight: Bool { authorizationWork != nil }

    /// Turns notification delivery on for one rule, by its id.
    ///
    /// By id, and applied to the configuration as it is *now*, because the
    /// system prompt is modal to nothing: the user can edit the threshold, the
    /// component, or the enabled switch while it is up. Writing back a rule
    /// captured before the prompt discarded every one of those edits.
    public func enableNotificationDelivery(ruleID: UUID, for id: DeviceIdentity) {
        guard var configuration = currentAlerts(for: id) else { return }
        guard let index = configuration.rules.firstIndex(where: { $0.id == ruleID }) else { return }
        guard !configuration.rules[index].delivery.contains(.notification) else { return }
        configuration.rules[index].delivery.insert(.notification)
        configuration.isCustomised = true
        setAlerts(configuration, for: id)
    }

    /// The configuration a rule edit should be applied on top of: what has
    /// been queued but not yet written, else what the selection holds.
    private func currentAlerts(for id: DeviceIdentity) -> DeviceAlertConfiguration? {
        if let pending = pendingAlertWrites[id] { return pending }
        guard let selected, selected.id == id else { return nil }
        return selected.alerts.isCustomised
            ? selected.alerts
            : DeviceAlertConfiguration(rules: [.defaultLow()], isCustomised: false)
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
