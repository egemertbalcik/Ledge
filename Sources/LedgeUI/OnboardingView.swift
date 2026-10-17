import LedgeCore
import SwiftUI

/// The welcome tour: four steps, hung under the notch, two of them done
/// rather than read.
///
/// The window sits directly under the thing it is teaching, so the steps can
/// point upwards instead of drawing a miniature of it. Hover and Drop are the
/// two facts about Ledge that nothing else can teach — the notch says nothing
/// about itself until it is touched — so those two steps watch the real notch
/// and say when they saw you. Neither ever blocks: a step that would not move
/// until you hovered traps anybody with VoiceOver, a broken trackpad, or
/// Ledge on another display, so Continue is live from the first second.
///
/// Permissions is the same row the Permissions pane draws, from
/// `PermissionPresentation.face`, with the same guide under it while somebody
/// is out granting one. Done says what Ledge does with your things, and is
/// the one page in the app whose whole job is to be true.
public struct OnboardingView: View {

    /// The content size. The window is pinned to it: a step must not be able
    /// to resize the window under the reader.
    ///
    /// 660 holds six unanswered permission rows without the scroll that used
    /// to hide one and a half of them, and still leaves room under the menu
    /// bar on the smallest notched screen.
    public static let contentSize = CGSize(width: 540, height: 660)

    private let model: SettingsModel
    private let actions: SettingsActions
    private let openSettings: () -> Void
    private let openCards: () -> Void
    private let openSource: () -> Void
    private let finish: () -> Void

    /// Whether this is somebody coming back to look something up rather than
    /// a first launch.
    ///
    /// A second visit is a lookup — "how did I get Accessibility back?" — so
    /// the steps become tabs that can be jumped between, nothing is written
    /// down, and Done plays no welcome. Making somebody click through Hover
    /// and Drop again to reach Permissions is a toll.
    private let isReturnVisit: Bool

    /// Whether this Mac has a notch of its own. Without one Ledge draws its
    /// own at the top of the screen, which is worth saying once rather than
    /// letting somebody hunt for a notch that isn't there.
    private let hasBuiltInNotch: Bool

    @State private var step: TourStep

    /// What the two do-it steps have seen the real notch do.
    @State private var progress = TourProgress()

    /// The subscription to the real notch, for as long as the tour is up.
    ///
    /// Held for the whole tour rather than per step: the signals cost nothing,
    /// and somebody who hovers while reading step three should find step one
    /// already answered when they go back to it, not waiting.
    @State private var stopWatching: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: SettingsModel,
        actions: SettingsActions,
        openSettings: @escaping () -> Void,
        openSource: @escaping () -> Void,
        finish: @escaping () -> Void,
        openCards: (() -> Void)? = nil,
        isReturnVisit: Bool = false,
        startStep: TourStep = .hover,
        hasBuiltInNotch: Bool = true
    ) {
        // A debug launch can open straight onto a step, so each can be
        // reviewed without clicking through the tour.
        let debug = Int(DebugSwitches.value("LEDGE_ONBOARDING_PAGE") ?? "")
        _step = State(initialValue: TourStep(rawValue: debug ?? startStep.rawValue) ?? .hover)
        self.model = model
        self.actions = actions
        self.openSettings = openSettings
        self.openCards = openCards ?? openSettings
        self.openSource = openSource
        self.finish = finish
        self.isReturnVisit = isReturnVisit
        self.hasBuiltInNotch = hasBuiltInNotch
    }

    public var body: some View {
        VStack(spacing: 0) {
            pointer

            // Every step gets the same box, and the footer never moves:
            // buttons that shift under the pointer between steps are the one
            // thing a wizard must not do. Content that does not fit scrolls.
            ScrollView(.vertical) {
                Group {
                    switch step {
                    case .hover: hover
                    case .drop: drop
                    case .permissions: permissions
                    case .done: done
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Said rather than hidden. macOS hides scroll bars by default, so
            // on a Mac with every permission still unanswered the old tour
            // simply cut the last row and a half off with nothing to say that
            // there was more; the bar is asked for, and flashed on arrival.
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .frame(height: 56)
                .padding(.horizontal, 28)
                .background(.bar)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: step)
        .onAppear {
            // One subscription for the tour's life, torn down on the way out.
            // Replacing an existing one would leak the first.
            if stopWatching == nil {
                stopWatching = actions.observeNotch { signal in progress.saw(signal) }
            }
            actions.tourStep(step)
        }
        .onChange(of: step) { _, now in actions.tourStep(now) }
        .onDisappear {
            stopWatching?()
            stopWatching = nil
            actions.tourStep(nil)
        }
    }

    // MARK: - The steps

    /// Points up at the notch, from directly under it.
    private var pointer: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .semibold))
            Text(hasBuiltInNotch ? TourCopy.pointer : TourCopy.pointerNoNotch)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .accessibilityAddTraits(.isHeader)
    }

    private var hover: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(TourCopy.hoverTitle)
            body(hasBuiltInNotch ? TourCopy.hoverBody : TourCopy.hoverBodyNoNotch)

            tryIt(
                ask: TourCopy.hoverAsk,
                note: TourCopy.hoverAskNote,
                waiting: TourCopy.hoverWaiting,
                done: TourCopy.hoverDone,
                isDone: progress.hoverIsDone
            )

            VStack(alignment: .leading, spacing: 8) {
                more("cursorarrow.click", TourCopy.hoverClick)
                more("hand.draw", TourCopy.hoverSwipe)
            }
        }
    }

    private var drop: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(TourCopy.dropTitle)
            body(TourCopy.dropBody)

            tryIt(
                ask: TourCopy.dropAsk,
                note: TourCopy.dropAskNote,
                waiting: TourCopy.dropWaiting,
                done: TourCopy.dropDone,
                isDone: progress.dropIsDone
            )
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(TourCopy.permissionsTitle)
            body(TourCopy.permissionsBody)

            if model.isLaunchedFromTerminal {
                terminalBanner
            }

            // While somebody is out granting one, the guide takes the list's
            // place. The rest of the list is noise next to the one switch
            // they are looking for in another application — and the row they
            // pressed stays at the top of it, saying what it is waiting for.
            if let handoff = model.handoff {
                // The row carries the guide itself — it is the same row the
                // Permissions pane draws, and the guide opens inside it.
                // Adding a second one here drew two diagrams, two tiles and
                // two Copy Location buttons.
                PermissionGrantRow(
                    kind: handoff.kind, model: model, actions: actions, namesItsCards: false
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(model.permissions) { row in
                        // The cards each permission unblocks are not named
                        // here: the step after this one is about cards, and
                        // six rows with a second sentence each is what pushed
                        // the list past the window.
                        PermissionGrantRow(
                            kind: row.kind, model: model, actions: actions, namesItsCards: false
                        )
                        .padding(.vertical, 9)
                        if row.kind != model.permissions.last?.kind {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                SettingsNote(TourCopy.permissionsFooter)
            }
        }
        // Read once on arrival. The coordinator's own watch covers a grant
        // made while this is up; the two-second poll that used to run here
        // built and tore down a key tap every two seconds beside it.
        .onAppear { actions.refreshPermissions() }
    }

    /// Everything granted now would be credited to the terminal instead of to
    /// Ledge, which looks exactly like a denial. Said above the list, with
    /// the way out beside it.
    private var terminalBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Ledge was launched from a terminal.")
                    .font(.system(size: 12, weight: .medium))
                SettingsNote("""
                    macOS credits a permission to the app that launched Ledge, so \
                    anything granted now attaches to your terminal instead, which looks \
                    exactly like a denial. Quit and open Ledge from Finder before granting.
                    """)
                Button("Quit Ledge") { actions.quit() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            title(TourCopy.doneTitle)

            VStack(alignment: .leading, spacing: 8) {
                more("cursorarrow.motionlines", TourCopy.doneHover)
                more("tray.and.arrow.down", TourCopy.doneDrop)
                more("gearshape", TourCopy.doneSettings)
            }

            Divider()

            // The one page in the app whose whole job is to be true. Three of
            // its four claims were wrong for months: there is capture code
            // (the Calendar card's mirror), the calendar is read for more
            // than titles and times (the meeting link), and more than
            // settings and shelf paths is written (notes, devices, the Keep
            // Awake log).
            Text(TourCopy.privacyTitle)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                more("camera", TourCopy.privacyCamera)
                more("calendar", TourCopy.privacyCalendar)
                more("network", TourCopy.privacyNetwork)
                more("internaldrive", TourCopy.privacyDisk)
            }

            HStack(spacing: 10) {
                Button(TourCopy.chooseCards) { openCards() }
                Button(TourCopy.readSource) { openSource() }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    // MARK: - Pieces

    /// A step that is done by doing it, with what the notch has been seen to
    /// do. Never a gate: the footer's Continue is live throughout.
    @ViewBuilder
    private func tryIt(
        ask: String,
        note: String,
        waiting: String,
        done: String,
        isDone: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ask)
                .font(.system(size: 13, weight: .medium))
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // On a second visit nothing waits: the point of coming back is to
            // look something up, not to perform it again.
            if isReturnVisit && !isDone {
                Text(TourCopy.hoverAgain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(isDone ? Color.green : Color.secondary)
                    Text(isDone ? done : waiting)
                        .font(.system(size: 12, weight: isDone ? .medium : .regular))
                        .foregroundStyle(isDone ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func body(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func more(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The footer

    /// Fixed slots, because the words change and the positions must not.
    private static let buttonWidth: CGFloat = 84

    private var footer: some View {
        HStack(spacing: 12) {
            steps
            Spacer(minLength: 12)

            Button(TourCopy.back) { step = step.previous ?? .hover }
                .frame(width: Self.buttonWidth)
                .disabled(step == .hover)

            if let next = step.next {
                Button(TourCopy.next) { step = next }
                    .frame(width: Self.buttonWidth)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(TourCopy.done) { finish() }
                    .frame(width: Self.buttonWidth)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    /// The step names are the indicator: a real sequence, numbered. On a
    /// second visit they are also the way between steps.
    private var steps: some View {
        HStack(spacing: 10) {
            ForEach(TourStep.allCases, id: \.self) { each in
                let isHere = each == step
                let label = HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(isHere ? Color.accentColor : Color.primary.opacity(0.10))
                            .frame(width: 15, height: 15)
                        Text("\(each.number)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isHere ? Color.white : Color.secondary)
                    }
                    Text(each.name)
                        .font(.system(size: 11.5, weight: isHere ? .medium : .regular))
                        .foregroundStyle(isHere ? Color.primary : Color.secondary)
                }
                if isReturnVisit {
                    Button { step = each } label: { label }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Step \(each.number), \(each.name)")
                } else {
                    label
                }
            }
        }
        .accessibilityElement(children: isReturnVisit ? .contain : .ignore)
        .accessibilityLabel(isReturnVisit ? "Steps" : "Step \(step.number) of \(TourStep.allCases.count), \(step.name)")
    }
}
