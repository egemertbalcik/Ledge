import Foundation
import LedgeCore
import LedgeProviders
import os

/// Finds the fixture scenarios that drive development.
///
/// They are looked up beside the app bundle as well as inside it, so a scenario
/// can be edited and replayed without rebuilding.
public enum ScenarioCatalog {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "scenarios")

    /// Explicit override, for pointing the app at a scratch fixture directory.
    private static var overrideDirectory: URL? {
        DebugSwitches.value("LEDGE_FIXTURES").map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    public static func bundled() -> [Scenario] {
        for directory in searchPaths() {
            let scenarios = ScenarioLoader.loadAll(in: directory)
            if !scenarios.isEmpty {
                log.notice("scenarios from \(directory.path, privacy: .public)")
                return scenarios
            }
        }
        log.notice("no scenarios found — running with no activities")
        return []
    }

    private static func searchPaths() -> [URL] {
        var paths: [URL] = []
        if let overrideDirectory { paths.append(overrideDirectory) }

        if let resources = Bundle.main.resourceURL {
            paths.append(resources.appendingPathComponent("scenarios", isDirectory: true))
        }

        // Development fallback: the checkout itself, so editing a fixture and
        // relaunching is enough.
        paths.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/scenarios", isDirectory: true))

        return paths
    }
}
