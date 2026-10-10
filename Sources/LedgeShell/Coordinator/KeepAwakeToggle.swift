import Foundation
import LedgeCore
import LedgeProviders

/// Which of several Keep Awake switches the user meant last.
///
/// Switching it off has to end the session *before* the hub removes the
/// provider — removal reaches only `stop()`, which releases the assertion and
/// deliberately writes nothing, so removing first leaves the journal saying a
/// session is running and the next launch picks it up again.
///
/// Ending waits on the disk, and that wait is long enough for the user to
/// change their mind. So every toggle takes a number, On included. Numbering
/// only the Off ones left an Off that was waiting on the disk still holding
/// the latest number when an On arrived behind it, and the switch settled on
/// the opposite of what the user last chose.
@MainActor
final class KeepAwakeToggle {

    private var latest = 0
    private let end: () async -> Void
    private let apply: (Bool) -> Void

    /// - Parameters:
    ///   - end: ends the running session, however long the disk takes.
    ///   - apply: adds or removes the provider.
    init(end: @escaping () async -> Void, apply: @escaping (Bool) -> Void) {
        self.end = end
        self.apply = apply
    }

    /// The number of the most recent choice, for a test to read.
    var requests: Int { latest }

    func set(_ enabled: Bool) {
        latest &+= 1
        let token = latest
        // On has nothing to wait for, so it lands at once — but it still takes
        // its number on the way past, which is what retires any Off that is
        // still waiting behind it.
        guard !enabled else {
            apply(true)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Before ending, not only before applying. Ending is the
            // destructive half — a switch that was turned back on before this
            // ran would otherwise still have its session ended underneath it.
            guard self.latest == token else { return }
            await self.end()
            guard self.latest == token else { return }
            self.apply(false)
        }
    }
}
