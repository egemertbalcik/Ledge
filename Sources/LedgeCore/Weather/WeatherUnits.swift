import Foundation

/// The temperature scale the cards draw in.
///
/// Payloads stay Celsius end to end — Open-Meteo hands it over that way and
/// every fixture is written that way — so this is a display decision made
/// once, at the moment a number is turned into text. Stored as the raw string
/// in `Prefs.weatherUnits`; anything unrecognised there falls back to `auto`.
public enum WeatherUnits: String, CaseIterable, Sendable {
    /// Follow the locale: Fahrenheit for a US measurement system, Celsius
    /// everywhere else.
    case auto
    case celsius
    case fahrenheit

    public init(stored: String) {
        self = WeatherUnits(rawValue: stored) ?? .auto
    }

    /// Whether this choice means Fahrenheit, resolving `auto` against the
    /// locale's measurement system.
    public func usesFahrenheit(locale: Locale = .current) -> Bool {
        switch self {
        case .celsius: false
        case .fahrenheit: true
        case .auto: locale.measurementSystem == .us
        }
    }

    /// The whole-degree number to draw for a Celsius reading, in this scale.
    ///
    /// Rounded and clamped before `Int()`: finite is not enough, since 1e308 is
    /// finite and still traps the conversion, and no terrestrial temperature
    /// leaves the range either way.
    public func displayDegrees(celsius: Double, locale: Locale = .current) -> Int {
        let value = usesFahrenheit(locale: locale) ? celsius * 9 / 5 + 32 : celsius
        let rounded = value.isFinite ? value.rounded() : 0
        let sane = min(max(rounded, -999), 999)
        return Int(sane == 0 ? 0 : sane)
    }

    /// The same, from the stored preference string.
    public static func displayDegrees(
        celsius: Double,
        units: String,
        locale: Locale = .current
    ) -> Int {
        WeatherUnits(stored: units).displayDegrees(celsius: celsius, locale: locale)
    }
}
