import Foundation

public enum HandyError: Error, Equatable {
    case notInstalled(String), failed(Int32, String), badOutput(String)
}

/// Local ASR through the Handy app's headless mode: `handy -f <wav> --json`.
public struct HandyTranscriber: Transcriber {
    let executable: URL
    let model: String?

    public init(executable: URL, model: String? = nil) {
        self.executable = executable
        self.model = model
    }

    /// Every run loads the model onto the GPU; parallel runs only slow each other down.
    public var maxConcurrent: Int { 1 }

    public func transcribe(wav: Data) async throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("konspekt-handy-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("audio.wav")
        try wav.write(to: input)
        let out = try await Self.run(executable, ["-f", input.path, "--json"] + (model.map { ["--model", $0] } ?? []), in: dir)
        guard let j = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let text = j["text"] as? String else {
            throw HandyError.badOutput(String(String(decoding: out, as: UTF8.self).prefix(500)))
        }
        return text
    }

    /// Ids of the models downloaded in Handy, for `--model`.
    public static func models(executable: URL) async throws -> [String] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("konspekt-handy-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let out = try await run(executable, ["--list-models", "--json"], in: dir)
        guard let list = try? JSONSerialization.jsonObject(with: out) as? [[String: Any]] else {
            throw HandyError.badOutput(String(String(decoding: out, as: UTF8.self).prefix(500)))
        }
        return list.filter { $0["is_downloaded"] as? Bool == true }.compactMap { $0["id"] as? String }
    }

    /// Runs Handy with stdout and stderr in files in `dir`: its log on stderr can outgrow a pipe buffer.
    static func run(_ exe: URL, _ args: [String], in dir: URL) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { throw HandyError.notInstalled(exe.path) }
        let outURL = dir.appendingPathComponent("out.json")
        let errURL = dir.appendingPathComponent("err.log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { c.resume(throwing: error) }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            // The last stderr line is the error, the ones before it are Handy's log.
            let log = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let last = log.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw HandyError.failed(status, String(last.prefix(500)))
        }
        return try Data(contentsOf: outURL)
    }
}
