import Foundation
import Testing

@testable import LedgeCore

@Suite("Weather units")
struct WeatherUnitsTests {

    private let us = Locale(identifier: "en_US")
    private let uk = Locale(identifier: "en_GB")
    private let de = Locale(identifier: "de_DE")

    @Test("Explicit choices ignore the locale")
    func explicit() {
        #expect(WeatherUnits.celsius.displayDegrees(celsius: 20, locale: us) == 20)
        #expect(WeatherUnits.fahrenheit.displayDegrees(celsius: 20, locale: de) == 68)
        #expect(WeatherUnits.fahrenheit.displayDegrees(celsius: 0, locale: de) == 32)
        #expect(WeatherUnits.fahrenheit.displayDegrees(celsius: -40, locale: de) == -40)
    }

    @Test("Auto follows the locale's measurement system")
    func auto() {
        // The UK is on the metric side of this: miles on the road, but
        // Celsius on the forecast, and Foundation says so.
        #expect(WeatherUnits.auto.displayDegrees(celsius: 20, locale: us) == 68)
        #expect(WeatherUnits.auto.displayDegrees(celsius: 20, locale: uk) == 20)
        #expect(WeatherUnits.auto.displayDegrees(celsius: 20, locale: de) == 20)
    }

    @Test("Rounding is to the nearest whole degree, in the shown scale")
    func rounding() {
        // 21.4°C is 70.52°F: rounding after converting keeps the half-degree.
        #expect(WeatherUnits.celsius.displayDegrees(celsius: 21.4) == 21)
        #expect(WeatherUnits.fahrenheit.displayDegrees(celsius: 21.4) == 71)
        #expect(WeatherUnits.fahrenheit.displayDegrees(celsius: 37) == 99)
        #expect(WeatherUnits.celsius.displayDegrees(celsius: -0.4) == 0)
    }

    @Test("Absurd inputs never trap")
    func absurd() {
        #expect(WeatherUnits.celsius.displayDegrees(celsius: .nan) == 0)
        #expect(WeatherUnits.fahrenheit.displayDegrees(celsius: .infinity) == 0)
        #expect(WeatherUnits.celsius.displayDegrees(celsius: 1e308) == 999)
        #expect(WeatherUnits.celsius.displayDegrees(celsius: -1e308) == -999)
    }

    @Test("The stored string round-trips, and garbage means auto")
    func stored() {
        #expect(WeatherUnits(stored: "celsius") == .celsius)
        #expect(WeatherUnits(stored: "fahrenheit") == .fahrenheit)
        #expect(WeatherUnits(stored: "auto") == .auto)
        #expect(WeatherUnits(stored: "kelvin") == .auto)
        #expect(WeatherUnits(stored: "") == .auto)
        #expect(WeatherUnits.displayDegrees(celsius: 20, units: "fahrenheit", locale: de) == 68)
        #expect(WeatherUnits.displayDegrees(celsius: 20, units: "nonsense", locale: de) == 20)
        #expect(Prefs.weatherUnits.defaultValue == WeatherUnits.auto.rawValue)
    }
}
