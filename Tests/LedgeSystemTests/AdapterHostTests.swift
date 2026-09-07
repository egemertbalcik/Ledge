import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

@Suite("Choosing a host for the MediaRemote helper")
struct AdapterHostTests {

    /// The gate is on the bundle identifier: `mediaremoted` answers clients
    /// under `com.apple.` and nobody else. Both hosts qualify; `tclsh` is
    /// signed `com.tcltk.tclsh` and deliberately is not on the list.
    @Test("Both hosts are Apple binaries that can load a dylib and call C")
    func hostsAreApplePermitted() {
        #expect(AdapterHost.all.map(\.name) == ["perl", "ruby"])
        #expect(AdapterHost.perl.executable == "/usr/bin/perl")
        #expect(AdapterHost.ruby.executable == "/usr/bin/ruby")
    }

    @Test("Each host loads the same helper by its one exported symbol")
    func bothCallTheSameSymbol() {
        for host in AdapterHost.all {
            #expect(host.script.contains("ledge_media_adapter_main"))
            #expect(host.script.contains("LEDGE_ADAPTER_DYLIB"))
        }
    }

    /// `dl_load_file` does not exist without it, so the argument is not
    /// decoration — losing it breaks perl entirely.
    @Test("Perl is invoked with DynaLoader")
    func perlLoadsDynaLoader() {
        #expect(AdapterHost.perl.leadingArguments == ["-MDynaLoader"])
        #expect(AdapterHost.perl.arguments.last == AdapterHost.perl.script)
        #expect(AdapterHost.ruby.arguments == ["-e", AdapterHost.ruby.script])
    }

    @Test("An override picks exactly one host, present or not")
    func overrideForcesOneHost() {
        let forced = AdapterHost.candidates(environment: ["LEDGE_ADAPTER_HOST": "ruby"])
        #expect(forced.map(\.name) == ["ruby"])
        // The point of the override is to exercise the understudy on a Mac
        // where the first host still works, rather than discovering on the day
        // it is needed that it does not.
        #expect(AdapterHost.candidates(environment: ["LEDGE_ADAPTER_HOST": "nonesuch"]).isEmpty)
    }

    @Test("With no override, only hosts that exist are tried")
    func candidatesAreFilteredByPresence() throws {
        let candidates = AdapterHost.candidates(environment: [:])
        let allPresent = candidates.allSatisfy(\.isPresent)
        #expect(allPresent)
    }
}

@Suite("Saying what the app can see")
struct MediaSourceStatusTests {

    @Test("The full state names the component doing the reading")
    func systemWideMentionsHost() {
        let status = MediaSourceStatus.systemWide(host: "perl")
        #expect(status.isFull)
        #expect(status.detail.contains("perl"))
        #expect(status.headline == "Everything playing on this Mac")
    }

    /// A demotion is temporary and self-healing, and the sentence has to say
    /// so — otherwise it reads as a permanent fault the user should act on.
    @Test("A demotion says what is missing and when it will retry")
    func degradedExplainsItself() {
        let status = MediaSourceStatus.degraded(retryingInSeconds: 600)
        #expect(status.isFull == false)
        #expect(status.detail.contains("10 minutes"))
        #expect(status.detail.localizedCaseInsensitiveContains("browser"))
    }

    @Test("A moment away still rounds to a minute rather than to nothing")
    func degradedNeverSaysZero() {
        #expect(MediaSourceStatus.degraded(retryingInSeconds: 5).detail.contains("1 minute"))
    }

    @Test("With no route at all, nothing promises a recovery")
    func playersOnlyMakesNoPromise() {
        let status = MediaSourceStatus.playersOnly
        #expect(status.isFull == false)
        #expect(status.detail.localizedCaseInsensitiveContains("trying again") == false)
    }
}

@Suite("Holding on to a cover")
struct ArtworkCarryTests {

    private func line(
        title: String = "Track",
        trackID: String? = "1",
        artwork: String? = nil,
        artworkID: String? = nil
    ) -> AdapterPayload {
        var payload = AdapterPayload()
        payload.kind = .now
        payload.playing = true
        payload.title = title
        payload.trackID = trackID
        payload.bundleID = "com.apple.Safari"
        payload.artwork = artwork
        payload.artworkID = artworkID
        return payload
    }

    /// Artwork rides only on the line that introduces it, so every later line
    /// for the same track carries none and the bytes must be carried forward.
    @Test("The same track keeps its cover")
    func sameTrackKeepsArt() {
        #expect(MediaRemoteAdapterSource.isSameTrack(line(), line()))
    }

    /// The bug: a line that simply stopped mentioning artwork — which Safari
    /// does mid-video — used to fail an artwork-id comparison and take the
    /// cover down with it.
    @Test("A line that says nothing about artwork is still the same track")
    func silenceAboutArtworkIsNotAChange() {
        let withArt = line(artwork: "AAAA", artworkID: "abc")
        let without = line()
        #expect(MediaRemoteAdapterSource.isSameTrack(without, withArt))
    }

    @Test("A different track does not inherit the last one's cover")
    func differentTrackDoesNotInherit() {
        #expect(MediaRemoteAdapterSource.isSameTrack(line(trackID: "2"), line(trackID: "1")) == false)
    }

    /// A browser gives no identifier for some items, so what is on screen is
    /// all there is to compare.
    @Test("With no identifier, the title decides")
    func titleDecidesWithoutAnID() {
        #expect(MediaRemoteAdapterSource.isSameTrack(
            line(title: "Same", trackID: nil), line(title: "Same", trackID: nil)
        ))
        #expect(MediaRemoteAdapterSource.isSameTrack(
            line(title: "One", trackID: nil), line(title: "Two", trackID: nil)
        ) == false)
    }
}
