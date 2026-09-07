import LedgeCore
import SwiftUI

/// What the shelf card can ask the shell to do.
public struct ShelfActions {
    public var remove: (String) -> Void
    public var clear: () -> Void
    public var reveal: (String) -> Void

    public init(
        remove: @escaping (String) -> Void = { _ in },
        clear: @escaping () -> Void = {},
        reveal: @escaping (String) -> Void = { _ in }
    ) {
        self.remove = remove
        self.clear = clear
        self.reveal = reveal
    }
}

/// Files parked in the notch: a row of tiles, each draggable back out to any
/// app, each removable.
public struct ShelfCardView: View {

    private let payload: ShelfPayload
    private let actions: ShelfActions
    private let isCompactWidth: Bool

    public init(
        payload: ShelfPayload,
        actions: ShelfActions = ShelfActions(),
        isCompactWidth: Bool = false
    ) {
        self.payload = payload
        self.actions = actions
        self.isCompactWidth = isCompactWidth
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(payload.items) { item in
                        ShelfTile(item: item, onRemove: { actions.remove(item.path) })
                            .onTapGesture { actions.reveal(item.path) }
                            // One element per tile: the remove control is
                            // hover-only, so it never exists where VoiceOver
                            // could land on it anyway.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(item.name)
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
                .font(.cardLabel)
                .foregroundStyle(.white.opacity(0.7))
            Text(payload.items.count == 1 ? "1 item" : "\(payload.items.count) items")
                .font(.cardControl)
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 8)
            if !isCompactWidth {
                Button("Clear", action: actions.clear)
                    .buttonStyle(.plain)
                    .font(.cardBody)
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityLabel("Clear shelf")
            }
        }
    }
}

/// One file: its Finder icon, its name, a remove affordance on hover — and it is
/// draggable straight back out into any app.
struct ShelfTile: View {

    let item: ShelfItem
    let onRemove: () -> Void

    @State private var hovering = false

    private var icon: NSImage? {
        item.iconData.flatMap { NSImage(data: $0) }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .frame(width: 34, height: 34)

                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white, .black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item.name)")
                    .offset(x: 5, y: -5)
                    .transition(.opacity)
                }
            }

            Text(item.name)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 52)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.white.opacity(0.10)) : AnyShapeStyle(.clear))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // The real file URL, so dropping onto Finder, Mail or anything else
        // behaves exactly as dragging from Finder would.
        .draggable(URL(fileURLWithPath: item.path))
        // The remove button only exists while hovered, which VoiceOver never
        // is; the tile is one element and carries the action itself.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityAction(named: "Remove", onRemove)
    }
}
