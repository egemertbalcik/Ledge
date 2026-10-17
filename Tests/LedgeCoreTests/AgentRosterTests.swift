import Foundation
import LedgeCore
import Testing

@Suite("The agent roster")
struct AgentRosterTests {

    @Test("What ships is a list somebody could read")
    func shippedIsSane() {
        let roster = AgentRoster()
        #expect(!roster.bundleIDs.isEmpty)
        #expect(roster.bundleIDs.count == Set(roster.bundleIDs).count, "a duplicate shipped")
        for id in roster.bundleIDs {
            #expect(AgentRoster.isWritableDomain(id), "\(id) is not a domain that can be written back")
        }
    }

    /// The agents this is for run *inside* a terminal, and the terminal is the
    /// app macOS knows about. A roster with no terminal on it would nap the
    /// one process the whole feature exists to keep running.
    @Test("Terminals are on the shipped roster")
    func terminalsShip() {
        let roster = AgentRoster()
        #expect(roster.carries("com.apple.Terminal"))
        #expect(roster.carries("com.mitchellh.ghostty"))
        #expect(roster.carries("com.googlecode.iterm2"))
    }

    @Test("Adding keeps order and refuses a duplicate")
    func addIsOrderedAndUnique() {
        var roster = AgentRoster(["com.a", "com.b"])
        roster.add("com.c")
        #expect(roster.bundleIDs == ["com.a", "com.b", "com.c"])
        roster.add("com.a")
        #expect(roster.bundleIDs == ["com.a", "com.b", "com.c"], "a duplicate was added")
    }

    @Test("Removing takes out exactly one entry")
    func remove() {
        var roster = AgentRoster(["com.a", "com.b", "com.c"])
        roster.remove("com.b")
        #expect(roster.bundleIDs == ["com.a", "com.c"])
    }

    /// `NSGlobalDomain` is every app on the Mac at once. Writing
    /// `NSAppSleepDisabled` there would turn App Nap off for everything —
    /// the exact opposite of a feature whose point is that only the agents
    /// keep running — and no recovery could name what it had changed.
    @Test("The global domain is never a roster entry")
    func globalDomainRefused() {
        #expect(!AgentRoster.isWritableDomain("NSGlobalDomain"))
        #expect(!AgentRoster.isWritableDomain(".GlobalPreferences"))
        #expect(AgentRoster(["NSGlobalDomain", "com.a"]).bundleIDs == ["com.a"])
    }

    /// CFPreferences' sentinels are ordinary strings — `kCFPreferencesAnyApplication`
    /// is literally that text — so they break none of the shape rules and a
    /// guard looking only for suspicious characters waves them through. Passed
    /// as an application id they address global preferences, and
    /// `NSAppSleepDisabled` written there turns App Nap off for every app on
    /// the Mac, with one journal entry naming a domain that is not an app.
    @Test("A CFPreferences sentinel is never a roster entry")
    func sentinelsRefused() {
        for sentinel in ["kCFPreferencesAnyApplication", "kCFPreferencesCurrentApplication",
                         "kCFPreferencesAnyUser", "kCFPreferencesCurrentUser",
                         "kCFPreferencesAnyHost", "kCFPreferencesCurrentHost"] {
            #expect(!AgentRoster.isWritableDomain(sentinel), "\(sentinel) was accepted")
            #expect(!AgentRoster.isWritableDomain(sentinel.lowercased()),
                    "\(sentinel) was accepted in another case")
            #expect(!AgentRoster.isWritableDomain(sentinel.uppercased()),
                    "\(sentinel) was accepted in another case")
        }
        #expect(AgentRoster(["kCFPreferencesAnyApplication", "com.a"]).bundleIDs == ["com.a"])
    }

    /// `apple.com` is the preference domain behind `.GlobalPreferences` by
    /// another name.
    @Test("The global domain's other spelling is refused too")
    func appleComRefused() {
        #expect(!AgentRoster.isWritableDomain("apple.com"))
    }

    /// Each of these is something `defaults` would read as other than a
    /// bundle's own domain, so a write could land anywhere and a restore
    /// could not find it again.
    @Test("Anything that is not a bundle's own domain is refused")
    func onlyRealDomains() {
        for bad in ["", "-f", "/tmp/evil", "../escape", "com..a", "com.a ", "com.a/b",
                    ".leading", "trailing.", "com.ä"] {
            #expect(!AgentRoster.isWritableDomain(bad), "\(bad.debugDescription) was accepted")
        }
        for good in ["com.apple.Terminal", "dev.zed.Zed", "com.todesktop.230313mzl4w4u92",
                     "org.alacritty", "a_b-c.d"] {
            #expect(AgentRoster.isWritableDomain(good), "\(good) was refused")
        }
    }

    @Test("A roster survives being stored and read back")
    func roundTrip() {
        let roster = AgentRoster(["com.a", "com.b"])
        #expect(AgentRoster(stored: roster.stored).bundleIDs == ["com.a", "com.b"])
        #expect(AgentRoster(stored: "").bundleIDs.isEmpty, "an empty store is an empty roster")
    }
}

@Suite("Which App Nap preferences get written")
struct AppNapPlanTests {

    private let roster = AgentRoster(["com.a", "com.b", "com.c"])

    @Test("An app with no key is written, and remembered as having had none")
    func absentKeyIsWritten() {
        let plan = AppNapPlan.writes(for: roster) { _ in .some(nil) }
        #expect(plan.map(\.bundleID) == ["com.a", "com.b", "com.c"])
        #expect(plan.allSatisfy { $0.previous == nil })
    }

    @Test("An app whose key is false is written, and remembered as false")
    func falseIsRemembered() {
        let plan = AppNapPlan.writes(for: roster) { _ in .some(false) }
        #expect(plan.allSatisfy { $0.previous == false })
    }

    /// Writing `true` over the user's own `true` and then deleting it on
    /// restore would leave them without a setting they had chosen. Doing
    /// nothing is strictly better here than doing the right thing.
    @Test("An app already set to true is left entirely alone")
    func alreadyTrueIsSkipped() {
        #expect(AppNapPlan.writes(for: roster) { _ in .some(true) }.isEmpty)
    }

    /// A preference nobody could read is a preference nobody could write
    /// back, so it is never written in the first place.
    @Test("An unreadable preference is never written")
    func unreadableIsSkipped() {
        let plan = AppNapPlan.writes(for: roster) { id in id == "com.b" ? nil : .some(nil) }
        #expect(plan.map(\.bundleID) == ["com.a", "com.c"])
    }

    @Test("An empty roster writes nothing")
    func emptyRosterWritesNothing() {
        #expect(AppNapPlan.writes(for: AgentRoster([])) { _ in .some(nil) }.isEmpty)
    }
}

/// What the Keep Awake list calls the apps on it.
@Suite("Naming the apps on the roster")
struct AgentRosterNamingTests {

    @Test("Every shipped app has a name, and none of them is a bundle-id fragment")
    func everyShippedAppIsNamed() {
        for id in AgentRoster.shipped {
            guard let name = AgentRoster.shippedName(of: id) else {
                Issue.record("\(id) has no name, so a closed one would show as an id fragment")
                continue
            }
            #expect(!name.isEmpty)
        }
    }

    @Test("The ones that used to read as rubbish read as themselves")
    func theWorstOffenders() {
        // Four of these are what somebody tidying the list actually saw, and
        // one of them is Claude. Taking it off the list because it looked
        // like junk is a thing this naming exists to prevent.
        let known = [
            "com.todesktop.230313mzl4w4u92": "Cursor",
            "com.anthropic.claudefordesktop": "Claude",
            "com.openai.chat": "ChatGPT",
            "company.thebrowser.Browser": "Arc",
            "dev.warp.Warp-Stable": "Warp",
            "com.googlecode.iterm2": "iTerm2",
            "com.microsoft.VSCode": "Visual Studio Code",
        ]
        for (id, name) in known {
            #expect(AgentRoster.shippedName(of: id) == name, "\(id) still has no proper name")
        }
        // And where the app really is called that, the name is left alone.
        #expect(AgentRoster.shippedName(of: "net.kovidgoyal.kitty") == "kitty")
    }

    @Test("An app nobody shipped is not guessed at")
    func unknownAppsAreNotNamed() {
        #expect(AgentRoster.shippedName(of: "com.example.whatever") == nil)
    }
}
