import AppKit
import LedgeCore
import SwiftUI

/// What the panel beside System Settings is saying.
public enum PermissionCompanionContent: Equatable, Sendable {
    case waiting(PermissionHandoff)
    /// The grant landed. The notch's words, because the notch says them when
    /// the panel is not up. Only one of the two ever says it.
    case arrived(PermissionKind)
}

/// The small panel that stands beside System Settings during a handoff.
///
/// The inline guide stays where it was, but it can be behind System Settings
/// at the moment it is needed. This is the same guide where it can be seen. It
/// draws no diagram, because the real list is right beside it, and it has no
/// row styling of System Settings' own, so it reads as Ledge's.
public struct PermissionCompanionView: View {

    let content: PermissionCompanionContent
    let model: SettingsModel
    let actions: SettingsActions
    let tile: AnyView?
    let backToLedge: () -> Void

    @State private var saidCopied = false

    public init(
        content: PermissionCompanionContent,
        model: SettingsModel,
        actions: SettingsActions,
        tile: AnyView?,
        backToLedge: @escaping () -> Void = {}
    ) {
        self.content = content
        self.model = model
        self.actions = actions
        self.tile = tile
        self.backToLedge = backToLedge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch content {
            case .waiting(let handoff):
                waiting(handoff)
            case .arrived(let kind):
                arrived(kind)
            }
        }
        .padding(16)
        .frame(width: PermissionCompanionDock.panelWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var title: String {
        switch content {
        case .waiting(let handoff): PermissionGuideCopy.companionTitle(handoff.kind)
        case .arrived(let kind): kind.displayName
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(PermissionGuideCopy.tileName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }

    // MARK: - Waiting

    @ViewBuilder
    private func waiting(_ handoff: PermissionHandoff) -> some View {
        Text(.init(PermissionGuide.bolded(PermissionGuideCopy.caption(handoff.kind))))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(PermissionGuideCopy.companionWaiting)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)

        // Only Accessibility: it is the one grant with no prompt, so the one
        // list that can be missing Ledge, and the only one macOS lets an app
        // be dragged into.
        if handoff.kind == .accessibility {
            Divider()
            rescue
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Button(PermissionGuideCopy.openAgain) {
                PermissionPress.perform(
                    .openSettings, for: handoff.kind, model: model, actions: actions
                )
            }
            Button(PermissionGuideCopy.stopWaiting) { actions.stopWaiting() }
        }
        .controlSize(.small)
    }

    /// The tile, for the case nothing else can fix.
    @ViewBuilder
    private var rescue: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PermissionGuideCopy.companionRescue)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            if let location = model.appLocation {
                SettingsNote(PermissionGuideCopy.companionRescueBody)
                HStack(alignment: .top, spacing: 12) {
                    if let tile {
                        tile.frame(width: 92, height: 92)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(PermissionGuideCopy.tileHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button(PermissionGuideCopy.copyLocation) {
                            actions.copyToClipboard(location)
                            saidCopied = true
                        }
                        .controlSize(.small)
                        if saidCopied {
                            Text(PermissionGuideCopy.copied(location))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let outcome = model.appDragEnded {
                    Text(MissingFromTheList.sentence(for: outcome))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Running from the disk image or a translocated path. Adding
                // this copy grants one that disappears, so no drag is offered.
                Text(PermissionGuideCopy.moveFirst)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                SettingsNote(PermissionGuideCopy.moveFirstNote)
            }
        }
    }

    // MARK: - Arrived

    @ViewBuilder
    private func arrived(_ kind: PermissionKind) -> some View {
        Label {
            Text(PermissionGuideCopy.arrivedTitle(kind.displayName))
                .font(.system(size: 13, weight: .semibold))
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        Text(PermissionGuideCopy.arrivedDetail(kind))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Button(PermissionGuideCopy.backToLedge, action: backToLedge)
            .controlSize(.small)
    }
}
