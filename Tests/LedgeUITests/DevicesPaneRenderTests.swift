import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// What each device row says, in every state that matters.
@Suite("Device row presentation")
struct DeviceRowPresentationTests {

    private static let seen = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private static func presentation(
        name: String = "AirPods Pro",
        presence: DevicePresence,
        isStale: Bool,
        level: Double? = 0.42
    ) -> DeviceRowPresentation {
        DeviceRowPresentation(
            name: name, presence: presence, isStale: isStale,
            lowestLevel: level, lastSeen: seen, now: seen,
            relativeText: "8 min ago",
            exactTime: "12 Jan 2026 at 09:41"
        )
    }

    @Test("Connected and fresh says so plainly")
    func connectedFresh() {
        let row = Self.presentation(presence: .connected, isStale: false)
        #expect(row.status == "Connected")
        #expect(row.levelText == "42%")
        #expect(!row.isLevelHistorical)
    }

    /// Connected-but-unheard is not a contradiction, and must not be shown as
    /// a disconnection — nobody observed one.
    @Test("Connected but stale says when it was last heard")
    func connectedStale() {
        let row = Self.presentation(presence: .connected, isStale: true)
        #expect(row.status == "Connected · last heard 8 min ago")
        #expect(row.isLevelHistorical)
        #expect(row.accessibilityLabel.contains("last known value"))
    }

    @Test("An observed disconnect is stated as one")
    func disconnected() {
        let row = Self.presentation(presence: .disconnected, isStale: false)
        #expect(row.status == "Disconnected · 8 min ago")
    }

    @Test("Silence reads as last seen, never as disconnected")
    func silentIsNotDisconnected() {
        let fresh = Self.presentation(presence: .unknown, isStale: false)
        #expect(fresh.status == "In range")

        let silent = Self.presentation(presence: .unknown, isStale: true)
        #expect(silent.status == "Last seen 8 min ago")
        #expect(
            !silent.status.localizedCaseInsensitiveContains("disconnect"),
            "silence was presented as a disconnection"
        )
    }

    @Test("A device with no battery says so rather than showing nothing")
    func noBattery() {
        let row = Self.presentation(presence: .connected, isStale: false, level: nil)
        #expect(row.levelText == nil)
        #expect(row.accessibilityLabel.contains("no battery reported"))
    }

    @Test("The accessibility label carries name, status, level and the exact time")
    func accessibilityIsComplete() {
        let row = Self.presentation(presence: .connected, isStale: false)
        #expect(row.accessibilityLabel.contains("AirPods Pro"))
        #expect(row.accessibilityLabel.contains("Connected"))
        #expect(row.accessibilityLabel.contains("42 percent"))
        #expect(
            row.accessibilityLabel.contains("12 Jan 2026 at 09:41"),
            "the exact time was not available to VoiceOver"
        )
    }

    @Test("A very long name is carried whole into the label")
    func longNameSurvivesInLabel() {
        let long = String(repeating: "Ege's Very Long AirPods Name ", count: 6)
        let row = Self.presentation(name: long, presence: .connected, isStale: false)
        #expect(row.accessibilityLabel.contains(long), "truncation reached the spoken label")
    }
}

/// Renders the pane off-screen, in each state, at the widths Settings uses.
///
/// This is not a look-at-it check — there is no display in this environment —
/// but it does prove the states compose, lay out, and produce a bitmap rather
/// than crashing or collapsing to nothing.
@Suite("Devices pane rendering", .serialized)
@MainActor
struct DevicesPaneRenderTests {

    private static let widths: [CGFloat] = [320, 420, 560]
    private static let scales: [CGFloat] = [1, 2]
    private static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private static func record(
        _ name: String,
        id: DeviceIdentity,
        presence: DevicePresence = .connected,
        readings: [BatteryReading] = [
            BatteryReading(component: .left, level: 0.42, observedAt: t0)
        ],
        lastSeen: TimeInterval = 0,
        pinned: Bool = false,
        alerts: DeviceAlertConfiguration = .untouched
    ) -> DeviceRecord {
        DeviceRecord(
            id: id, name: name, presence: presence, readings: readings,
            firstSeen: t0, lastSeen: t0.addingTimeInterval(lastSeen),
            isPinned: pinned, alerts: alerts
        )
    }

    private static func model(_ catalogue: DeviceCatalogue) async -> DevicesSettingsModel {
        let model = DevicesSettingsModel(
            actions: .init(load: { catalogue }), now: { t0 }
        )
        model.load()
        try? await Task.sleep(for: .milliseconds(80))
        return model
    }

    /// Renders and returns the size produced, or nil if nothing came out.
    private func render(_ view: some View, width: CGFloat, scale: CGFloat) -> CGSize? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        return image.size
    }

    private func checkRenders(
        _ view: some View,
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for width in Self.widths {
            for scale in Self.scales {
                let size = render(view, width: width, scale: scale)
                #expect(
                    size != nil,
                    "\(what) produced no image at \(width)pt @\(scale)x",
                    sourceLocation: sourceLocation
                )
                if let size {
                    #expect(
                        size.height > 0,
                        "\(what) collapsed to zero height at \(width)pt @\(scale)x",
                        sourceLocation: sourceLocation
                    )
                }
            }
        }
    }

    @Test("The empty state renders")
    func emptyState() async {
        let model = await Self.model(DeviceCatalogue())
        checkRenders(DevicesSettingsTab(model: model), "empty state")
    }

    @Test("The loading state renders before anything has arrived")
    func loadingState() {
        // Never resolves, so the pane is drawn mid-load.
        let model = DevicesSettingsModel(
            actions: .init(load: {
                try? await Task.sleep(for: .seconds(60))
                return DeviceCatalogue()
            }),
            now: { Self.t0 }
        )
        model.load()
        checkRenders(DevicesSettingsTab(model: model), "loading state")
        model.cancel()
    }

    @Test("Connected, disconnected, stale and pinned rows render together")
    func mixedStates() async {
        var catalogue = DeviceCatalogue()
        let stale = DeviceIdentity.bluetooth("cc").freshnessInterval + 600
        catalogue.devices = [
            Self.record("MacBook Pro", id: .thisMac, readings: [
                BatteryReading(component: .main, level: 0.88, charging: .charging, observedAt: Self.t0)
            ]),
            Self.record("Magic Mouse", id: .bluetooth("bb"), presence: .disconnected),
            Self.record("AirPods Pro", id: .bluetooth("cc"), presence: .unknown, lastSeen: -stale, pinned: true),
        ]
        let model = await Self.model(catalogue)
        checkRenders(DevicesSettingsTab(model: model), "mixed states")
    }

    @Test("A very long device name renders without collapsing the row")
    func longName() async {
        var catalogue = DeviceCatalogue()
        catalogue.devices = [Self.record(
            String(repeating: "Ege's Extremely Long AirPods Pro Name ", count: 5),
            id: .bluetooth("aa")
        )]
        let model = await Self.model(catalogue)
        checkRenders(DevicesSettingsTab(model: model), "long name")
    }

    @Test("A multi-component device detail renders, charging and all")
    func multiComponentDetail() async {
        let id = DeviceIdentity.peripheral(UUID())
        var catalogue = DeviceCatalogue()
        let record = Self.record("AirPods Pro", id: id, readings: [
            BatteryReading(component: .left, level: 0.55, charging: .notCharging, observedAt: Self.t0),
            BatteryReading(component: .right, level: 0.60, charging: .notCharging, observedAt: Self.t0),
            BatteryReading(component: .case, level: 0.95, charging: .charging, observedAt: Self.t0),
        ])
        catalogue.devices = [record]
        let model = await Self.model(catalogue)
        checkRenders(DeviceDetailPane(model: model, record: record), "multi-component detail")
    }

    /// A device whose source cannot report charging must render the detail
    /// pane with the charged option refused and explained.
    @Test("Unsupported charging renders its explanation")
    func unsupportedCharging() async {
        let record = Self.record("Beats Studio", id: .bluetooth("dd"), readings: [
            BatteryReading(component: .main, level: 0.30, charging: .unknown, observedAt: Self.t0)
        ])
        var catalogue = DeviceCatalogue()
        catalogue.devices = [record]
        let model = await Self.model(catalogue)
        #expect(!BatteryAlertEngine.supportsCharged(record.readings, for: .main))
        checkRenders(DeviceDetailPane(model: model, record: record), "unsupported charging")
    }

    /// The detail pane holds batteries, a chart, a range picker, a row per
    /// rule and the removal controls, inside a fixed-height window. Without a
    /// scroll view the overflow was clipped with no way to reach it.
    @Test("A crowded detail pane is reachable rather than clipped")
    func crowdedDetailScrolls() async {
        let record = Self.record(
            "AirPods Pro", id: .peripheral(UUID()),
            readings: [
                BatteryReading(component: .left, level: 0.4, charging: .notCharging, observedAt: Self.t0),
                BatteryReading(component: .right, level: 0.5, charging: .notCharging, observedAt: Self.t0),
                BatteryReading(component: .case, level: 0.9, charging: .charging, observedAt: Self.t0),
            ],
            alerts: DeviceAlertConfiguration(
                rules: (0..<6).map { index in
                    BatteryAlertRule(
                        kind: index.isMultiple(of: 2) ? .low : .charged,
                        component: [.left, .right, .case][index % 3],
                        threshold: index.isMultiple(of: 2) ? 0.2 : 0.9,
                        delivery: .both
                    )
                },
                isCustomised: true
            )
        )
        var catalogue = DeviceCatalogue()
        catalogue.devices = [record]
        let model = await Self.model(catalogue)

        let pane = DeviceDetailPane(model: model, record: record)
        checkRenders(pane, "crowded detail")

        // Inside a window-sized frame the content must still be scrollable
        // rather than silently cut: rendering it in a short box and getting a
        // bitmap of that box is what a ScrollView does and a VStack does not.
        let boxed = pane.frame(height: 200)
        let size = render(boxed, width: 420, scale: 2)
        #expect(size != nil, "the crowded pane produced no image in a short window")
    }

    @Test("A device with custom rules and notification delivery renders")
    func customisedRules() async {
        let record = Self.record(
            "AirPods Pro", id: .peripheral(UUID()),
            alerts: DeviceAlertConfiguration(
                rules: [
                    BatteryAlertRule(kind: .low, component: .left, threshold: 0.15, delivery: .both),
                    BatteryAlertRule(kind: .charged, component: .case, threshold: 0.95, delivery: .notification),
                ],
                isCustomised: true
            )
        )
        var catalogue = DeviceCatalogue()
        catalogue.devices = [record]
        let model = await Self.model(catalogue)
        checkRenders(DeviceDetailPane(model: model, record: record), "customised rules")
    }

    /// Dark mode and large Dynamic Type sizes are injectable, so they are
    /// actually exercised here.
    ///
    /// Reduce Motion and increased contrast are *read-only* environment
    /// values derived from system settings — SwiftUI offers no way to write
    /// them, so no test can inject them. The pane is built not to depend on
    /// either (it has no animation of its own and no colour-only state), but
    /// that is a property of the code rather than something proven here, and
    /// it stays on the hardware list.
    @Test("The pane renders in dark mode and at accessibility type sizes")
    func accessibilityEnvironments() async {
        var catalogue = DeviceCatalogue()
        catalogue.devices = [
            Self.record("AirPods Pro", id: .bluetooth("aa")),
            Self.record("Magic Keyboard", id: .bluetooth("bb"), presence: .disconnected, readings: []),
        ]
        let model = await Self.model(catalogue)

        checkRenders(
            DevicesSettingsTab(model: model).environment(\.colorScheme, .dark),
            "dark mode"
        )
        for size in [DynamicTypeSize.large, .accessibility1, .accessibility3] {
            checkRenders(
                DevicesSettingsTab(model: model).dynamicTypeSize(size),
                "dynamic type \(size)"
            )
        }
    }
}
