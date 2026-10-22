import Foundation

public struct Pipeline {
    let transcriber: Transcriber
    let summarizer: Summarizer
    let diarizer: Diarizer?
    let voicesFile: URL?

    public init(transcriber: Transcriber, summarizer: Summarizer, diarizer: Diarizer? = nil, voicesFile: URL? = nil) {
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.diarizer = diarizer
        self.voicesFile = voicesFile
    }

    public func process(_ s: Session) async -> SessionStatus {
        var status: SessionStatus
        do { status = try s.readStatus() } catch {
            return SessionStatus(state: .recording, attempts: 0, lastError: "\(error)", start: Date(), end: nil)
        }
        do {
            if status.state == .recorded {
                try await transcribe(s)
                status.state = .transcribed
                status.lastError = nil
                try s.write(status)
            }
            if status.state == .transcribed {
                try await summarize(s, status)
                status.state = .done
                status.lastError = nil
                try s.write(status)
            }
        } catch {
            status.attempts += 1
            status.lastError = "\(error)"
            try? s.write(status)
        }
        return status
    }

    private func transcribe(_ s: Session) async throws {
        if let diarizer {
            do {
                try await transcribeBySpeaker(s, diarizer)
                return
            } catch let e as DiarizationFailed {
                FileHandle.standardError.write(Data("\(s.name): diarization failed, transcribing without speakers: \(e.error)\n".utf8))
            }
        }
        let rate = 16000
        let samples = try AudioMixer.mixToMono16k([s.micURL, s.callURL])
        let fm = FileManager.default
        try fm.createDirectory(at: s.chunksDir, withIntermediateDirectories: true)
        var out = ""
        for (i, r) in Chunker.ranges(samples: samples, rate: rate).enumerated() {
            let file = s.chunksDir.appendingPathComponent(String(format: "%03d.txt", i))
            let text: String
            if let cached = try? String(contentsOf: file, encoding: .utf8) {
                text = cached
            } else {
                text = try await transcriber.transcribe(wav: AudioMixer.wav16k(samples[r]))
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out += "## [\(stamp(r.lowerBound / rate))]\n\n\(trimmed)\n\n"
            }
        }
        try out.write(to: s.transcriptURL, atomically: true, encoding: .utf8)
    }

    private struct DiarizationFailed: Error {
        let error: Error
    }

    /// Diarizes mic and call tracks separately, then transcribes each speaker turn from its own track.
    private func transcribeBySpeaker(_ s: Session, _ diarizer: Diarizer) async throws {
        let rate = 16000
        var audio: [Track: [Float]] = [:]
        for (track, url) in [(Track.mic, s.micURL), (.call, s.callURL)] where FileManager.default.fileExists(atPath: url.path) {
            audio[track] = try AudioMixer.decode(url)
        }
        if let mic = audio[.mic], let call = audio[.call] {
            audio[.mic] = EchoSuppressor.clean(mic: mic, call: call)
        }
        var map: SpeakerMap
        if let saved = try? s.readSpeakers() {
            map = saved
        } else {
            var tracks: [(Track, [VoiceSegment], [String: [Float]])] = []
            do {
                for track in [Track.mic, .call] {
                    guard let samples = audio[track], !samples.isEmpty else { continue }
                    let (segments, embeddings) = try await diarizer.diarize(samples)
                    tracks.append((track, segments, embeddings))
                }
            } catch {
                throw DiarizationFailed(error: error)
            }
            map = SpeakerMap.build(tracks: tracks, voices: voicesFile.flatMap { try? VoiceDB.load($0) })
            try s.write(map)
        }
        try FileManager.default.createDirectory(at: s.chunksDir, withIntermediateDirectories: true)
        let pad = rate / 5
        let fixed = map
        func text(_ i: Int) async throws -> String {
            let t = fixed.turns[i]
            let track = fixed.speakers.first { $0.id == t.speaker }?.track ?? .call
            let file = s.chunksDir.appendingPathComponent(String(format: "%@-%08d.txt", track.rawValue, Int(t.start * 1000)))
            if let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
            let samples = audio[track] ?? []
            let lo = min(samples.count, max(0, Int(t.start * Double(rate)) - pad))
            let hi = min(samples.count, max(lo, Int(t.end * Double(rate)) + pad))
            let turn = Array(samples[lo..<hi])
            var parts: [String] = []
            for r in Chunker.ranges(samples: turn, rate: rate) {
                parts.append(try await transcriber.transcribe(wav: AudioMixer.wav16k(turn[r])))
            }
            let out = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            try out.write(to: file, atomically: true, encoding: .utf8)
            return out
        }
        // The ASR server batches requests well; keep a few in flight.
        try await withThrowingTaskGroup(of: (Int, String).self) { g in
            for i in map.turns.indices {
                if i >= 4, let (j, t) = try await g.next() { map.turns[j].text = t }
                g.addTask { (i, try await text(i)) }
            }
            for try await (j, t) in g { map.turns[j].text = t }
        }
        try s.write(map)
        try map.render().write(to: s.transcriptURL, atomically: true, encoding: .utf8)
    }

    private func summarize(_ s: Session, _ status: SessionStatus) async throws {
        let transcript = try String(contentsOf: s.transcriptURL, encoding: .utf8)
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try "Речь не распознана".write(to: s.summaryURL, atomically: true, encoding: .utf8)
            return
        }
        let body = try await summarizer.summarize(transcript: transcript)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# Конспект звонка \(f.string(from: status.start))\n"
        if let end = status.end {
            out += "Длительность: \(max(1, Int((end.timeIntervalSince(status.start) / 60).rounded()))) мин\n"
        } else {
            out += "Длительность: неизвестна\n"
        }
        out += "\n\(body)\n"
        try out.write(to: s.summaryURL, atomically: true, encoding: .utf8)
    }
}
