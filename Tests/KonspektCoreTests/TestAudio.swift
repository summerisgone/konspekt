import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import KonspektCore

/// Writes a constant-valued track in the platform's recording format (CAF on macOS, WAV elsewhere),
/// `values[c]` for channel c. `sample` overrides the value per frame for mono tracks.
func makeTrack(_ url: URL, rate: Double, channels: Int, seconds: Double, values: [Float],
               sample: ((Int) -> Float)? = nil) throws {
    let n = Int(rate * seconds)
    func value(_ c: Int, _ i: Int) -> Float { sample?(i) ?? values[c] }
    #if canImport(AVFoundation)
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard n > 0 else { return }
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for c in 0..<channels { for i in 0..<n { buf.floatChannelData![c][i] = value(c, i) } }
    try file.write(from: buf)
    #else
    let w = try WavWriter(url: url, sampleRate: Int(rate), channels: channels)
    var interleaved = [Float](repeating: 0, count: n * channels)
    for i in 0..<n { for c in 0..<channels { interleaved[i * channels + c] = value(c, i) } }
    try interleaved.withUnsafeBufferPointer { try w.write($0) }
    try w.close()
    #endif
}

let audioExt = Session.audioExtension
