import Foundation

public extension Notification.Name {

    /// A Bluetooth device was just heard connecting. Posted the moment the
    /// provider hears it, which can be a second or two before its hello is
    /// told: the hello may wait for battery levels.
    ///
    /// The shell uses it to know that macOS's own banner for the same device
    /// is on its way.
    static let ledgeDeviceConnectHeard = Notification.Name("com.egemert.ledge.deviceConnectHeard")

    /// The sound output was just heard changing device.
    static let ledgeSoundOutputHeard = Notification.Name("com.egemert.ledge.soundOutputHeard")
}
