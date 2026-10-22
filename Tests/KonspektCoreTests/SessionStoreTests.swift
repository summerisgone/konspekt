import Testing
import Foundation
@testable import KonspektCore

@Suite struct SessionStoreTests {
    func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
    }
    func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    @Test func test_create_named_and_recording() throws {
        let store = SessionStore(root: tmp())
        let t = date("2026-10-21 10:05:03")
        let s = try store.create(start: t)
        #expect(s.name == "2026-10-21_10-05-03")
        let st = try s.readStatus()
        #expect(st.state == .recording)
        #expect(st.attempts == 0)
        #if os(macOS)
        #expect(s.micURL.lastPathComponent == "mic.caf")
        #expect(s.callURL.lastPathComponent == "call.caf")
        #else
        #expect(s.micURL.lastPathComponent == "mic.wav")
        #expect(s.callURL.lastPathComponent == "call.wav")
        #endif
        #expect(s.chunksDir.lastPathComponent == "chunks")
    }
    @Test func test_reset_for_reprocessing() throws {
        let s = try SessionStore(root: tmp()).create(start: date("2026-10-21 10:05:03"))
        var st = try s.readStatus()
        st.state = .done
        st.attempts = 2
        st.lastError = "boom"
        try s.write(st)
        try FileManager.default.createDirectory(at: s.chunksDir, withIntermediateDirectories: true)
        try "x".write(to: s.chunksDir.appendingPathComponent("mic-00000000.txt"), atomically: true, encoding: .utf8)
        try s.write(SpeakerMap(speakers: [], turns: []))
        try "t".write(to: s.transcriptURL, atomically: true, encoding: .utf8)

        try s.resetForReprocessing()
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: s.chunksDir.path) && !fm.fileExists(atPath: s.speakersURL.path))
        #expect(fm.fileExists(atPath: s.transcriptURL.path))
        let after = try s.readStatus()
        #expect(after.state == .recorded && after.attempts == 0 && after.lastError == nil)
    }
    @Test func test_create_same_second_unique() throws {
        let store = SessionStore(root: tmp())
        let t = date("2026-10-21 10:05:03")
        let a = try store.create(start: t)
        let b = try store.create(start: t)
        #expect(a.name != b.name)
        #expect(b.name == "2026-10-21_10-05-03-2")
    }
    @Test func test_status_roundtrip() throws {
        let store = SessionStore(root: tmp())
        let s = try store.create(start: date("2026-10-21 10:05:03"))
        let st = SessionStatus(state: .transcribed, attempts: 2, lastError: "boom",
                               start: date("2026-10-21 10:05:03"), end: date("2026-10-21 11:00:00"))
        try s.write(st)
        #expect(try s.readStatus() == st)
    }
    @Test func test_corrupt_status_skipped_in_pending() throws {
        let store = SessionStore(root: tmp())
        let a = try store.create(start: date("2026-10-21 10:00:00"))
        let b = try store.create(start: date("2026-10-21 11:00:00"))
        let c = try store.create(start: date("2026-10-21 12:00:00"))
        let d = try store.create(start: date("2026-10-21 13:00:00"))
        var st = try a.readStatus()
        st.state = .recorded; try a.write(st)
        try "{not json".write(to: b.dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        st.state = .transcribed; try c.write(st)
        st.state = .done; try d.write(st)
        #expect(store.pending().map(\.name) == [a.name, c.name])
        #expect(store.all().map(\.name) == [a.name, c.name, d.name])
    }
}
