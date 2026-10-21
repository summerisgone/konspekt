import Testing
import Foundation
@testable import KonspektCore

private final class Fake: Transcriber, Summarizer, @unchecked Sendable {
    var asrCalls = 0
    var sumCalls = 0
    var asrFail = false
    var sumFail = false
    var text = "привет"
    func transcribe(wav: Data) async throws -> String {
        asrCalls += 1
        if asrFail { throw APIError.http(502, "bad gateway") }
        return text
    }
    func summarize(transcript: String) async throws -> String {
        sumCalls += 1
        if sumFail { throw APIError.http(500, "boom") }
        return "итоги"
    }
}

private func makeSession(status: SessionState = .recorded) throws -> Session {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pl-" + UUID().uuidString)
    let store = SessionStore(root: root)
    let s = try store.create(start: Date(timeIntervalSince1970: 1_800_000_000))
    try makeTrack(s.micURL, rate: 16000, channels: 1, seconds: 3, values: [0]) { 0.3 * sin(Float($0) * 0.1) }
    var st = try s.readStatus()
    st.state = status
    st.end = st.start.addingTimeInterval(180)
    try s.write(st)
    return s
}

@Suite struct PipelineTests {
    @Test func test_happy_path_done() async throws {
        let s = try makeSession()
        let f = Fake()
        let st = await Pipeline(transcriber: f, summarizer: f).process(s)
        #expect(st.state == .done)
        #expect(st.lastError == nil)
        let t = try String(contentsOf: s.transcriptURL, encoding: .utf8)
        #expect(t.contains("## [00:00]") && t.contains("привет"))
        let sum = try String(contentsOf: s.summaryURL, encoding: .utf8)
        #expect(sum.hasPrefix("# Конспект звонка ") && sum.contains("итоги"))
    }

    @Test func test_transcriber_failure_keeps_recorded() async throws {
        let s = try makeSession()
        let f = Fake(); f.asrFail = true
        let st = await Pipeline(transcriber: f, summarizer: f).process(s)
        #expect(st.state == .recorded)
        #expect(st.attempts == 1)
        #expect(st.lastError != nil)
        #expect(try s.readStatus().attempts == 1)
    }

    @Test func test_resume_uses_cached_chunks() async throws {
        let s = try makeSession()
        try FileManager.default.createDirectory(at: s.chunksDir, withIntermediateDirectories: true)
        try "кэш".write(to: s.chunksDir.appendingPathComponent("000.txt"), atomically: true, encoding: .utf8)
        let f = Fake()
        let st = await Pipeline(transcriber: f, summarizer: f).process(s)
        #expect(f.asrCalls == 0)
        #expect(st.state == .done)
        #expect(try String(contentsOf: s.transcriptURL, encoding: .utf8).contains("кэш"))
    }

    @Test func test_summary_fail_keeps_transcript() async throws {
        let s = try makeSession()
        let f = Fake(); f.sumFail = true
        let p = Pipeline(transcriber: f, summarizer: f)
        let st = await p.process(s)
        #expect(st.state == .transcribed)
        #expect(st.attempts == 1)
        #expect(FileManager.default.fileExists(atPath: s.transcriptURL.path))
        f.sumFail = false
        let st2 = await p.process(s)
        #expect(st2.state == .done)
        #expect(f.asrCalls == 1)
        #expect(f.sumCalls == 2)
    }

    @Test func test_empty_speech() async throws {
        let s = try makeSession()
        let f = Fake(); f.text = "  "
        let st = await Pipeline(transcriber: f, summarizer: f).process(s)
        #expect(st.state == .done)
        #expect(f.sumCalls == 0)
        #expect(try String(contentsOf: s.summaryURL, encoding: .utf8) == "Речь не распознана")
    }

    @Test func test_done_is_noop() async throws {
        let s = try makeSession(status: .done)
        let f = Fake()
        let st = await Pipeline(transcriber: f, summarizer: f).process(s)
        #expect(st.state == .done)
        #expect(f.asrCalls == 0 && f.sumCalls == 0)
    }
}
