import Foundation

public enum Track: String, Codable {
    case mic, call
}

/// A stretch of speech by one speaker, seconds from the start of the recording.
public struct VoiceSegment: Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public protocol Diarizer {
    /// Speech segments of 16 kHz mono audio and one voice embedding per speaker id.
    func diarize(_ samples: [Float]) async throws -> (segments: [VoiceSegment], embeddings: [String: [Float]])
}

/// One voice found in a call: a speaker cluster on one track.
public struct CallSpeaker: Codable, Equatable {
    /// "<track>:<cluster>", e.g. "call:S2".
    public var id: String
    public var track: Track
    public var name: String
    /// The name came from the voice database or the user, not a "Спикер N" placeholder.
    public var known: Bool
    public var embedding: [Float]
}

public struct Turn: Codable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String?
}

/// Who spoke when in a call; saved as speakers.json next to the recording.
public struct SpeakerMap: Codable, Equatable {
    public var speakers: [CallSpeaker]
    public var turns: [Turn]

    /// Builds turns from per-track diarization and names speakers from the voice database.
    /// Unknown speakers are numbered in order of their first turn.
    public static func build(tracks: [(Track, [VoiceSegment], [String: [Float]])], voices: VoiceDB?) -> SpeakerMap {
        var segments: [VoiceSegment] = []
        var embeddings: [String: (Track, [Float])] = [:]
        for (track, segs, embs) in tracks {
            segments += segs.map { VoiceSegment(speaker: "\(track.rawValue):\($0.speaker)", start: $0.start, end: $0.end) }
            for (k, v) in embs { embeddings["\(track.rawValue):\(k)"] = (track, v) }
        }
        let turns = Self.turns(segments)
        let names = voices?.match(embeddings.mapValues { $0.1 }) ?? [:]
        var speakers: [CallSpeaker] = []
        var unknown = 0
        for t in turns where !speakers.contains(where: { $0.id == t.speaker }) {
            let (track, emb) = embeddings[t.speaker] ?? (t.speaker.hasPrefix("mic:") ? .mic : .call, [])
            let name = names[t.speaker]
            if name == nil { unknown += 1 }
            speakers.append(CallSpeaker(id: t.speaker, track: track, name: name ?? "Спикер \(unknown)",
                                        known: name != nil, embedding: emb))
        }
        return SpeakerMap(speakers: speakers, turns: turns)
    }

    /// Merges consecutive segments of one speaker separated by short pauses into turns of at most `maxLen` seconds.
    static func turns(_ segments: [VoiceSegment], minLen: Double = 0.3, maxGap: Double = 1.5, maxLen: Double = 120) -> [Turn] {
        var out: [Turn] = []
        for s in segments.sorted(by: { $0.start < $1.start }) where s.end - s.start >= minLen {
            if let last = out.last, last.speaker == s.speaker, s.start - last.end <= maxGap, s.end - last.start <= maxLen {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(Turn(speaker: s.speaker, start: s.start, end: s.end))
            }
        }
        return out
    }

    public func name(of id: String) -> String {
        speakers.first { $0.id == id }?.name ?? id
    }

    /// Seconds of speech per speaker id. Turns the ASR found no words in (residual echo, noise) don't count.
    public func seconds() -> [String: Double] {
        turns.filter { $0.text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true }
            .reduce(into: [:]) { $0[$1.speaker, default: 0] += $1.end - $1.start }
    }

    /// Markdown transcript: participants with their share of speech, then one paragraph per turn.
    public func render() -> String {
        var byName: [(String, Double)] = []
        for (id, sec) in seconds() {
            let n = name(of: id)
            if let i = byName.firstIndex(where: { $0.0 == n }) { byName[i].1 += sec } else { byName.append((n, sec)) }
        }
        let total = byName.reduce(0) { $0 + $1.1 }
        var out = ""
        if total > 0 {
            let list = byName.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
                .map { "\($0.0) (\(Int(($0.1 / total * 100).rounded()))%)" }
            out += "Участники: \(list.joined(separator: ", "))\n\n"
        }
        var paragraphs: [(name: String, text: String)] = []
        for t in turns {
            let text = (t.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let n = name(of: t.speaker)
            if paragraphs.last?.name == n {
                paragraphs[paragraphs.count - 1].text += " \(text)"
            } else {
                paragraphs.append((n, "[\(stamp(Int(t.start)))] **\(n)**: \(text)"))
            }
        }
        if paragraphs.isEmpty { return "" }
        return out + paragraphs.map(\.text).joined(separator: "\n\n") + "\n"
    }
}

func stamp(_ sec: Int) -> String {
    sec >= 3600
        ? String(format: "%02d:%02d:%02d", sec / 3600, sec % 3600 / 60, sec % 60)
        : String(format: "%02d:%02d", sec / 60, sec % 60)
}

/// Named voice embeddings remembered across calls, in voices.json next to the config.
public struct VoiceDB {
    public struct Voice: Codable, Equatable {
        public var name: String
        public var embeddings: [[Float]]
    }

    public let url: URL
    public var voices: [Voice]
    /// Minimum cosine similarity to a remembered embedding for a match.
    public static let threshold: Float = 0.6
    static let maxEmbeddings = 10

    /// An empty database when the file does not exist yet.
    public static func load(_ url: URL) throws -> VoiceDB {
        guard FileManager.default.fileExists(atPath: url.path) else { return VoiceDB(url: url, voices: []) }
        return VoiceDB(url: url, voices: try JSONDecoder().decode([Voice].self, from: Data(contentsOf: url)))
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(voices).write(to: url, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    /// Names for the given speaker embeddings; each name goes to at most one speaker, best matches first.
    public func match(_ embeddings: [String: [Float]], threshold: Float = threshold) -> [String: String] {
        var pairs: [(id: String, name: String, score: Float)] = []
        for (id, e) in embeddings {
            for v in voices {
                let score = v.embeddings.map { cosine($0, e) }.max() ?? -1
                if score >= threshold { pairs.append((id, v.name, score)) }
            }
        }
        var out: [String: String] = [:]
        for p in pairs.sorted(by: { ($0.score, $1.id) > ($1.score, $0.id) })
        where out[p.id] == nil && !out.values.contains(p.name) {
            out[p.id] = p.name
        }
        return out
    }

    /// Remembers an embedding under a name, keeping the latest `maxEmbeddings` per name.
    public mutating func enroll(_ name: String, _ embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        if let i = voices.firstIndex(where: { $0.name == name }) {
            voices[i].embeddings = Array((voices[i].embeddings + [embedding]).suffix(Self.maxEmbeddings))
        } else {
            voices.append(Voice(name: name, embeddings: [embedding]))
        }
    }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in a.indices {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : -1
}

extension Session {
    public var speakersURL: URL { dir.appendingPathComponent("speakers.json") }

    public func readSpeakers() throws -> SpeakerMap {
        try JSONDecoder().decode(SpeakerMap.self, from: Data(contentsOf: speakersURL))
    }

    public func write(_ map: SpeakerMap) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(map).write(to: speakersURL, options: .atomic)
    }

    /// Renames speakers by id, remembers their voices under the new names and rewrites the transcript.
    /// A finished call goes back to `.transcribed` so the summary is rebuilt with the new names.
    /// Returns whether any name changed.
    @discardableResult
    public func rename(_ names: [String: String], voicesFile: URL) throws -> Bool {
        var map = try readSpeakers()
        var db = try VoiceDB.load(voicesFile)
        var changed = false
        for i in map.speakers.indices {
            guard let n = names[map.speakers[i].id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !n.isEmpty, n != map.speakers[i].name else { continue }
            map.speakers[i].name = n
            map.speakers[i].known = true
            db.enroll(n, map.speakers[i].embedding)
            changed = true
        }
        guard changed else { return false }
        try db.save()
        try write(map)
        try map.render().write(to: transcriptURL, atomically: true, encoding: .utf8)
        var st = try readStatus()
        if st.state == .done {
            st.state = .transcribed
            try write(st)
        }
        return true
    }
}
