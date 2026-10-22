import Testing
import Foundation
@testable import KonspektCore

/// Speech-like bursts: noise with a syllable envelope in [start, end) seconds.
private func speech(_ seconds: Double, _ parts: [(Double, Double)], amp: Float, seed: UInt64) -> [Float] {
    var rng = seed
    var out = [Float](repeating: 0, count: Int(seconds * 16000))
    for (s, e) in parts {
        for i in Int(s * 16000)..<Int(e * 16000) {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: rng >> 1) % 2000) / 1000 - 1
            let syllable = abs(sin(Float(i) / 16000 * .pi * 4))
            out[i] = amp * noise * syllable
        }
    }
    return out
}

private func rms(_ s: ArraySlice<Float>) -> Float {
    (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
}

@Suite struct EchoSuppressorTests {
    // Call speaks 2-10 s and 14-20 s; the user speaks 11-13 s and over the call at 16-18 s.
    let call = speech(22, [(2, 10), (14, 20)], amp: 0.3, seed: 1)
    let user = speech(22, [(11, 13), (16, 18)], amp: 0.3, seed: 2)

    func mic(echoGain: Float, delay: Int) -> [Float] {
        (0..<user.count).map { user[$0] + ($0 >= delay ? echoGain * call[$0 - delay] : 0) }
    }

    func at(_ s: [Float], _ from: Double, _ to: Double) -> Float {
        rms(s[Int(from * 16000)..<Int(to * 16000)])
    }

    @Test func test_removes_echo_keeps_own_voice() {
        let m = mic(echoGain: 0.2, delay: 1600)
        let out = EchoSuppressor.clean(mic: m, call: call)
        #expect(at(out, 3, 9) < at(m, 3, 9) * 0.1)
        #expect(at(out, 11.2, 12.8) == at(m, 11.2, 12.8))
        #expect(at(out, 16.3, 17.7) > at(m, 16.3, 17.7) * 0.8)
    }

    @Test func test_no_echo_leaves_mic_untouched() {
        let m = mic(echoGain: 0, delay: 0)
        #expect(EchoSuppressor.clean(mic: m, call: call) == m)
    }

    @Test func test_short_or_missing_audio() {
        #expect(EchoSuppressor.clean(mic: [0.1, 0.2], call: []) == [0.1, 0.2])
    }
}
