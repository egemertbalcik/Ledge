import Foundation

/// Synthesized equalizer levels — musical motion with no microphone, no tap,
/// no capture of any kind.
///
/// True audio sync requires reading the audio, and reading the audio means
/// the system's recording indicator and a consent prompt — a red flag out of
/// proportion to six dancing bars. This is the honest alternative: a small
/// beat model, deterministic in (track seed, wall clock), that *behaves* like
/// music. Each track gets its own tempo and character from its seed; the low
/// bands pump on the beat with a percussive decay, the mids drift like a
/// melody, the highs tick like hats on the off-beats. Deterministic, so every
/// view asking in the same frame draws the same bars.
public enum LevelSimulator {

    /// Stable across launches, unlike `String.hashValue`. FNV-1a.
    public static func seed(for key: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Six band levels in 0...1 at a moment in time.
    ///
    /// - Parameters:
    ///   - time: any monotonic-enough clock; callers use wall time.
    ///   - seed: per-track, so two tracks feel different but one track always
    ///     feels like itself.
    public static func levels(at time: TimeInterval, seed: UInt64, bands: Int = 6) -> [Double] {
        // A clock set before 2001 makes the reference-date time negative,
        // and `UInt64(negative)` traps — 24 times a second, the moment a
        // track played. Clamp rather than trust the wall clock.
        guard bands > 0, time.isFinite, time >= 0 else { return [] }

        // 84–132 BPM out of the seed: slow ballads and quick tracks exist.
        let bpm = 84.0 + Double(seed % 49)
        let beat = time * bpm / 60.0
        let beatPhase = beat.truncatingRemainder(dividingBy: 1)
        let beatIndex = UInt64(beat.rounded(.down))

        // A percussive envelope: sharp on the beat, decaying through it.
        let kick = pow(max(0, 1 - beatPhase), 2.2)
        // Hats live between the beats.
        let offbeat = pow(max(0, 1 - abs(beatPhase - 0.5) * 2), 3.0)

        // Bar-to-bar variation that is deterministic, not random: hash the
        // beat index so a quiet bar stays quiet on every redraw.
        func pulse(_ index: UInt64, _ salt: UInt64) -> Double {
            var h = index &+ salt &* 0x9e3779b97f4a7c15
            h = (h ^ (h >> 30)) &* 0xbf58476d1ce4e5b9
            h = (h ^ (h >> 27)) &* 0x94d049bb133111eb
            return Double((h ^ (h >> 31)) % 1000) / 999.0
        }

        return (0..<bands).map { band in
            let salt = seed &+ UInt64(band) &* 0x2545f4914f6cdd1d
            let character = pulse(beatIndex, salt)
            let level: Double
            switch band {
            case 0, 1:
                // Bass: the beat itself, occasionally sitting a bar out.
                let strength = character > 0.15 ? 0.55 + 0.45 * character : 0.2
                level = 0.12 + strength * kick
            case bands - 1:
                // Highs: hat ticks on the off-beat, light and busy.
                level = 0.1 + (0.35 + 0.45 * character) * offbeat
            default:
                // Mids: melodic drift — layered sines at seed-detuned rates,
                // lifted slightly by the beat so the whole thing breathes
                // together.
                let rate = 0.9 + Double((seed >> (band * 7)) % 13) / 9.0
                let phase = Double((seed >> (band * 5)) % 628) / 100.0
                let wave = (sin(time * rate * 2.1 + phase) + 1) / 2
                level = 0.15 + 0.5 * wave * (0.5 + 0.5 * character) + 0.2 * kick
            }
            return min(max(level, 0), 1)
        }
    }
}
