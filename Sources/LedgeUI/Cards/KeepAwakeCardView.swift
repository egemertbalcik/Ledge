import LedgeCore
import SwiftUI

/// The Keep Awake card: one surface with three faces.
///
/// Ready is a launcher — a length to set and a Start — and it wears the timer
/// card's own instrument for the length, because dragging a number sideways is
/// already how a duration is set in this app and a second way to do it would
/// be a second thing to learn. Running is the Live Activity shape the timer
/// uses: what is left, what time that is, and the one button that stops it.
/// Finished is a sentence and the two things that follow it.
///
/// Nothing here is said in colour alone. The tint marks Keep Awake's identity,
/// never its state: whether a session is running, over, or refused is always
/// written out — which is what makes the card readable with Increase Contrast
/// on, and the only version of it worth shipping anyway.
public struct KeepAwakeCardView: View {

    private let payload: KeepAwakePayload
    private let actions: KeepAwakeActions
    private let isCompactWidth: Bool

    /// The length on the Ready card. Seeded from the payload — which carries
    /// the user's own default — and kept afterwards, so a length chosen and
    /// not yet started is still theirs when the card comes back.
    @State private var minutes: Int
    /// The value the drag started from, and whether Option is down. Held apart
    /// from `minutes` so the whole drag is one movement from where it began
    /// rather than a chain of relative nudges that drift. Same seam the timer's
    /// scrub has, for the same reason.
    @State private var scrubAnchor: Int?
    @State private var isFineScrubbing = false
    @State private var hold = CardHold()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        payload: KeepAwakePayload,
        actions: KeepAwakeActions = KeepAwakeActions(),
        isCompactWidth: Bool = false
    ) {
        self.payload = payload
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        _minutes = State(initialValue: KeepAwakeReducer.clamp(minutes: payload.minutes))
    }

    /// Keep Awake's own tan. Warm rather than alarming: nothing is wrong when
    /// this card is up, the Mac is simply being held open.
    static let tint = Color(red: 0.72, green: 0.56, blue: 0.38)

    public var body: some View {
        content
            // A drag that was still latched when the card went away left the
            // notch held open by a control that no longer exists. The latch is
            // the shell's, so only the shell can let it go — and the card
            // disappearing is the last moment it can say so.
            .onDisappear {
                hold.release()
                actions.setDragging(false)
            }
    }

    @ViewBuilder private var content: some View {
        if isCompactWidth {
            compact
        } else {
            switch payload.phase {
            case .ready: ready
            case .running: running
            case .finished(let reason): finished(reason)
            }
        }
    }

    // MARK: - Ready

    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    Text(KeepAwakeCopy.title)
                        .font(.cardFigure)
                        .foregroundStyle(Self.tint)
                        .lineLimit(1)
                    Text(readyLine)
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                length
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(KeepAwakeCopy.title), ready")
            .accessibilityValue("\(Self.spoken(TimeInterval(minutes * 60))). \(readyLine)")
            .accessibilityAdjustableAction { direction in
                // VoiceOver's own way of changing a value, so the length is
                // reachable without the drag the sighted card is built around.
                nudge(by: direction == .increment ? 1 : -1)
            }

            HStack(spacing: 8) {
                CardCapsuleButton(KeepAwakeCopy.start, tint: Self.tint) {
                    hold.release()
                    actions.setDragging(false)
                    actions.start(minutes)
                }
            }
        }
    }

    /// What the Ready card says under the title: whatever went wrong last
    /// time, else what closing the lid will do.
    ///
    /// A failure outranks the standing line because it is the answer to the
    /// question the user is about to ask — they pressed Start and nothing
    /// happened.
    private var readyLine: String {
        switch payload.problem {
        case .assertionRefused: KeepAwakeCopy.assertionRefused
        case .startNotSaved: KeepAwakeCopy.startNotSaved
        case .tooManyUnsaved: KeepAwakeCopy.tooManyUnsaved
        case .journalUnreadable: KeepAwakeCopy.journalUnreadable
        case nil:
            payload.lidHeld
                ? KeepAwakeCopy.readyLidHeld(floor: payload.batteryFloor)
                : KeepAwakeCopy.readyLidOpen
        }
    }

    /// The length, as the control that sets it: put the pointer on the number
    /// and drag sideways. The timer card's gesture, unchanged.
    private var length: some View {
        Text(SatelliteContent.keepAwakeLabel(remaining: TimeInterval(minutes * 60)))
            .font(.system(size: 42, weight: .light, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Self.tint)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentShape(Rectangle())
            .gesture(scrub)
            .onModifierKeysChanged(mask: .option) { _, new in
                isFineScrubbing = new.contains(.option)
            }
    }

    private var scrub: some Gesture {
        // Zero minimum distance, like the timer's: a number that ignores the
        // first of a drag reads as stuck rather than as precise.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if scrubAnchor == nil {
                    scrubAnchor = minutes
                    // Latches the shell's hover so the card cannot close under
                    // a pointer that has wandered off it mid-drag.
                    if hold.hold() { actions.setDragging(true) }
                }
                // Clamped through the reducer afterwards rather than inside
                // Keep Awake's own span, not the timer's. The shared ladder
                // stops at three hours, which would have made a day-long
                // session undialable while the card advertised twenty-four.
                let landed = KeepAwakeReducer.clamp(minutes: DurationScrub.minutes(
                    anchor: scrubAnchor ?? minutes,
                    translation: value.translation.width,
                    fine: isFineScrubbing,
                    range: KeepAwakeReducer.minimumMinutes ... KeepAwakeReducer.maximumMinutes
                ))
                guard landed != minutes else { return }
                setMinutes(landed)
                // One tick per detent, which is what makes a scrubbed number
                // feel like a dial with stops rather than a value sliding.
                actions.haptic()
            }
            .onEnded { _ in
                scrubAnchor = nil
                hold.release()
                actions.setDragging(false)
            }
    }

    private func setMinutes(_ landed: Int) {
        withAnimation(reduceMotion ? nil : Motion.levelChange) { minutes = landed }
    }

    private func nudge(by delta: Int) {
        let landed = KeepAwakeReducer.clamp(minutes: minutes + delta)
        guard landed != minutes else { return }
        setMinutes(landed)
    }

    // MARK: - Running

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    Text(KeepAwakeCopy.title)
                        .font(.cardFigure)
                        .foregroundStyle(Self.tint)
                        .lineLimit(1)
                    // The wall-clock time the hold ends. The countdown alone
                    // says how long, not until when, and "until when" is the
                    // thing somebody checks before walking away from the Mac.
                    Text(KeepAwakeCopy.runningUntil(payload.until))
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                // Nothing sweeps or drains here. A keep-awake has no progress
                // worth watching — it is a condition, not a race — so the
                // label simply changes as the minutes go, which is also the
                // whole of what Reduce Motion would have asked for.
                Text(SatelliteContent.keepAwakeLabel(remaining: payload.remaining))
                    .font(.system(size: 42, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Self.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(KeepAwakeCopy.title), running")
            .accessibilityValue(
                "\(Self.spoken(payload.remaining)) left, \(KeepAwakeCopy.runningUntil(payload.until).lowercased())"
            )

            HStack(spacing: 8) {
                CardCapsuleButton(KeepAwakeCopy.end, tint: Self.tint) { actions.end() }
            }
        }
    }

    // MARK: - Finished

    private func finished(_ reason: KeepAwakeEndReason) -> some View {
        let sentence = KeepAwakeCopy.finished(
            reason,
            at: payload.until,
            floor: payload.batteryFloor,
            lidClosed: payload.lidClosed
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    Text(KeepAwakeCopy.title)
                        .font(.cardFigure)
                        .foregroundStyle(Self.tint)
                        .lineLimit(1)
                    Text(sentence)
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    // Said before it can surprise anyone: a relaunch may bring
                    // this session back, and being told that now is the whole
                    // difference between a quirk and a fault.
                    if payload.endUnrecorded {
                        Text(KeepAwakeCopy.endNotSaved(until: payload.until))
                            .font(.cardCaption)
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(KeepAwakeCopy.title), finished")
            .accessibilityValue(payload.endUnrecorded
                ? "\(sentence) \(KeepAwakeCopy.endNotSaved(until: payload.until))"
                : sentence)

            // Resume never arrives alone. It is offered only after the user's
            // own End, which is exactly the case where they may have meant it
            // — so the card still has to be dismissible, and Done keeps the
            // quieter seat the finished timer gives Repeat.
            HStack(spacing: 8) {
                if let resumable = payload.resumable {
                    CardCapsuleButton(KeepAwakeCopy.done, tint: nil) { actions.dismiss() }
                    CardCapsuleButton(
                        KeepAwakeCopy.resumeButton(
                            remaining: SatelliteContent.keepAwakeLabel(remaining: resumable)
                        ),
                        tint: Self.tint
                    ) { actions.resume() }
                } else {
                    CardCapsuleButton(KeepAwakeCopy.done, tint: Self.tint) { actions.dismiss() }
                }
            }
        }
    }

    // MARK: - Duo

    /// The duo-width card: what it is and what is left, and nothing to press.
    /// Half a card has no room for a control row, and the full card is one
    /// click away.
    private var compact: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.tint)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(KeepAwakeCopy.title)
                    .font(.cardSmallFigure)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Text(compactLine)
                    .font(.system(size: 17, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Self.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var compactLine: String {
        switch payload.phase {
        case .ready: SatelliteContent.keepAwakeLabel(remaining: TimeInterval(minutes * 60))
        case .running: SatelliteContent.keepAwakeLabel(remaining: payload.remaining)
        // "Ended", not a blank or a zero: half a card is still a card, and a
        // keep-awake that has stopped is the one fact worth the space.
        case .finished: KeepAwakeCopy.finished(.endedByYou, at: payload.until,
                                               floor: payload.batteryFloor,
                                               lidClosed: payload.lidClosed)
        }
    }

    // MARK: - Pieces

    /// The cup, in the slot every full card's glyph sits in.
    private var glyph: some View {
        Image(systemName: "cup.and.saucer")
            .font(.cardTitle)
            .foregroundStyle(Self.tint)
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }

    /// "1 hour 12 minutes", for VoiceOver.
    ///
    /// Spelled out rather than read off the card: "1h 12m" is a label sized
    /// for a glance, and a screen reader saying "one h twelve m" is not the
    /// same sentence the card is showing.
    ///
    /// Not `DurationDial.spoken`, which says "1 hr 12 min" and clamps at three
    /// hours — the dial's own range. A keep-awake runs to a day, and a label
    /// that stops at three hours would read every longer session wrong.
    static func spoken(_ seconds: TimeInterval) -> String {
        let sane = seconds.isFinite ? min(max(seconds, 0), 359_940) : 0
        let total = Int(sane.rounded())
        if total < 60 {
            return total == 1 ? "1 second" : "\(total) seconds"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let hourPart = hours == 1 ? "1 hour" : "\(hours) hours"
        let minutePart = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        if hours == 0 { return minutePart }
        return minutes == 0 ? hourPart : "\(hourPart) \(minutePart)"
    }
}

/// What the Keep Awake card can ask the shell to do.
///
/// Closures with empty defaults, like every other card's actions: the gallery
/// and the tests build the card without a provider behind it.
public struct KeepAwakeActions {

    /// Start a session of the given minutes — the Ready card's own Start.
    public var start: (Int) -> Void
    /// The End button. The only ending a session can be resumed from.
    public var end: () -> Void
    /// Takes the Finished card away, so it ends when the user says so.
    public var dismiss: () -> Void
    /// Picks the ended session back up, to its original deadline.
    public var resume: () -> Void
    /// One tick of the trackpad as the length crosses a detent. The card
    /// cannot do this itself: feedback is the shell's to give, and LedgeUI
    /// never imports AppKit.
    public var haptic: () -> Void
    /// Latches a drag in flight so the card stays open while the pointer
    /// wanders off it — the same latch the timer's length and the volume
    /// sliders use.
    public var setDragging: (Bool) -> Void

    public init(
        start: @escaping (Int) -> Void = { _ in },
        end: @escaping () -> Void = {},
        dismiss: @escaping () -> Void = {},
        resume: @escaping () -> Void = {},
        haptic: @escaping () -> Void = {},
        setDragging: @escaping (Bool) -> Void = { _ in }
    ) {
        self.start = start
        self.end = end
        self.dismiss = dismiss
        self.resume = resume
        self.haptic = haptic
        self.setDragging = setDragging
    }
}
