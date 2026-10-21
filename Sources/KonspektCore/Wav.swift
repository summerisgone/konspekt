import Foundation

/// Streams interleaved Float32 samples into a WAV file (IEEE float).
/// Sizes in the header are patched on close; a file left unpatched after a crash
/// is still readable by `WavReader`, which then reads data up to the end of file.
public final class WavWriter {
    public let sampleRate: Int
    public let channels: Int
    private let handle: FileHandle
    private var dataBytes: UInt64 = 0

    public init(url: URL, sampleRate: Int, channels: Int) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: 0)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !samples.isEmpty else { return }
        var d = Data(capacity: samples.count * 4)
        for s in samples { withUnsafeBytes(of: s.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        try handle.write(contentsOf: d)
        dataBytes += UInt64(d.count)
    }

    public func close() throws {
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: dataBytes))
    }

    static func header(sampleRate: Int, channels: Int, dataBytes: UInt64) -> Data {
        let data = UInt32(clamping: dataBytes)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(data == 0 ? 0 : 36 &+ data)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 4)); u16(UInt16(channels * 4)); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(data)
        return d
    }
}

public enum WavError: Error, Equatable {
    case notWav, unsupported(String)
}

public enum WavReader {
    /// Returns interleaved samples in [-1, 1]. Supports PCM 16/24/32-bit, Float32 and WAVE_FORMAT_EXTENSIBLE.
    public static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Int, channels: Int) {
        let d = try Data(contentsOf: url)
        guard d.count >= 12, String(decoding: d[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: d[8..<12], as: UTF8.self) == "WAVE" else { throw WavError.notWav }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var pos = 12
        var format = 0, channels = 0, rate = 0, bits = 0
        while pos + 8 <= d.count {
            let id = String(decoding: d[pos..<pos + 4], as: UTF8.self)
            let size = u32(pos + 4)
            let body = pos + 8
            if id == "fmt " {
                guard body + 16 <= d.count else { throw WavError.notWav }
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if format == 0xFFFE, size >= 26, body + 26 <= d.count { format = u16(body + 24) }
            } else if id == "data" {
                guard channels > 0, rate > 0 else { throw WavError.notWav }
                // Size 0 or past the end: header left unpatched, read to the end of file.
                let end = size == 0 || body + size > d.count ? d.count : body + size
                return (try decode(d[body..<end], format: format, bits: bits), rate, channels)
            }
            pos = body + size + (size & 1)
        }
        throw WavError.notWav
    }

    private static func decode(_ d: Data, format: Int, bits: Int) throws -> [Float] {
        let width = bits / 8
        guard width > 0 else { throw WavError.unsupported("bits \(bits)") }
        let n = d.count / width
        let base = d.startIndex
        var out = [Float](repeating: 0, count: n)
        switch (format, bits) {
        case (3, 32):
            for i in 0..<n {
                let o = base + i * 4
                let v = UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
                let f = Float(bitPattern: v)
                out[i] = f.isNaN ? 0 : f
            }
        case (1, 16):
            for i in 0..<n {
                let o = base + i * 2
                out[i] = Float(Int16(bitPattern: UInt16(d[o]) | UInt16(d[o + 1]) << 8)) / 32768
            }
        case (1, 24):
            for i in 0..<n {
                let o = base + i * 3
                let v = Int32(bitPattern: UInt32(d[o]) << 8 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 24) >> 8
                out[i] = Float(v) / 8_388_608
            }
        case (1, 32):
            for i in 0..<n {
                let o = base + i * 4
                let v = UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
                out[i] = Float(Int32(bitPattern: v)) / 2_147_483_648
            }
        default:
            throw WavError.unsupported("format \(format), bits \(bits)")
        }
        return out
    }
}

public enum Resampler {
    /// Averages channels to mono and resamples with a windowed-sinc low-pass filter.
    public static func toMono(_ interleaved: [Float], channels: Int, from inRate: Int, to outRate: Int) -> [Float] {
        guard channels > 0, inRate > 0, outRate > 0 else { return [] }
        let frames = interleaved.count / channels
        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            mono = Array(interleaved.prefix(frames))
        } else {
            let k = 1 / Float(channels)
            interleaved.withUnsafeBufferPointer { src in
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += src[i * channels + c] }
                    mono[i] = s * k
                }
            }
        }
        guard inRate != outRate, frames > 0 else { return mono }

        let ratio = Double(outRate) / Double(inRate)
        let fc = min(1, ratio)
        let zeroCrossings = 16.0
        let reach = zeroCrossings / fc
        let res = 256
        let tableLen = Int(reach * Double(res)) + 2
        var table = [Float](repeating: 0, count: tableLen)
        for i in 0..<tableLen {
            let x = Double(i) / Double(res)
            guard x < reach else { continue }
            let a = Double.pi * fc * x
            let sinc = x == 0 ? 1 : sin(a) / a
            let w = 0.42 + 0.5 * cos(Double.pi * x / reach) + 0.08 * cos(2 * Double.pi * x / reach)
            table[i] = Float(sinc * w)
        }

        let outCount = Int(Double(frames) * ratio)
        var out = [Float](repeating: 0, count: outCount)
        let span = Int(reach.rounded(.up))
        mono.withUnsafeBufferPointer { x in
            table.withUnsafeBufferPointer { h in
                for i in 0..<outCount {
                    let t = Double(i) / ratio
                    let c = Int(t)
                    var acc: Float = 0, wsum: Float = 0
                    for k in max(0, c - span)...min(frames - 1, c + span) {
                        let idx = Int((abs(t - Double(k)) * Double(res)).rounded())
                        guard idx < tableLen else { continue }
                        let w = h[idx]
                        acc += x[k] * w
                        wsum += w
                    }
                    out[i] = wsum != 0 ? acc / wsum : 0
                }
            }
        }
        return out
    }
}
