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
    static let clock = PreviewClock.fixed

    struct State {
        let name: String
        /// Applied to a fresh presentation. Everything the state needs is set
        /// here, before the first render, so nothing animates into place.
        let apply: (NotchPresentation) -> Void
    }

    /// One per lid-closed state, built rather than written out, for the same
    /// reason the finished states are: each is a different sentence, and a
    /// sentence nobody has looked at is a sentence that reads wrong. These are
    /// the ones that most need looking at — a refusal truncated on a card 275
    /// points wide has told the user nothing.
    ///
    /// Its own property rather than another term in the gallery's `+` chain:
    /// the type checker gives up on that expression once it gets long enough.
    private static let keepAwakeLidStates: [State] = {
        // Only what a running card draws. "Not set up" and "waiting for
        // approval" are about the app rather than this session, so
        // `belongsOnARunningCard` keeps them off it — and a gallery state that
        // draws nothing of its own is two identical exports, which is the one
        // thing the sweep refuses to produce. They are drawn on the resting
        // card below, which is the card they belong to.
        let lids: [KeepAwakeLidState] = [.holding, .unconfirmed, .unreachable]
            + KeepAwakeLidCode.allCases.map { KeepAwakeLidState.refused($0) }
        return lids.map { lid in
            State(name: "card-keep-awake-lid-\(lid.name)") { presentation in
                presentation.phase = .expanded
                presentation.selected = PreviewFixtures.keepAwakeLid(lid)
                presentation.count = 3
            }
        }
    }()

    /// The lid-closed mode's states on the card somebody meets before they
    /// have started anything.
    ///
    /// The lid sweep above is all running cards, which is where these
    /// sentences were first drawn — and it meant the resting face was only
    /// ever looked at in one state, `off`. The resting face is where the two
    /// states that wait to be reached for are reached for, where a standing
    /// failure from an earlier session can sit beside a lid sentence, and
    /// where a press that cannot start anything has to say why. None of that
    /// was in the gallery at all.
    ///
    /// Only the states that speak without being asked. The three that wait
    /// for the press — not set up, waiting for approval, unsigned build — draw
    /// exactly `card-keep-awake-ready` until it happens, and the press is view
    /// state the gallery cannot reach through a payload. Those three are drawn
    /// and measured after the press in `KeepAwakeLidRenderTests` instead,
    /// which is the one place that can press them.
    private static let keepAwakeRestingStates: [State] = {
        let lids: [KeepAwakeLidState] = [.unreachable, .unconfirmed]
            + KeepAwakeLidCode.allCases.map { KeepAwakeLidState.refused($0) }
        return lids.map { lid in
            State(name: "card-keep-awake-resting-\(lid.name)") { presentation in
                presentation.phase = .expanded
                presentation.selected = PreviewFixtures.keepAwakeResting(lid)
                presentation.count = 3
            }
        }
    }()

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
        /// Notes. The card had no state here at all, so none of its faces
        /// was in the suite — the first thing anybody reading it found.
        State(name: "card-notes-empty") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.notesCard(count: 0)
            presentation.count = 3
        },
        /// One note: no list and no count, because with nothing hidden there
        /// is nothing to open All for.
        State(name: "card-notes-one") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.notesCard(count: 1)
            presentation.count = 3
        },
        State(name: "card-notes-twelve") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.notesCard(count: 12)
            presentation.count = 3
        },
        /// Three hundred, at the same height as twelve. Only the count grows.
        State(name: "card-notes-many") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.notesCard(count: 312)
            presentation.count = 3
        },
        /// Marked where it sits, with the window's own amber. The order does
        /// not change to bring it to the top.
        State(name: "card-notes-open") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.notesCard(count: 312, open: 2)
            presentation.count = 3
        },
        /// A note with no first line yet: Untitled in the window's muted ink,
        /// with its own words under it so it can still be recognised.
        State(name: "card-notes-untitled") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.notesCard(count: 312, untitledLead: true)
            presentation.count = 3
        },
        /// Long titles and other scripts. Titles give way; times never do.
        State(name: "card-notes-long-titles") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.notesCard(count: 312, longTitles: true)
            presentation.count = 3
        },
        /// The plain switch, on: the whole of what a hold with no end has to
        /// say for itself. Drawn because this face is nearly empty by design,
        /// and nearly empty is where a sentence that matters goes missing.
        State(name: "card-keep-awake-holding") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeHolding()
            presentation.count = 3
        },
        /// The same face with the daemon gone quiet under it.
        State(name: "card-keep-awake-holding-unreachable") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeHolding(lid: .unreachable)
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
    } + keepAwakeLidStates + keepAwakeRestingStates + [

        /// A standing failure from an earlier session, with the lid-closed
        /// mode's own reason beside it. This is the picture the old card could
        /// not draw: the two shared one line, the failure took it, and
        /// pressing Lid closed did nothing visible at all.
        State(name: "card-keep-awake-resting-problem-and-lid") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.keepAwakeResting(
                .refused(.foreign), problem: .tooManyUnsaved
            )
            presentation.count = 3
        },

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

        /// The self-view, face by face. One export each, because each is a
        /// different sentence in the same 126pt frame, and a sentence nobody
        /// has looked at is a sentence that reads wrong — a truncated refusal
        /// has told the user nothing.
        ///
        /// The picture itself is the only drawn stand-in in the gallery:
        /// `ImageRenderer` cannot photograph a live capture layer, and a
        /// photograph of somebody's face is not something to keep in a
        /// repository. Every other point of these cards is the real card.
        /// macOS's own dialog is up, and the frame holds the notch open while the pointer travels to it.
        State(name: "card-calendar-asking") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
            presentation.selfView = SelfViewPayload(phase: .asking)
        },
        /// Past the six tenths of a second that buys silence, so the sentence is there.
        State(name: "card-calendar-waking") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
            presentation.selfView = SelfViewPayload(phase: .waking, waitHasLasted: true)
        },
        /// Mirrored, edge to edge, with the frame's corner sat concentric inside the card's own.
        State(name: "card-calendar-live") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
            presentation.selfView = SelfViewPayload(phase: .live)
        },
        /// A minute away, with ten seconds of it left.
        State(name: "card-calendar-closing") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
            presentation.selfView = SelfViewPayload(phase: .live, countdown: 8)
        },
        /// The one action worth offering: the pane in System Settings that undoes it.
        State(name: "card-calendar-refused") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
            presentation.selfView = SelfViewPayload(phase: .refused)
        },
        /// A profile decided. Nothing to offer, so nothing is offered.
        State(name: "card-calendar-blocked") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
            presentation.selfView = SelfViewPayload(phase: .blocked)
        },
        /// No built-in front camera. Ledge will not fall back to an iPhone on the desk.
        State(name: "card-calendar-nocamera") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
            presentation.selfView = SelfViewPayload(phase: .noCamera)
        },
        /// Five seconds and no frame. The session is already stopped when this is drawn.
        State(name: "card-calendar-failed") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.event
            presentation.count = 3
            presentation.selfView = SelfViewPayload(phase: .failed)
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
        /// Turned all the way down: a plain speaker, an empty line, the number
        /// nought. Nothing red. The glyph used to be the struck speaker here,
        /// so the card drew mute at a level of zero.
        State(name: "card-levels-zero") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.levelsCard(volume: 0, tag: "zero")
            presentation.count = 3
        },
        /// Muted at 55: the red capsule and the word, with the line held at
        /// the level unmuting goes back to.
        State(name: "card-levels-muted") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.levelsCard(muted: true, tag: "muted")
            presentation.count = 3
        },
        /// An external display: its line has a hatched start, because Ledge
        /// dims the picture rather than the backlight and below 18% it cannot
        /// go.
        State(name: "card-levels-external") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.levelsCard(external: true, tag: "external")
            presentation.count = 3
        },
        /// A change macOS refused. The line is back at what the device
        /// reports, and the row says why.
        State(name: "card-levels-refused") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.levelsCard(note: .refused, tag: "refused")
            presentation.count = 3
        },
        /// A fixed-volume output and an unreadable panel together: no lines to
        /// drag, two dashed rules, two sentences.
        State(name: "card-levels-nothing-to-drag") { presentation in
            presentation.phase = .expanded
            presentation.selected = PreviewFixtures.levelsCard(
                volume: nil, brightness: nil, tag: "nothing"
            )
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

    // MARK: - Levels
    //
    // The card used to ignore its payload and read devices through its
    // actions, so the preview supplied none and every photograph of it showed
    // two empty bars named Sound and Display. These are rows.

    static func levelRows(
        volume: Double? = 0.55,
        muted: Bool = false,
        external: Bool = false,
        note: LevelRow.Note? = nil,
        brightness: Double? = 0.8
    ) -> [LevelRow] {
        var rows: [LevelRow] = []
        if let volume {
            rows.append(LevelRow(
                id: "sound", kind: .sound, name: "MacBook Pro Speakers",
                control: .level(volume), isMuted: muted,
                canMute: true, note: note
            ))
        } else {
            rows.append(LevelRow(
                id: "sound", kind: .sound, name: "LG HDR 4K",
                control: .fixed, note: .fixedElsewhere
            ))
        }
        if let brightness {
            rows.append(LevelRow(id: "display-1", kind: .display,
                                 name: "Built-in Display", control: .level(brightness)))
        } else {
            rows.append(LevelRow(id: "display-1", kind: .display,
                                 name: "Built-in Display", control: .unreadable,
                                 note: .unreadable))
        }
        if external {
            rows.append(LevelRow(
                id: "display-2", kind: .display, name: "Dell U2723QE",
                control: .level(0.6), floor: 0.18, note: .gamma(floor: 0.18)
            ))
        }
        return rows
    }

    // MARK: - Notes
    //
    // The card had no gallery state at all, so none of its faces was in the
    // suite and none of them had ever been looked at. These are the ones that
    // are awkward to click your way to.

    /// A collection of the size somebody actually keeps. The card is the same
    /// height here as it is at three notes; only the count grows.
    static func notesCard(count: Int, open: Int? = nil,
                          untitledLead: Bool = false,
                          longTitles: Bool = false) -> Activity {
        var notes = (0 ..< count).map { i -> NoteSummary in
            NoteSummary(
                id: "n\(i)",
                title: notesTitles[i % notesTitles.count],
                preview: notesPreviews[i % notesPreviews.count],
                editedAt: notesNow - notesAges[min(i, notesAges.count - 1)]
            )
        }
        if untitledLead, !notes.isEmpty {
            notes[0] = NoteSummary(id: "u", title: "", preview: notesPreviews[1],
                                   editedAt: notesNow - 240)
        }
        if longTitles, notes.count > 2 {
            notes[0] = NoteSummary(
                id: "l0",
                title: "Toplantı notları: Çarşamba öğleden sonra bütçe ve işe alım",
                preview: "Bütçe onaylandı, işe alım ikinci çeyreğe kaldı.",
                editedAt: notesNow - 540
            )
            notes[1] = NoteSummary(id: "l1", title: "Café crème, déjà vu, and the naïve résumé",
                                   editedAt: notesNow - 3 * 3600)
        }
        return Activity(
            id: ActivityID(kind: .notes, source: "preview.notes-\(count)-\(open ?? -1)"),
            createdAt: 0,
            payload: .notes(NotesPayload(
                notes: notes,
                openNoteID: open.flatMap { notes.indices.contains($0) ? notes[$0].id : nil }
            ))
        )
    }

    /// Relative to the moment the gallery runs, not a fixed instant.
    ///
    /// A fixed timestamp made every age wrong: the card reads the real clock,
    /// so "two hours ago" photographed as a date from months back. The
    /// pictures differ a little between runs in exchange for every label
    /// saying the thing it was chosen to say.
    static var notesNow: TimeInterval { Date().timeIntervalSince1970 }
    private static let notesAges: [TimeInterval] = [
        2 * 3600, 26 * 3600, 3 * 86400, 9 * 86400, 40 * 86400, 400 * 86400
    ]
    private static let notesTitles = [
        "Groceries for Saturday", "Flight to Istanbul, TK 1979",
        "Questions for the landlord", "Q3 planning, Thursday call", "Book list",
        "Wi-Fi at the studio"
    ]
    private static let notesPreviews = [
        "Milk, eggs, the good olive oil, lemons, and whatever bread is still warm.",
        "Call back about the parcel — it went to the wrong door again.",
        "Boiler service date? Who pays for the window?",
        "Three things to agree: the date, who owns the migration, what we drop.",
        "The Dispossessed, A Fine Balance, Piranesi again.",
        "Network: studio-5g. The password is on the router."
    ]


    /// The length the card opens on, and the floor it would end at: the
    /// shipped defaults, so the gallery shows what a new install does.
    private static let keepAwakeMinutes = 60
    private static let keepAwakeFloor = 15

    /// The wall-clock end time, fixed like every other clock read in the
    /// gallery — the shell formats this for the user's locale, and an export
    /// that differs from yesterday's for that reason is a diff nobody reads.
    private static let keepAwakeUntil = "17:40"

    /// The ordinary resting card: helper installed, nothing held. `.off`
    /// rather than the type's default, because the default is "no helper" and
    /// drawing the common case as the unhappy one is how a dimmed switch went
    /// unnoticed.
    static let keepAwakeReady = keepAwake(KeepAwakePayload(
        phase: .ready,
        minutes: keepAwakeMinutes,
        batteryFloor: keepAwakeFloor,
        lid: .off
    ))

    /// The plain switch, on. No deadline, so no time — the face the 34pt
    /// counting-up stopwatch used to occupy.
    static func keepAwakeHolding(lid: KeepAwakeLidState = .notInstalled) -> Activity {
        Activity(
            id: ActivityID(kind: .keepAwake, source: "preview.holding-\(lid.name)"),
            createdAt: 0,
            payload: .keepAwake(KeepAwakePayload(
                phase: .running,
                remaining: 0,
                held: 37 * 60,
                isIndefinite: true,
                minutes: keepAwakeMinutes,
                batteryFloor: keepAwakeFloor,
                lid: lid
            ))
        )
    }

    /// A hold with a deadline — which now means the lid-closed mode, and only
    /// it. The plain switch holds until it is switched off, so a running
    /// session with a time left on it is always this one.
    static func keepAwakeRunning(remaining: TimeInterval) -> Activity {
        keepAwake(KeepAwakePayload(
            phase: .running,
            remaining: remaining,
            until: keepAwakeUntil,
            minutes: keepAwakeMinutes,
            batteryFloor: keepAwakeFloor,
            lidHeld: true,
            lidClosed: true,
            lid: .holding
        ))
    }

    /// A running session with the lid-closed mode in a given state.
    ///
    /// Running rather than ready because that is where every one of these
    /// sentences appears without being reached for, and because a hold that
    /// is being held is the case the sentences are about.
    static func keepAwakeLid(_ state: KeepAwakeLidState) -> Activity {
        Activity(
            id: ActivityID(kind: .keepAwake, source: "preview.lid-\(state.name)"),
            createdAt: 0,
            payload: .keepAwake(KeepAwakePayload(
                phase: .running,
                remaining: 2 * 3600,
                until: keepAwakeUntil,
                minutes: keepAwakeMinutes,
                batteryFloor: keepAwakeFloor,
                lidHeld: state.isConfirmed,
                lidClosed: true,
                lid: state
            ))
        )
    }

    /// The resting card, with the lid-closed mode in a given state — and,
    /// when there is one, a standing failure from an earlier session beside
    /// it. The two used to share a line.
    static func keepAwakeResting(
        _ state: KeepAwakeLidState,
        problem: KeepAwakePayload.Problem? = nil
    ) -> Activity {
        Activity(
            id: ActivityID(kind: .keepAwake,
                           source: "preview.resting-\(state.name)-\(problem?.rawValue ?? "none")"),
            createdAt: 0,
            payload: .keepAwake(KeepAwakePayload(
                phase: .ready,
                minutes: keepAwakeMinutes,
                batteryFloor: keepAwakeFloor,
                lidHeld: state.isConfirmed,
                lid: state,
                problem: problem
            ))
        )
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
