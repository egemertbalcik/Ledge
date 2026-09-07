import Foundation
import Testing

@testable import LedgeCore
@testable import LedgeUI

@Suite("Weather formatting")
struct WeatherFormattingTests {

    @Test("Temperatures round to whole degrees")
    func degrees() {
        #expect(WeatherCardView.degrees(21.4, units: "celsius") == "21")
        #expect(WeatherCardView.degrees(21.6, units: "celsius") == "22")
        #expect(WeatherCardView.degrees(-3.2, units: "celsius") == "-3")
    }

    @Test("A temperature just below zero never renders as -0")
    func noNegativeZero() {
        // `Int(-0.4.rounded())` is `-0`, which prints with the sign. "-0°" is
        // the kind of detail that makes a card look broken.
        #expect(WeatherCardView.degrees(-0.4, units: "celsius") == "0")
    }

    @Test("The card converts to Fahrenheit when asked, and follows the locale on auto")
    func fahrenheit() {
        #expect(WeatherCardView.degrees(20, units: "fahrenheit") == "68")
        #expect(WeatherCardView.degrees(20, units: "auto", locale: Locale(identifier: "en_US")) == "68")
        #expect(WeatherCardView.degrees(20, units: "auto", locale: Locale(identifier: "en_GB")) == "20")
        #expect(WeatherCardView.range(high: 22, low: 14, units: "fahrenheit") == "H:72°  L:57°")
    }

    @Test("Hour labels follow the locale's clock")
    func hourLabels() {
        let us = Locale(identifier: "en_US")       // 12-hour
        let uk = Locale(identifier: "en_GB")       // 24-hour
        #expect(WeatherCardView.hourLabel(15, locale: us) == "3 PM")
        #expect(WeatherCardView.hourLabel(0, locale: us) == "12 AM")
        #expect(WeatherCardView.hourLabel(12, locale: us) == "12 PM")
        #expect(WeatherCardView.hourLabel(15, locale: uk) == "15")
        #expect(WeatherCardView.hourLabel(0, locale: uk) == "0")
    }

    @Test("The range line omits whatever the service did not send")
    func range() {
        #expect(WeatherCardView.range(high: 22, low: 14, units: "celsius") == "H:22°  L:14°")
        #expect(WeatherCardView.range(high: 22, low: nil, units: "celsius") == "H:22°")
        #expect(WeatherCardView.range(high: nil, low: 14, units: "celsius") == "L:14°")
        #expect(WeatherCardView.range(high: nil, low: nil, units: "celsius") == nil)
    }

    @Test("The ear drops the countdown's \"in \" prefix; the card keeps it")
    func earCountdown() {
        #expect(CompactEarsView.earCountdown(15 * 60) == "15m")
        #expect(CompactEarsView.earCountdown(2 * 3600 + 30 * 60) == "2h 30m")
        #expect(CompactEarsView.earCountdown(0) == "now")
        #expect(ActivityCardView.relative(15 * 60) == "in 15m")
    }
}
