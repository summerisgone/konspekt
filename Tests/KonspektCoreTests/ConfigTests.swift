import Testing
import Foundation
@testable import KonspektCore

@Suite struct ConfigTests {
    func load(_ text: String) throws -> Config {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)")
        try text.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        return try Config.load(envFile: f)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser

    @Test func test_defaults() throws {
        let c = try load("OPENAI_BASE_URL=\"https://h/v1\"\nOPENAI_API_KEY=k\nOPENAI_MODEL_NAME=asr\n# c")
        #expect(c.baseURL == URL(string: "https://h/v1")!)
        #expect(c.apiKey == "k")
        #expect(c.asrModel == "asr")
        #expect(c.summaryModel == "qwen-3.8-27b")
        #expect(c.outputDir.path == Config.documentsDir.appendingPathComponent("Konspekt").path)
        #if os(macOS)
        #expect(c.outputDir.path == home.appendingPathComponent("Documents/Konspekt").path)
        #endif
        #expect(c.transcriptionPromptFile == nil)
        #expect(c.summaryPromptFile == nil)
    }
    @Test func test_prompt_files() throws {
        let c = try load("OPENAI_BASE_URL=https://h\nOPENAI_API_KEY=k\nOPENAI_MODEL_NAME=a\n"
            + "TRANSCRIPTION_PROMPT_FILE=~/p/asr.txt\nSUMMARY_PROMPT_FILE=/tmp/sum.md")
        #expect(c.transcriptionPromptFile?.path == home.appendingPathComponent("p/asr.txt").path)
        #expect(c.summaryPromptFile?.path == "/tmp/sum.md")
        let empty = try load("OPENAI_BASE_URL=https://h\nOPENAI_API_KEY=k\nOPENAI_MODEL_NAME=a\nSUMMARY_PROMPT_FILE=")
        #expect(empty.summaryPromptFile == nil)
    }
    @Test func test_keep_audio_gb() throws {
        let base = "OPENAI_BASE_URL=https://h\nOPENAI_API_KEY=k\nOPENAI_MODEL_NAME=a\n"
        #expect(try load(base).keepAudioGB == 10)
        #expect(try load(base + "KEEP_AUDIO_GB=25").keepAudioGB == 25)
        #expect(try load(base + "KEEP_AUDIO_GB=x").keepAudioGB == 10)
    }
    @Test func test_missing_key_throws() {
        #expect(throws: ConfigError.missing("OPENAI_API_KEY")) {
            try load("OPENAI_BASE_URL=https://h\nOPENAI_MODEL_NAME=asr")
        }
    }
    @Test func test_handy_engine_needs_no_asr_model_or_key() throws {
        let c = try load("OPENAI_BASE_URL=http://localhost:11434/v1\nASR_ENGINE=handy\nHANDY_PATH=~/bin/handy\nHANDY_MODEL=m")
        #expect(c.handy == Config.Handy(executable: home.appendingPathComponent("bin/handy"), model: "m"))
        #expect(c.apiKey == "")
        #expect(c.asrModel == "")
        #if os(macOS)
        let d = try load("OPENAI_BASE_URL=https://h\nASR_ENGINE=handy\nHANDY_MODEL=")
        #expect(d.handy?.executable.path.hasSuffix("Applications/Handy.app/Contents/MacOS/handy") == true)
        #expect(d.handy?.model == nil)
        #endif
    }
    @Test func test_default_engine_is_api() throws {
        let c = try load("OPENAI_BASE_URL=https://h\nOPENAI_API_KEY=k\nOPENAI_MODEL_NAME=a\nASR_ENGINE=openai\nHANDY_MODEL=m")
        #expect(c.handy == nil)
    }
    @Test func test_unknown_engine_throws() {
        #expect(throws: ConfigError.invalid("ASR_ENGINE")) {
            try load("OPENAI_BASE_URL=https://h\nOPENAI_API_KEY=k\nOPENAI_MODEL_NAME=a\nASR_ENGINE=whisper")
        }
    }
    @Test func test_tilde_expanded() throws {
        let c = try load("OPENAI_BASE_URL=https://h\nOPENAI_API_KEY=k\nOPENAI_MODEL_NAME=a\nKONSPEKT_DIR=~/x")
        #expect(c.outputDir.path == home.appendingPathComponent("x").path)
    }
    @Test func test_export_quotes_summary() throws {
        let c = try load("export OPENAI_BASE_URL='https://h'\n\nexport OPENAI_API_KEY=\"k\"\nOPENAI_MODEL_NAME=a\nSUMMARY_MODEL_NAME=m")
        #expect(c.baseURL.absoluteString == "https://h")
        #expect(c.apiKey == "k")
        #expect(c.summaryModel == "m")
    }
    @Test func test_unreadable() {
        let f = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        #expect(throws: ConfigError.unreadable(f.path)) { try Config.load(envFile: f) }
    }
    @Test func test_updating_replaces_and_appends() {
        let text = "# c\nexport OPENAI_API_KEY=\"old\"\nOPENAI_MODEL_NAME=a\nOTHER=x\n"
        let out = Config.updating(text, with: ["OPENAI_API_KEY": "new", "SUMMARY_MODEL_NAME": "m"])
        #expect(out == "# c\nOPENAI_API_KEY=new\nOPENAI_MODEL_NAME=a\nOTHER=x\nSUMMARY_MODEL_NAME=m\n")
        #expect(Config.parse(out)["OPENAI_API_KEY"] == "new")
    }
    @Test func test_updating_empty() {
        #expect(Config.updating("", with: ["A": "1"]) == "A=1\n")
    }
}
