import Foundation

public enum SessionState: String, Codable {
    case recording, recorded, transcribed, done
}

public struct SessionStatus: Codable, Equatable {
    public var state: SessionState
    public var attempts: Int
    public var lastError: String?
    public var start: Date
    public var end: Date?
    public init(state: SessionState, attempts: Int, lastError: String?, start: Date, end: Date?) {
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.start = start
        self.end = end
    }
}

public struct Session {
    public let dir: URL
    public var name: String { dir.lastPathComponent }
    #if os(macOS)
    static let audioExtension = "caf"
    #else
    static let audioExtension = "wav"
    #endif
    public var micURL: URL { dir.appendingPathComponent("mic.\(Self.audioExtension)") }
    public var callURL: URL { dir.appendingPathComponent("call.\(Self.audioExtension)") }
    public var transcriptURL: URL { dir.appendingPathComponent("transcript.md") }
    public var summaryURL: URL { dir.appendingPathComponent("summary.md") }
    public var chunksDir: URL { dir.appendingPathComponent("chunks") }
    var statusURL: URL { dir.appendingPathComponent("status.json") }
    public init(dir: URL) {
        self.dir = dir
    }
    public func readStatus() throws -> SessionStatus {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SessionStatus.self, from: Data(contentsOf: statusURL))
    }
    public func write(_ s: SessionStatus) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(s).write(to: statusURL, options: .atomic)
    }
    /// Drops the speaker map and cached transcription so the next run processes the call from scratch.
    /// Names come back from the voice database; transcript and summary are overwritten by that run.
    public func resetForReprocessing() throws {
        let fm = FileManager.default
        for url in [speakersURL, chunksDir] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        var st = try readStatus()
        st.state = .recorded
        st.attempts = 0
        st.lastError = nil
        try write(st)
    }
}

public struct SessionStore {
    public let root: URL
    public init(root: URL) {
        self.root = root
    }
    public func create(start: Date) throws -> Session {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = f.string(from: start)
        var name = base
        var n = 1
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            n += 1
            name = "\(base)-\(n)"
        }
        let session = Session(dir: root.appendingPathComponent(name))
        try fm.createDirectory(at: session.dir, withIntermediateDirectories: false)
        try session.write(SessionStatus(state: .recording, attempts: 0, lastError: nil, start: start, end: nil))
        return session
    }
    public func all() -> [Session] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.map { Session(dir: $0) }
            .filter { (try? $0.readStatus()) != nil }
            .sorted { $0.name < $1.name }
    }
    public func pending() -> [Session] {
        all().filter {
            guard let s = try? $0.readStatus() else { return false }
            return s.state == .recorded || s.state == .transcribed
        }
    }
}
