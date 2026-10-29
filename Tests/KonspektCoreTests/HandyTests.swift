#if !os(Windows)
import Testing
import Foundation
@testable import KonspektCore

@Suite struct HandyTests {
    /// A shell script standing in for the handy binary.
    func fake(_ body: String) throws -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("handy-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return f
    }

    @Test func test_transcribe_reads_json_text() async throws {
        // Echoes the arguments back so the test sees what Handy was called with.
        let exe = try fake(#"echo "log line" >&2; printf '{"text":"привет","args":"%s"}' "$*""#)
        let h = HandyTranscriber(executable: exe, model: "giga")
        #expect(try await h.transcribe(wav: Data([1, 2])) == "привет")
        #expect(h.maxConcurrent == 1)
    }

    @Test func test_arguments_and_input_file() async throws {
        let exe = try fake(#"[ "$1" = -f ] && [ -s "$2" ] && [ "$3" = --json ] && [ "$4" = --model ] && [ "$5" = m ] && echo '{"text":"ok"}'"#)
        #expect(try await HandyTranscriber(executable: exe, model: "m").transcribe(wav: Data([1])) == "ok")
        let noModel = try fake(#"[ $# -eq 3 ] && echo '{"text":"ok"}'"#)
        #expect(try await HandyTranscriber(executable: noModel).transcribe(wav: Data([1])) == "ok")
    }

    @Test func test_failure_reports_last_stderr_line() async throws {
        let exe = try fake("echo '[INFO] loading' >&2; echo 'error: model not found' >&2; exit 2")
        await #expect(throws: HandyError.failed(2, "error: model not found")) {
            try await HandyTranscriber(executable: exe).transcribe(wav: Data([1]))
        }
    }

    @Test func test_not_installed() async {
        let path = "/nonexistent/\(UUID().uuidString)/handy"
        await #expect(throws: HandyError.notInstalled(path)) {
            try await HandyTranscriber(executable: URL(fileURLWithPath: path)).transcribe(wav: Data([1]))
        }
    }

    @Test func test_bad_output() async throws {
        let exe = try fake("echo nope")
        await #expect(throws: HandyError.badOutput("nope\n")) {
            try await HandyTranscriber(executable: exe).transcribe(wav: Data([1]))
        }
    }

    @Test func test_cancel_terminates_handy() async throws {
        let exe = try fake("exec sleep 30")
        let start = Date()
        let t = Task { try await HandyTranscriber(executable: exe).transcribe(wav: Data([1])) }
        try await Task.sleep(nanoseconds: 300_000_000)
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func test_models_lists_downloaded() async throws {
        let exe = try fake(#"[ "$1" = --list-models ] && echo '[{"id":"a","is_downloaded":true},{"id":"b","is_downloaded":false}]'"#)
        #expect(try await HandyTranscriber.models(executable: exe) == ["a"])
    }
}
#endif
