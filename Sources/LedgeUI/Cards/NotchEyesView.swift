import SwiftUI

/// The eyes Ledge opens with.
///
/// A filled dome, flat along the bottom and curved over the top, lit in the
/// app's own amber. Not an outline and not an eyeball —
/// the charm is that two plain shapes read as a face, and everything they
/// express comes from how those shapes move.
///
/// Three parameters carry every expression:
///
/// - `openness` is the dome's height. One is wide awake; zero is a closed lid,
///   and because the shape collapses onto its own flat base rather than
///   scaling, closing reads as a blink instead of the eye receding.
/// - `curve` bends the base upward. Straight is neutral; bent is the squint
///   people read as a smile, which is EVE's whole vocabulary of pleasure.
/// - `tilt` leans the eye. A few degrees inward is curious, outward is warm.
public struct NotchEyeShape: Shape {

    /// 0…1, the dome's height as a fraction of the frame.
    public var openness: CGFloat

    /// 0…1, how far the base bows upward.
    public var curve: CGFloat

    /// Where the dome peaks, -1 (inner) to 1 (outer). EVE's eyes are not
    /// symmetrical: the high point sits away from the nose, which is most of
    /// what stops two domes reading as two bridges.
    public var skew: CGFloat

    public init(openness: CGFloat, curve: CGFloat = 0, skew: CGFloat = 0) {
        self.openness = openness
        self.curve = curve
        self.skew = skew
    }

    /// Both, so a blink and a smile can happen at once without either
    /// snapping — SwiftUI interpolates the path itself rather than the view.
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(openness, curve) }
        set {
            openness = newValue.first
            curve = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let open = min(max(openness, 0), 1)
        let base = rect.maxY
        // Never quite nothing: a closed eye is a line with weight, the way a
        // lid is, rather than an absence.
        let height = max(rect.height * open, rect.height * 0.06)
        let top = base - height

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: base))
        // The dome. Control points pulled inward from the corners so the
        // shoulders are full and the ends come to a soft point — the
        // difference between EVE's eye and a half-circle.
        let lean = rect.width * 0.16 * min(max(skew, -1), 1)
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: base),
            control1: CGPoint(x: rect.minX + rect.width * 0.06 + lean, y: top),
            control2: CGPoint(x: rect.maxX - rect.width * 0.06 + lean, y: top)
        )
        // And back along the base, bowed up by however much this eye is
        // smiling.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: base),
            control: CGPoint(x: rect.midX, y: base - height * 0.85 * min(max(curve, 0), 1))
        )
        path.closeSubpath()
        return path
    }
}

/// One eye, with its glow.
public struct NotchEye: View {

    private let openness: CGFloat
    private let curve: CGFloat
    private let tilt: Double
    private let skew: CGFloat
    private let size: CGSize

    /// Ledge's amber — the same light the app icon is lit with, so the face on
    /// screen and the face in the Dock are one thing. Warm enough to read as
    /// friendly against the notch's black, pale enough not to look like a
    /// warning lamp.
    public static let amber = Color(red: 1.0, green: 0.80, blue: 0.55)

    /// What the glow is made of: a touch more orange than the fill, so the
    /// halo warms rather than smears.
    public static let glow = Color(red: 1.0, green: 0.68, blue: 0.36)

    public init(
        openness: CGFloat,
        curve: CGFloat = 0,
        tilt: Double = 0,
        skew: CGFloat = 0,
        size: CGSize = CGSize(width: 30, height: 14)
    ) {
        self.openness = openness
        self.curve = curve
        self.tilt = tilt
        self.skew = skew
        self.size = size
    }

    public var body: some View {
        NotchEyeShape(openness: openness, curve: curve, skew: skew)
            .fill(
                LinearGradient(
                    colors: [Self.amber, Self.amber.opacity(0.84)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Two shadows, not one: a tight one for the edge and a wide one
            // for the halo. A single radius either smears the shape or barely
            // shows against black.
            .shadow(color: Self.glow.opacity(0.9), radius: 2)
            .shadow(color: Self.glow.opacity(0.5), radius: 7)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(tilt))
    }
}

/// The greeting: Ledge waking up.
///
/// One performance, deliberately slow enough to be watched. It wakes, looks
/// around, is pleased to see you, blinks, and settles — the beats a face makes
/// when it opens its eyes, in that order, because any other order reads as a
/// list of animations rather than a character.
///
/// Both eyes are driven from here so they move as a pair. Two views blinking
/// on their own timers is the single fastest way to lose the illusion.
public struct NotchGreetingEyes: View {

    /// Which eye this is, so the pair can lean toward each other and look in
    /// the same direction without either being mirrored wholesale.
    public enum Side { case leading, trailing }

    private let side: Side
    private let state: GreetingState

    public init(side: Side, state: GreetingState) {
        self.side = side
        self.state = state
    }

    public var body: some View {
        let inward: Double = side == .leading ? 1 : -1
        NotchEye(
            openness: state.openness,
            curve: state.curve,
            tilt: state.tilt * inward,
            // Peaking away from the cutout, so the pair leans outward the way
            // EVE's do rather than meeting in the middle like eyebrows.
            skew: 0.55 * inward,
            size: CGSize(width: 30, height: 14)
        )
        .offset(x: state.gaze, y: state.rise)
        .opacity(state.opacity)
        .scaleEffect(state.scale)
    }
}

/// What the eyes are doing right now. Held by the overlay so both eyes read
/// the same values in the same frame.
public struct GreetingState: Equatable, Sendable {
    public var openness: CGFloat = 0
    public var curve: CGFloat = 0
    public var tilt: Double = 0
    public var gaze: CGFloat = 0
    public var rise: CGFloat = 0
    public var opacity: Double = 0
    public var scale: CGFloat = 0.86

    public init() {}

    /// Asleep: nothing on screen yet.
    public static let closed = GreetingState()

    /// One beat of the performance: where the eyes move to, how long the move
    /// takes, and how long they hold there before the next one.
    public struct Beat: Sendable {
        public let state: GreetingState
        public let move: Double
        public let hold: Double
        public let spring: Bool

        public var animation: Animation {
            spring
                ? .spring(response: move, dampingFraction: 0.7)
                : .easeInOut(duration: move)
        }

        /// A spring is still settling when its response is up, so it is given
        /// half again before the next beat starts.
        public var length: Double { (spring ? move * 1.5 : move) + hold }
    }

    /// The performance, as the states it passes through.
    ///
    /// Written as data rather than a run of `withAnimation` calls so the whole
    /// thing can be read — and re-timed — in one place, and so the shell can
    /// add up how long to hold the island open without guessing.
    public static func script() -> [Beat] {
        var waking = GreetingState()
        waking.opacity = 1
        waking.scale = 1
        waking.openness = 0.06

        var awake = waking
        awake.openness = 1

        var lookAway = awake
        lookAway.gaze = -3.2
        lookAway.tilt = 3

        var lookBack = awake
        lookBack.gaze = 2.6
        lookBack.tilt = -2

        let centred = awake

        var blinkShut = centred
        blinkShut.openness = 0.04

        var pleased = centred
        pleased.curve = 1
        pleased.openness = 0.82
        pleased.rise = -1
        pleased.tilt = -5

        var sleeping = centred
        sleeping.openness = 0.05
        sleeping.opacity = 0.9

        var gone = sleeping
        gone.opacity = 0
        gone.scale = 0.94

        return [
            // Coming to: the lids part before anything else moves.
            Beat(state: waking, move: 0.34, hold: 0.14, spring: false),
            Beat(state: awake, move: 0.50, hold: 0.30, spring: true),
            // A look around the room. Slow on purpose: this is the half that
            // is watched, and hurrying it is what made the first attempt read
            // as a twitch rather than a character.
            Beat(state: lookAway, move: 0.62, hold: 0.26, spring: false),
            Beat(state: lookBack, move: 0.66, hold: 0.24, spring: false),
            // Blink.
            Beat(state: blinkShut, move: 0.09, hold: 0.04, spring: false),
            Beat(state: centred, move: 0.15, hold: 0.20, spring: false),
            // Pleased to see you: the squint that reads as a smile, held long
            // enough to be the thing anyone remembers.
            Beat(state: pleased, move: 0.44, hold: 0.55, spring: true),
            Beat(state: centred, move: 0.36, hold: 0.16, spring: false),
            // One more, slower than the first: a blink on the way out reads as
            // settling, where the same blink in the middle read as noticing.
            Beat(state: blinkShut, move: 0.12, hold: 0.05, spring: false),
            Beat(state: centred, move: 0.18, hold: 0.18, spring: false),
            // Back to sleep, and the island closes behind it.
            Beat(state: sleeping, move: 0.38, hold: 0.10, spring: false),
            Beat(state: gone, move: 0.30, hold: 0.02, spring: false),
        ]
    }

    /// How long the whole performance takes, so the shell holds the island
    /// open for exactly that and not a frame longer.
    public static var duration: Double {
        script().reduce(0) { $0 + $1.length }
    }
}

