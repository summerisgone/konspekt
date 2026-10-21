#if os(Windows)
import CWinAudio
import Foundation

public enum RecorderError: Error {
    case wasapi(String, Int32)
}

public final class Recorder {
    /// One capture stream written to a WAV file; `gate` returns false to write silence instead.
    final class Stream {
        let writer: WavWriter
        let queue: DispatchQueue
        let gate: () -> Bool
        var capture: OpaquePointer?

        init(writer: WavWriter, queue: DispatchQueue, gate: @escaping () -> Bool) {
            self.writer = writer
            self.queue = queue
            self.gate = gate
        }

        func receive(_ samples: UnsafePointer<Float>, frames: UInt32) {
            let count = Int(frames) * writer.channels
            let copy = gate() ? Array(UnsafeBufferPointer(start: samples, count: count))
                              : [Float](repeating: 0, count: count)
            queue.async { [writer] in copy.withUnsafeBufferPointer { try? writer.write($0) } }
        }
    }

    private static let sink: kw_sink = { ctx, samples, frames in
        guard let ctx, let samples else { return }
        Unmanaged<Stream>.fromOpaque(ctx).takeUnretainedValue().receive(samples, frames: frames)
    }

    private let queue = DispatchQueue(label: "konspekt.recorder.write")
    private let lock = NSLock()
    private var micGate = true
    private var call: Stream?
    private var mic: Stream?

    public init() {}

    public func start(session: Session, processObjects: [UInt32]) throws {
        stop()
        guard let pid = processObjects.first else { throw RecorderError.wasapi("no Telemost process", -1) }
        let stream = Stream(writer: try WavWriter(url: session.callURL, sampleRate: Int(KW_SAMPLE_RATE),
                                                  channels: Int(KW_LOOPBACK_CHANNELS)),
                            queue: queue, gate: { true })
        let hr = kw_start_process_loopback(pid, Self.sink, Unmanaged.passUnretained(stream).toOpaque(), &stream.capture)
        guard hr == 0 else {
            try? stream.writer.close()
            throw RecorderError.wasapi("process loopback", hr)
        }
        call = stream
        startMic(url: session.micURL)
    }

    private func startMic(url: URL) {
        do {
            let stream = Stream(writer: try WavWriter(url: url, sampleRate: Int(KW_SAMPLE_RATE),
                                                      channels: Int(KW_MIC_CHANNELS)),
                                queue: queue, gate: { [weak self] in
                                    guard let self else { return false }
                                    lock.lock(); defer { lock.unlock() }
                                    return micGate
                                })
            let hr = kw_start_mic(Self.sink, Unmanaged.passUnretained(stream).toOpaque(), &stream.capture)
            guard hr == 0 else {
                try? stream.writer.close()
                throw RecorderError.wasapi("microphone", hr)
            }
            mic = stream
        } catch {
            FileHandle.standardError.write(Data("mic start failed: \(error)\n".utf8))
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func stop() {
        let streams = [call, mic].compactMap { $0 }
        // kw_stop joins the capture thread, so no sink call outlives its stream.
        for s in streams { kw_stop(s.capture); s.capture = nil }
        queue.sync {}
        for s in streams { try? s.writer.close() }
        call = nil
        mic = nil
    }

    public func setMicGate(open: Bool) {
        lock.lock(); micGate = open; lock.unlock()
    }
}
#endif
