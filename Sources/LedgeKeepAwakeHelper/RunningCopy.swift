import Darwin
import Foundation

/// Whether the copy of the helper that is running is still the one on disk.
///
/// An update deletes the app bundle this process was started from and puts a
/// new one in its place, and nothing tells the process. It keeps running, and
/// from then on macOS cannot look its code up: every answer it sends fails the
/// app's code signing check, while every message the app sends it still lands.
/// The app can hear nothing from it, and as long as the app keeps a connection
/// open it never idle-exits to make way for the new copy.
///
/// So the helper checks for itself. At launch it notes which file it was
/// started from — the device and inode at its own executable's path — and
/// asks again on every idle tick. A different file at that path, or none,
/// means the next launch would run different code, and a clean helper then
/// exits without waiting for its clients to leave.
///
/// The file's identity rather than a code signing lookup of itself. The lookup
/// is the check that actually fails after an update, and it fails only once
/// the bundle has been deleted: a binary renamed over with an identical copy,
/// or a bundle moved aside, still passes it. This notices those too, which
/// costs at most one exit that launchd undoes on the next call — and unlike a
/// lookup of a running process's code, it can be exercised with plain files.
struct RunningCopy: Sendable {

    /// Which file a path named, at the moment it was asked.
    struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    enum Reading: Equatable, Sendable {
        /// The file at the path is the one this process was started from.
        case same
        /// It is not, or there is nothing there.
        case replaced
        /// The question could not be answered. Never a reason to exit: a
        /// helper that guessed here could exit from under a client on the
        /// strength of a permission error.
        case unknown
    }

    /// The executable's path, or nil if it could not be found at launch.
    let path: String?
    /// The file that path named at launch, or nil if it could not be read.
    let launched: Identity?

    /// Notes the file at `path` as it is now.
    init(path: String?) {
        self.path = path
        self.launched = path.flatMap { Self.identity(at: $0).identity }
    }

    /// This process's own executable, noted as early as `main` can.
    ///
    /// By the kernel's path for it rather than `argv[0]`, which launchd sets
    /// to the plist's relative `BundleProgram`, and rather than the main
    /// bundle, which for a tool inside an app's `Contents/MacOS` is the app.
    /// There is a moment between launch and this call in which an update
    /// could already have swapped the file; the identity noted would then be
    /// the new one, and this helper would merely fall back on the ordinary
    /// idle rule, which is how every helper behaved before this existed.
    static func atLaunch() -> RunningCopy {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else { return RunningCopy(path: nil) }
        return RunningCopy(path: String(decoding: buffer.prefix(Int(length)), as: UTF8.self))
    }

    /// Asked on every idle tick, and whenever the core may just have become
    /// clean. One `stat`, so cheap enough to ask that often.
    func reading() -> Reading {
        guard let path, let launched else { return .unknown }
        let now = Self.identity(at: path)
        if let identity = now.identity { return identity == launched ? .same : .replaced }
        // Gone, or a folder on the way to it gone: the update's deletion, or
        // a bundle moved somewhere else. Anything else — a permission, an
        // I/O error — says nothing about which copy is installed.
        return now.errno == ENOENT || now.errno == ENOTDIR ? .replaced : .unknown
    }

    private static func identity(at path: String) -> (identity: Identity?, errno: Int32) {
        var info = stat()
        guard stat(path, &info) == 0 else { return (nil, errno) }
        return (Identity(device: UInt64(UInt32(bitPattern: info.st_dev)),
                         inode: UInt64(info.st_ino)), 0)
    }
}
