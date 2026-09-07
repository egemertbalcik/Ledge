import Foundation
import LedgeCore
import LedgeSystem
import os

/// Turns current conditions into a standing, ambient card.
///
/// Weather is the one deliberate exception to "transitions, not state": there
/// is no event to react to, and weather is a widget you cycle to rather than
/// news. So this publishes a card at the *lowest* priority in the app — it sits at the
/// back of the queue, never peeks, and never gets in front of actual news.
@MainActor
public final class WeatherProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "weather")

    public let identifier = "weather"

    /// Conditions change on the hour scale; asking more often is discourteous
    /// to a free service and buys nothing.
    /// A quarter-hour, not the old half: "Updated 40m ago" on a glanceable
    /// card reads as neglect, and Open-Meteo's forecast endpoint is fine
    /// with 96 small requests a day.
    static let refreshInterval: TimeInterval = 15 * 60

    /// After a failure, retry sooner than the normal cadence — but not so soon
    /// that an outage becomes a retry storm.
    static let retryInterval: TimeInterval = 5 * 60

    private let source: any WeatherSource
    /// Hours shown in the forecast strip. Six fits the card's width without
    /// crowding, which is also roughly what the Weather app shows at a glance.
    static let forecastHours = 6

    private let city: () -> String
    /// Where you are. Consulted first: a forecast should follow you without
    /// being retyped in every new city.
    private let location: (any LocationProviding)?
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var pending: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var publishedID: ActivityID?

    /// Kept so a network failure degrades to slightly stale weather rather than
    /// a vanishing card. Weather from twenty minutes ago is still weather.
    private var lastGood: WeatherSnapshot?
    /// When `lastGood` was actually fetched, for honest freshness stamps.
    private var lastGoodAt: TimeInterval = 0

    public init(
        source: any WeatherSource,
        city: @escaping () -> String,
        location: (any LocationProviding)? = nil,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.city = city
        self.location = location
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            self.refresh()
        }
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        publishedID = nil
        lastGood = nil
        lastGoodAt = 0
    }

    /// Fetches now, but only when the reading is older than `maxAge` — the
    /// card-open hook calls this on every open, and opening twice in a minute
    /// must not mean two fetches.
    public func refreshIfStale(olderThan maxAge: TimeInterval) {
        guard now() - lastGoodAt >= maxAge else { return }
        refresh()
    }

    /// Re-reads the city and fetches now. Called by the shell when the city
    /// preference changes, so a retyped city takes effect immediately.
    public func refresh() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }

            let snapshot = await self.fetch()
            guard !Task.isCancelled else { return }

            if let snapshot {
                self.lastGood = snapshot
                self.lastGoodAt = self.now()
                self.publish(snapshot, fetchedAt: self.lastGoodAt)
                // Refresh at the half-hour cadence — but never coast across an
                // hour boundary, where the strip's "Now" cell and its leading
                // hour go quietly wrong until the next fetch.
                self.schedule(after: min(Self.refreshInterval, Self.untilNextHour() + 5))
            } else if let stale = self.lastGood {
                // Keep showing what we had; try again sooner. The original
                // fetch time rides along — restamping it fresh would hide
                // exactly the staleness the card's "Updated Xm ago" exists
                // to admit. The rain warning is relative to the fetch, so it
                // ages with it: "rain in ~30m" forty minutes later is wrong,
                // and past its own horizon it drops rather than lying.
                var aged = stale
                if let rain = aged.rainSoonMinutes {
                    let elapsedMinutes = Int((self.now() - self.lastGoodAt) / 60)
                    let remaining = rain - elapsedMinutes
                    aged.rainSoonMinutes = remaining > 0 ? remaining : nil
                }
                self.publish(aged, fetchedAt: self.lastGoodAt)
                self.schedule(after: Self.retryInterval)
            } else {
                Self.log.notice("no weather available for the configured city")
                self.retractIfPublished()
                self.schedule(after: Self.retryInterval)
            }
        }
    }

    /// Location first, typed city second.
    ///
    /// A location fix means the card follows the user to a new city on its own;
    /// the typed city stays as the fallback for a machine that will not give up
    /// a fix, or a user who would rather not grant it. When location supplies a
    /// fix but no place *name*, the typed city labels it — the coordinates are
    /// still the ones the forecast came from.
    /// Whether the last good reading came from a location fix rather than the
    /// typed city. Remembered alongside the snapshot, so a stale republish
    /// keeps making the same claim the reading itself made.
    private var lastGoodFromLocation = false

    private func fetch() async -> WeatherSnapshot? {
        let cityName = city().trimmingCharacters(in: .whitespacesAndNewlines)

        if let fix = await location?.current() {
            let label = fix.name.isEmpty ? cityName : fix.name
            if let snapshot = await source.current(
                latitude: fix.latitude, longitude: fix.longitude, name: label
            ) {
                lastGoodFromLocation = true
                return snapshot
            }
        }

        guard !cityName.isEmpty else { return nil }
        lastGoodFromLocation = false
        return await source.current(city: cityName)
    }

    /// Seconds until the top of the next hour.
    private static func untilNextHour(now: Date = Date()) -> TimeInterval {
        guard let interval = Calendar.current.dateInterval(of: .hour, for: now)
        else { return refreshInterval }
        return max(interval.end.timeIntervalSince(now), 60)
    }

    private func publish(_ snapshot: WeatherSnapshot, fetchedAt: TimeInterval) {
        let glyph = WeatherGlyph.describe(code: snapshot.conditionCode, isDay: snapshot.isDay)
        let calendar = Calendar.current
        let hourStart = calendar.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let currentHour = calendar.component(.hour, from: Date())
        // A stale snapshot republished an hour later still leads with the hour
        // it was fetched in; hours already over are dropped so the strip never
        // opens on the past.
        let hourly = snapshot.hourly
            .filter { $0.date >= hourStart }
            .prefix(Self.forecastHours)
            .map { hour in
            let hourOfDay = calendar.component(.hour, from: hour.date)
            return WeatherHourPayload(
                hour: hourOfDay,
                temperatureCelsius: hour.temperatureCelsius,
                symbolName: WeatherGlyph.describe(
                    code: hour.conditionCode, isDay: hour.isDay
                ).symbol,
                isNow: hourOfDay == currentHour
            )
        }
        let id = ActivityID(kind: .weather, source: "current")
        publishedID = id

        continuation?.yield(.publish(Activity(
            id: id,
            createdAt: now(),
            // Standing by design; replaced on each refresh, retracted when the
            // city is cleared or the provider is disabled.
            payload: .weather(WeatherPayload(
                temperatureCelsius: snapshot.temperatureCelsius,
                symbolName: glyph.symbol,
                condition: glyph.name,
                city: snapshot.city,
                isDay: snapshot.isDay,
                highCelsius: snapshot.highCelsius,
                lowCelsius: snapshot.lowCelsius,
                hourly: Array(hourly),
                fetchedAt: fetchedAt,
                rainSoonMinutes: snapshot.rainSoonMinutes,
                usesDeviceLocation: lastGoodFromLocation
            ))
        )))
    }

    private func retractIfPublished() {
        guard let publishedID else { return }
        continuation?.yield(.retract(publishedID))
        self.publishedID = nil
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
