import Testing
import Foundation
@testable import KonspektCore

private func tmp(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sp-" + UUID().uuidString).appendingPathComponent(name)
}

@Suite struct SpeakersTests {
    @Test func test_turns_merge_short_pauses_only() {
        let t = SpeakerMap.turns([
            VoiceSegment(speaker: "a", start: 0, end: 2),
            VoiceSegment(speaker: "a", start: 3, end: 4),     // 1 s pause: merged
            VoiceSegment(speaker: "b", start: 4.5, end: 5),
            VoiceSegment(speaker: "a", start: 5.2, end: 6),   // another speaker in between: new turn
            VoiceSegment(speaker: "a", start: 9, end: 10),    // 3 s pause: new turn
            VoiceSegment(speaker: "b", start: 10.5, end: 10.6), // too short: dropped
        ])
        #expect(t.map(\.speaker) == ["a", "b", "a", "a"])
        #expect(t[0].start == 0 && t[0].end == 4)
    }

    @Test func test_turns_respect_max_length() {
        let segs = (0..<10).map { VoiceSegment(speaker: "a", start: Double($0) * 30, end: Double($0) * 30 + 29.5) }
        let t = SpeakerMap.turns(segs)
        #expect(t.count == 3)
        #expect(t.allSatisfy { $0.end - $0.start <= 120 })
    }

    @Test func test_match_is_one_to_one_and_thresholded() {
        var db = VoiceDB(url: tmp("voices.json"), voices: [])
        db.enroll("Илья", [1, 0, 0])
        db.enroll("Анна", [0, 1, 0])
        let m = db.match(["x": [0.9, 0.1, 0], "y": [1, 0.05, 0], "z": [0, 0, 1]])
        #expect(m == ["y": "Илья"])
        #expect(db.match(["w": [0.1, 1, 0]]) == ["w": "Анна"])
    }

    @Test func test_enroll_keeps_latest() throws {
        var db = VoiceDB(url: tmp("voices.json"), voices: [])
        for i in 0..<15 { db.enroll("A", [Float(i), 1]) }
        #expect(db.voices.count == 1)
        #expect(db.voices[0].embeddings.count == VoiceDB.maxEmbeddings)
        #expect(db.voices[0].embeddings.last == [14, 1])
        try db.save()
        #expect(try VoiceDB.load(db.url).voices == db.voices)
        #expect(try VoiceDB.load(tmp("missing.json")).voices.isEmpty)
    }

    @Test func test_build_names_known_and_numbers_unknown() {
        let db = VoiceDB(url: tmp("voices.json"), voices: [.init(name: "Илья", embeddings: [[0, 1]])])
        let map = SpeakerMap.build(tracks: [
            (.mic, [VoiceSegment(speaker: "S1", start: 0, end: 2)], ["S1": [1, 0]]),
            (.call, [VoiceSegment(speaker: "S1", start: 3, end: 5), VoiceSegment(speaker: "S2", start: 6, end: 7)],
             ["S1": [0, 1], "S2": [-1, 0]]),
        ], voices: db)
        #expect(map.speakers.map(\.id) == ["mic:S1", "call:S1", "call:S2"])
        #expect(map.speakers.map(\.name) == ["Спикер 1", "Илья", "Спикер 2"])
        #expect(map.speakers.map(\.known) == [false, true, false])
        #expect(map.speakers[0].track == .mic && map.speakers[2].track == .call)
    }

    @Test func test_render_shares_and_merges_same_name() {
        let map = SpeakerMap(speakers: [
            CallSpeaker(id: "mic:S1", track: .mic, name: "Я", known: true, embedding: []),
            CallSpeaker(id: "call:S1", track: .call, name: "Илья", known: true, embedding: []),
            CallSpeaker(id: "call:S2", track: .call, name: "Илья", known: true, embedding: []),
            CallSpeaker(id: "mic:S2", track: .mic, name: "Спикер 1", known: false, embedding: []),
        ], turns: [
            Turn(speaker: "mic:S1", start: 0, end: 10, text: "привет"),
            Turn(speaker: "call:S1", start: 10, end: 30, text: "раз"),
            Turn(speaker: "call:S2", start: 31, end: 40, text: "два"),
            Turn(speaker: "mic:S1", start: 3700, end: 3700, text: " "),
            Turn(speaker: "mic:S2", start: 41, end: 50, text: ""),
        ])
        #expect(map.render() == """
        Участники: Илья (74%), Я (26%)

        [00:00] **Я**: привет

        [00:10] **Илья**: раз два

        """)
    }

    @Test func test_rename_updates_db_transcript_and_status() throws {
        let root = tmp("calls")
        let s = try SessionStore(root: root).create(start: Date())
        var st = try s.readStatus()
        st.state = .done
        try s.write(st)
        try s.write(SpeakerMap(speakers: [
            CallSpeaker(id: "call:S1", track: .call, name: "Спикер 1", known: false, embedding: [1, 2]),
        ], turns: [Turn(speaker: "call:S1", start: 0, end: 5, text: "привет")]))
        let voices = root.appendingPathComponent("voices.json")

        #expect(try s.rename(["call:S1": " Спикер 1 "], voicesFile: voices) == false)
        #expect(try s.rename(["call:S1": "Анна"], voicesFile: voices))
        #expect(try s.readSpeakers().speakers[0].name == "Анна")
        #expect(try VoiceDB.load(voices).voices == [.init(name: "Анна", embeddings: [[1, 2]])])
        #expect(try String(contentsOf: s.transcriptURL, encoding: .utf8).contains("**Анна**: привет"))
        #expect(try s.readStatus().state == .transcribed)
    }
}
