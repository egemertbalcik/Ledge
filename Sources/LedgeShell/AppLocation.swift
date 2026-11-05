import Foundation

/// Whether a copy of Ledge is somewhere that will still be there tomorrow.
///
/// Not anything under /Volumes, and not a translocated path. A disk image is
/// ejected, an external drive unplugged, a translocated copy cleaned up, and
/// whatever macOS was told to start from there then starts nothing. A second
/// internal volume is refused too, as it is for the Accessibility entry.
public enum AppLocation {

    public static func isLasting(_ bundleURL: URL) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().path
        return !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
    }
}
