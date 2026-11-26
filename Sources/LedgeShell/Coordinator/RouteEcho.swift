import Foundation

/// The device that last said hello, held for the one sound output change
/// that is its echo.
///
/// Sound moving to earbuds that have just connected is the same news told
/// twice. Only that: the first route heard after the hello settles it either
/// way. It is swallowed if it names the same device in time. If it names
/// another, sound has gone elsewhere. A later return to the first device is
/// then a choice somebody made. It used to be swallowed too, so the notch
/// went on saying the wrong output.
struct RouteEcho {

    private var armed: (name: String, at: TimeInterval)?

    mutating func arm(_ name: String, at moment: TimeInterval) {
        armed = (name, moment)
    }

    /// Whether this route is the echo. Whatever the answer, nothing is left
    /// armed afterwards.
    mutating func swallows(route name: String, at moment: TimeInterval) -> Bool {
        guard let armed else { return false }
        self.armed = nil
        return LedgeCoordinator.routeEchoes(route: name, connected: armed.name, elapsed: moment - armed.at)
    }
}
