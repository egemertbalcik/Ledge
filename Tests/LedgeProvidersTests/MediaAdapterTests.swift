import Foundation
import Testing

@testable import LedgeSystem

/// Fixture lines, copied from the real helper's output on macOS 26.4.
private enum Line {
    static let hello = #"{"kind":"hello","adapter":1,"ok":true,"pid":53442}"#

    static let playing = """
        {"pid":918,"displayName":"Spotify","album":"Cracker Island",\
        "elapsedAt":1785733298.475871,"artworkID":"a33ad2b0ece159c9",\
        "artworkMIME":"image/jpeg","title":"Possession Island (feat. Beck)",\
        "adapter":1,"elapsed":32.632,"t":1785754269.346797,\
        "bundleID":"com.spotify.client","ok":true,"duration":206.41,"rate":1,\
        "artist":"Gorillaz","kind":"now","playing":true}
        """

    static let idle = #"{"adapter":1,"ok":true,"kind":"now","t":1785754269.3,"playing":null}"#
    static let heartbeat = #"{"adapter":1,"ok":true,"kind":"heartbeat","t":1785754299.3}"#

    /// A browser tab: no bundleID from the client, only a pid.
    static let browserByPID = """
        {"adapter":1,"ok":true,"kind":"now","t":1785754269.3,"playing":true,\
        "title":"Some Video","artist":"A Channel","duration":600,"elapsed":12,\
        "rate":1,"pid":4711}
        """

    static func decode(_ text: String) -> AdapterPayload? {
        try? JSONDecoder().decode(AdapterPayload.self, from: Data(text.utf8))
    }
}

@Suite("Adapter payload decoding")
struct AdapterPayloadDecodeTests {

    @Test("A full playing line becomes a complete snapshot")
    func decodesPlayingLine() throws {
        let payload = try #require(Line.decode(Line.playing))
        #expect(payload.describesTrack)

        // Read it at the moment it was stamped, so no projection applies.
        let snapshot = try #require(payload.snapshot(at: 1785733298.475871))
        #expect(snapshot.title == "Possession Island (feat. Beck)")
        #expect(snapshot.artist == "Gorillaz")
        #expect(snapshot.album == "Cracker Island")
        #expect(snapshot.isPlaying)
        #expect(snapshot.duration == 206.41)
        #expect(snapshot.appBundleID == "com.spotify.client")
        #expect(snapshot.appName == "Spotify")
        #expect(snapshot.artworkID == "a33ad2b0ece159c9")
        #expect(snapshot.artworkData == nil, "this line carried no base64 artwork")
    }

    @Test("A null playing field means nothing is loaded")
    func idleLineHasNoSnapshot() throws {
        let payload = try #require(Line.decode(Line.idle))
        #expect(payload.describesTrack == false)
        #expect(payload.snapshot(at: 0) == nil)
    }

    @Test("The handshake and heartbeat are liveness, not tracks")
    func nonTrackLines() throws {
        let hello = try #require(Line.decode(Line.hello))
        #expect(hello.kind == .hello)
        #expect(hello.snapshot(at: 0) == nil)

        let beat = try #require(Line.decode(Line.heartbeat))
        #expect(beat.kind == .heartbeat)
        #expect(beat.snapshot(at: 0) == nil)
    }

    @Test("A line with only a pid asks the resolver for the app")
    func resolvesAppFromPID() throws {
        let payload = try #require(Line.decode(Line.browserByPID))
        // Without a resolver there is no bundle id, so no snapshot.
        #expect(payload.snapshot(at: 0) == nil)

        let snapshot = try #require(payload.snapshot(at: 0) { pid in
            pid == 4711 ? ("Google Chrome", "com.google.Chrome") : nil
        })
        #expect(snapshot.appBundleID == "com.google.Chrome")
        #expect(snapshot.appName == "Google Chrome")
    }

    @Test("Malformed and truncated input returns nil rather than throwing")
    func malformedInput() {
        #expect(Line.decode("not json at all") == nil)
        #expect(Line.decode("") == nil)
        // Truncated mid-string.
        #expect(Line.decode(String(Line.playing.prefix(60))) == nil)
    }

    @Test("Unknown keys are ignored, so a new macOS field cannot break decoding")
    func unknownKeysIgnored() throws {
        let text = #"{"adapter":1,"ok":true,"kind":"now","playing":true,"title":"T","bundleID":"x","somethingNew":42}"#
        let payload = try #require(Line.decode(text))
        #expect(payload.describesTrack)
        #expect(payload.snapshot(at: 0)?.title == "T")
    }

    @Test("Base64 artwork is decoded to bytes")
    func decodesArtwork() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let text = """
            {"adapter":1,"ok":true,"kind":"now","playing":true,"title":"T",\
            "bundleID":"x","artworkID":"abc","artwork":"\(bytes.base64EncodedString())"}
            """
        let snapshot = try #require(Line.decode(text)?.snapshot(at: 0))
        #expect(snapshot.artworkData == bytes)
    }
}

@Suite("Elapsed projection")
struct ElapsedProjectionTests {

    private func payload(elapsed: Double, at stamp: Double, rate: Double, duration: Double) -> AdapterPayload {
        let text = """
            {"adapter":1,"ok":true,"kind":"now","playing":true,"title":"T",\
            "bundleID":"x","elapsed":\(elapsed),"elapsedAt":\(stamp),\
            "rate":\(rate),"duration":\(duration)}
            """
        return try! JSONDecoder().decode(AdapterPayload.self, from: Data(text.utf8))
    }

    @Test("Playing at normal speed, the position advances with wall time")
    func projectsForward() {
        let line = payload(elapsed: 10, at: 1000, rate: 1, duration: 300)
        #expect(line.snapshot(at: 1000)?.elapsed == 10)
        #expect(line.snapshot(at: 1005)?.elapsed == 15)
    }

    @Test("A paused track does not advance")
    func pausedDoesNotAdvance() {
        let line = payload(elapsed: 10, at: 1000, rate: 0, duration: 300)
        #expect(line.snapshot(at: 1060)?.elapsed == 10)
    }

    @Test("The projection never runs past the track's duration")
    func clampsToDuration() {
        let line = payload(elapsed: 290, at: 1000, rate: 1, duration: 300)
        #expect(line.snapshot(at: 2000)?.elapsed == 300)
    }

    @Test("A timestamp in the future cannot rewind the position")
    func futureStampDoesNotRewind() {
        let line = payload(elapsed: 42, at: 2000, rate: 1, duration: 300)
        #expect(line.snapshot(at: 1000)?.elapsed == 42)
    }
}

@Suite("Line buffering")
struct LineBufferTests {

    private func lines(from chunks: [Data]) -> [String] {
        var buffer = LineBuffer()
        var out: [String] = []
        for chunk in chunks {
            out += buffer.append(chunk).map { String(decoding: $0, as: UTF8.self) }
        }
        return out
    }

    @Test("The same bytes split any way produce the same lines")
    func chunkingIsIrrelevant() {
        let stream = Data("one\ntwo\nthree\n".utf8)

        let whole = lines(from: [stream])
        let bytewise = lines(from: stream.map { Data([$0]) })
        let sevens = lines(from: stride(from: 0, to: stream.count, by: 7).map {
            Data(stream[$0..<min($0 + 7, stream.count)])
        })

        #expect(whole == ["one", "two", "three"])
        #expect(bytewise == whole)
        #expect(sevens == whole)
    }

    @Test("A line with no trailing newline is held, not emitted early")
    func partialLineHeld() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("partial".utf8)).isEmpty)
        let finished = buffer.append(Data("-rest\n".utf8))
        #expect(finished.map { String(decoding: $0, as: UTF8.self) } == ["partial-rest"])
    }

    @Test("An absurdly long line is dropped and the buffer recovers")
    func oversizedLineDropped() {
        var buffer = LineBuffer()
        let huge = Data(repeating: 0x41, count: LineBuffer.maximumLineLength + 10)
        #expect(buffer.append(huge).isEmpty)
        // The tail of the dropped line must not become the head of the next.
        _ = buffer.append(Data("junk\n".utf8))
        let recovered = buffer.append(Data("good\n".utf8))
        #expect(recovered.map { String(decoding: $0, as: UTF8.self) } == ["good"])
    }

    @Test("Blank lines are skipped")
    func blankLinesSkipped() {
        #expect(lines(from: [Data("\n\na\n\n".utf8)]) == ["a"])
    }
}

@Suite("Adapter restart policy")
struct AdapterRestartPolicyTests {

    @Test("Backoff doubles and then holds at a minute")
    func backoffDoubles() {
        var policy = AdapterRestartPolicy()
        let delays = (0..<5).map { _ in
            policy.nextDelay(now: 0, lastRunDuration: 1)
        }
        #expect(delays == [1, 2, 4, 8, 16])
    }

    @Test("A run that lasted a while resets the backoff")
    func longRunResets() {
        var policy = AdapterRestartPolicy()
        _ = policy.nextDelay(now: 0, lastRunDuration: 1)
        _ = policy.nextDelay(now: 1, lastRunDuration: 1)
        // Ran for a minute before dying: transient, not broken.
        #expect(policy.nextDelay(now: 100, lastRunDuration: 60) == 1)
    }

    @Test("Too many restarts in the window gives up for good")
    func ceilingStopsTrying() {
        var policy = AdapterRestartPolicy()
        for index in 0..<AdapterRestartPolicy.maximumRestarts {
            #expect(policy.nextDelay(now: Double(index), lastRunDuration: 1) != nil)
        }
        #expect(
            policy.nextDelay(now: 6, lastRunDuration: 1) == nil,
            "a helper that crashes on load must not become a fork bomb"
        )
    }

    @Test("Restarts spread beyond the window do not trip the ceiling")
    func staleFailuresExpire() {
        var policy = AdapterRestartPolicy()
        for index in 0..<AdapterRestartPolicy.maximumRestarts {
            _ = policy.nextDelay(now: Double(index), lastRunDuration: 1)
        }
        let later = AdapterRestartPolicy.window + 10
        #expect(policy.nextDelay(now: later, lastRunDuration: 1) != nil)
    }
}

/// Round-one hunt pins for the restart policy's give-up window.
@Suite("Adapter restart policy, hunt regressions")
struct AdapterRestartPolicyHuntTests {

    @Test("Long runs never accumulate toward the give-up window")
    func longRunsStayOutOfTheWindow() {
        var policy = AdapterRestartPolicy()
        // A helper that reliably works for over half a minute and then dies is
        // degraded service, not a broken build: it must keep being restarted
        // indefinitely, not abandoned on the fifth death.
        for index in 0..<(AdapterRestartPolicy.maximumRestarts * 3) {
            #expect(policy.nextDelay(now: Double(index * 40), lastRunDuration: 35) != nil)
        }
    }
}
