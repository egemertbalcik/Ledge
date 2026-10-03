import Foundation
import LedgeCore
import LedgeMediaAdapter
import Testing

@testable import LedgeSystem

/// The real parser, called directly.
///
/// This is the one piece of the origin path written in C, and it decides what
/// counts as evidence of a website — so it is tested by calling exactly what
/// the helper calls, rather than by a Swift re-implementation that could
/// drift from it.
@Suite("Reading an asset URL")
struct AssetURLParsingTests {

    /// Calls the exported parser and returns both of its answers.
    private func parse(_ text: String?) -> (host: String?, fromBlob: Bool) {
        var fromBlob: ObjCBool = false
        let host = ledge_media_adapter_host_of_asset(text, &fromBlob)
        return (host, fromBlob.boolValue)
    }

    /// The case the whole feature rests on: media-source playback, where the
    /// page's own script creates the blob.
    @Test("A blob URL yields its inner origin, marked as a blob")
    func blobURL() {
        let result = parse("blob:https://music.youtube.com/8f2c-4a1b-9d3e")
        #expect(result.host == "music.youtube.com")
        #expect(result.fromBlob, "the one signal that stands for a website was lost")
    }

    @Test("An uppercase blob scheme is still a blob")
    func uppercaseBlobScheme() {
        let result = parse("BLOB:HTTPS://music.youtube.com/8f2c")
        #expect(result.host == "music.youtube.com")
        #expect(result.fromBlob)
    }

    /// An ordinary CDN asset: a host, and emphatically *not* a blob.
    @Test("A direct asset URL is read but not marked as a blob", arguments: [
        "https://rr3---sn-4g5e6nsz.googlevideo.com/videoplayback?expire=1&ei=secret",
        "http://d2wrhdhlxnsn6a.cloudfront.net/media/track.mp3",
        "https://video-weaver.lhr03.hls.ttvnw.net/v1/playlist/abc.m3u8",
    ])
    func directAsset(text: String) {
        let result = parse(text)
        #expect(result.host != nil)
        #expect(result.fromBlob == false, "a CDN URL was marked as a web origin")
    }

    /// The privacy promise at its source: whatever comes in, only a host
    /// comes out.
    @Test("Paths, queries and fragments are stripped", arguments: [
        "https://youtube.com/watch?v=dQw4w9WgXcQ&list=private#t=42",
        "blob:https://youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com:8443/some/deep/path",
    ])
    func onlyTheHostSurvives(text: String) {
        let host = parse(text).host
        #expect(host == "youtube.com", "got \(host ?? "nil")")
    }

    @Test("A non-web scheme has no host to give", arguments: [
        "file:///Users/someone/Music/track.mp3",
        "ipod-library://item/item.m4a?id=1",
        "data:audio/mp3;base64,AAAA",
        "blob:file:///tmp/x",
        "blob:data:audio/mp3;base64,AAAA",
    ])
    func nonWebSchemes(text: String) {
        let result = parse(text)
        #expect(result.host == nil, "\(text) produced a host")
        #expect(result.fromBlob == false, "\(text) was marked as a web origin")
    }

    @Test("Credentials are refused")
    func credentialsRefused() {
        #expect(parse("https://user:secret@youtube.com/watch").host == nil)
        #expect(parse("blob:https://user:secret@youtube.com/x").host == nil)
    }

    @Test("Malformed and empty values yield nothing", arguments: [
        "", "   ", "blob:", "blob:blob:", "https://", "://nope", "not a url at all",
    ])
    func malformed(text: String) {
        let result = parse(text)
        #expect(result.host == nil, "\(text) produced \(result.host ?? "")")
    }

    @Test("A missing value yields nothing")
    func missingValue() {
        let result = parse(nil)
        #expect(result.host == nil)
        #expect(result.fromBlob == false)
    }

    /// Only one level is unwrapped on purpose: a nested blob is not a real
    /// shape, and looping here would loop on attacker-shaped input.
    @Test("Nested blobs are not unwrapped repeatedly")
    func nestedBlob() {
        // After one unwrap this is `blob:https://…`, whose scheme is `blob`,
        // which is not a web scheme — so nothing comes back.
        #expect(parse("blob:blob:https://youtube.com/x").host == nil)
    }

    /// And the end-to-end shape: what the parser produces becomes evidence,
    /// and only the blob case can match a rule.
    @Test("The parser's answers become the right evidence")
    func feedsEvidence() {
        let blob = parse("blob:https://music.youtube.com/8f2c")
        let blobEvidence = MediaOriginEvidence.from(host: blob.host, isBlob: blob.fromBlob)
        #expect(blobEvidence.verifiedWebsite?.value == "music.youtube.com")

        let cdn = parse("https://rr3---sn-x.googlevideo.com/videoplayback?expire=1")
        let cdnEvidence = MediaOriginEvidence.from(host: cdn.host, isBlob: cdn.fromBlob)
        #expect(cdnEvidence.hasAnyHost)
        #expect(cdnEvidence.verifiedWebsite == nil, "a CDN became a website")
    }
}
