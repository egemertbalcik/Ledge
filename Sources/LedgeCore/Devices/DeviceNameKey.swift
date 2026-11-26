import Foundation

/// A device name in the one form every comparison uses.
///
/// The audio system, Bluetooth and the notch each compared names their own
/// way: one folded macOS's curly apostrophe and the others did not, so the
/// same earbuds were one device in one place and two in another.
public enum DeviceNameKey {

    /// Case, surrounding space and the curly apostrophe do not make a
    /// different device.
    public static func of(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
}
