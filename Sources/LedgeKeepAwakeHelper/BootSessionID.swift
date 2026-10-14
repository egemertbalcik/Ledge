import Foundation

/// Which boot this is.
///
/// The same `kern.bootsessionuuid` the app reads through `BootSession`, copied
/// rather than shared: this binary runs as root and links Foundation, Security
/// and LedgeHelperKit only, so it cannot reach into LedgeSystem for it. Six
/// lines of sysctl are a smaller price than the dependency.
enum BootSessionID {

    /// Never nil, and deliberately so.
    ///
    /// If the kernel will not say, a fresh identifier is returned instead. Then
    /// every claim in the store looks like it came from another boot, and every
    /// one of them is put back — which is the direction that lets a Mac sleep.
    /// Returning a constant stand-in would do the opposite: it would make a
    /// claim written by a daemon that also could not tell look live.
    static func current() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return UUID().uuidString
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
            return UUID().uuidString
        }
        if let terminator = buffer.firstIndex(of: 0) { buffer.removeSubrange(terminator...) }
        let value = String(decoding: buffer, as: UTF8.self)
        return value.isEmpty ? UUID().uuidString : value
    }
}
