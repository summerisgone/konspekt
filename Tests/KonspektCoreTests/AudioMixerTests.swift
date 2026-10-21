import Testing
import Foundation
@testable import KonspektCore

@Suite struct AudioMixerTests {
    func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mix-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func makeCAF(_ dir: URL, _ name: String, rate: Double, channels: Int, seconds: Double, value: Float) -> URL {
        let url = dir.appendingPathComponent(name)
        try! makeTrack(url, rate: rate, channels: channels, seconds: seconds, values: Array(repeating: value, count: channels))
        return url
    }

    @Test func test_stereo_48k() throws {
        let d = tmp()
        let u = makeCAF(d, "a.\(audioExt)", rate: 48000, channels: 2, seconds: 1, value: 0.25)
        let s = try AudioMixer.mixToMono16k([u])
        #expect(abs(s.count - 16000) <= 2)
        #expect(abs(s[8000] - 0.25) < 0.01)
    }

    @Test func test_stereo_right_only_downmixed() throws {
        let d = tmp()
        let url = d.appendingPathComponent("r.\(audioExt)")
        try makeTrack(url, rate: 48000, channels: 2, seconds: 1, values: [0, 0.5])
        let s = try AudioMixer.mixToMono16k([url])
        #expect(abs(s.count - 16000) <= 2)
        #expect(abs(s[8000] - 0.25) < 0.02)
    }

    @Test func test_mix_two_lengths() throws {
        let d = tmp()
        let a = makeCAF(d, "a.\(audioExt)", rate: 16000, channels: 1, seconds: 2, value: 0.2)
        let b = makeCAF(d, "b.\(audioExt)", rate: 16000, channels: 1, seconds: 1, value: 0.1)
        let s = try AudioMixer.mixToMono16k([a, b])
        #expect(abs(s.count - 32000) <= 2)
        #expect(abs(s[4000] - 0.3) < 0.01)
        #expect(abs(s[24000] - 0.2) < 0.01)
    }

    @Test func test_missing_file_skipped() throws {
        let d = tmp()
        let v = makeCAF(d, "v.\(audioExt)", rate: 16000, channels: 1, seconds: 1, value: 0.3)
        let s = try AudioMixer.mixToMono16k([d.appendingPathComponent("nope.\(audioExt)"), v])
        #expect(s.count == 16000)
        #expect(abs(s[100] - 0.3) < 0.01)
    }

    @Test func test_all_missing_empty() throws {
        let d = tmp()
        #expect(try AudioMixer.mixToMono16k([d.appendingPathComponent("x.\(audioExt)")]).isEmpty)
    }

    @Test func test_zero_frames_empty() throws {
        let d = tmp()
        let u = makeCAF(d, "z.\(audioExt)", rate: 48000, channels: 1, seconds: 0, value: 0)
        #expect(try AudioMixer.mixToMono16k([u]).isEmpty)
    }

    @Test func test_clamp() throws {
        let d = tmp()
        let a = makeCAF(d, "a.\(audioExt)", rate: 16000, channels: 1, seconds: 1, value: 0.8)
        let b = makeCAF(d, "b.\(audioExt)", rate: 16000, channels: 1, seconds: 1, value: 0.8)
        let s = try AudioMixer.mixToMono16k([a, b])
        #expect(s[1000] == 1.0)
        let wav = AudioMixer.wav16k(s[1000..<1001])
        let v = Int16(littleEndian: wav.subdata(in: 44..<46).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        #expect(v == 32767)
    }

    @Test func test_44_khz_input() throws {
        let d = tmp()
        let u = makeCAF(d, "a.\(audioExt)", rate: 44100, channels: 1, seconds: 1, value: 0.5)
        let s = try AudioMixer.mixToMono16k([u])
        #expect(abs(s.count - 16000) <= 2)
    }

    @Test func test_wav_header() {
        let w = AudioMixer.wav16k([0, 0.5, -0.5, 1][...])
        #expect(w.count == 52)
        #expect(String(decoding: w.prefix(4), as: UTF8.self) == "RIFF")
        #expect(w[22] == 1 && w[23] == 0)
        #expect(w[24] == 0x80 && w[25] == 0x3E && w[26] == 0 && w[27] == 0)
        #expect(w[40] == 8)
    }
}

@Suite struct AudioMixerNaNTests {
    @Test func test_wav_nan_does_not_trap() {
        let d = AudioMixer.wav16k([Float.nan, 0.5][...])
        #expect(d.count == 44 + 4)
    }
}
