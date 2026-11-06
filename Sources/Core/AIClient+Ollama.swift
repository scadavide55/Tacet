import Foundation

// MARK: - Ollama's own chat API

/// Ollama's OpenAI-compatible endpoint has no way to set the context, so a model runs with Ollama's default of 4,096
/// tokens and drops the start of anything longer: the instructions go first. Ollama's own /api/chat takes the context
/// with each request (options.num_ctx), streams one JSON object per line and takes tool calls with their arguments as
/// objects. The chat keeps its transcript in the OpenAI shape; it's converted here, on the way out and back.
extension AIClient {
    /// The OpenAI-shaped transcript as /api/chat wants it: text content, pictures as base64 in "images", tool calls
    /// with object arguments, and tool results named by tool instead of by call id.
    static func ollamaMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var names: [String: String] = [:]
        return messages.map { m in
            var out: [String: Any] = ["role": m["role"] as? String ?? "user"]
            if let s = m["content"] as? String {
                out["content"] = s
            } else if let parts = m["content"] as? [[String: Any]] {
                var text: [String] = []
                var images: [String] = []
                for p in parts {
                    if let t = p["text"] as? String { text.append(t) }
                    if let u = (p["image_url"] as? [String: Any])?["url"] as? String, let comma = u.range(of: "base64,") {
                        images.append(String(u[comma.upperBound...]))
                    }
                }
                out["content"] = text.joined(separator: "\n")
                if !images.isEmpty { out["images"] = images }
            } else {
                out["content"] = ""
            }
            if let calls = m["tool_calls"] as? [[String: Any]] {
                out["tool_calls"] = calls.map { c -> [String: Any] in
                    let f = c["function"] as? [String: Any] ?? [:]
                    let name = f["name"] as? String ?? ""
                    if let id = c["id"] as? String { names[id] = name }
                    let args = (f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? [String: Any]()
                    return ["function": ["name": name, "arguments": args]]
                }
            }
            if m["role"] as? String == "tool", let id = m["tool_call_id"] as? String, let name = names[id] {
                out["tool_name"] = name
            }
            return out
        }
    }

    /// Reads /api/chat's stream: one JSON object per line, text in message.content, tool calls whole in
    /// message.tool_calls. What Ollama calls thinking isn't shown, as with every provider. The reply comes back in the
    /// OpenAI shape, like the rest of the transcript.
    @MainActor
    static func readOllama(_ lines: AsyncThrowingStream<String, Error>, onText: (String) -> Void) async throws -> Result {
        var text = ""
        var calls: [(name: String, args: [String: Any])] = []
        var reason: String?
        for try await line in lines {
            try Task.checkCancellation()
            guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let err = e["error"] as? String { throw Failure.http(500, err) }
            if let m = e["message"] as? [String: Any] {
                if let t = m["content"] as? String, !t.isEmpty {
                    text += t
                    onText(t)
                }
                for c in m["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let f = c["function"] as? [String: Any], let name = f["name"] as? String, !name.isEmpty else { continue }
                    let args = (f["arguments"] as? [String: Any])
                        ?? (f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                        ?? [:]
                    calls.append((name, args))
                }
            }
            if e["done"] as? Bool == true { reason = e["done_reason"] as? String ?? "stop"; break }
        }
        var message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
        if reason == "length" { return Result(assistantMessage: message, toolCalls: [], stopReason: "length") }
        let stamp = UUID().uuidString.prefix(8)
        let ids = calls.indices.map { "call_\(stamp)_\($0)" }
        if !calls.isEmpty {
            message["tool_calls"] = calls.enumerated().map { n, c in
                let args = (try? JSONSerialization.data(withJSONObject: c.args)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return ["id": ids[n], "type": "function", "function": ["name": c.name, "arguments": args]] as [String: Any]
            }
        }
        let toolCalls = calls.enumerated().map { n, c in ToolCall(id: ids[n], name: c.name, arguments: c.args) }
        return Result(assistantMessage: message, toolCalls: toolCalls, stopReason: calls.isEmpty ? reason : "tool_calls")
    }

    /// The lines of a response body.
    static func lines(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let t = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in t.cancel() }
        }
    }
}
