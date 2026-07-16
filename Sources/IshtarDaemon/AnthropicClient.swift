import Foundation

/// Client natif de l'API Messages d'Anthropic (BYOK), en flux SSE.
/// Même contrat `LLMClient` que le client OpenAI-compatible : le démon ne voit
/// aucune différence. Le décodage vit dans `AnthropicStreamAccumulator`, pur et
/// testé sans réseau.
public struct AnthropicClient: LLMClient {
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
                        url: config.baseURL.appendingPathComponent("v1/messages"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(config.apiKey ?? "", forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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

                    var accumulator = AnthropicStreamAccumulator()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let text = accumulator.ingest(json: Data(payload.utf8)) {
                            continuation.yield(.text(text))
                        }
                        if accumulator.isDone || Task.isCancelled { break }
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

    // MARK: Corps de requête (mapping LLMMessage → API Messages)

    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec]) throws -> Data {
        // Le système est un paramètre séparé chez Anthropic.
        let system = messages.first(where: { $0.role == .system })?.content

        var apiMessages: [[String: Any]] = []
        for message in messages where message.role != .system {
            switch message.role {
            case .assistant:
                var content: [[String: Any]] = []
                if !message.content.isEmpty {
                    content.append(["type": "text", "text": message.content])
                }
                for call in message.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(
                        with: Data(call.argumentsJSON.utf8))) ?? [:]
                    content.append(["type": "tool_use", "id": call.id,
                                    "name": call.name, "input": input])
                }
                apiMessages.append(["role": "assistant", "content": content])
            case .tool:
                // Un résultat d'outil = message user avec bloc tool_result.
                apiMessages.append(["role": "user", "content": [
                    ["type": "tool_result",
                     "tool_use_id": message.toolCallID ?? "",
                     "content": message.content],
                ]])
            case .user:
                apiMessages.append(["role": "user", "content": message.content])
            case .system:
                break
            }
        }

        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "messages": apiMessages,
        ]
        if let system { payload["system"] = system }
        if !tools.isEmpty {
            payload["tools"] = try tools.map { spec -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(
                    with: Data(spec.parametersJSON.utf8))
                return ["name": spec.name, "description": spec.description,
                        "input_schema": schema]
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

/// Accumulateur PUR du flux SSE Anthropic : `content_block_start` (text ou
/// tool_use), `content_block_delta` (`text_delta` / `input_json_delta`),
/// `message_stop`. Testé sans réseau.
public struct AnthropicStreamAccumulator {
    private struct PartialCall {
        var id: String
        var name: String
        var arguments: String = ""
    }

    private var calls: [Int: PartialCall] = [:]
    public private(set) var isDone = false

    public init() {}

    /// Ingère un événement ; retourne le texte assistant s'il y en a.
    public mutating func ingest(json: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        switch type {
        case "content_block_start":
            if let index = object["index"] as? Int,
               let block = object["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use",
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                calls[index] = PartialCall(id: id, name: name)
            }
            return nil
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return nil }
            switch delta["type"] as? String {
            case "text_delta":
                return delta["text"] as? String
            case "input_json_delta":
                if let index = object["index"] as? Int,
                   let fragment = delta["partial_json"] as? String {
                    calls[index]?.arguments += fragment
                }
                return nil
            default:
                return nil
            }
        case "message_stop":
            isDone = true
            return nil
        default:
            return nil
        }
    }

    public func finalizedToolCalls() -> [LLMToolCall] {
        calls.sorted { $0.key < $1.key }.map { _, call in
            LLMToolCall(id: call.id, name: call.name,
                        argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        }
    }
}
