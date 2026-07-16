import Foundation

/// Client « chat completions » OpenAI-compatible, en flux SSE.
/// Le décodage des événements vit dans `OpenAIStreamAccumulator`, pur et testé
/// sans réseau.
public struct OpenAICompatibleClient: LLMClient {
    public let config: LLMProviderConfig
    let session: URLSession

    public init(config: LLMProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func stream(messages: [LLMMessage], tools: [LLMToolSpec])
        -> AsyncThrowingStream<LLMChunk, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(
                        url: config.baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let key = config.apiKey, !key.isEmpty {
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try Self.requestBody(
                        model: config.model, messages: messages, tools: tools)
                    request.timeoutInterval = 300

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 800 { break }
                        }
                        throw DaemonError.provider(status: http.statusCode, body: body)
                    }

                    var accumulator = OpenAIStreamAccumulator()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let text = accumulator.ingest(json: Data(payload.utf8)) {
                            continuation.yield(.text(text))
                        }
                        if Task.isCancelled { break }
                    }
                    continuation.yield(.finished(toolCalls: accumulator.finalizedToolCalls()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Corps de requête

    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec]) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { message -> [String: Any] in
                var m: [String: Any] = ["role": message.role.rawValue,
                                        "content": message.content]
                if !message.toolCalls.isEmpty {
                    m["tool_calls"] = message.toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": call.argumentsJSON]]
                    }
                }
                if let id = message.toolCallID { m["tool_call_id"] = id }
                return m
            },
        ]
        if !tools.isEmpty {
            payload["tools"] = try tools.map { spec -> [String: Any] in
                let params = try JSONSerialization.jsonObject(
                    with: Data(spec.parametersJSON.utf8))
                return ["type": "function",
                        "function": ["name": spec.name,
                                     "description": spec.description,
                                     "parameters": params]]
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

public enum DaemonError: LocalizedError {
    case provider(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case let .provider(status, body):
            "Le fournisseur a répondu \(status) : \(String(body.prefix(300)))"
        }
    }
}

/// Accumulateur PUR du flux SSE OpenAI : ingère chaque `data: {…}` et rend le
/// texte à afficher ; agrège les fragments d'appels d'outils (livrés par deltas
/// indexés). Testé sans réseau.
public struct OpenAIStreamAccumulator {
    private struct PartialCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private var calls: [Int: PartialCall] = [:]

    public init() {}

    /// Ingère un événement ; retourne le texte assistant s'il y en a.
    public mutating func ingest(json: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any]
        else { return nil }

        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for fragment in toolCalls {
                let index = fragment["index"] as? Int ?? 0
                var call = calls[index] ?? PartialCall()
                if let id = fragment["id"] as? String { call.id += id }
                if let function = fragment["function"] as? [String: Any] {
                    if let name = function["name"] as? String { call.name += name }
                    if let args = function["arguments"] as? String { call.arguments += args }
                }
                calls[index] = call
            }
        }
        return delta["content"] as? String
    }

    public func finalizedToolCalls() -> [LLMToolCall] {
        calls.sorted { $0.key < $1.key }.compactMap { _, call in
            guard !call.name.isEmpty else { return nil }
            return LLMToolCall(
                id: call.id.isEmpty ? UUID().uuidString : call.id,
                name: call.name,
                argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        }
    }
}
