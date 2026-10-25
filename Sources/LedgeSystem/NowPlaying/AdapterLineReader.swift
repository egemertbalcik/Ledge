import Foundation
import os

/// Turns the adapter's stdout into decoded lines, off the main actor.
///
/// Every byte from the pipe used to be handled on the main actor, in one
/// queued `Task` per chunk: the newline search, the JSON, the base64. A
/// browser's video artwork was a single five-megabyte line, its three hundred
/// chunk tasks ran back to back, and the main thread was gone for seconds —
/// long enough for macOS to switch off the media-key tap and draw its own
/// volume HUD over Ledge's.
///
/// Here the chunks go into one ordered stream with one consumer, so the order
/// they arrived in is the order they are read in, and the main actor is only
/// handed what came out: decoded payloads.
final class AdapterLineReader: Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "adapter")

    /// A line longer than this is reported. After the adapter learned to
    /// shrink artwork, nothing it sends comes close.
    static let longLine = 512 * 1024
    /// A chunk that took longer than this to read is reported.
    static let slowParse: Duration = .milliseconds(50)

    private let continuation: AsyncStream<Data>.Continuation
    private let consumer: Task<Void, Never>

    /// - Parameter deliver: given each batch of payloads one chunk completed,
    ///   in order. Awaited before the next chunk is read, so batches never
    ///   overtake one another.
    init(deliver: @escaping @Sendable ([AdapterPayload]) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.continuation = continuation
        consumer = Task.detached(priority: .userInitiated) {
            var buffer = LineBuffer()
            let decoder = JSONDecoder()
            for await chunk in stream {
                let started = ContinuousClock.now
                var payloads: [AdapterPayload] = []
                for line in buffer.append(chunk) {
                    if line.count > Self.longLine {
                        Self.log.notice("adapter line of \(line.count, privacy: .public) bytes")
                    }
                    if let payload = try? decoder.decode(AdapterPayload.self, from: line) {
                        payloads.append(payload)
                    }
                }
                let took = ContinuousClock.now - started
                if took > Self.slowParse {
                    Self.log.notice("adapter chunk of \(chunk.count, privacy: .public) bytes took \(took, privacy: .public) to read")
                }
                if !payloads.isEmpty { await deliver(payloads) }
            }
        }
    }

    /// Hands over bytes from the pipe. Cheap, and safe from any thread.
    func feed(_ chunk: Data) {
        continuation.yield(chunk)
    }

    /// Stops reading. Chunks already fed may still be delivered; the caller's
    /// generation check is what keeps them from counting.
    func finish() {
        continuation.finish()
        consumer.cancel()
    }
}
