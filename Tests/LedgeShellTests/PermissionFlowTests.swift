import Foundation
import LedgeCore
import LedgeUI
import Testing

@testable import LedgeShell

/// A press on a permission button, run for real: every way an answer can
/// arrive, and what each does to the window that asked.
@MainActor
@Suite("A permission press and the window that asked")
struct PermissionFlowTests {

    /// Everything outside the flow, under the test's control.
    @MainActor
    private final class World {
        var statuses: [PermissionKind: PermissionStatus] = [:]
        var knownStatuses: [PermissionKind: PermissionStatus] = [:]
        var systemSettingsInFront = true
        var settingsVisible = true
        var tourVisible = false
        var panelUp = false
        var wasAsked = false

        var requests: [(kind: PermissionKind, alertMayAppear: Bool)] = []
        var answers: [PermissionKind: PermissionStatus] = [:] { didSet { ring() } }
        var opened: [PermissionKind] = []
        var answered: [(PermissionKind, PermissionStatus)] = []
        var presents = 0
        var tourRaises = 0
        var reclaims = 0
        var standAsides = 0
        var panelEnds = 0
        var marks = 0
        var waiting: [PermissionKind] = []
        var arrived: [PermissionKind] = []
        var lockClears = 0
        var comingBack: (@MainActor () -> Void)?
        var comingBackStops = 0
        var sleepsAllowed = 0 { didSet { ring() } }
        var sleepsStarted = 0

        weak var flow: PermissionFlow?

        /// Parked rather than polling: a press a test leaves unanswered costs
        /// nothing for the rest of the run, where hundreds of pollers on the
        /// main actor starved every other test.
        private var parked: [UUID: CheckedContinuation<Void, Never>] = [:]

        private func ring() {
            let waking = parked
            parked = [:]
            for continuation in waking.values { continuation.resume() }
        }

        private func unpark(_ id: UUID) {
            parked.removeValue(forKey: id)?.resume()
        }

        private func park() async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        parked[id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in self.unpark(id) }
            }
        }

        /// What the coordinator's diff does: a gain goes to `grantArrived`.
        func reread() {
            let was = knownStatuses
            knownStatuses = statuses
            for (kind, status) in statuses where status == .granted && was[kind] != .granted {
                flow?.grantArrived(kind)
            }
        }

        func sleep() async {
            sleepsStarted += 1
            let mine = sleepsStarted
            while sleepsAllowed < mine, !Task.isCancelled { await park() }
        }

        func request(_ kind: PermissionKind, _ alertMayAppear: Bool) async -> PermissionStatus {
            requests.append((kind, alertMayAppear))
            while answers[kind] == nil, !Task.isCancelled { await park() }
            return answers[kind] ?? .notDetermined
        }

        /// Ways the window that asked was moved.
        var moves: Int { presents + tourRaises + reclaims }

        var asWorld: PermissionFlowWorld {
            PermissionFlowWorld(
                status: { self.statuses[$0] ?? .notDetermined },
                request: { await self.request($0, $1) },
                openSettings: { self.opened.append($0) },
                reread: { self.reread() },
                answered: { self.answered.append(($0, $1)) },
                settingsIsVisible: { self.settingsVisible },
                tourIsVisible: { self.tourVisible },
                presentSettings: { self.presents += 1 },
                raiseTour: { self.tourRaises += 1 },
                reclaimFront: { self.reclaims += 1 },
                standAside: { self.standAsides += 1 },
                systemSettingsHoldsTheFront: { self.systemSettingsInFront },
                panelIsUp: { self.panelUp },
                endPanelArrival: { self.panelEnds += 1 },
                watchComingBack: { cameBack in
                    self.comingBack = cameBack
                    return { self.comingBackStops += 1; self.comingBack = nil }
                },
                accessibilityWasAsked: { self.wasAsked },
                markAccessibilityAsked: { self.wasAsked = true; self.marks += 1 },
                sayWaiting: { self.waiting.append($0) },
                sayArrived: { self.arrived.append($0) },
                clearLock: { self.lockClears += 1 },
                sleep: { _ in await self.sleep() }
            )
        }
    }

    private func make() -> (PermissionFlow, SettingsModel, World) {
        let model = SettingsModel()
        model.permissions = PermissionKind.allCases.map { PermissionRow(kind: $0, status: .notDetermined) }
        let world = World()
        let flow = PermissionFlow(model: model, world: world.asWorld)
        world.flow = flow
        return (flow, model, world)
    }

    /// Polled against a deadline, so something that never happens is a
    /// failure rather than a hung run.
    private func arrive(
        _ what: Comment,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition(), what, sourceLocation: sourceLocation)
    }

    /// Pressed, with the flow waiting on macOS. The model's guide is what the
    /// button puts up before the press reaches the shell.
    private func pressed(_ kind: PermissionKind = .accessibility) async -> (PermissionFlow, SettingsModel, World) {
        let (flow, model, world) = make()
        if kind.isGrantedInSystemSettings { model.beganHandoff(for: kind) }
        flow.press(kind)
        await arrive("macOS was asked") { world.requests.count == 1 }
        return (flow, model, world)
    }

    /// Pressed, and macOS said nothing yet, so the watch is on it.
    private func watching(_ kind: PermissionKind = .accessibility) async -> (PermissionFlow, SettingsModel, World) {
        let (flow, model, world) = await pressed(kind)
        world.answers[kind] = .notDetermined
        await arrive("the watch is on and waiting") { flow.isWatching && world.sleepsStarted == 1 }
        return (flow, model, world)
    }

    // MARK: - The request answers at once

    /// The finding: this path never went through the decision, and floated the
    /// window straight over somebody still in System Settings.
    @Test("A grant returned by the request leaves the window behind System Settings")
    func immediateGrantAtSystemSettings() async {
        let (flow, model, world) = await pressed()
        world.statuses[.accessibility] = .granted
        world.answers[.accessibility] = .granted
        await arrive("the press is over") { model.handoff == nil }
        #expect(flow.isOwedTheFront)
        #expect(world.moves == 0)
        #expect(!flow.isWatching)
        #expect(world.comingBack != nil)
    }

    @Test("A grant returned by the request with nobody at System Settings takes the front back")
    func immediateGrantAway() async {
        let (flow, model, world) = await pressed()
        world.systemSettingsInFront = false
        world.statuses[.accessibility] = .granted
        world.answers[.accessibility] = .granted
        await arrive("the press is over") { model.handoff == nil }
        #expect(!flow.isOwedTheFront)
        #expect(world.reclaims == 1)
        #expect(world.presents == 0)
    }

    /// No watch ran for this one, so nothing else would ever say it.
    @Test("A grant returned by the request is announced in one place", arguments: [false, true])
    func immediateGrantSaid(panelUp: Bool) async {
        let (_, model, world) = await pressed()
        world.panelUp = panelUp
        world.statuses[.accessibility] = .granted
        world.answers[.accessibility] = .granted
        await arrive("the press is over") { model.handoff == nil }
        #expect(world.arrived == (panelUp ? [] : [.accessibility]))
    }

    /// A prompt is answered in front of the window that asked, wherever System
    /// Settings happens to be.
    @Test("A prompt's answer takes the front back whatever else is open", arguments: [
        PermissionStatus.granted, .denied,
    ])
    func promptAnswer(status: PermissionStatus) async {
        let (flow, _, world) = await pressed(.calendars)
        world.statuses[.calendars] = status
        world.answers[.calendars] = status
        await arrive("the front came back") { world.reclaims == 1 }
        #expect(!flow.isOwedTheFront)
        #expect(world.answered.map(\.1) == [status])
        #expect(world.arrived.isEmpty)
    }

    /// Its request returns once it has asked, with the dialog still up.
    @Test("Location keeps standing aside until its answer comes")
    func locationWaitsForItsAnswer() async {
        let (flow, _, world) = await pressed(.location)
        world.answers[.location] = .notDetermined
        await arrive("the watch is on and waiting") { flow.isWatching && world.sleepsStarted == 1 }
        #expect(world.reclaims == 0)
        world.statuses[.location] = .granted
        world.sleepsAllowed = 1
        await arrive("the watch ended") { !flow.isWatching }
        #expect(world.reclaims == 1)
        #expect(!flow.isOwedTheFront)
    }

    @Test("A request overtaken by a newer press does nothing when it returns")
    func overtaken() async {
        let (flow, _, world) = await pressed()
        flow.press(.calendars)
        await arrive("the newer press asked") { world.requests.count == 2 }
        world.statuses[.accessibility] = .granted
        world.answers[.accessibility] = .granted
        await arrive("the older answer was read") { world.answered.count == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(world.moves == 0)
        #expect(!flow.isOwedTheFront)
        #expect(!flow.isWatching)
    }

    // MARK: - The diff and the watch

    /// A grant usually reaches the diff first, from the settings pane's poll or
    /// the list changing, a moment before the watch's own turn.
    @Test("A grant heard by the diff leaves the window behind System Settings, then the watch ends it")
    func diffThenWatch() async {
        let (flow, model, world) = await watching()
        world.statuses[.accessibility] = .granted
        world.reread()
        #expect(flow.isOwedTheFront)
        #expect(world.moves == 0)
        world.sleepsAllowed = 1
        await arrive("the watch ended") { !flow.isWatching && model.handoff == nil }
        #expect(flow.isOwedTheFront)
        #expect(world.moves == 0)
        #expect(world.arrived == [.accessibility])
    }

    @Test("A grant heard by the watch leaves the window behind System Settings")
    func watchAtSystemSettings() async {
        let (flow, _, world) = await watching()
        world.statuses[.accessibility] = .granted
        world.sleepsAllowed = 1
        await arrive("the watch ended") { !flow.isWatching }
        #expect(flow.isOwedTheFront)
        #expect(world.moves == 0)
    }

    @Test("Away from System Settings, a grant brings Settings forward")
    func watchAwayFromSettings() async {
        let (flow, _, world) = await watching()
        world.systemSettingsInFront = false
        world.statuses[.accessibility] = .granted
        world.sleepsAllowed = 1
        await arrive("the watch ended") { !flow.isWatching }
        #expect(world.presents >= 1)
        #expect(world.tourRaises == 0)
        #expect(!flow.isOwedTheFront)
    }

    @Test("Away from System Settings, a grant from the tour brings the tour forward")
    func watchAwayFromTour() async {
        let (flow, model, world) = make()
        world.tourVisible = true
        model.beganHandoff(for: .accessibility)
        flow.press(.accessibility)
        await arrive("macOS was asked") { world.requests.count == 1 }
        world.answers[.accessibility] = .notDetermined
        await arrive("the watch is on and waiting") { flow.isWatching && world.sleepsStarted == 1 }
        world.systemSettingsInFront = false
        world.statuses[.accessibility] = .granted
        world.sleepsAllowed = 1
        await arrive("the watch ended") { !flow.isWatching }
        #expect(world.tourRaises >= 1)
        #expect(world.presents == 0)
    }

    @Test("Another permission's grant during the wait moves nothing")
    func otherKind() async {
        let (flow, _, world) = await watching()
        world.statuses[.calendars] = .granted
        world.reread()
        #expect(world.moves == 0)
        #expect(!flow.isOwedTheFront)
        #expect(flow.isWatching)
        #expect(world.arrived.isEmpty)
    }

    @Test("A grant with no press outstanding moves nothing")
    func noPress() {
        let (flow, _, world) = make()
        flow.grantArrived(.accessibility)
        #expect(world.moves == 0)
        #expect(!flow.isOwedTheFront)
    }

    @Test("The four minutes running out at System Settings leaves the window where it is")
    func timeoutAtSystemSettings() async {
        let (flow, model, world) = await watching()
        world.sleepsAllowed = Int.max
        await arrive("the watch ran out") { !flow.isWatching }
        #expect(world.sleepsStarted == Int(PermissionFlow.watchWindow))
        #expect(flow.isOwedTheFront)
        #expect(world.moves == 0)
        #expect(model.handoff == nil)
    }

    @Test("The four minutes running out anywhere else takes the front back")
    func timeoutAway() async {
        let (flow, model, world) = await watching()
        world.systemSettingsInFront = false
        world.sleepsAllowed = Int.max
        await arrive("the watch ran out") { !flow.isWatching }
        #expect(!flow.isOwedTheFront)
        #expect(world.reclaims == 1)
        #expect(model.handoff == nil)
    }

    @Test("Closing the window that asked ends the watch and the press")
    func windowClosed() async {
        let (flow, model, world) = await watching()
        world.settingsVisible = false
        world.sleepsAllowed = 1
        await arrive("the watch ended") { !flow.isWatching }
        #expect(model.handoff == nil)
        #expect(world.lockClears >= 1)
    }

    // MARK: - Getting back

    private func owed() async -> (PermissionFlow, World) {
        let (flow, model, world) = await pressed()
        world.statuses[.accessibility] = .granted
        world.answers[.accessibility] = .granted
        await arrive("the press is over") { model.handoff == nil }
        #expect(flow.isOwedTheFront)
        return (flow, world)
    }

    @Test("Going to another app floats the window again and activates nothing")
    func cameBackViaAnotherApp() async {
        let (flow, world) = await owed()
        world.comingBack?()
        #expect(!flow.isOwedTheFront)
        #expect(world.reclaims == 1)
        #expect(world.presents == 0)
        #expect(world.panelEnds == 1)
        #expect(world.comingBackStops == 1)
    }

    @Test("Coming back twice moves the window once")
    func cameBackTwice() async {
        let (flow, world) = await owed()
        flow.personCameBack()
        flow.personCameBack()
        #expect(world.reclaims == 1)
    }

    @Test("The panel or the notch brings the asking window forward", arguments: [false, true])
    func wentBack(tour: Bool) async {
        let (flow, world) = await owed()
        world.tourVisible = tour
        flow.goBackToTheAskingWindow()
        #expect(!flow.isOwedTheFront)
        #expect(world.tourRaises == (tour ? 1 : 0))
        #expect(world.presents == (tour ? 0 : 1))
        #expect(world.comingBackStops == 1)
    }

    /// Asked for, so it isn't held back by System Settings being in front.
    @Test("A click on the notch while waiting brings the window forward")
    func notchClickWhileWaiting() async {
        let (flow, _, world) = await watching()
        flow.grantArrived(nil)
        #expect(world.presents == 1)
        #expect(!flow.isOwedTheFront)
        #expect(flow.isWatching)
    }

    @Test("A new press owes nothing from the last one")
    func newPressClears() async {
        let (flow, world) = await owed()
        world.answers[.bluetooth] = .notDetermined
        flow.press(.bluetooth)
        #expect(!flow.isOwedTheFront)
        #expect(world.comingBackStops == 1)
    }

    // MARK: - The press

    /// The press writes the flag, so reading it after would never see true.
    @Test("Only the first Accessibility press can raise macOS's message")
    func alertOnlyOnFirstPress() async {
        let (flow, _, world) = await pressed()
        #expect(world.requests[0].alertMayAppear)
        #expect(world.marks == 1)
        world.answers[.accessibility] = .notDetermined
        await arrive("the watch is on") { flow.isWatching }
        flow.press(.accessibility)
        await arrive("asked again") { world.requests.count == 2 }
        #expect(!world.requests[1].alertMayAppear)
        #expect(world.marks == 1)
    }

    @Test("A press for anything else never expects the message")
    func noAlertForOthers() async {
        let (_, _, world) = await pressed(.calendars)
        #expect(!world.requests[0].alertMayAppear)
        #expect(world.marks == 0)
    }

    @Test("A press stands aside and the handoff rests the lock in the notch")
    func pressStandsAside() async {
        let (_, _, world) = await pressed()
        #expect(world.standAsides == 1)
        #expect(world.waiting == [.accessibility])
    }

    @Test("A prompt rests nothing in the notch")
    func promptRestsNothing() async {
        let (_, _, world) = await pressed(.calendars)
        #expect(world.waiting.isEmpty)
    }

    @Test("Opening System Settings starts a watch with no request")
    func openingSettings() async {
        let (flow, model, world) = make()
        model.beganHandoff(for: .focusStatus)
        flow.openSettings(for: .focusStatus)
        #expect(world.opened == [.focusStatus])
        #expect(world.requests.isEmpty)
        #expect(flow.isWatching)
        #expect(world.waiting == [.focusStatus])
        world.statuses[.focusStatus] = .granted
        await arrive("the watch is waiting") { world.sleepsStarted == 1 }
        world.sleepsAllowed = 1
        await arrive("the watch ended") { !flow.isWatching }
        #expect(flow.isOwedTheFront)
        #expect(model.handoff == nil)
    }

    /// The second go's guide survives the first go's ending.
    @Test("Another go at the same permission keeps its guide and its watch")
    func secondGoKeepsGuide() async {
        let (flow, model, world) = await watching()
        model.beganHandoff(for: .accessibility)
        flow.openSettings(for: .accessibility)
        #expect(model.handoff?.kind == .accessibility)
        #expect(flow.isWatching)
        #expect(world.lockClears >= 1)
        #expect(world.waiting == [.accessibility, .accessibility])
    }

    @Test("Stop Waiting ends the press and takes the front back")
    func stopWaiting() async {
        let (flow, model, world) = await watching()
        flow.stopWaiting()
        #expect(!flow.isWatching)
        #expect(model.handoff == nil)
        #expect(world.reclaims == 1)
        #expect(world.lockClears >= 1)
        // And nothing is waiting to come back for it.
        world.sleepsAllowed = Int.max
        try? await Task.sleep(for: .milliseconds(20))
        #expect(world.reclaims == 1)
    }

    @Test("Ledge going away leaves nothing running or owed")
    func goingAway() async {
        let (flow, world) = await owed()
        flow.stop()
        #expect(!flow.isOwedTheFront)
        #expect(!flow.isWatching)
        #expect(world.comingBackStops == 1)
        #expect(world.lockClears >= 1)
        #expect(world.moves == 0)
    }

    @Test("A refusal in System Settings says nothing in the notch")
    func refusal() async {
        let (flow, _, world) = await watching()
        world.statuses[.accessibility] = .denied
        world.sleepsAllowed = 1
        await arrive("the watch ended") { !flow.isWatching }
        #expect(world.arrived.isEmpty)
    }
}
