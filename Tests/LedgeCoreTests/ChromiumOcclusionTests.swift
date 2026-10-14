import Foundation
import LedgeCore
import Testing

/// A browser that stalls behind a shut lid fails silently: the page is still
/// there, the agent is still waiting, and nothing happens. So the check has to
/// be right about what counts as protected — a false yes here means an agent
/// that quietly stops and nobody told.
@Suite("Chromium behind a shut lid")
struct ChromiumOcclusionTests {

    private let both = ChromiumOcclusion.flags.joined(separator: " ")

    @Test("Both flags present is protected")
    func bothFlags() {
        #expect(ChromiumOcclusion.isProtected(
            commandLine: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome \(both)"))
    }

    /// With only one the work still stalls, just differently — one stops the
    /// window being backgrounded, the other the renderer behind it.
    @Test("One flag alone is not enough")
    func oneFlagIsNotEnough() {
        for flag in ChromiumOcclusion.flags {
            #expect(!ChromiumOcclusion.isProtected(commandLine: "/path/Chrome \(flag)"),
                    "\(flag) alone was taken as protection")
        }
    }

    @Test("No flags is not protected")
    func noFlags() {
        #expect(!ChromiumOcclusion.isProtected(commandLine: "/path/Chrome --restore-last-session"))
        #expect(!ChromiumOcclusion.isProtected(commandLine: ""))
    }

    /// The near-miss that makes a check look like it works. Nobody passes
    /// this flag, which is exactly why a `contains` would never be caught
    /// being wrong until it mattered.
    @Test("A flag that merely starts the same way does not count")
    func prefixIsNotAMatch() {
        let impostor = ChromiumOcclusion.flags.map { $0 + "-except-this" }.joined(separator: " ")
        #expect(!ChromiumOcclusion.isProtected(commandLine: "/path/Chrome \(impostor)"))
    }

    @Test("A flag given with a value still counts")
    func flagWithValue() {
        let valued = ChromiumOcclusion.flags.map { $0 + "=true" }.joined(separator: " ")
        #expect(ChromiumOcclusion.isProtected(commandLine: "/path/Chrome \(valued)"))
    }

    @Test("Flags are found wherever they sit on the line")
    func orderDoesNotMatter() {
        let line = "/path/Chrome \(ChromiumOcclusion.flags[1]) --foo \(ChromiumOcclusion.flags[0]) --bar"
        #expect(ChromiumOcclusion.isProtected(commandLine: line))
    }

    /// Firefox is not Chromium and does not take these flags; Safari has no
    /// equivalent switch at all. Offering either a fix that cannot work would
    /// be worse than saying nothing.
    @Test("Only Chromium browsers are Chromium")
    func onlyChromium() {
        #expect(ChromiumOcclusion.isChromium("com.google.Chrome"))
        #expect(ChromiumOcclusion.isChromium("company.thebrowser.Browser"))
        #expect(!ChromiumOcclusion.isChromium("org.mozilla.firefox"))
        #expect(!ChromiumOcclusion.isChromium("com.apple.Safari"))
    }
}

@Suite("Which browsers to warn about")
struct ChromiumAdviceTests {

    private func browser(_ id: String, protected: Bool) -> ChromiumBrowser {
        ChromiumBrowser(bundleID: id, name: id, isProtected: protected)
    }

    /// A Chromium window somebody left open is not a reason to suggest
    /// restarting anything. The advice is for the browser an agent is driving,
    /// and the roster is where the user says which that is.
    @Test("A browser nobody put on the roster is nobody's problem")
    func offRosterIsIgnored() {
        let running = [browser("com.google.Chrome", protected: false)]
        #expect(ChromiumAdvice.stalling(running, roster: AgentRoster(["com.a"])).isEmpty)
    }

    @Test("A roster browser without the flags is named")
    func onRosterUnprotectedIsNamed() {
        let running = [browser("com.google.Chrome", protected: false)]
        let stalling = ChromiumAdvice.stalling(running, roster: AgentRoster(["com.google.Chrome"]))
        #expect(stalling.map(\.bundleID) == ["com.google.Chrome"])
    }

    @Test("A roster browser that already has them is left alone")
    func protectedIsNotNamed() {
        let running = [browser("com.google.Chrome", protected: true)]
        #expect(ChromiumAdvice.stalling(running, roster: AgentRoster(["com.google.Chrome"])).isEmpty)
    }

    /// The flags only take effect at launch, so the only honest fix is a
    /// restart — and a user who would rather do it themselves gets the command.
    @Test("The command carries both flags and names the browser")
    func commandIsComplete() {
        let command = ChromiumAdvice.launchCommand(
            for: browser("com.google.Chrome", protected: false))
        #expect(command.contains("com.google.Chrome"))
        for flag in ChromiumOcclusion.flags {
            #expect(command.contains(flag), "\(flag) was left out of the command")
        }
        #expect(command.contains("--args"), "without --args the flags go to open, not the browser")
    }
}
