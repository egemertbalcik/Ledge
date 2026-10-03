import Foundation
import LedgeCore
import LedgeSystem
import os

/// Shows battery alerts. The only thing that does.
///
/// The catalogue decides — one engine, one latch — and this publishes what it
/// decided. Splitting the two is what makes "exactly one alert decision and
/// delivery path" checkable rather than hopeful: nothing else in the app
/// constructs a low-battery card.
///
/// Pushed, not polled. The store hands alerts over the moment it makes them,
/// so there is no timer here and nothing to run while nothing is happening.
@MainActor
public final class DeviceAlertProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "devices")

    public let identifier = "devicealerts"

    /// How long an alert card stays up. The same as a connect card: long
    /// enough to read, short enough that it never holds the notch.
    static let lifetime: TimeInterval = 6

    private let store: DeviceCatalogueStore
    private let notifier: any AlertNotifying
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    public init(
        store: DeviceCatalogueStore,
        notifier: any AlertNotifying = SystemAlertNotifier(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.store = store
        self.notifier = notifier
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            let store = self.store
            let session = self.session
            // Minted here, before the subscription exists, and captured by
            // value. A rejected delivery must be able to name itself even
            // after `stop()` has cleared the provider's own state — reading it
            // from `self` at rejection time meant the rejection arrived
            // anonymous exactly when it mattered, and the store could hand the
            // alert back to the consumer that had just refused it.
            let token = UUID()
            self.subscription = token
            let deliver: @Sendable ([BatteryAlert]) -> Void = { [weak self] alerts in
                Task { @MainActor [weak self] in
                    guard let self, self.session == session else {
                        // Stopped between the store deciding this and us
                        // reaching the main actor. The store already counts it
                        // delivered, so dropping it here loses the alert
                        // outright — hand it back, naming ourselves so it is
                        // queued rather than offered straight back to us while
                        // our own unsubscribe is still in flight.
                        await store.requeueAlerts(alerts, from: token)
                        return
                    }
                    self.present(alerts)
                }
            }
            Task { @MainActor [weak self] in
                // Installing and taking the backlog is one step: doing them
                // separately let an alert arriving in between be delivered
                // twice.
                let (_, backlog) = await store.subscribeToAlerts(token: token, deliver)
                guard let self, self.session == session else {
                    // Stopped while we were subscribing. Undo it, and hand the
                    // backlog back — subscribing took it out of the store, so
                    // dropping it here lost those alerts outright.
                    await store.unsubscribeFromAlerts(token, returning: backlog)
                    return
                }
                self.present(backlog)
            }
        }
    }

    public func stop() {
        // Bumped first, so anything already in flight for this session is
        // disqualified before it can present.
        session &+= 1
        continuation?.finish()
        continuation = nil
        guard let token = subscription else { return }
        subscription = nil
        Task { [store] in await store.unsubscribeFromAlerts(token) }
    }

    /// Which run of this provider we are on. A delivery from an older one is
    /// dropped rather than shown after a stop.
    private var session = 0
    private var subscription: UUID?

    private func present(_ alerts: [BatteryAlert]) {
        for alert in alerts {
            if alert.delivery.contains(.notch) { publishCard(alert) }
            if alert.delivery.contains(.notification) {
                let title = AlertWording.title(alert)
                let body = AlertWording.body(alert)
                // Never requests authorisation. If the user has not opted in,
                // this is silently nothing rather than a prompt.
                Task { [notifier] in await notifier.deliver(title: title, body: body) }
            }
        }
    }

    private func publishCard(_ alert: BatteryAlert) {
        let suffix = alert.kind == .low ? "/low" : "/charged"
        continuation?.yield(.publish(Activity(
            id: ActivityID(kind: .device, source: alert.deviceID.value + suffix),
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: alert.deviceName,
                // The device's own glyph and tint, and every battery it
                // reports — not a generic headphones icon and one number,
                // which is what the shipped AirPods card would have lost.
                symbolName: alert.symbolName,
                batteryLevels: alert.allLevels.isEmpty
                    ? [alert.component.label: alert.level]
                    : alert.allLevels,
                isConnected: true,
                isApple: alert.isApple,
                statusText: alert.kind == .charged ? "Charged" : nil
            ))
        )))
    }

}
