import LedgeCore
import SwiftUI

/// The stored `Prefs.weatherUnits` value, threaded down from the overlay.
///
/// An environment value rather than an initializer argument: three unrelated
/// views draw a temperature (the weather card, the compact ear, the generic
/// row) and every intermediate initializer would otherwise have to carry a
/// unit it does not care about. Defaults to the preference's own default so
/// previews and tests need no setup.
private struct WeatherUnitsKey: EnvironmentKey {
    static let defaultValue: String = Prefs.weatherUnits.defaultValue
}

extension EnvironmentValues {
    var weatherUnits: String {
        get { self[WeatherUnitsKey.self] }
        set { self[WeatherUnitsKey.self] = newValue }
    }
}
