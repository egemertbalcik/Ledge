import SwiftUI

/// Motion tokens.
///
/// Values come from `Preferences`, which is tunable at runtime from the
/// Appearance tab. Without Xcode previews, tuning a spring by
/// edit-rebuild-relaunch is unusable; sliders make it seconds.
public enum Motion {

    /// The open/close spring. `response` is roughly the duration of one
    /// oscillation.
    ///
    /// Damping is floored near critical: an under-damped spring overshoots
    /// *below* the target height when collapsing, pushing the shape up past the
    /// hardware cutout — a visible gap above the notch. Keeping it close to
    /// critically damped lets the shape ease to rest at the notch line without
    /// ever crossing it.
    public static func expand(response: Double, damping: Double, reduced: Bool = false) -> Animation {
        // Reduce Motion asks for less *movement*, not less feedback: a short
        // ease keeps the state change visible without the travel of a spring.
        if reduced { return .easeInOut(duration: 0.18) }
        return .spring(response: response, dampingFraction: max(damping, 0.92))
    }

    /// Content appearing after the silhouette has started moving, so the shape
    /// leads and the contents follow.
    public static func content(response: Double, reduced: Bool = false) -> Animation {
        if reduced { return .easeInOut(duration: 0.15) }
        return .easeOut(duration: response * 0.5).delay(response * 0.25)
    }

    /// One card replacing another *inside* an already-open shape.
    ///
    /// `content` is wrong for this: its delay exists so contents follow a shape
    /// that is busy resizing, but a swap happens at a constant size, and the
    /// delay reads as a stall then a jump. A gentle spring instead, so the
    /// outgoing and incoming cards cross over continuously.
    public static func swap(response: Double, reduced: Bool = false) -> Animation {
        if reduced { return .easeInOut(duration: 0.15) }
        return .spring(response: max(response * 0.85, 0.26), dampingFraction: 0.86)
    }

    /// How one card gives way to the next: the new one rises into place while
    /// the old one falls away, both fading. A cut would make an announcement
    /// that lasts two seconds feel like a glitch.
    public static var cardSwap: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.94, anchor: .top)),
            removal: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }

    /// How one compact card gives way to the next, inside the ears.
    ///
    /// No translation. The compact strip is barely taller than the cutout and
    /// its middle is reserved for physical hardware, so anything that moves
    /// vertically slides behind the notch and is clipped mid-flight — which is
    /// what made music-to-keyboard look broken. A soft scale-and-blur dissolve
    /// stays inside its own ear and reads as one thing becoming another.
    public static var earSwap: AnyTransition {
        .modifier(
            active: EarSwapEffect(hidden: true),
            identity: EarSwapEffect(hidden: false)
        )
    }

    /// The dissolve between two compact cards. Short and fully damped: this is
    /// a change of subject, not a gesture, and a bouncy spring on a 22pt glyph
    /// reads as a wobble.
    public static let earContent: Animation = .spring(response: 0.34, dampingFraction: 1.0)

    /// A readout arriving, which is a different kind of event from a card
    /// changing hands.
    ///
    /// The ears' ordinary timing is a third of a second, which is right for
    /// music giving way to a timer — those are changes of subject and want a
    /// beat. A volume key is not a change of subject: it is feedback, and
    /// feedback a third of a second behind the key reads as the app being
    /// slow. macOS's own readout appears at once.
    public static let readoutIn: Animation = .spring(response: 0.16, dampingFraction: 1.0)

    /// A level moving under a held key.
    ///
    /// Ease-out restarts from zero velocity on every repeat, so sixteen presses
    /// in two seconds are sixteen little accelerations — the steppiness you
    /// feel rather than see. A spring retargets from wherever it is, carrying
    /// its velocity, which is what makes a held key read as one continuous
    /// slide.
    public static let levelChange: Animation = .spring(response: 0.2, dampingFraction: 0.85)

    /// How one *expanded* card gives way to another — media to weather, timer
    /// to shelf.
    ///
    /// The same language as `earSwap` but far gentler on the scale: a full card
    /// shrinking by a third on its way out reads as the card being thrown away,
    /// where a compact glyph doing it reads as a swap. No translation, because
    /// the two cards are rarely the same height and a card sliding *while* the
    /// silhouette resizes is two motions fighting.
    public static var expandedSwap: AnyTransition {
        .modifier(
            active: ExpandedSwapEffect(hidden: true),
            identity: ExpandedSwapEffect(hidden: false)
        )
    }

    /// Radius edits from a slider should land immediately, not spring.
    public static let tuning: Animation = .easeOut(duration: 0.08)

    /// Micro-animation tokens, so level changes, fades and ring fills across
    /// the cards share three speeds instead of a scatter of near-misses.
    public static let fast: Animation = .easeOut(duration: 0.12)
    public static let medium: Animation = .easeOut(duration: 0.18)
    public static let slow: Animation = .easeOut(duration: 0.3)

    /// The Reduce Motion stand-in for every AnyTransition here: a plain
    /// crossfade, no translation, no scale, no blur.
    public static var reducedSwap: AnyTransition { .opacity }

    /// The media card turning over to its output list and back.
    ///
    /// Anchored at the AirPlay button, because that is where the press was: the
    /// list grows out of the control that asked for it and folds back into it.
    /// Gentler than `cardSwap` — nothing is arriving or leaving the notch here,
    /// one face of the same card is turning into another.
    /// A plain dissolve, deliberately.
    ///
    /// What actually travels between the two faces of the media card is the
    /// artwork, the title and the equalizer, and those are tied together with
    /// `matchedGeometryEffect` — they move rather than fade. A scale or an
    /// offset on the containers would drag those same elements along with it
    /// and fight the geometry that is already carrying them, which is how a
    /// swap ends up looking busy and abrupt at the same time.
    public static var routeSwap: AnyTransition { .opacity }

    public static func routeSwap(reduced: Bool) -> AnyTransition {
        reduced ? reducedSwap : routeSwap
    }

    public static func cardSwap(reduced: Bool) -> AnyTransition {
        reduced ? reducedSwap : cardSwap
    }
    public static func earSwap(reduced: Bool) -> AnyTransition {
        reduced ? reducedSwap : earSwap
    }
    public static func expandedSwap(reduced: Bool) -> AnyTransition {
        reduced ? reducedSwap : expandedSwap
    }
}

/// The visual state either side of an expanded-card swap.
struct ExpandedSwapEffect: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.965 : 1)
            .blur(radius: hidden ? 4 : 0)
    }
}

/// The visual state either side of an ear swap. Scaling *down* on both the way
/// in and the way out means neither card ever grows past its ear, so nothing
/// spills over the cutout.
struct EarSwapEffect: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.72 : 1)
            .blur(radius: hidden ? 2.5 : 0)
    }
}
