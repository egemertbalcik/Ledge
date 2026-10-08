import Foundation
import LedgeSystem
import Testing
@testable import LedgeShell

@Suite("Notes opening lifecycle")
@MainActor
struct NotesOpeningTests {
    private final class Gate {
        var started: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<NoteBody?, Never>?
        func load() async -> NoteBody? {
            await withCheckedContinuation { continuation in
                release = continuation
                started?.resume()
                started = nil
            }
        }
    }

    @Test("A cancelled load cannot reopen the editor")
    func stopDuringLoad() async {
        let request = NotesOpeningRequest()
        let gate = Gate()
        var oldWork: Task<Void, Never>?
        var delivered = false
        await withCheckedContinuation { entered in
            gate.started = entered
            oldWork = request.start(load: { await gate.load() }, deliver: { _ in delivered = true })
        }
        request.cancel()
        gate.release?.resume(returning: NoteBody(id: "old", createdAt: 0, editedAt: 0))
        await oldWork?.value
        #expect(!delivered)
    }

    @Test("A newer request wins even when an old load completes last")
    func newerWins() async {
        let request = NotesOpeningRequest()
        let gate = Gate()
        var oldWork: Task<Void, Never>?
        var delivered: [String] = []
        await withCheckedContinuation { entered in
            gate.started = entered
            oldWork = request.start(load: { await gate.load() }, deliver: { delivered.append($0.id) })
        }
        await withCheckedContinuation { done in
            request.start(load: { NoteBody(id: "new", createdAt: 0, editedAt: 0) }, deliver: {
                delivered.append($0.id)
                done.resume()
            })
        }
        gate.release?.resume(returning: NoteBody(id: "old", createdAt: 0, editedAt: 0))
        await oldWork?.value
        #expect(delivered == ["new"])
    }
}
