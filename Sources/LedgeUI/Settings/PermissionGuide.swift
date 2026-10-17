import LedgeCore
import SwiftUI

/// What to draw while somebody is in System Settings on Ledge's behalf.
///
/// A row cannot carry this on its own: the person is in another app, the
/// switch is in a list no application can read, and the only honest things to
/// show are where to look and a way to stop waiting. One component, so the
/// tour and the Permissions pane cannot drift about any of it — in the tour it
/// replaces the list of rows, in Settings it opens inside the row.
///
/// The list is drawn as a diagram: dashed, unfilled, no window chrome, and it
/// says underneath that it is a diagram. A picture of another application's
/// window, drawn well enough to be mistaken for it, would be worse than
/// drawing nothing at all.
struct PermissionGuide: View {

    let handoff: PermissionHandoff
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.init(bolded(PermissionGuideCopy.caption(handoff.kind))))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if handoff.isFirstTime {
                SettingsNote(PermissionGuideCopy.firstTime)
            }

            SystemSettingsDiagram(kind: handoff.kind)

            Text(PermissionGuideCopy.isADiagram)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            // Only Accessibility. It is the one grant with no prompt, so it
            // is the one list that can be missing Ledge entirely — and the
            // only one macOS lets an app be dragged into.
            if handoff.kind == .accessibility {
                MissingFromTheList(model: model, actions: actions)
            }

            HStack(spacing: 10) {
                // Only while nothing else offers it. Once somebody is back
                // and the switch is still off, the row above says "Still off"
                // and carries Open System Settings… itself — two buttons that
                // do the same thing, an inch apart, is a row that has not
                // decided what it is asking.
                if handoff.phase == .waiting {
                    Button(PermissionGuideCopy.openAgain) {
                        PermissionPress.perform(
                            .openSettings, for: handoff.kind, model: model, actions: actions
                        )
                    }
                }
                Button(PermissionGuideCopy.stopWaiting) { actions.stopWaiting() }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The first sentence carries the instruction, so it is the bold one.
    /// Markdown rather than two concatenated `Text`s, which wrapped as two
    /// paragraphs at this width.
    private func bolded(_ caption: String) -> String {
        guard let stop = caption.firstIndex(of: ".") else { return caption }
        let lead = caption[caption.startIndex...stop]
        let rest = caption[caption.index(after: stop)...]
        return "**\(lead)**\(rest)"
    }
}

/// Where to look, as a diagram.
///
/// Three rows: two apps that are not Ledge, drawn as bars because their names
/// are nobody's business and inventing them would make this a fake screenshot,
/// and Ledge's own row in the accent with its switch off.
private struct SystemSettingsDiagram: View {

    let kind: PermissionKind

    private static let stroke = StrokeStyle(lineWidth: 1.5, dash: [5, 4])

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PermissionCopy.settingsPaneName(kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 0) {
                otherApp(width: 76)
                Divider().opacity(0.35)
                ledgeRow
                Divider().opacity(0.35)
                otherApp(width: 58)
            }
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, style: Self.stroke)
            )

            // The + is a real part of the keyboard path below, so it is in
            // the diagram where that path says it is.
            Text("+  −")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "A diagram of the \(PermissionCopy.settingsPaneName(kind)) list in System Settings, "
                + "with Ledge in it and its switch off."
        )
    }

    private var ledgeRow: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1)
                .frame(width: 16, height: 16)
            Text(PermissionGuideCopy.tileName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Spacer(minLength: 12)
            switchShape(on: false, accented: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func otherApp(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .frame(width: 16, height: 16)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .frame(width: width, height: 7)
            Spacer(minLength: 12)
            switchShape(on: true, accented: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// A switch, drawn as a pill with the knob at one end. Unfilled, like the
    /// rest of the diagram.
    private func switchShape(on: Bool, accented: Bool) -> some View {
        let tint = accented ? Color.accentColor : Color.primary.opacity(0.25)
        return Capsule()
            .strokeBorder(tint, lineWidth: 1)
            .frame(width: 22, height: 13)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    .padding(.horizontal, 3)
            }
    }
}

/// The case nothing in today's app can fix: Ledge is not in the list, or the
/// list holds an older copy of it.
///
/// Two equal paths. The tile drags Ledge itself, with `.link` as its only
/// operation, so the worst a stray drop can leave anywhere is an alias. Copy
/// Location is the same thing for the keyboard and for VoiceOver, and it is
/// visible for everybody rather than hidden behind the drag.
private struct MissingFromTheList: View {

    let model: SettingsModel
    let actions: SettingsActions

    @State private var saidCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(PermissionGuideCopy.notInList)
                .font(.system(size: 12, weight: .medium))

            if let location = model.appLocation {
                SettingsNote(PermissionGuideCopy.notInListBody)
                HStack(alignment: .top, spacing: 12) {
                    if let tile = actions.appTile() {
                        tile.frame(width: 92, height: 92)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Button(PermissionGuideCopy.copyLocation) {
                            actions.copyToClipboard(location)
                            saidCopied = true
                        }
                        .controlSize(.small)
                        // Said in words, not in a flash of colour, and it
                        // says *what* was copied: a path on the clipboard is
                        // invisible until it is pasted somewhere.
                        if saidCopied {
                            Text(PermissionGuideCopy.copied(location))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if let outcome = model.appDragEnded {
                            Text(Self.sentence(for: outcome))
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                // Running from the disk image or a translocated path. Adding
                // *this* to the list grants a copy that disappears, so the
                // drag is not offered at all.
                Text(PermissionGuideCopy.moveFirst)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                SettingsNote(PermissionGuideCopy.moveFirstNote)
            }
        }
        // A fresh path deserves a fresh confirmation.
        .onChange(of: model.appLocation) { _, _ in saidCopied = false }
    }

    private static func sentence(for outcome: AppDragOutcome) -> String {
        switch outcome {
        case .missed: PermissionGuideCopy.dropMissed
        case .landedElsewhere: PermissionGuideCopy.dropLandedElsewhere
        }
    }
}
