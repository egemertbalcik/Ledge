import AppKit
import Foundation
import Testing

@testable import LedgeSystem

@Suite("Media key decoding")
struct MediaKeyDecoderTests {

    /// Builds the `data1` field the way macOS packs it: key code in the high 16
    /// bits, state in bits 8...15, repeat flag in bit 0.
    private func data1(key: Int, isDown: Bool, isRepeat: Bool = false) -> Int {
        (key << 16) | ((isDown ? 0x0A : 0x0B) << 8) | (isRepeat ? 1 : 0)
    }

    @Test("Each supported key decodes to itself")
    func decodesEveryKey() {
        for key in MediaKey.allCases {
            let press = MediaKeyDecoder.decode(data1: data1(key: key.rawValue, isDown: true))
            #expect(press?.key == key)
        }
    }

    @Test("Key down and key up are distinguished")
    func decodesState() {
        #expect(MediaKeyDecoder.decode(data1: data1(key: 0, isDown: true))?.isDown == true)
        #expect(MediaKeyDecoder.decode(data1: data1(key: 0, isDown: false))?.isDown == false)
    }

    @Test("A held key is marked as a repeat")
    func decodesRepeat() {
        let held = MediaKeyDecoder.decode(data1: data1(key: 0, isDown: true, isRepeat: true))
        #expect(held?.isRepeat == true)
    }

    /// macOS moves a quarter of a step with Option and Shift held. Ledge took
    /// the key and moved a whole one.
    @Test("Option and Shift together ask for the fine step and nothing else does")
    func fineStepModifiers() {
        #expect(MediaKeyDecoder.isFine([.option, .shift]))
        #expect(MediaKeyDecoder.isFine([.option, .shift, .function]), "the volume keys are fn keys on some keyboards")
        #expect(MediaKeyDecoder.isFine([.option, .shift, .capsLock]))
        #expect(!MediaKeyDecoder.isFine([]))
        #expect(!MediaKeyDecoder.isFine([.option]))
        #expect(!MediaKeyDecoder.isFine([.shift]))
        #expect(!MediaKeyDecoder.isFine([.option, .shift, .command]))
        #expect(!MediaKeyDecoder.isFine([.option, .shift, .control]))
    }

    @Test("A press carries whether it is the fine one")
    func decodesFine() {
        let plain = MediaKeyDecoder.decode(data1: data1(key: 0, isDown: true))
        let fine = MediaKeyDecoder.decode(data1: data1(key: 0, isDown: true), modifiers: [.option, .shift])
        #expect(plain?.isFine == false)
        #expect(fine?.isFine == true)
        #expect(fine?.key == .soundUp)
    }

    @Test("Keys this app does not handle are ignored, not guessed at")
    func ignoresUnknownKeys() {
        // Play/pause is key 16. Decoding it would mean swallowing it while
        // having nothing to do with it.
        #expect(MediaKeyDecoder.decode(data1: data1(key: 16, isDown: true)) == nil)
        #expect(MediaKeyDecoder.decode(data1: data1(key: 999, isDown: true)) == nil)
    }

    @Test("A malformed state byte is rejected")
    func rejectsBadState() {
        // Neither 0xA nor 0xB. Treating an unrecognised state as a press would
        // fire the action twice.
        let malformed = (0 << 16) | (0x0C << 8)
        #expect(MediaKeyDecoder.decode(data1: malformed) == nil)
    }

    @Test("Volume and brightness keys carry the right direction")
    func stepDirection() {
        #expect(MediaKey.soundUp.delta == 1)
        #expect(MediaKey.soundDown.delta == -1)
        #expect(MediaKey.brightnessUp.delta == 1)
        #expect(MediaKey.brightnessDown.delta == -1)
        // Mute is not a step in either direction.
        #expect(MediaKey.mute.delta == 0)
    }
}
