import Foundation
import LedgeCore
import Testing

@Suite("Noticing a permission that moved")
struct PermissionDiffTests {

    private let granted: [PermissionKind: PermissionStatus] = [
        .calendars: .granted, .accessibility: .granted, .location: .granted,
    ]

    /// Launch reads the world for the first time. Reporting all of it as
    /// gained would restart every provider that had just started.
    @Test("A first reading is a baseline, not a change")
    func firstReadingIsSilent() {
        #expect(PermissionDiff.changes(from: [:], to: granted).isEmpty)
    }

    @Test("Nothing moving reports nothing")
    func steadyStateIsSilent() {
        #expect(PermissionDiff.changes(from: granted, to: granted).isEmpty)
    }

    /// The case this exists for: revoked in System Settings while the app runs.
    @Test("A revoked permission is reported as a loss")
    func revocationIsALoss() {
        var after = granted
        after[.calendars] = .denied
        let changes = PermissionDiff.changes(from: granted, to: after)
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .calendars)
        #expect(changes.first?.isLoss == true)
        #expect(changes.first?.isGain == false)
    }

    @Test("A permission granted while running is reported as a gain")
    func grantIsAGain() {
        var before = granted
        before[.location] = .denied
        let changes = PermissionDiff.changes(from: before, to: granted)
        #expect(changes.first?.kind == .location)
        #expect(changes.first?.isGain == true)
    }

    /// Only usability matters. `notDetermined` and `denied` are different
    /// sentences in the Permissions pane but the same fact to a provider, and
    /// flipping between them must not restart anything.
    @Test("A change that leaves the answer unusable is not a change")
    func unusableToUnusableIsSilent() {
        let before: [PermissionKind: PermissionStatus] = [.bluetooth: .notDetermined]
        let after: [PermissionKind: PermissionStatus] = [.bluetooth: .denied]
        #expect(PermissionDiff.changes(from: before, to: after).isEmpty)
    }

    @Test("Automation's \"open the app first\" is not a grant either")
    func notApplicableNowIsNotUsable() {
        let before: [PermissionKind: PermissionStatus] = [.automation: .granted]
        let after: [PermissionKind: PermissionStatus] = [.automation: .notApplicableNow]
        #expect(PermissionDiff.changes(from: before, to: after).first?.isLoss == true)
    }

    @Test("Several at once come back in a stable order")
    func changesAreOrdered() {
        var after = granted
        after[.calendars] = .denied
        after[.accessibility] = .notDetermined
        let names = PermissionDiff.changes(from: granted, to: after).map(\.kind.rawValue)
        #expect(names == names.sorted())
        #expect(names.count == 2)
    }
}
