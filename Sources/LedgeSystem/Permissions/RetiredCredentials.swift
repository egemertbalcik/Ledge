import Foundation
import Security
import os

/// Deletes credentials belonging to features this app no longer has.
///
/// Removing a feature removes its code, its settings and its buttons — but
/// not what it had already written into the user's keychain. The Spotify
/// account link stored an OAuth token there, and after the feature went the
/// token would have stayed: a live credential to someone's music library,
/// kept by an app that has no way left to use it and no screen left to
/// disconnect it from.
///
/// So it is deleted on launch. Cheap when there is nothing to delete, which
/// on almost every Mac is the case, and it prompts for nothing: the item
/// belongs to this app, which is what makes it ours to remove.
public enum RetiredCredentials {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "cleanup")

    /// Keychain services written by features that have since been removed.
    private static let retiredServices = [
        // Written by an earlier Spotify Web API integration that no longer
        // exists. Anything it left behind is cleared on launch.
        "com.egemert.ledge.spotify",
    ]

    public static func purge() {
        for service in retiredServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                log.notice("removed a credential for a retired feature: \(service, privacy: .public)")
            }
        }
    }
}
