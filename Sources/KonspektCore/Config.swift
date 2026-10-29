import Foundation

public struct Config: Equatable {
    public var baseURL: URL
    public var apiKey: String
    public var asrModel: String
    public var summaryModel: String
    public var outputDir: URL
    /// Files with prompts, read on every request so edits apply without a restart.
    public var transcriptionPromptFile: URL?
    public var summaryPromptFile: URL?
    /// Voice database for naming speakers, voices.json next to the .env file.
    public var voicesFile: URL?
    /// Audio of processed calls kept on disk, newest first; older recordings are deleted.
    public var keepAudioGB: Double
    public static let defaultKeepAudioGB: Double = 10
    /// Local ASR through the Handy app instead of the API (ASR_ENGINE=handy).
    public var handy: Handy?
    public init(baseURL: URL, apiKey: String, asrModel: String, summaryModel: String, outputDir: URL,
                transcriptionPromptFile: URL? = nil, summaryPromptFile: URL? = nil, voicesFile: URL? = nil,
                keepAudioGB: Double = defaultKeepAudioGB, handy: Handy? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.asrModel = asrModel
        self.summaryModel = summaryModel
        self.outputDir = outputDir
        self.transcriptionPromptFile = transcriptionPromptFile
        self.summaryPromptFile = summaryPromptFile
        self.voicesFile = voicesFile
        self.keepAudioGB = keepAudioGB
        self.handy = handy
    }

    public struct Handy: Equatable {
        public var executable: URL
        /// Handy model id; nil means the model selected in Handy.
        public var model: String?
        public init(executable: URL, model: String? = nil) {
            self.executable = executable
            self.model = model
        }

        /// Handy.app in /Applications or ~/Applications; no default outside macOS.
        public static var defaultExecutable: URL? {
            #if os(macOS)
            let suffix = "Applications/Handy.app/Contents/MacOS/handy"
            let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(suffix)
            return FileManager.default.fileExists(atPath: user.path) ? user : URL(fileURLWithPath: "/" + suffix)
            #else
            return nil
            #endif
        }
    }

    public static func load(envFile: URL) throws -> Config {
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else {
            throw ConfigError.unreadable(envFile.path)
        }
        let env = parse(text)
        func need(_ k: String) throws -> String {
            guard let v = env[k], !v.isEmpty else { throw ConfigError.missing(k) }
            return v
        }
        let base = try need("OPENAI_BASE_URL")
        var handy: Handy?
        switch env["ASR_ENGINE"] ?? "" {
        case "", "openai":
            break
        case "handy":
            guard let exe = env["HANDY_PATH"].flatMap(path) ?? Handy.defaultExecutable else { throw ConfigError.missing("HANDY_PATH") }
            handy = Handy(executable: exe, model: env["HANDY_MODEL"].flatMap { $0.isEmpty ? nil : $0 })
        default:
            throw ConfigError.invalid("ASR_ENGINE")
        }
        // With local ASR the API serves only the summary, possibly a local server without a key.
        let key = handy == nil ? try need("OPENAI_API_KEY") : env["OPENAI_API_KEY"] ?? ""
        let asr = handy == nil ? try need("OPENAI_MODEL_NAME") : env["OPENAI_MODEL_NAME"] ?? ""
        guard let url = URL(string: base) else { throw ConfigError.missing("OPENAI_BASE_URL") }
        let sm = env["SUMMARY_MODEL_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "qwen-3.8-27b"
        return Config(baseURL: url, apiKey: key, asrModel: asr, summaryModel: sm, outputDir: outputDir(env),
                      transcriptionPromptFile: env["TRANSCRIPTION_PROMPT_FILE"].flatMap(path),
                      summaryPromptFile: env["SUMMARY_PROMPT_FILE"].flatMap(path),
                      voicesFile: envFile.deletingLastPathComponent().appendingPathComponent("voices.json"),
                      keepAudioGB: keepAudioGB(env), handy: handy)
    }

    public static func parse(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            guard let (key, value) = entry(raw) else { continue }
            env[key] = value
        }
        return env
    }

    public static func outputDir(_ env: [String: String]) -> URL {
        env["KONSPEKT_DIR"].flatMap(path) ?? documentsDir.appendingPathComponent("Konspekt")
    }

    public static func keepAudioGB(_ env: [String: String]) -> Double {
        env["KEEP_AUDIO_GB"].flatMap(Double.init).map { max(0, $0) } ?? defaultKeepAudioGB
    }

    /// The user's Documents folder; on Windows it may be redirected (OneDrive, another drive).
    public static var documentsDir: URL {
        #if os(Windows)
        if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first { return d }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    }

    /// Default .env location: ~/.config/konspekt/.env, on Windows %APPDATA%\Konspekt\.env.
    public static var defaultEnvFile: URL {
        #if os(Windows)
        if let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty {
            return URL(fileURLWithPath: appData).appendingPathComponent("Konspekt").appendingPathComponent(".env")
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/konspekt/.env")
    }

    /// Expands a leading "~"; nil for an empty value.
    public static func path(_ d: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if d.isEmpty { return nil }
        if d == "~" { return home }
        if d.hasPrefix("~/") { return home.appendingPathComponent(String(d.dropFirst(2))) }
        #if os(Windows)
        if d.hasPrefix("~\\") { return home.appendingPathComponent(String(d.dropFirst(2))) }
        #endif
        return URL(fileURLWithPath: d)
    }

    /// Replaces the given keys in .env text in place, appends missing ones, keeps everything else.
    public static func updating(_ text: String, with values: [String: String]) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var left = values
        for i in lines.indices {
            guard let (key, _) = entry(lines[i]), let v = left[key] else { continue }
            lines[i] = "\(key)=\(v)"
            left[key] = nil
        }
        for key in left.keys.sorted() { lines.append("\(key)=\(left[key]!)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func entry(_ raw: String) -> (String, String)? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }
}

public enum ConfigError: Error, Equatable {
    case missing(String), unreadable(String), invalid(String)
}
