import AppKit
import LedgeCore
import LedgeUI
import SwiftUI

/// Every state the notch can be in, rendered through the shape the app draws.
///
/// The section gallery renders bare cards in a scroll view. That answers "does
/// this card look right", and it has been answering it about a card 47pt wider
/// than the app's — and without the panel's corner radii, its top cutout, its
/// padding or its clipping. The parity question is a different one: *this*
/// state, in *that* container, at *this* scale, exported whole.
///
/// So each state here is a name, a presentation, and nothing else. The
/// container is `NotchOverlayView` — the production one, not a copy — and the
/// geometry is an explicit fixture rather than whatever display the harness
/// happens to run on.
@MainActor
enum StateGallery {

    /// The Macs a card can be drawn on, reduced to the only two things that
    /// change its size: the cutout it hangs from, and the scale the app chose
    /// from the panel's physical width.
    ///
    /// Named rather than parameterised by a bare number, because "1.03" says
    /// nothing and "14" says which machine somebody can go and check. The
    /// scales are `ScreenGeometry`'s own arithmetic — panel millimetres over
    /// the 291mm reference, clamped at 1.20 — and `LEDGE_SIM_DISPLAY` gives the
    /// app the same numbers, so an export can be held against a real overlay.
    enum Mac: String, CaseIterable {
        /// The reference: 13-inch Air, 290mm, the machine this was drawn on.
        case thirteen = "13"
        /// 14-inch Pro: a taller, wider cutout and a slightly larger panel.
        case fourteen = "14"
        /// 16-inch Pro, the largest that ships.
        case sixteen = "16"
        /// No cutout at all — an external display, or a Mac without a notch.
        /// The shape stands in for hardware that is not there, and it is the
        /// one case where the ears hang off nothing.
        case none

        var geometry: NotchGeometry {
            switch self {
            case .thirteen:
                NotchGeometry(
                    screenSize: CGSize(width: 1470, height: 956),
                    notchSize: CGSize(width: 179, height: 32),
                    notchCenterX: 735, isHardwareNotch: true, displayScale: 1.0
                )
            case .fourteen:
                NotchGeometry(
                    screenSize: CGSize(width: 1512, height: 982),
                    notchSize: CGSize(width: 190, height: 38),
                    notchCenterX: 756, isHardwareNotch: true, displayScale: 1.03
                )
            case .sixteen:
                NotchGeometry(
                    screenSize: CGSize(width: 1728, height: 1117),
                    notchSize: CGSize(width: 200, height: 38),
                    notchCenterX: 864, isHardwareNotch: true, displayScale: 1.18
                )
            case .none:
                .simulated(screenSize: CGSize(width: 1920, height: 1080))
            }
        }
    }

    static func mac(named name: String?) -> Mac {
        Mac(rawValue: name ?? "13") ?? .thirteen
    }

    /// A clock that does not move: "Ends at 10:36" and the calendar's own
    /// "today" are the only wall-clock reads on these cards, and an export
    /// that differs from yesterday's for that reason is a diff nobody reads.
    /// 2026-09-14 09:41:00 UTC — the hour Apple puts on every device it ships.
    static let clock = Date(timeIntervalSince1970: 1_789_378_860)

    struct State {
        let name: String
        /// Applied to a fresh presentation. Everything the state needs is set
        /// here, before the first render, so nothing animates into place.
        let apply: (NotchPresentation) -> Void
    }

    static let states: [State] = [
        // MARK: Closed and compact
        State(name: "idle") { $0.phase = .idle },
        State(name: "peek-music") { presentation in
            presentation.phase = .peek
            presentation.peeked = PreviewFixtures.nowPlaying
            presentation.selected = PreviewFixtures.nowPlaying
        },
        State(name: "companion-music") { presentation in
            presentation.phase = .companion
            presentation.nowPlaying = PreviewFixtures.nowPlaying
            presentation.selected = PreviewFixtures.nowPlaying
        },
        State(name: "hud-volume") { presentation in
            presentation.phase = .hud
            presentation.hud = HUDReadout(kind: .volume, level: 0.4)
            presentation.latestLevel = presentation.hud
        },
        State(name: "hud-brightness") { presentation in
            presentation.phase = .hud
            presentation.hud = HUDReadout(kind: .brightness, level: 0.62)
            presentation.latestLevel = presentation.hud
        },
        // The satellite only has a seat while the companion rests — the first
        // sweep proved it, by exporting this state byte-for-byte identical to
        // `hud-volume` when it was written as a HUD.
        State(name: "companion-with-timer-satellite") { presentation in
            presentation.phase = .companion
            presentation.nowPlaying = PreviewFixtures.nowPlaying
            presentation.selected = PreviewFixtures.nowPlaying
            presentation.timerSession = PreviewFixtures.timer
        },
        State(name: "companion-with-privacy-satellite") { presentation in
            presentation.phase = .companion
            presentation.nowPlaying = PreviewFixtures.nowPlaying
            presentation.selected = PreviewFixtures.nowPlaying
            presentation.privacyActive = PreviewFixtures.privacy
        },

        // MARK: Open cards
        State(name: "card-music") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.nowPlaying
            presentation.nowPlaying = PreviewFixtures.nowPlaying
            presentation.count = 3
            presentation.selectedIndex = 0
        },
        /// The output list, actually open.
        ///
        /// `routePickerRows` is the card *reporting* how tall its list is, not
        /// a switch that opens it — set alone, it exported the ordinary player
        /// with a band of empty card under it, and the populated picker went
        /// unreviewed. The card opens its list under this environment switch,
        /// which is the seam it already had for exactly this reason.
        State(name: "card-music-routes") { presentation in
            setenv("LEDGE_SHOW_OUTPUTS", "1", 1)
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.nowPlaying
            presentation.nowPlaying = PreviewFixtures.nowPlaying
            presentation.routePickerRows = 3
            presentation.count = 3
        },
        /// The timer with its rule out — the state the card spends its whole
        /// adjustment in, and the one that grows the card by 42pt.
        State(name: "card-timer-editing") { presentation in
            setenv("LEDGE_SHOW_RULER", "1", 1)
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.timerIdle
            presentation.count = 3
            presentation.selectedIndex = 1
        },
        State(name: "card-timer-ready") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.timerIdle
            presentation.count = 3
            presentation.selectedIndex = 1
        },
        State(name: "card-timer-running") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.timer
            presentation.timerSession = PreviewFixtures.timer
            presentation.count = 3
            presentation.selectedIndex = 1
        },
        State(name: "card-timer-finished") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.timerFinished
            presentation.count = 3
        },

        // MARK: Keep Awake
        //
        // Every face the card has, and every sentence it can end on. The
        // finished states are one per reason rather than a representative
        // sample on purpose: each reason is a different sentence, and a
        // sentence nobody has looked at is a sentence that reads wrong.
        State(name: "card-keep-awake-ready") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeReady
            presentation.count = 3
        },
        /// The last minute, when the seconds come back.
        State(name: "card-keep-awake-running-seconds") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeRunning(remaining: 42)
            presentation.count = 3
        },
        /// The ordinary case: hours left, and the label in "1h 12m".
        State(name: "card-keep-awake-running-hours") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeRunning(remaining: 72 * 60 + 3600)
            presentation.count = 3
        },
        /// The assertion was refused. Nothing changed, and the card says so
        /// where the lid line would otherwise be.
        State(name: "card-keep-awake-refused") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeProblem(.assertionRefused)
            presentation.count = 3
        },
        State(name: "card-keep-awake-start-not-saved") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeProblem(.startNotSaved)
            presentation.count = 3
        },
    ] + KeepAwakeEndReason.allCases.filter(\.isVisible).map { reason in
        // One state per reason, built rather than written out: a case added to
        // the enum then arrives in the gallery on its own, instead of being
        // the one sentence nobody remembered to export.
        State(name: "card-keep-awake-finished-\(reason.rawValue)") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeFinished(reason)
            presentation.count = 3
        }
    } + [
        State(name: "card-weather") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.weather
            presentation.count = 3
            presentation.selectedIndex = 2
        },
        State(name: "card-calendar") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
        },
        State(name: "card-shelf") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.shelf
            presentation.count = 3
        },
        State(name: "card-levels") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.levels
            presentation.count = 3
        },
        State(name: "card-device") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.device
            presentation.count = 3
        },
        State(name: "card-focus") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.focus
            presentation.count = 3
        },
        State(name: "card-privacy") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.privacy
            presentation.privacyActive = PreviewFixtures.privacy
            presentation.count = 3
        },
        State(name: "card-keyboard") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keyboard
            presentation.count = 3
        },
        State(name: "card-empty") { presentation in
            presentation.phase = .expanded
            presentation.count = 0
        },

        // MARK: Duo — a card beside a companion
        State(name: "duo-music-and-timer") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.nowPlaying
            presentation.nowPlaying = PreviewFixtures.nowPlaying
            presentation.timerSession = PreviewFixtures.timer
            presentation.count = 3
        },
        // MARK: The states a narrower card is most likely to break

        /// A charger arriving: the strip that stands up under the cutout, one
        /// line, its corners eaten by the shape's radius. Narrow ears move its
        /// edges, so it is exported rather than trusted.
        State(name: "announcement-charging") { presentation in
            // Peek, not companion: the shape only stands up for an
            // announcement in that phase. Written as a companion first, and
            // the export came back a bare strip with nothing in it.
            presentation.phase = .peek
            presentation.peeked = PreviewFixtures.nowPlaying
            presentation.nowPlaying = PreviewFixtures.nowPlaying
            presentation.announcement = NotchAnnouncement(
                title: "Charging",
                symbolName: "bolt.fill",
                accent: AccentColor(red: 0.3, green: 0.78, blue: 0.4)
            )
        },
        /// The longest thing a card ever carries. The title marquees rather
        /// than wrapping, so what this proves is that nothing else on the row
        /// gets pushed out of the card by it.
        State(name: "card-music-long-title") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.longTitleNowPlaying
            presentation.nowPlaying = PreviewFixtures.longTitleNowPlaying
            presentation.count = 3
        },
        State(name: "card-timer-stopwatch") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.stopwatchRunning
            presentation.count = 3
        },
        // `hover` is not in this catalogue. It draws the same card at the same
        // size as `expanded` — the difference between them is whether a click
        // has pinned it, which a still image cannot show. Keeping it meant two
        // states exporting identical bytes, which is the very thing the sweep
        // fails on, and it was right to.

    ]

    static func state(named name: String) -> State? {
        states.first { $0.name == name }
    }

    /// The panel, at the size the shell would give it, with the state already
    /// in place. Hosted rather than described: this is the same view the app
    /// puts on screen.
    static func view(for state: State, mac: Mac) -> some View {
        let geometry = mac.geometry
        let preferences = Preferences(store: MemoryPreferenceStore())
        let presentation = NotchPresentation()
        presentation.fixedNow = clock
        state.apply(presentation)

        return NotchOverlayView(
            geometry: geometry,
            preferences: preferences,
            presentation: presentation,
            nowPlayingActions: NowPlayingActions(outputs: {
                (1...3).map { index in
                    AudioOutputOption(
                        id: UInt32(index), name: "Output \(index)",
                        isCurrent: index == 1, level: 0.6
                    )
                }
            })
        )
        .frame(
            width: NotchLayout.panelSize(for: geometry).width,
            height: NotchLayout.panelSize(for: geometry).height
        )
        // Nothing may animate into place: an export is a still, and a spring
        // caught halfway is a difference between two runs that means nothing.
        // `accessibilityReduceMotion` is read-only in the environment, so the
        // motion is stopped at the source instead: nothing here animates
        // unless a transaction carries an animation, and none does.
        .transaction { $0.animation = nil }
    }
}


extension PreviewFixtures {

    /// The length the card opens on, and the floor it would end at: the
    /// shipped defaults, so the gallery shows what a new install does.
    private static let keepAwakeMinutes = 60
    private static let keepAwakeFloor = 15

    /// The wall-clock end time, fixed like every other clock read in the
    /// gallery — the shell formats this for the user's locale, and an export
    /// that differs from yesterday's for that reason is a diff nobody reads.
    private static let keepAwakeUntil = "17:40"

    static let keepAwakeReady = keepAwake(KeepAwakePayload(
        phase: .ready,
        minutes: keepAwakeMinutes,
        batteryFloor: keepAwakeFloor
    ))

    static func keepAwakeRunning(remaining: TimeInterval) -> Activity {
        keepAwake(KeepAwakePayload(
            phase: .running,
            remaining: remaining,
            until: keepAwakeUntil,
            minutes: keepAwakeMinutes,
            batteryFloor: keepAwakeFloor
        ))
    }

    static func keepAwakeProblem(_ problem: KeepAwakePayload.Problem) -> Activity {
        keepAwake(KeepAwakePayload(
            phase: .ready,
            minutes: keepAwakeMinutes,
            batteryFloor: keepAwakeFloor,
            problem: problem
        ))
    }

    static func keepAwakeFinished(_ reason: KeepAwakeEndReason) -> Activity {
        keepAwake(KeepAwakePayload(
            phase: .finished(reason),
            until: keepAwakeUntil,
            minutes: keepAwakeMinutes,
            batteryFloor: keepAwakeFloor,
            // Phase 1 never holds the lid, so the thermal sentence exported
            // here is the one a shipping build can actually produce.
            lidClosed: false,
            // Only the user's own End offers Resume, so only that state gets
            // the two-button row.
            resumable: reason.isUserCancellation ? 72 * 60 : nil
        ))
    }

    /// The source is the reason, so two finished states can sit in one
    /// presentation without deduplicating each other.
    private static func keepAwake(_ payload: KeepAwakePayload) -> Activity {
        let source: String
        switch payload.phase {
        case .ready: source = payload.problem.map { "ready-\($0)" } ?? "ready"
        case .running: source = "running"
        case .finished(let reason): source = "finished-\(reason.rawValue)"
        }
        return Activity(
            id: ActivityID(kind: .keepAwake, source: "preview.\(source)"),
            createdAt: 0,
            payload: .keepAwake(payload)
        )
    }
}
