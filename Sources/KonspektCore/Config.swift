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
    public init(baseURL: URL, apiKey: String, asrModel: String, summaryModel: String, outputDir: URL,
                transcriptionPromptFile: URL? = nil, summaryPromptFile: URL? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.asrModel = asrModel
        self.summaryModel = summaryModel
        self.outputDir = outputDir
        self.transcriptionPromptFile = transcriptionPromptFile
        self.summaryPromptFile = summaryPromptFile
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
        let key = try need("OPENAI_API_KEY")
        let asr = try need("OPENAI_MODEL_NAME")
        guard let url = URL(string: base) else { throw ConfigError.missing("OPENAI_BASE_URL") }
        let sm = env["SUMMARY_MODEL_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "qwen-3.8-27b"
        return Config(baseURL: url, apiKey: key, asrModel: asr, summaryModel: sm, outputDir: outputDir(env),
                      transcriptionPromptFile: env["TRANSCRIPTION_PROMPT_FILE"].flatMap(path),
                      summaryPromptFile: env["SUMMARY_PROMPT_FILE"].flatMap(path))
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
    case missing(String), unreadable(String)
}
