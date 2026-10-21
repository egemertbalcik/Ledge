import Foundation
import LedgeCore
import LedgeSystem

/// A file arriving on the Shelf, and what it is allowed to change besides the
/// Shelf itself.
///
/// The two ways in are not the same act. A drop is the user putting a file on
/// the notch, so it switches a Shelf they had turned off back on rather than
/// silently discard the file. A screenshot is Ledge acting on its own, so it
/// never does: a card the user turned off stays off, and while it is off its
/// screenshot query is not running either ("a source you turn off is never
/// even built"). Both used to share one "enable if off" line, which a
/// refactor carried from the drop path into the screenshot path, so any
/// screenshot quietly switched a disabled Shelf back on and saved it.
@MainActor
struct ShelfArrival {

    let preferences: Preferences
    let shelf: ShelfStore

    /// Switches the Shelf card on, and saves that.
    let enableShelf: () -> Void

    /// Flashes the Shelf to say something landed on it.
    let announce: () -> Void

    /// Whether new screenshots should be noticed at all: only while the user
    /// wants them saved *and* has the card on. With the card off the "Save
    /// screenshots" switch keeps its value but does nothing.
    var watchesScreenshots: Bool {
        preferences.shelfAutoScreenshots && preferences.isProviderEnabled("shelf")
    }

    /// Files dropped on the notch. Returns how many the Shelf took.
    @discardableResult
    func dropped(_ urls: [URL]) -> Int {
        let added = shelf.add(urls)
        guard added > 0 else { return 0 }
        if !preferences.isProviderEnabled("shelf") { enableShelf() }
        announce()
        return added
    }

    /// A screenshot the watcher noticed.
    func screenshotTaken(_ url: URL) {
        // The query is stopped when the card goes off, but a result already on
        // its way can still land after that.
        guard watchesScreenshots else { return }
        // On a clock, unlike a file the user dropped: Ledge put this here on
        // their behalf and should tidy up after itself.
        guard shelf.add([url], expiresAfter: ShelfStore.screenshotLifetime) > 0 else { return }
        // And say so. A screenshot that lands in the notch without a word is
        // indistinguishable from one that went only to the desktop, which
        // makes the feature invisible to the person it is for.
        announce()
    }
}
