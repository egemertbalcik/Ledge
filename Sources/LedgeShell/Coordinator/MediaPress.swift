import Foundation
import LedgeSystem
import OSLog

/// One press of a transport button, and what the rest of the app may conclude
/// from it.
///
/// A press that never left the app changes nothing: the player was not asked,
/// so there is nothing to wait for and nothing to show. Granting the handover
/// anyway told the provider to expect a change nobody had requested — the card
/// then held its place for a track that was never going to arrive, which is
/// exactly how Play/Pause and Next come to look unreliable.
@MainActor
struct MediaPress {

    private static let log = Logger(subsystem: "dev.ledgeapp.Ledge", category: "media")

    /// Sends the command to the player on the card.
    let send: (NowPlayingCommand) -> NowPlayingDispatch

    /// Says a change was asked for, so the next reading is read back quickly
    /// and is not mistaken for a player handing its slot around.
    let expectChange: () -> Void

    /// - Returns: whether anything left the app, which is the only thing that
    ///   entitles the card to show what was asked for.
    @discardableResult
    func callAsFunction(_ command: NowPlayingCommand) -> Bool {
        guard send(command).wasSent else {
            Self.log.debug("a media command was refused, so nothing is expected to change")
            return false
        }
        expectChange()
        return true
    }
}
