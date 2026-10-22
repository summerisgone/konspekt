import Foundation

/// Removes the call's sound that the microphone picked up from the speakers (no headphones).
/// Works on 20 ms frame levels: finds the echo delay, learns how much quieter the echo is than
/// the call, and silences mic frames no louder than the echo the call predicts for them.
/// The user's own voice over the call is louder than that echo, so it is kept.
public enum EchoSuppressor {
    static let frame = 320  // 20 ms at 16 kHz
    static let maxDelayFrames = 25  // 500 ms
    static let tailFrames = 10  // reverb after the call's sound, 200 ms
    /// Minimum correlation of mic and delayed call levels to treat the mic as carrying echo.
    static let minCorrelation: Float = 0.3
    static let marginDB: Float = 6

    public static func clean(mic: [Float], call: [Float]) -> [Float] {
        let em = levels(mic), ec = levels(call)
        let n = min(em.count, ec.count)
        guard n > maxDelayFrames + tailFrames else { return mic }
        let callActive = max(-55, percentile(Array(ec[0..<n]), 0.1) + 10)

        // Echo delay: the lag at which mic levels follow call levels best while the call is heard.
        var best: (lag: Int, corr: Float) = (0, -1)
        for lag in 0...maxDelayFrames {
            let frames = (lag..<n).filter { ec[$0 - lag] > callActive }
            guard frames.count > 50 else { continue }
            let c = correlation(frames.map { em[$0] }, frames.map { ec[$0 - lag] })
            if c > best.corr { best = (lag, c) }
        }
        guard best.corr >= minCorrelation else { return mic }

        // Loudest call frame that can still sound in the mic at frame i (direct sound and tail).
        var ref = [Float](repeating: -100, count: n)
        for i in 0..<n {
            let hi = i - best.lag + 1
            let lo = max(0, hi - tailFrames - 2)
            if hi > lo { ref[i] = ec[lo..<min(hi, n)].max() ?? -100 }
        }
        // How much quieter the echo is than the call; most call-active frames are echo only.
        let gains = (best.lag..<n).filter { ec[$0 - best.lag] > callActive }.map { em[$0] - ec[$0 - best.lag] }
        let gain = percentile(gains, 0.5)

        var out = mic
        for i in 0..<n where ref[i] > callActive && em[i] <= ref[i] + gain + marginDB {
            let end = min(out.count, (i + 1) * frame)
            for j in (i * frame)..<end { out[j] = 0 }
        }
        return out
    }

    /// Level of each 20 ms frame, dBFS.
    static func levels(_ s: [Float]) -> [Float] {
        stride(from: 0, to: s.count / frame * frame, by: frame).map { start in
            var e: Float = 0
            for j in start..<(start + frame) { e += s[j] * s[j] }
            return 10 * log10(e / Float(frame) + 1e-10)
        }
    }

    static func percentile(_ v: [Float], _ p: Double) -> Float {
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var ab: Float = 0, aa: Float = 0, bb: Float = 0
        for i in a.indices {
            let x = a[i] - ma, y = b[i] - mb
            ab += x * y
            aa += x * x
            bb += y * y
        }
        return aa > 0 && bb > 0 ? ab / (aa.squareRoot() * bb.squareRoot()) : 0
    }
}
