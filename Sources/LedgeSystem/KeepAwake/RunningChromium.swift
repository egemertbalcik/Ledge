import AppKit
import Foundation
import LedgeCore
import os

/// Finds the Chromium-family browsers running right now, and whether each was
/// started with what it needs to keep working behind a shut lid.
///
/// Read-only, always. The flags can only be given at launch, so the only fix is
/// a restart, and restarting somebody's browser out from under them is a worse
/// surprise than a slow one. This reports; the user decides.
public enum RunningChromium {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "chromium")

    /// How `ps` is asked. `-ww` matters: without it the command line is
    /// truncated to the terminal width, and a flag that was there would read
    /// as missing — a check that silently says "unprotected" for a browser
    /// that is fine.
    static func commandLine(of pid: pid_t, run: (String, [String]) -> String?) -> String? {
        run("/bin/ps", ["-ww", "-o", "args=", "-p", String(pid)])
    }

    public static func all() -> [ChromiumBrowser] {
        browsers(running: NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, ChromiumOcclusion.isChromium(id) else { return nil }
            return (id: id, name: app.localizedName ?? id, pid: app.processIdentifier)
        }, commandLine: { pid in commandLine(of: pid, run: Self.capture) })
    }

    /// Separated from `NSWorkspace` so the decision can be tested without
    /// anybody's actual browsers being open.
    static func browsers(running: [(id: String, name: String, pid: pid_t)],
                         commandLine: (pid_t) -> String?) -> [ChromiumBrowser] {
        running.map { app in
            // A command line nobody could read is reported as unprotected.
            // The cost of being wrong that way is one unnecessary suggestion;
            // the other way it is an agent that silently stops.
            let line = commandLine(app.pid) ?? ""
            return ChromiumBrowser(bundleID: app.id, name: app.name,
                                   isProtected: ChromiumOcclusion.isProtected(commandLine: line))
        }
    }

    private static func capture(_ path: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            log.error("chromium: could not read a command line: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
