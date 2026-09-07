import Foundation
import os

/// One hour of the forecast.
public struct WeatherHour: Equatable, Sendable {
    /// Start of the hour.
    public var date: Date
    public var temperatureCelsius: Double
    public var conditionCode: Int
    public var isDay: Bool

    public init(date: Date, temperatureCelsius: Double, conditionCode: Int, isDay: Bool) {
        self.date = date
        self.temperatureCelsius = temperatureCelsius
        self.conditionCode = conditionCode
        self.isDay = isDay
    }
}

/// Current conditions at one place, plus the hours just ahead.
public struct WeatherSnapshot: Equatable, Sendable {
    public var temperatureCelsius: Double
    /// WMO weather interpretation code, as reported by the service.
    public var conditionCode: Int
    public var isDay: Bool
    public var city: String
    /// Today's range, when the service reports it.
    public var highCelsius: Double?
    public var lowCelsius: Double?
    /// The next few hours, earliest first. Empty when unavailable — the card
    /// then shows current conditions alone rather than nothing.
    public var hourly: [WeatherHour]

    /// Minutes until rain starts, from the 15-minute forecast. Nil when dry
    /// for the window, already raining, or the service has no minutely data
    /// for the region.
    public var rainSoonMinutes: Int?

    public init(
        temperatureCelsius: Double,
        conditionCode: Int,
        isDay: Bool,
        city: String,
        highCelsius: Double? = nil,
        lowCelsius: Double? = nil,
        hourly: [WeatherHour] = [],
        rainSoonMinutes: Int? = nil
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.conditionCode = conditionCode
        self.isDay = isDay
        self.city = city
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.hourly = hourly
        self.rainSoonMinutes = rainSoonMinutes
    }
}

/// Where weather comes from.
@MainActor
public protocol WeatherSource: AnyObject {
    /// Conditions for a named city, or nil when the city cannot be resolved or
    /// the network is down. Failure is normal here and must stay quiet.
    func current(city: String) async -> WeatherSnapshot?
    /// Conditions at an exact place, skipping geocoding. Used when a location
    /// fix is available, which is the normal case.
    func current(latitude: Double, longitude: Double, name: String) async -> WeatherSnapshot?
}

/// Open-Meteo, chosen because it needs no key and no paid developer account —
/// WeatherKit requires both, which this project deliberately avoids.
@MainActor
public final class OpenMeteoWeatherSource: WeatherSource {

    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "weather")

    private let session: URLSession

    /// Geocoding results cached per city string: the city changes when the user
    /// retypes it, not between refreshes, and the lookup is a network round trip.
    private var geocodeCache: [String: (latitude: Double, longitude: Double, name: String)] = [:]

    /// Cities the geocoder could not resolve, so a persistently bad name is not
    /// looked up again on every refresh.
    /// City → when its geocode last failed. A *cooldown*, not a permanent
    /// latch: a transient geocoder degradation must not kill a valid typed
    /// city until relaunch. Half an hour matches the refresh cadence.
    private var geocodeFailures: [String: Date] = [:]
    private static let geocodeRetryAfter: TimeInterval = 30 * 60

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    public func current(city: String) async -> WeatherSnapshot? {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let place = await geocode(trimmed) else { return nil }
        return await current(
            latitude: place.latitude, longitude: place.longitude, name: place.name
        )
    }

    public func current(
        latitude: Double,
        longitude: Double,
        name: String
    ) async -> WeatherSnapshot? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            // A forecast is city-scale: two decimals (~1 km) is all the
            // service needs, and a full-precision fix is more of the user's
            // whereabouts than a weather query should carry.
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            // The next two hours of 15-minute precipitation, for the
            // rain-soon line. Regions without minutely data just omit it.
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "forecast_minutely_15", value: "8"),
            // Local wall-clock hours, so "3 PM" means three in the afternoon
            // where the user is rather than in UTC.
            URLQueryItem(name: "timezone", value: "auto"),
            // A day of hours is plenty for a card that shows six, and keeps the
            // response small.
            URLQueryItem(name: "forecast_days", value: "2"),
        ]
        guard let url = components?.url, let data = await fetch(url) else { return nil }

        // Defensive throughout: a service schema change must degrade to "no
        // weather card", never to a crash.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              temperature.isFinite
        else {
            Self.log.debug("weather response unparseable")
            return nil
        }

        let daily = root["daily"] as? [String: Any]
        return WeatherSnapshot(
            temperatureCelsius: temperature,
            conditionCode: current["weather_code"] as? Int ?? 0,
            isDay: (current["is_day"] as? Int ?? 1) == 1,
            city: name,
            highCelsius: (daily?["temperature_2m_max"] as? [Double])?.first,
            lowCelsius: (daily?["temperature_2m_min"] as? [Double])?.first,
            hourly: Self.parseHourly(
                root["hourly"] as? [String: Any],
                utcOffsetSeconds: root["utc_offset_seconds"] as? Int
            ),
            rainSoonMinutes: Self.parseRainSoon(root["minutely_15"] as? [String: Any])
        )
    }

    /// Minutes until the first wet 15-minute interval — nil when the window is
    /// dry or it is already raining (an umbrella warning for rain you can see
    /// out the window is noise).
    nonisolated static func parseRainSoon(_ minutely: [String: Any]?) -> Int? {
        guard let minutely,
              let precipitation = minutely["precipitation"] as? [Double]
        else { return nil }
        // A trace under 0.1 mm per interval is mist, not rain.
        let wet = precipitation.prefix(8).map { $0.isFinite && $0 > 0.1 }
        guard wet.first == false, let index = wet.firstIndex(of: true) else { return nil }
        return index * 15
    }

    /// Open-Meteo returns hourly data as parallel arrays. Hours already past are
    /// dropped here rather than in the view, so the card never has to reason
    /// about the clock.
    nonisolated static func parseHourly(
        _ hourly: [String: Any]?,
        utcOffsetSeconds: Int? = nil
    ) -> [WeatherHour] {
        guard let hourly,
              let times = hourly["time"] as? [String],
              let temperatures = hourly["temperature_2m"] as? [Double]
        else { return [] }

        let codes = hourly["weather_code"] as? [Int] ?? []
        let days = hourly["is_day"] as? [Int] ?? []

        // `timezone=auto` means these are wall-clock stamps in the *queried
        // location's* timezone, which the response names via
        // `utc_offset_seconds`. Parsing them with the Mac's timezone shifted
        // every hour — and the past-hour cutoff — by the full offset whenever
        // the configured city was not where the machine is.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // From the top of the current hour, so the hour you are *in* is
        // included. `date(bySetting: .minute, value: 0)` searches *forward* —
        // at 14:37 it answers 15:00 — which silently dropped the current hour
        // and left the strip with no "Now" cell except in the minute it was
        // fetched at :00 exactly.
        let start = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let cutoff = start.addingTimeInterval(-1)

        var result: [WeatherHour] = []
        for (index, stamp) in times.enumerated() where index < temperatures.count {
            guard let date = formatter.date(from: stamp), date > cutoff else { continue }
            result.append(WeatherHour(
                date: date,
                temperatureCelsius: temperatures[index],
                conditionCode: index < codes.count ? codes[index] : 0,
                isDay: index < days.count ? days[index] == 1 : true
            ))
        }
        return result
    }

    private func geocode(_ city: String) async -> (latitude: Double, longitude: Double, name: String)? {
        if let cached = geocodeCache[city] { return cached }
        if let failedAt = geocodeFailures[city] {
            guard Date().timeIntervalSince(failedAt) > Self.geocodeRetryAfter else { return nil }
            geocodeFailures[city] = nil
        }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
        ]
        guard let url = components?.url, let data = await fetch(url) else { return nil }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let latitude = first["latitude"] as? Double,
              let longitude = first["longitude"] as? Double,
              latitude.isFinite, longitude.isFinite
        else {
            Self.log.notice("could not geocode \(city, privacy: .private(mask: .hash))")
            geocodeFailures[city] = Date()
            return nil
        }

        let resolved = (
            latitude: latitude,
            longitude: longitude,
            name: first["name"] as? String ?? city
        )
        geocodeCache[city] = resolved
        return resolved
    }

    private func fetch(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            return data
        } catch {
            Self.log.debug("weather fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Maps WMO condition codes to a symbol and a name.
///
/// Nonisolated and pure so it is testable; grouped by the code ranges the WMO
/// interpretation table defines.
public enum WeatherGlyph {

    public nonisolated static func describe(code: Int, isDay: Bool) -> (symbol: String, name: String) {
        switch code {
        case 0:
            return (isDay ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2:
            return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3:
            return ("cloud.fill", "Overcast")
        case 45, 48:
            return ("cloud.fog.fill", "Fog")
        case 51...57:
            return ("cloud.drizzle.fill", "Drizzle")
        case 61...67, 80...82:
            return ("cloud.rain.fill", "Rain")
        case 71...77, 85, 86:
            return ("cloud.snow.fill", "Snow")
        case 95...99:
            return ("cloud.bolt.rain.fill", "Thunderstorm")
        default:
            return ("cloud.fill", "Cloudy")
        }
    }
}

/// Fixed conditions, for tests.
@MainActor
public final class StubWeatherSource: WeatherSource {

    public var value: WeatherSnapshot?
    public private(set) var requestedCities: [String] = []

    public init(value: WeatherSnapshot? = nil) {
        self.value = value
    }

    public func current(city: String) async -> WeatherSnapshot? {
        requestedCities.append(city)
        return value
    }

    public private(set) var requestedCoordinates: [(latitude: Double, longitude: Double)] = []

    public func current(
        latitude: Double,
        longitude: Double,
        name: String
    ) async -> WeatherSnapshot? {
        requestedCoordinates.append((latitude, longitude))
        return value
    }
}
