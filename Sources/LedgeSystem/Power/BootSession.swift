import Foundation

/// Which boot this is.
///
/// A Keep Awake session never survives a restart, and the only way to tell a
/// restart from a relaunch is to ask the kernel what boot it is in. The value
/// changes on every boot and on nothing else.
public enum BootSession {

    /// `kern.bootsessionuuid`, or nil if the kernel will not say.
    ///
    /// A nil answer is not treated as "same boot": the caller ends the session
    /// instead, because the safe direction is letting the Mac sleep.
    public static func identifier() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl reports the size including the terminator, which is not part
        // of the string.
        if let terminator = buffer.firstIndex(of: 0) { buffer.removeSubrange(terminator...) }
        return String(decoding: buffer, as: UTF8.self)
    }
}
