import LedgeCore
import SwiftUI

/// Permissions: what Ledge is allowed to do, and the one button that changes
/// each answer.
///
/// One list rather than a boxed section per permission, each holding a single
/// "Status" row. Six boxes for six facts made the pane read like a form to be
/// filled in; it is a list of answers.
struct PermissionsSettingsTab: View {

    let model: SettingsModel
    let actions: SettingsActions

    /// A row a search result asked to be shown. The window clears it.
    var highlighted: String?

    var body: some View {
        SettingsPage(scrollTo: highlighted) {
            if model.isLaunchedFromTerminal {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ledge was launched from a terminal.")
                            SettingsNote("""
                                macOS credits a permission to the process that launched the app, \
                                so anything granted now attaches to your terminal instead of to \
                                Ledge — which looks exactly like a denial. Quit and open Ledge \
                                from Finder before granting.
                                """)
                            // The way out, beside the sentence that explains
                            // it: everything on this pane is wasted effort
                            // until Ledge is launched from Finder.
                            Button("Quit Ledge") { actions.quit() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                ForEach(model.permissions) { row in
                    PermissionGrantRow(kind: row.kind, model: model, actions: actions)
                        .searchRow("perm:\(row.kind.rawValue)", highlighted: highlighted)
                }
            } header: {
                Text("What Ledge may use")
            } footer: {
                SettingsNote(
                    "Every one of these is optional, and each says what it is for. "
                        + "Nothing is ever asked for on its own. "
                        + Self.waitingSentence(model.waitingOnYou)
                )
            }

            // Not a system permission, so it is not among them: one folder the
            // user hands over in an open panel, which is what Full Disk Access
            // would otherwise be asked for.
            Section {
                // Five states, not two. The folder does not exist until a
                // Focus has been used once, the panel can be up, and a pick
                // that was not this folder keeps nothing — all three used to
                // read "Not granted", one of them behind a modal alert.
                let face = model.focusFolderFace
                LabeledContent("Folder access") {
                    SettingsStatus(face.word, face.tone.settingsTone)
                }
                SettingsNote(face.note)
                // Offered whenever there is something to pick. Granted, it is
                // how somebody points Ledge at the folder again after moving a
                // home directory — which used to mean a Focus card that
                // quietly stopped following the switch with no way to say so.
                if let button = face.button {
                    Button(button) { actions.chooseFocusFolder() }
                        .controlSize(.small)
                }
            } header: {
                Text("Focus folder")
            } footer: {
                SettingsNote("""
                    macOS keeps the Focus you are in inside one folder. Given that \
                    folder, the Focus card follows the switch immediately and shows the \
                    mode's own name and icon. Nothing else in the folder is used, and \
                    nothing leaves your Mac.
                    """)
            }
            .searchRow("focusFolder", highlighted: highlighted)
        }
        .refreshingPermissions(actions)
    }

    /// How the footer counts what is still owed.
    static func waitingSentence(_ count: Int) -> String {
        switch count {
        case 0: "Nothing is waiting for you."
        case 1: "One is waiting for you."
        default: "\(count) are waiting for you."
        }
    }
}

/// One permission: what it is, where it stands, what it buys, and the single
/// action that can move it.
///
/// Shared with each card's own page, so a card blocked on a permission can be
/// unblocked without leaving it. The pane and the card row cannot disagree
/// about what the button says, because there is one of them — and the
/// decision behind it is `PermissionPresentation.face`, which the welcome
/// tour reads too.
struct PermissionGrantRow: View {

    let kind: PermissionKind
    let model: SettingsModel
    let actions: SettingsActions

    /// Whether to name the cards this permission unblocks. On the Permissions
    /// pane, where a row is far from the card it is about, that is the whole
    /// answer to "what is this for". On a card's own page it would be the
    /// card telling you its own name.
    var namesItsCards = true

    var body: some View {
        let face = model.face(of: kind)
        HStack(alignment: .top, spacing: 10) {
            SettingsIcon.forPermission(kind).view
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind.displayName)
                    Spacer(minLength: 12)
                    SettingsStatus(face.word, face.tone.settingsTone)
                }
                SettingsNote(kind.rationale)
                if let note = face.note {
                    SettingsNote(note)
                }
                if namesItsCards, let used = Self.cardsUsing(kind, in: model) {
                    SettingsNote(used)
                }
                if let remedy = face.remedy {
                    Button(remedy.label) { perform(remedy) }
                        .controlSize(.small)
                }
                // While somebody is out granting this one, the guide opens
                // inside the row rather than in a panel of its own: it is
                // about this permission, and it folds away on an answer.
                if let handoff = model.handoff, handoff.kind == kind {
                    PermissionGuide(handoff: handoff, model: model, actions: actions)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Which cards this permission unblocks, named.
    ///
    /// Read from the providers the shell actually registered rather than from
    /// a list written here, so a card added later says so without anybody
    /// remembering to update a sentence.
    static func cardsUsing(_ kind: PermissionKind, in model: SettingsModel) -> String? {
        let names = model.providers.filter { $0.permission == kind }.map(\.displayName)
        guard !names.isEmpty else { return nil }
        return "Used by \(names.joined(separator: ", "))."
    }

    private func perform(_ remedy: PermissionRemedy) {
        PermissionPress.perform(remedy, for: kind, model: model, actions: actions)
    }
}

/// What a remedy's button does, in one place.
///
/// Three views offer these buttons — the Permissions pane, a card's page and
/// the Cards list's "waiting" group — and they must not drift about what a
/// press means or about what the row says while it waits.
@MainActor
enum PermissionPress {

    static func perform(
        _ remedy: PermissionRemedy,
        for kind: PermissionKind,
        model: SettingsModel,
        actions: SettingsActions
    ) {
        switch remedy {
        case .ask:
            model.beganWaiting(for: kind, on: .prompt, saying: PermissionCopy.waitingForAnswer)
            actions.requestPermission(kind)
        case .openPlayer:
            model.beganWaiting(for: kind, on: .prompt, saying: "Opening Music…")
            actions.requestPermission(kind)
        case .openSettings:
            // A handoff, not just a wait: the person is about to be in
            // another application, looking for a switch in a list, and the
            // guide is the only thing Ledge can still be useful with.
            model.beganHandoff(
                for: kind,
                isFirstTime: kind == .accessibility && !model.accessibilityWasAskedBefore
            )
            // Accessibility goes through the *request*, not through the pane
            // alone. Only that path calls `AXIsProcessTrustedWithOptions`,
            // which is what puts Ledge in the list in the first place; a Mac
            // that has never seen Ledge there gets a list with nothing to
            // switch on otherwise. The request opens the same pane.
            if kind.isGrantedInSystemSettings {
                actions.requestPermission(kind)
            } else {
                actions.openPermissionSettings(kind)
            }
        }
    }
}
