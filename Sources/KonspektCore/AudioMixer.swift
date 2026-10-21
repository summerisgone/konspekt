import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum AudioMixer {
    static let rate: Double = 16000

    public static func mixToMono16k(_ files: [URL]) throws -> [Float] {
        var mix: [Float] = []
        for url in files {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let track = try decode(url)
            if track.count > mix.count { mix.append(contentsOf: [Float](repeating: 0, count: track.count - mix.count)) }
            for i in 0..<track.count { mix[i] += track[i] }
        }
        for i in 0..<mix.count { mix[i] = mix[i].isNaN ? 0 : min(1, max(-1, mix[i])) }
        return mix
    }

    #if canImport(AVFoundation)
    static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inFmt = file.processingFormat
        guard file.length > 0 else { return [] }
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw NSError(domain: "AudioMixer", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot convert \(url.lastPathComponent)"])
        }
        conv.downmix = true
        let block = AVAudioFrameCount(inFmt.sampleRate)
        let outCap = AVAudioFrameCount(rate * 1.5) + 1024
        var out: [Float] = []
        var eof = false
        while true {
            let ob = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)!
            var err: NSError?
            let status = conv.convert(to: ob, error: &err) { _, inStatus in
                if eof { inStatus.pointee = .endOfStream; return nil }
                let ib = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: block)!
                do { try file.read(into: ib, frameCount: block) } catch { eof = true; inStatus.pointee = .endOfStream; return nil }
                if ib.frameLength == 0 { eof = true; inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return ib
            }
            if status == .error { throw err ?? NSError(domain: "AudioMixer", code: 2) }
            if ob.frameLength > 0 { out.append(contentsOf: UnsafeBufferPointer(start: ob.floatChannelData![0], count: Int(ob.frameLength))) }
            if status == .endOfStream || (eof && ob.frameLength == 0) { break }
        }
        return out
    }
    #else
    static func decode(_ url: URL) throws -> [Float] {
        let (samples, sampleRate, channels) = try WavReader.read(url)
        return Resampler.toMono(samples, channels: channels, from: sampleRate, to: Int(rate))
    }
    #endif

    public static func wav16k(_ samples: ArraySlice<Float>) -> Data {
        let dataLen = UInt32(samples.count * 2)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataLen)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataLen)
        for s in samples {
            u16(UInt16(bitPattern: s.isNaN ? 0 : Int16(max(-1, min(1, s)) * 32767)))
        }
        return d
    }
}
