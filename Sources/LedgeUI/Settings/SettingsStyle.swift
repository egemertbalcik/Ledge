import SwiftUI

/// The settings window's house style, in one file.
///
/// Every pane used to say the same kinds of thing in its own way: explanatory
/// prose was `.callout` here, `.footnote` there and `.caption` somewhere else;
/// a state was a tinted word in one pane, a word with a symbol in the next,
/// and a `LabeledContent("Status")` row in a third; two panes were `Form`s and
/// the Devices pane was a bare `ScrollView` with no grouped background at all.
/// None of that was a decision — it was the order the panes were written in.
///
/// So there are four pieces here and the panes use nothing else:
///
/// * `SettingsPage` — the container. Every pane is one.
/// * `SettingsNote` — prose. One size, one colour, always wrapping.
/// * `SettingsStatus` — a state, with the symbol and tint that go with it.
/// * `LabeledSlider` — a number, with its value where the eye already is.
///
/// The rule for prose, which the panes follow without exception: a sentence
/// about the whole section goes in the section's `footer`; a sentence about
/// one control sits directly under that control as a row.

// MARK: - The page

/// A settings pane: a grouped form on the window's own material.
///
/// The three modifiers were written out at the bottom of all nine panes, and
/// one of them had drifted. Now a pane cannot forget them.
struct SettingsPage<Content: View>: View {

    /// The row a search result is pointing at, if this pane holds one.
    ///
    /// The pane scrolls to it. A highlight on a row below the fold is a
    /// highlight nobody sees, and "Cards › Weather › City" is a promise that
    /// the row will be in front of you when you arrive.
    var scrollTo: String?

    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                content
            }
            .formStyle(.grouped)
            // The window carries the material; a form drawing its own
            // background over it is what makes a settings window look like a
            // dialog pasted onto a desktop.
            .scrollContentBackground(.hidden)
            .task(id: scrollTo) {
                guard let scrollTo else { return }
                // A beat, so the pane it is scrolling inside has been laid
                // out. Scrolling into a form that has not measured itself
                // lands on nothing.
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(scrollTo, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Prose

/// A sentence the user reads rather than operates.
///
/// Always wraps: several of these were being cut off mid-word, including the
/// one explaining what a card *is*, on the pane whose whole job is to explain
/// what the cards are.
struct SettingsNote: View {

    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - State

/// How a state reads: good, needs you, broken, or nothing to say.
///
/// Colour alone is not a message — a symbol goes with every one of these, and
/// the word is always there too.
enum SettingsTone: Equatable, Sendable {
    /// Working. Nothing to do.
    case ok
    /// Waiting for the user. The only tone that implies an action nearby.
    case attention
    /// Refused or failed.
    case problem
    /// True, and not a verdict — unavailable on this Mac, not applicable now.
    case quiet

    var color: Color {
        switch self {
        case .ok: .green
        case .attention: .orange
        case .problem: .red
        case .quiet: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .problem: "xmark.circle.fill"
        case .quiet: "minus.circle"
        }
    }
}

/// A state, said once, the same way everywhere.
struct SettingsStatus: View {

    let text: String
    let tone: SettingsTone

    init(_ text: String, _ tone: SettingsTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Label(text, systemImage: tone.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(tone.color)
            // Some of these are a sentence rather than a word — "macOS has
            // not handed over the key press yet" — and a state that is cut
            // off halfway is worse than no state at all.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Numbers

/// A slider in the Tahoe idiom: title on the left, the live value in a rounded
/// badge on the right, and the slider running the row's full width beneath.
struct LabeledSlider<Value: BinaryFloatingPoint>: View
where Value.Stride: BinaryFloatingPoint {

    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let format: String

    init(_ title: String, value: Binding<Value>, in range: ClosedRange<Value>, format: String) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        // `labelsHidden()` is what makes this span the row.
        //
        // A grouped `Form` reserves a leading label column for any control
        // that carries a label — and `Slider(value:in:)` carries an empty
        // one. Every slider in this window was drawing in the trailing half
        // of its row, which is half the travel for the same range: the
        // battery floor got about 220 points for forty-five steps. The doc
        // comment above has promised the full width since the day it was
        // written. The title is a sibling here, so hiding the slider's own
        // label loses nothing — VoiceOver still gets it, below.
        VStack(spacing: 7) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(String(format: format, Double(value)))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Slider(value: $value, in: range)
                .labelsHidden()
                // The row's title is a sibling, not the slider's label, so
                // VoiceOver otherwise announces every one of these as
                // "slider".
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

// MARK: - The window's ground

/// A behind-window material, so the desktop tints the whole settings window the
/// way Tahoe's own panes are tinted by the wallpaper.
struct VibrantBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Keeping a pane honest

extension View {

    /// Re-reads permissions while this pane is open.
    ///
    /// Granting happens in System Settings, outside this window, so a pane
    /// that shows permission state has to re-read rather than assume. Two
    /// panes did this on two different cadences with two copies of the loop;
    /// this is the one cadence, and it stops when the pane goes away.
    func refreshingPermissions(_ actions: SettingsActions) -> some View {
        modifier(PermissionRefresh(actions: actions))
    }
}

private struct PermissionRefresh: ViewModifier {

    let actions: SettingsActions

    /// Slow enough to cost nothing, quick enough that a user coming back from
    /// System Settings does not catch the old answer.
    static let interval: Duration = .seconds(2)

    func body(content: Content) -> some View {
        content
            .onAppear { actions.refreshPermissions() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.interval)
                    guard !Task.isCancelled else { return }
                    actions.refreshPermissions()
                }
            }
    }
}
