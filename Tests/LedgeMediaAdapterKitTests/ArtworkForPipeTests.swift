import CoreGraphics
import Foundation
import ImageIO
import LedgeMediaAdapterKit
import Testing

/// Images made in the test, in the shapes the adapter actually receives.
private enum Fixture {

    /// Gradients with grain in every pixel, so neither JPEG nor PNG can make
    /// it trivially small and a size check means something. `grain` is how
    /// many low bits are noise: a little for something shaped like a video
    /// frame, all eight for something no encoder can shrink.
    static func image(
        width: Int, height: Int, seed: UInt32 = 1, grain: UInt32 = 3, alpha: Bool = false
    ) -> CGImage {
        var state = seed
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Int(state >> (32 - grain))
            let pixel = index / 4
            let x = pixel % width, y = pixel / width
            pixels[index] = UInt8(truncatingIfNeeded: x * 255 / width + noise + Int(seed) * 40)
            pixels[index + 1] = UInt8(truncatingIfNeeded: y * 255 / height + noise)
            pixels[index + 2] = UInt8(truncatingIfNeeded: (x + y) * 128 / width + noise)
            pixels[index + 3] = alpha ? UInt8(truncatingIfNeeded: 128 + x % 128) : 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alpha
                ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    static func encode(_ image: CGImage, as type: String, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// What WebKit publishes for a video: the current frame, 720×724 RGBA,
    /// uncompressed TIFF.
    static func videoFrame(seed: UInt32 = 1) -> Data {
        encode(
            image(width: 720, height: 724, seed: seed, alpha: true),
            as: "public.tiff",
            properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]]
        )
    }

    static func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap(CGImageSourceGetType).map { $0 as String }
    }

    static func size(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }
}

private func forPipe(_ data: Data) -> (bytes: Data?, mime: String?) {
    var mime: NSString?
    let bytes = ledge_artwork_for_pipe(data, LedgeArtworkMaximumPixels, &mime)
    return (bytes, mime as String?)
}

@Suite("Artwork sent down the adapter's pipe")
struct ArtworkForPipeTests {

    @Test("A raw TIFF video frame is shrunk to a small JPEG")
    func videoFrameShrinks() throws {
        let frame = Fixture.videoFrame()
        try #require(frame.count > 1_500_000, "the fixture must be the multi-megabyte frame WebKit sends")
        try #require(Fixture.type(of: frame) == "public.tiff")

        let (bytes, mime) = forPipe(frame)
        let out = try #require(bytes)
        #expect(out.count <= 128 * 1024, "was \(out.count) bytes")
        #expect(out.prefix(2) == Data([0xFF, 0xD8]))
        #expect(mime == "image/jpeg")
        let size = try #require(Fixture.size(of: out))
        #expect(max(size.width, size.height) <= LedgeArtworkMaximumPixels)
        #expect(max(size.width, size.height) >= LedgeArtworkMaximumPixels - 1, "shrunk to the limit, not past it")
    }

    @Test("Small JPEG artwork passes through untouched")
    func smallJPEGUntouched() throws {
        // At full quality, so a re-encode would come out smaller and could
        // not hide behind the "send the source if it is not smaller" rule.
        let cover = Fixture.encode(
            Fixture.image(width: 300, height: 300), as: "public.jpeg",
            properties: [kCGImageDestinationLossyCompressionQuality: 1.0]
        )
        try #require(Fixture.type(of: cover) == "public.jpeg")
        try #require(cover.count <= LedgeArtworkPassThroughBytes)
        let reencoded = Fixture.encode(
            Fixture.image(width: 300, height: 300), as: "public.jpeg",
            properties: [kCGImageDestinationLossyCompressionQuality: 0.8]
        )
        try #require(reencoded.count < cover.count, "a re-encode must be distinguishable by size")

        let (bytes, mime) = forPipe(cover)
        #expect(bytes == cover)
        #expect(mime == "image/jpeg")
    }

    /// WebKit's label is not to be trusted, so the type is read off the bytes,
    /// and a PNG that needs no shrinking goes as PNG.
    @Test("Small PNG artwork passes through and is called PNG")
    func smallPNGNamedByItsBytes() throws {
        let cover = Fixture.encode(Fixture.image(width: 64, height: 64, alpha: true), as: "public.png")
        try #require(Fixture.type(of: cover) == "public.png")
        try #require(cover.count <= LedgeArtworkPassThroughBytes)

        let (bytes, mime) = forPipe(cover)
        #expect(bytes == cover)
        #expect(mime == "image/png")
    }

    @Test("A large PNG is shrunk but stays a PNG, keeping its transparency")
    func largePNGStaysPNG() throws {
        let cover = Fixture.encode(
            Fixture.image(width: 1400, height: 1400, grain: 8, alpha: true), as: "public.png"
        )
        try #require(Fixture.type(of: cover) == "public.png")
        try #require(cover.count > LedgeArtworkPassThroughBytes)

        let (bytes, mime) = forPipe(cover)
        let out = try #require(bytes)
        #expect(mime == "image/png")
        #expect(Fixture.type(of: out) == "public.png")
        #expect(out.count < cover.count)
        let size = try #require(Fixture.size(of: out))
        #expect(max(size.width, size.height) <= LedgeArtworkMaximumPixels)
    }

    @Test("Bytes ImageIO cannot read produce nothing to send")
    func unreadableBytesSendNothing() throws {
        let junk = Data(repeating: 0x41, count: 300_000)
        try #require(Fixture.type(of: junk) == nil)
        let (bytes, mime) = forPipe(junk)
        #expect(bytes == nil)
        #expect(mime == nil)
    }
}

@Suite("Artwork identity")
struct ArtworkIdentityTests {

    @Test("The artwork id names the source, not the thumbnail")
    func idNamesTheSource() throws {
        let frame = Fixture.videoFrame(seed: 1)
        let other = Fixture.videoFrame(seed: 2)
        try #require(frame != other, "the two fixtures must really be different images")

        let id = ledge_artwork_identifier(frame)
        #expect(id.count == 16)
        #expect(ledge_artwork_identifier(frame) == id, "the same source names the same id every time")
        #expect(ledge_artwork_identifier(other) != id)

        let shrunk = try #require(forPipe(frame).bytes)
        #expect(ledge_artwork_identifier(shrunk) != id, "the thumbnail is not what the id describes")
    }
}

@Suite("Artwork ids already sent")
struct ArtworkRememberTests {

    @Test("A video's two images are both remembered, so neither is resent")
    func flippingPairStaysRemembered() {
        var recent: [String] = []
        for id in ["frame", "poster", "frame", "poster", "frame"] {
            recent = ledge_artwork_remember(recent, id, LedgeArtworkRecentCapacity)
        }
        #expect(recent == ["frame", "poster"])
    }

    @Test("Newest first, trimmed to the capacity, oldest dropped")
    func trimsOldest() {
        var recent: [String] = []
        for id in ["a", "b", "c", "d", "e"] {
            recent = ledge_artwork_remember(recent, id, LedgeArtworkRecentCapacity)
        }
        #expect(recent.count == Int(LedgeArtworkRecentCapacity))
        #expect(recent == ["e", "d", "c", "b"])
    }

    @Test("Naming an id again moves it to the front, so it outlives newer ones")
    func touchRenews() {
        var recent = ["d", "c", "b", "a"]
        recent = ledge_artwork_remember(recent, "a", LedgeArtworkRecentCapacity)
        #expect(recent == ["a", "d", "c", "b"])
        recent = ledge_artwork_remember(recent, "e", LedgeArtworkRecentCapacity)
        #expect(recent == ["e", "a", "d", "c"])
    }
}

@Suite("When the poll asks for artwork bytes")
struct ArtworkFullReadTests {

    private func needs(
        systemID: String? = "sys", heldSystemID: String? = "sys",
        track: String = "t", heldTrack: String = "t",
        holds: Bool = true, now: TimeInterval = 105, since: TimeInterval = 100
    ) -> Bool {
        ledge_artwork_needs_full_read(systemID, heldSystemID, track, heldTrack, holds, now, since, 10, 3)
    }

    @Test("Same image, same track, fresh: the bytes are not asked for")
    func quietPollSkipsBytes() {
        #expect(needs() == false)
    }

    @Test("Nothing held yet: always asked for, so a late cover is not missed")
    func nothingHeldAsks() {
        #expect(needs(holds: false))
    }

    @Test("A new track asks")
    func newTrackAsks() {
        #expect(needs(track: "u"))
    }

    @Test("A new system artwork identifier asks")
    func newSystemIDAsks() {
        #expect(needs(systemID: "other"))
        #expect(needs(systemID: nil))
    }

    @Test("The backstop asks again once the held image is old")
    func backstop() {
        #expect(needs(now: 109.9) == false)
        #expect(needs(now: 110))
        // With no system identifier to watch, sooner.
        #expect(needs(systemID: nil, heldSystemID: nil, now: 102.9) == false)
        #expect(needs(systemID: nil, heldSystemID: nil, now: 103))
    }

    @Test("A clock that went backwards asks")
    func clockBackwardsAsks() {
        #expect(needs(now: 90))
    }
}
