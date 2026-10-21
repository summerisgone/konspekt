import Testing
import Foundation
@testable import KonspektCore

@Suite struct WavTests {
    func tmp(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wav-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(name)
    }

    func write(_ url: URL, rate: Int, channels: Int, _ samples: [Float], close: Bool = true) throws {
        let w = try WavWriter(url: url, sampleRate: rate, channels: channels)
        try samples.withUnsafeBufferPointer { try w.write($0) }
        if close { try w.close() }
    }

    @Test func test_roundtrip_float() throws {
        let u = tmp("a.wav")
        try write(u, rate: 48000, channels: 2, [0.1, -0.2, 0.3, -0.4])
        let (s, rate, ch) = try WavReader.read(u)
        #expect(rate == 48000 && ch == 2)
        #expect(s == [0.1, -0.2, 0.3, -0.4])
        let d = try Data(contentsOf: u)
        #expect(d.count == 44 + 16)
        #expect(d[4] == 52 && d[40] == 16)
    }

    @Test func test_unpatched_header_reads_to_eof() throws {
        let u = tmp("crash.wav")
        let w = try WavWriter(url: u, sampleRate: 16000, channels: 1)
        try [Float](repeating: 0.5, count: 100).withUnsafeBufferPointer { try w.write($0) }
        // No close(): sizes in the header stay 0, as after a crash.
        let (s, _, _) = try WavReader.read(u)
        #expect(s.count == 100 && s[99] == 0.5)
    }

    @Test func test_pcm16() throws {
        let u = tmp("p.wav")
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + 4)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(4); u16(UInt16(bitPattern: 16384)); u16(UInt16(bitPattern: -32768))
        try d.write(to: u)
        let (s, rate, ch) = try WavReader.read(u)
        #expect(rate == 8000 && ch == 1)
        #expect(s == [0.5, -1])
    }

    @Test func test_not_wav() throws {
        let u = tmp("x.wav")
        try Data("hello world!".utf8).write(to: u)
        #expect(throws: WavError.notWav) { try WavReader.read(u) }
    }

    @Test func test_resampler_keeps_passband_and_cuts_above_nyquist() {
        func sine(_ hz: Double) -> [Float] {
            (0..<48000).map { Float(sin(2 * Double.pi * hz * Double($0) / 48000)) }
        }
        func peak(_ s: [Float]) -> Float { s[2000..<(s.count - 2000)].map(abs).max() ?? 0 }
        let low = Resampler.toMono(sine(1000), channels: 1, from: 48000, to: 16000)
        #expect(low.count == 16000)
        #expect(abs(peak(low) - 1) < 0.02)
        let high = Resampler.toMono(sine(12000), channels: 1, from: 48000, to: 16000)
        #expect(peak(high) < 0.02)
    }

    @Test func test_resampler_downmix() {
        let s = Resampler.toMono([0, 0.5, 0, 0.5], channels: 2, from: 16000, to: 16000)
        #expect(s == [0.25, 0.25])
    }
}
