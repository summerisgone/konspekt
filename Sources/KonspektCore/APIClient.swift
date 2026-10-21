import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol Transcriber {
    func transcribe(wav: Data) async throws -> String
}

public protocol Summarizer {
    func summarize(transcript: String) async throws -> String
}

public protocol HTTPTransport {
    func send(_ r: URLRequest) async throws -> (Data, Int)
}

public enum APIError: Error, Equatable {
    case http(Int, String), transport(String), badResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(timeout: TimeInterval) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        session = URLSession(configuration: c)
    }
    public func send(_ r: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(for: r)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct APIClient: Transcriber, Summarizer {
    private let config: Config
    private let asrTransport: HTTPTransport
    private let chatTransport: HTTPTransport

    public init(config: Config, transport: HTTPTransport) {
        self.config = config
        self.asrTransport = transport
        self.chatTransport = transport
    }

    init(config: Config, asr: HTTPTransport, chat: HTTPTransport) {
        self.config = config
        self.asrTransport = asr
        self.chatTransport = chat
    }

    public static func live(config: Config) -> APIClient {
        APIClient(config: config, asr: URLSessionTransport(timeout: 300), chat: URLSessionTransport(timeout: 900))
    }

    public static let systemPrompt = """
    Ты помощник, который составляет конспект рабочего звонка по его расшифровке. \
    Ответь на русском языке в формате Markdown с разделами: \
    ## Кратко, ## Решения, ## Задачи (кто что делает и к какому сроку, если названо), ## Открытые вопросы. \
    Не выдумывай факты, которых нет в расшифровке. Если раздел пуст, напиши «нет».
    """

    /// Trimmed contents of a prompt file, nil when no file is set or it is empty.
    private func prompt(_ file: URL?) throws -> String? {
        guard let file else { return nil }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw ConfigError.unreadable(file.path)
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func perform(_ req: URLRequest, via t: HTTPTransport) async throws -> Data {
        let data: Data
        let status: Int
        do { (data, status) = try await t.send(req) }
        catch let e as APIError { throw e }
        catch {
            var m = error.localizedDescription
            if !config.apiKey.isEmpty { m = m.replacingOccurrences(of: config.apiKey, with: "***") }
            throw APIError.transport(m)
        }
        guard (200..<300).contains(status) else {
            var body = String(decoding: data, as: UTF8.self)
            if !config.apiKey.isEmpty { body = body.replacingOccurrences(of: config.apiKey, with: "***") }
            throw APIError.http(status, String(body.prefix(500)))
        }
        return data
    }

    private func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: config.baseURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return r
    }

    public func transcribe(wav: Data) async throws -> String {
        let boundary = "konspekt-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(config.asrModel)\r\n")
        if let p = try prompt(config.transcriptionPromptFile) {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n\(p)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")
        var r = request("audio/transcriptions")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let data = try await perform(r, via: asrTransport)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = j["text"] as? String else { throw APIError.badResponse }
        return text
    }

    public func summarize(transcript: String) async throws -> String {
        let system = try prompt(config.summaryPromptFile) ?? Self.systemPrompt
        let payload: [String: Any] = [
            "model": config.summaryModel,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": transcript]],
            "max_tokens": 4000,
            "temperature": 0.3,
        ]
        var r = request("chat/completions")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await perform(r, via: chatTransport)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = j["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw APIError.badResponse }
        return content
    }
}
