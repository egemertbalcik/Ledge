import Foundation
import LedgeHelperKit
import OSLog

// The root daemon's whole entry point. Everything it does is in LedgeHelperKit
// and in the four files beside this one, and the reason this is so short is
// that the thing running as root should be readable in one sitting.

private let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake-helper")

private func stop(_ message: String) -> Never {
    log.fault("keep awake helper: \(message, privacy: .public)")
    FileHandle.standardError.write(Data((message + "\n").utf8))
    // launchd throttles a job that keeps failing to ten seconds between tries,
    // so refusing to start is a loud, bounded failure rather than a daemon
    // quietly running with a check it could not make.
    exit(1)
}

let arguments: HelperArguments
do {
    arguments = try HelperArguments.parse(CommandLine.arguments)
} catch {
    stop("\(error)")
}

// Compiled before it is used: `NSXPCListener` treats a malformed requirement as
// a fatal error, and a trap at launch says nothing about what was wrong with it.
guard CodeSigningRequirement.compiles(arguments.requirement) else {
    stop("the client requirement does not compile: \(arguments.requirement)")
}

let daemon = KeepAwakeDaemon(
    arguments: arguments,
    store: FileClaimStore(directory: FileClaimStore.systemDirectory),
    pmset: ProcessPmsetRunner(tool: ProcessPmsetRunner.pmset),
    // A second runner for the lease watchdog, with its own queues. It exists
    // to act when the ordinary path cannot, so it must not be able to queue
    // behind the ordinary path's child.
    watchdogPmset: ProcessPmsetRunner(tool: ProcessPmsetRunner.pmset)
)
daemon.start()
dispatchMain()
