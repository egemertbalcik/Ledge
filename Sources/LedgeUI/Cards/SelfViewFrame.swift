import LedgeCore
import SwiftUI

/// What the calendar card can ask for on the self-view's behalf.
///
/// Four closures and a picture. The picture is a closure too, because the
/// thing that draws a camera is an `AVCaptureVideoPreviewLayer` and this
/// target cannot see one: the shell hands one down, and everything that is
/// not the shell — previews, the gallery, the rendering tests — gets the
/// drawn stand-in instead.
public struct SelfViewActions {

    /// The segment was pressed. What that means depends on the face, and the
    /// rule for it is `SelfViewPolicy.press`.
    public var press: () -> Void

    /// Opens System Settings at Privacy & Security › Camera.
    public var openSettings: () -> Void

    /// Starts a fresh session after one that never produced a frame.
    public var tryAgain: () -> Void

    /// The card left the screen. The camera goes with it — a card that has
    /// been swiped away cannot be the thing holding the notch open.
    public var cardWentAway: () -> Void

    /// Join was pressed while the frame was open. The meeting app needs the
    /// camera, so Ledge gives it up before the link opens — not afterwards,
    /// and never both holding it at once.
    public var letGo: () -> Void

    /// The live picture, mirrored, or the stand-in when nobody supplied one.
    public var picture: () -> AnyView

    public init(
        press: @escaping () -> Void = {},
        openSettings: @escaping () -> Void = {},
        tryAgain: @escaping () -> Void = {},
        cardWentAway: @escaping () -> Void = {},
        letGo: @escaping () -> Void = {},
        picture: (() -> AnyView)? = nil
    ) {
        self.press = press
        self.openSettings = openSettings
        self.tryAgain = tryAgain
        self.cardWentAway = cardWentAway
        self.letGo = letGo
        // The stand-in is the default picture, and it is built here rather
        // than in the parameter list: a view is main-actor and a default
        // argument is not.
        self.picture = picture ?? { AnyView(SelfViewStandIn()) }
    }
}

/// The frame that opens over the month: a picture, or the one sentence that
/// explains why there isn't one.
///
/// It is drawn at the month column's own size and corner — 16 points
/// continuous, which is the card's 30pt bottom radius less its 14pt bottom
/// inset, so the frame's corner sits concentric inside the card's own. Nothing
/// here travels: the month racks out of focus and the picture racks in, in
/// place. The control that opened it is in the left column and closing is a
/// return, so a frame that flew across the card would be two motions arguing
/// about one press.
struct SelfViewFrameView: View {

    let payload: SelfViewPayload
    let actions: SelfViewActions

    /// Whether to animate at all. Passed down rather than read here so the
    /// card and the frame can never disagree about it.
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            // Smoked glass over the month. Thicker under a face that has
            // given up: those faces are a sentence to read at 10pt, and a
            // month still showing through its own fog is a second thing
            // asking to be read in the same hundred points.
            Rectangle()
                .fill(Color(red: 0.055, green: 0.055, blue: 0.063))
                .opacity(payload.phase.isDeadEnd ? 0.82 : 0.42)

            // Always mounted while the frame is open, and shown by the phase
            // rather than by an `onAppear`: the gallery's renderer never
            // mounts a view, so an arrival animated from `onAppear` would
            // export as a hole where the picture should be.
            actions.picture()
                .opacity(payload.phase == .live ? 1 : 0)
                .blur(radius: payload.phase == .live ? 0 : 10)
                .scaleEffect(payload.phase == .live ? 1 : 1.04)
                .allowsHitTesting(false)

            if payload.phase.isDeadEnd {
                deadEnd
            } else if let sentence = payload.sentence {
                caption(sentence)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        // The one moment that matters — you, arriving. Undamped scale on a
        // face reads as a zoom, so the picture only settles four percent.
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.15)
                : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32),
            value: payload.phase
        )
        .animation(Motion.fast, value: payload.countdown)
    }

    /// Over the picture, at the bottom, on a scrim — the only place a sentence
    /// is ever written. Nothing is written in the left column: that column is
    /// today's card, and it stays that way.
    private func caption(_ text: String) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(text)
                .font(.cardCaption)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .padding(.top, 22)
                .frame(maxWidth: .infinity)
                .background(alignment: .bottom) {
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .transition(.opacity)
    }

    /// A face with nothing to watch: a glyph, the sentence, and — where there
    /// is one worth offering — the single thing that fixes it.
    @ViewBuilder
    private var deadEnd: some View {
        VStack(spacing: 7) {
            Image(systemName: "video.slash")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
            if let sentence = payload.sentence {
                Text(sentence)
                    .font(.cardCaption)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = SelfViewPolicy.action(for: payload.phase) {
                Button {
                    switch action {
                    case .openSettings: actions.openSettings()
                    case .tryAgain: actions.tryAgain()
                    }
                } label: {
                    Text(action.label)
                        .font(.cardLabel)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .transition(.opacity)
    }
}

/// What the gallery and the previews draw in the picture's place.
///
/// `ImageRenderer` cannot photograph a live capture layer — it would export a
/// hole — and a photograph of a real face is not something to keep in a
/// repository. So: a dim room and a silhouette, with no text anywhere in it
/// that could ever be mistaken for a shipped sentence.
public struct SelfViewStandIn: View {

    public init() {}

    public var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.23, green: 0.21, blue: 0.19), Color(red: 0.12, green: 0.11, blue: 0.10)],
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadius: 2,
                endRadius: 120
            )
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                ZStack {
                    // Shoulders, rising out of the bottom edge.
                    Ellipse()
                        .fill(.white.opacity(0.07))
                        .frame(width: w * 0.95, height: h * 0.6)
                        .position(x: w / 2, y: h * 1.05)
                    // A head, lit from the screen in front of it.
                    Ellipse()
                        .fill(.white.opacity(0.10))
                        .frame(width: w * 0.36, height: h * 0.34)
                        .position(x: w / 2, y: h * 0.42)
                }
            }
        }
    }
}
