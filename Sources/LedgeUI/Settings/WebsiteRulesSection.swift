import LedgeCore
import SwiftUI

/// Which websites may appear in the notch, and how far.
///
/// An allow list rather than a switch. A browser holds one now-playing slot
/// for every tab and hands it around, so "show web media" meant showing
/// whatever a background tab decided to play; naming the handful of sites you
/// actually listen to is the thing people wanted instead.
struct WebsiteRulesSection: View {

    @Bindable var preferences: Preferences

    @State private var editing: Editing?
    @State private var selection: WebsiteHost?

    /// The sheet's subject: a new website, or one being changed.
    private struct Editing: Identifiable {
        var id: String { existing?.value ?? "new" }
        var existing: WebsiteHost?
        var text: String
        var appearance: WebsiteAppearance
    }

    private var policy: WebsitePolicy { preferences.webMedia }

    var body: some View {
        Section("Web media") {
            Text("Web media is hidden unless you allow its website.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if preferences.webMediaNoticePending {
                // Said plainly, and only until the user has answered it by
                // dismissing or adding a site. Persisted, so the relaunch that
                // follows an update does not swallow the explanation.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ledge used to show media from every website. That setting has been replaced by this list, and no websites were added for you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Got It") { preferences.webMediaNoticePending = false }
                        .accessibilityLabel("Dismiss the explanation about web media")
                }
                .padding(.vertical, 2)
            }

            if policy.isEmpty {
                emptyState
            } else {
                list
            }

            HStack {
                Button("Add Website…") { editing = Editing(existing: nil, text: "", appearance: .card) }
                if let selection, policy.rule(for: selection) != nil {
                    Button("Edit…") { beginEditing(selection) }
                    Button("Remove", role: .destructive) { remove(selection) }
                }
            }
            .padding(.top, 2)

            Text("Ledge cannot always tell which website media came from. When it cannot, that media stays hidden whatever this list says.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { subject in
            WebsiteRuleSheet(
                subject: subject.existing,
                text: subject.text,
                appearance: subject.appearance,
                isDuplicate: { host in
                    host != subject.existing && policy.rules.contains { $0.host == host }
                },
                onSave: { rule in
                    save(rule, replacing: subject.existing)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    private var emptyState: some View {
        Text("No websites yet. Add one to let its media appear.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(policy.rules) { rule in
                Button {
                    selection = rule.host
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.host.value)
                            Text(rule.appearance.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == rule.host {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(rule.host.value), \(rule.appearance.title)")
                .accessibilityHint("Select to edit or remove this website")
                .accessibilityAddTraits(selection == rule.host ? [.isSelected] : [])
                // Double-click to edit, as a list row does everywhere else.
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    selection = rule.host
                    beginEditing(rule.host)
                })
                if rule.host != policy.rules.last?.host { Divider() }
            }
        }
    }

    private func beginEditing(_ host: WebsiteHost) {
        guard let rule = policy.rule(for: host) else { return }
        editing = Editing(existing: rule.host, text: rule.host.value, appearance: rule.appearance)
    }

    private func save(_ rule: WebsiteRule, replacing existing: WebsiteHost?) {
        var updated = policy
        // An edit that renames the site removes the old rule, so editing
        // `youtube.com` into `music.youtube.com` leaves one rule rather than
        // two — the second of which would have been a permission nobody asked
        // for.
        if let existing, existing != rule.host { updated = updated.removing(existing) }
        preferences.webMedia = updated.setting(rule)
        selection = rule.host
    }

    private func remove(_ host: WebsiteHost) {
        preferences.webMedia = policy.removing(host)
        selection = nil
    }
}

/// Adding or changing one website.
private struct WebsiteRuleSheet: View {

    let subject: WebsiteHost?
    @State var text: String
    @State var appearance: WebsiteAppearance
    let isDuplicate: (WebsiteHost) -> Bool
    let onSave: (WebsiteRule) -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool

    /// What the typed text amounts to, and what to say about it.
    private var validation: (host: WebsiteHost?, message: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        guard let host = WebsiteHost(trimmed) else {
            return (nil, "That is not a website address Ledge can use. Try youtube.com.")
        }
        if isDuplicate(host) {
            return (nil, "\(host.value) is already in the list.")
        }
        return (host, nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(subject == nil ? "Add Website" : "Edit Website")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Website", text: $text, prompt: Text("youtube.com"))
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { saveIfValid() }
                    .accessibilityLabel("Website address")

                if let host = validation.host, host.value != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    // Shown before saving, so the canonical form is never a
                    // surprise after the fact.
                    Text("Will be saved as \(host.value)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let message = validation.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("A website address, or a link to a page on it. Subdomains are included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Appearance", selection: $appearance) {
                ForEach(WebsiteAppearance.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveIfValid() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation.host == nil)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { fieldFocused = true }
    }

    private func saveIfValid() {
        guard let host = validation.host else { return }
        onSave(WebsiteRule(host: host, appearance: appearance))
    }
}

/// `sheet(item:)` for a plain `Identifiable` binding, which SwiftUI spells
/// `sheet(item:onDismiss:content:)` only for `Binding<Item?>`.
private extension View {
    func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
