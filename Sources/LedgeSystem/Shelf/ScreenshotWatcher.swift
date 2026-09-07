import Foundation
import os

/// Notices new screenshots as they land, wherever the user saves them.
///
/// A Spotlight live query on `kMDItemIsScreenCapture` rather than a directory
/// watch: the save location is a preference (`defaults write
/// com.apple.screencapture location …`) and the filename is localized, but
/// Spotlight tags every screenshot the same way in every language and folder.
@MainActor
public final class ScreenshotWatcher {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "screenshots")

    private var query: NSMetadataQuery?
    private var observers: [any NSObjectProtocol] = []
    /// Only screenshots taken after watching began count — the query's first
    /// result set is the user's entire screenshot history.
    private var startedAt = Date.distantFuture
    /// Paths already delivered, so a metadata update (Spotlight re-indexing
    /// the same file) does not add the screenshot twice.
    private var seen: Set<String> = []

    public init() {}

    public func startWatching(_ onNew: @escaping @MainActor (URL) -> Void) {
        stopWatching()
        startedAt = Date()

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]

        let center = NotificationCenter.default
        for name in [
            Notification.Name.NSMetadataQueryDidFinishGathering,
            Notification.Name.NSMetadataQueryDidUpdate,
        ] {
            observers.append(center.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.harvest(onNew) }
            })
        }
        query.start()
        self.query = query
    }

    public func stopWatching() {
        query?.stop()
        query = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        seen.removeAll()
        startedAt = .distantFuture
    }

    private func harvest(_ onNew: @MainActor (URL) -> Void) {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !seen.contains(path)
            else { continue }
            let created = item.value(
                forAttribute: NSMetadataItemFSCreationDateKey
            ) as? Date
            guard let created else {
                // Mid-index the attribute can be momentarily absent; latching
                // the path into `seen` here would skip the screenshot forever.
                // Leave it unremembered — the next update delivers it whole.
                continue
            }
            guard created >= startedAt else {
                // Old history: remember it so the loop stays cheap, skip it.
                seen.insert(path)
                continue
            }
            seen.insert(path)
            Self.log.debug("new screenshot: \(path, privacy: .private(mask: .hash))")
            onNew(URL(fileURLWithPath: path))
        }
    }
}
