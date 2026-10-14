import AppKit
import LedgeCore

/// Where a lid-closed hold is visible when the lid is shut.
///
/// Ledge's entire UI is the notch, and the notch is on the built-in display.
/// Shut the lid with an external display attached and that panel is off: the
/// island does not exist, the card does not exist, and a Mac being held awake
/// by a root daemon has no surface at all. The user would have no way to know
/// it was happening and no way to stop it short of opening the lid — which is
/// the one thing the mode exists to spare them.
///
/// So a menu-bar item, scoped to the session. It appears when the hold does
/// and goes when the hold goes, which is the difference between a feature that
/// reports itself and an app that has moved into the menu bar: nobody who
/// never uses the mode ever sees it.
///
/// Thin on purpose. Every decision worth arguing about — whether there is an
/// item at all, what it says — is made by `KeepAwakeLidBadge` in LedgeCore,
/// where it can be tested without a window server.
///
/// `NSObject` because an `NSMenuItem`'s target is reached by Objective-C
/// message send, and a target that is not one is a menu item whose action
/// silently goes nowhere.
@MainActor
final class KeepAwakeLidStatusItem: NSObject {

    private var item: NSStatusItem?
    private var shown: KeepAwakeLidBadge?
    private let end: () -> Void

    /// - Parameter end: lets the Mac sleep again. The menu's only verb.
    init(end: @escaping () -> Void) {
        self.end = end
        super.init()
    }

    /// Shows, updates, or takes away the item.
    ///
    /// Idempotent, because it is called from the publish path and that fires
    /// once a minute for the whole of a session that may run for days. An
    /// unchanged badge must not rebuild the item: a status item that is
    /// replaced jumps in the menu bar, and a menu that is rebuilt under an
    /// open menu closes it.
    func show(_ badge: KeepAwakeLidBadge?) {
        let change = Self.plan(from: shown, to: badge)
        shown = badge
        switch change {
        case .nothing:
            return
        case .remove:
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        case .draw(let badge):
            draw(badge)
        }
    }

    /// What a new reading means for the item that is already there.
    ///
    /// Pure and static so the decision can be made in a test: putting an item
    /// in a real menu bar to find out whether a redundant publish rebuilds it
    /// is not something a test suite may do to somebody's Mac.
    enum Change: Equatable {
        /// The same badge as last time. Leave the item exactly as it is.
        case nothing
        case draw(KeepAwakeLidBadge)
        case remove
    }

    static func plan(from shown: KeepAwakeLidBadge?, to badge: KeepAwakeLidBadge?) -> Change {
        // The publish path fires once a minute for the whole of a session that
        // may run for days. Rebuilding an unchanged item makes it jump in the
        // menu bar, and rebuilding its menu underneath an open one closes it.
        guard badge != shown else { return .nothing }
        guard let badge else { return .remove }
        return .draw(badge)
    }

    private func draw(_ badge: KeepAwakeLidBadge) {
        let item = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: badge.symbolName,
                                   accessibilityDescription: badge.spoken)
            // Template, so it follows a light or dark menu bar rather than
            // being a tan smudge in one of them.
            button.image?.isTemplate = true
            button.toolTip = badge.headline
            button.setAccessibilityLabel(badge.spoken)
        }
        item.menu = menu(for: badge)
    }

    /// Takes the item away whatever it is showing. For a quit, where the
    /// badge's own source is already gone.
    func hide() { show(nil) }

    /// Internal rather than private so a test can read it. An `NSMenu` can be
    /// built without a status bar to hang it from, which is what makes the one
    /// promise this item has to keep — that clicking it can end the hold —
    /// checkable at all.
    func menu(for badge: KeepAwakeLidBadge) -> NSMenu {
        let menu = NSMenu()
        // The sentence first, as an item nobody can press. A menu-bar icon
        // that only offers "stop" leaves the user to work out what they are
        // stopping from a picture of a coffee cup.
        menu.addItem(disabled(badge.headline))
        if let detail = badge.detail {
            menu.addItem(disabled(detail))
        }
        menu.addItem(.separator())
        let ending = NSMenuItem(title: badge.endTitle,
                                action: #selector(endPressed), keyEquivalent: "")
        ending.target = self
        menu.addItem(ending)
        return menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func endPressed() {
        end()
    }
}
