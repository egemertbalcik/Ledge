import AppKit
import Foundation
import LedgeCore
import os

/// Fetched artwork plus the colour derived from it.
public struct Artwork: Sendable {
    /// Encoded image bytes, ready for the view layer to turn into an image.
    public let data: Data
    public let accent: AccentColor
}

/// Fetches album artwork and derives an accent colour from it.
///
/// Results are cached by track key, because the poll asks for the same track
/// several times a minute and neither the network round trip nor the pixel
/// analysis should happen more than once per track.
@MainActor
public final class ArtworkLoader {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "artwork")

    private var cache: [String: Artwork] = [:]
    private var inFlight: Set<String> = []

    /// Keys whose fetch failed. Remembered because the provider polls every
    /// second and asks again each time it finds no cache entry — without this,
    /// one unreachable cover URL becomes a request per second for as long as
    /// the track plays. Bounded like `cache`: a session-long CDN outage must
    /// not grow it one key per track forever. Wholesale reset rather than LRU —
    /// a rare extra retry beats bookkeeping the failure order.
    private var failed: Set<String> = [] {
        didSet { if failed.count > limit * 4 { failed.removeAll() } }
    }

    /// Bounded so a long listening session cannot grow the cache without limit.
    private var insertionOrder: [String] = []
    private let limit: Int

    private let session: URLSession

    public init(limit: Int = 24) {
        self.limit = limit
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    public func cached(for key: String) -> Artwork? {
        cache[key]
    }

    /// Fetches if needed. Returns nil when already cached (nothing changed) or
    /// when a fetch for the same key is already running.
    public func load(key: String, url: URL) async -> Artwork? {
        if let existing = cache[key] { return existing }
        guard !inFlight.contains(key), !failed.contains(key) else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Self.log.debug("artwork http \(http.statusCode) for \(key, privacy: .public)")
                failed.insert(key)
                return nil
            }
            guard let accent = Self.dominantColor(of: data) else {
                // Fetched but undecodable — asking again would fetch the same
                // bytes and fail the same way.
                failed.insert(key)
                return nil
            }

            let artwork = Artwork(data: data, accent: accent)
            insert(artwork, for: key)
            return artwork
        } catch {
            Self.log.debug("artwork fetch failed: \(error.localizedDescription, privacy: .public)")
            // A thrown error is transient — a Wi-Fi blip, a timed-out CDN —
            // unlike the deterministic failures above (bad status,
            // undecodable bytes). Still latched, so the 1 Hz poll cannot
            // hammer a dead network, but only briefly: the playing track's
            // cover deserves another try once the blip passes.
            failed.insert(key)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(90))
                self?.failed.remove(key)
            }
            return nil
        }
    }

    /// Artwork that arrived as bytes rather than a URL — same cache, same
    /// accent derivation, no network at all.
    @discardableResult
    public func load(key: String, data: Data) -> Artwork? {
        if let existing = cache[key] { return existing }
        guard let accent = Self.dominantColor(of: data) else {
            failed.insert(key)
            return nil
        }
        let artwork = Artwork(data: data, accent: accent)
        insert(artwork, for: key)
        return artwork
    }

    /// Clears the failure memory, for a retry after the network comes back.

    public func forgetFailures() {
        failed.removeAll()
    }

    /// Whether a key has been tried and failed, so callers can stop asking.
    public func hasFailed(for key: String) -> Bool {
        failed.contains(key)
    }

    private func insert(_ artwork: Artwork, for key: String) {
        if cache[key] == nil { insertionOrder.append(key) }
        cache[key] = artwork
        while insertionOrder.count > limit {
            let oldest = insertionOrder.removeFirst()
            cache[oldest] = nil
        }
    }

    // MARK: - Colour

    /// Picks a representative colour by averaging a heavily downscaled copy,
    /// weighting each pixel by its saturation.
    ///
    /// The weighting is the whole trick: a plain average of a mostly-dark cover
    /// returns mud, whereas weighting towards saturated pixels finds the colour
    /// a person would actually name. The result is then floored for brightness
    /// so it stays legible against the black card.
    nonisolated static func dominantColor(of data: Data) -> AccentColor? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let side = 32
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)

        var totalRed = 0.0, totalGreen = 0.0, totalBlue = 0.0, totalWeight = 0.0

        // The whole context lifetime lives inside this closure. Passing `&pixels`
        // to `CGContext(data:)` would be undefined behaviour: an inout-to-pointer
        // conversion is only valid for the duration of the call it appears in,
        // but the context keeps the pointer and writes through it during `draw`.
        // The compiler is free to hand over a temporary and copy back when the
        // initialiser returns, in which case every colour read is zero.
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

            let bytes = buffer.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: bytes.count, by: bytesPerPixel) {
                let alpha = Double(bytes[index + 3]) / 255
                guard alpha > 0.1 else { continue }

                let red = Double(bytes[index]) / 255
                let green = Double(bytes[index + 1]) / 255
                let blue = Double(bytes[index + 2]) / 255

                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)
                let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0

                // A floor keeps a genuinely monochrome cover from producing a
                // zero-weight average, which would divide by zero below.
                let weight = (0.08 + saturation) * alpha
                totalRed += red * weight
                totalGreen += green * weight
                totalBlue += blue * weight
                totalWeight += weight
            }
            return true
        }

        guard ok, totalWeight > 0 else { return nil }

        return brighten(AccentColor(
            red: totalRed / totalWeight,
            green: totalGreen / totalWeight,
            blue: totalBlue / totalWeight
        ))
    }

    /// Raises a colour to a minimum brightness without changing its hue, so a
    /// dark cover still yields something visible on black.
    nonisolated static func brighten(_ color: AccentColor, minimumBrightness: Double = 0.55) -> AccentColor {
        let brightness = max(color.red, color.green, color.blue)
        guard brightness > 0, brightness < minimumBrightness else { return color }
        let scale = minimumBrightness / brightness
        return AccentColor(
            red: min(color.red * scale, 1),
            green: min(color.green * scale, 1),
            blue: min(color.blue * scale, 1)
        )
    }
}
