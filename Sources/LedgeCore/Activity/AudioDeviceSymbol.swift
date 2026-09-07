import Foundation

/// The glyph for an audio device, chosen from its name.
///
/// macOS gives no icon for an output device, only a string, so the name is all
/// there is to go on. Kept in one place because three surfaces need the same
/// answer — the route list in the media card, the sound panel's rows, and the
/// peek that says where sound just went — and two of them had already drifted
/// into being separate copies of the same ladder.
/// Names that no SF Symbol answers to, drawn by the app instead.
///
/// A payload speaks in symbol names, so a glyph the system does not ship needs
/// a name of its own for the view to recognise. The prefix keeps it from ever
/// colliding with a real one.
public enum LedgeSymbol {
    /// The Bluetooth rune. Apple ships no symbol for it, and there is only
    /// one: the ear beside it carries On or Off, so the glyph does not have to.
    public static let bluetooth = "ledge.bluetooth"

    public static func isCustom(_ name: String) -> Bool {
        name.hasPrefix("ledge.")
    }
}

public enum AudioDeviceSymbol {

    public static func forName(_ name: String?) -> String {
        let lowered = (name ?? "").lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpods.pro" }
        if lowered.contains("airpods") { return "airpods.gen3" }
        if lowered.contains("beats") { return "beats.headphones" }
        if lowered.contains("macbook") || lowered.contains("built-in") { return "laptopcomputer" }
        if lowered.contains("studio display") || lowered.contains("display") { return "display" }
        if lowered.contains("tv") { return "tv" }
        if lowered.contains("homepod") { return "homepod.fill" }
        if lowered.contains("headphone") { return "headphones" }
        return "hifispeaker.fill"
    }
}
