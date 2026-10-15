import Foundation
import FoundationModels
import Security

enum ClaudeError: LocalizedError {
    case http(Int, String)
    case refusal
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .http(401, _): "API-Key ungültig"
        case .http(let status, let message): "Claude-Fehler \(status): \(message)"
        case .refusal: "Claude hat die Anfrage abgelehnt"
        case .incomplete(let reason): "Claude-Antwort unvollständig (\(reason))"
        }
    }
}

/// Optional stage 4 with the user's own Anthropic API key. Claude Haiku 5.5 gets the same
/// instructions and examples as the local model and answers with `FormattedDictation` as JSON,
/// which then passes the same checks. Only the dictated text leaves the Mac, never audio. Every
/// failure throws; the pipeline then tries the local model.
///
/// No structured outputs (`output_config.format`): the constrained schema orders keys its own
/// way, and Claude then wrote the blocks before the greeting and chose empty lists — 4 to 12 of
/// 14 test dictations failed, versus 0 of 14 with the examples alone, which was also faster.
struct ClaudeFormatter: TextFormatting {
    let apiKey: String
    var name: String { "Claude Haiku 5.5" }

    static let model = "claude-haiku-5-5"
    static let timeout: Double = 8
    private static let api = URL(string: "https://api.anthropic.com/v1/")!

    /// Haiku 5.5 in $ per million tokens (prompts up to 100K); cache writes are the 5-minute kind.
    private static let price = (input: 0.10, cacheWrite: 0.125, cacheRead: 0.01, output: 0.50)
    // ponytail: fixed exchange rate, update by hand if the dollar moves a lot
    static let euroPerDollar = 0.86
    /// Colin's working time in the settings is priced at this.
    static let euroPerHour = 19.0
    /// Euro cents spent on Claude so far, in the defaults; the statistics reset leaves it.
    static let costKey = "claudeCost"

    func format(_ text: String, terms: [String]) async throws -> String {
        var request = URLRequest(url: Self.api.appending(path: "messages"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: text, terms: terms))
        let data = try await withTimeout(seconds: Self.timeout) { [apiKey] in try await Self.send(request, key: apiKey) }
        // Before the checks: an answer that fails them is billed all the same.
        let defaults = UserDefaults.standard
        defaults.set(defaults.double(forKey: Self.costKey) + Self.cents(data), forKey: Self.costKey)
        return try Formatter.verified(Self.parse(data), for: text)
    }

    /// Free request that checks the key and opens the HTTPS connection the dictation then reuses.
    static func check(key: String) async throws {
        _ = try await send(URLRequest(url: api.appending(path: "models/\(model)")), key: key)
    }

    private static func send(_ request: URLRequest, key: String) async throws -> Data {
        var request = request
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message ?? ""
            throw ClaudeError.http(status, message)
        }
        return data
    }

    // MARK: - Pure helpers

    static func body(for text: String, terms: [String]) -> [String: Any] {
        var messages: [[String: Any]] = Formatter.examples.flatMap { example in
            [["role": "user", "content": Formatter.tagged(example.dictation)],
             ["role": "assistant", "content": example.formatted.generatedContent.jsonString]]
        }
        // Instructions and examples are the same for every dictation: cache them (5 minutes).
        messages[messages.count - 1]["content"] = [
            ["type": "text", "text": messages[messages.count - 1]["content"]!, "cache_control": ["type": "ephemeral"]]
        ]
        messages.append(["role": "user", "content": Formatter.tagged(text)])
        return [
            "model": model,
            "max_tokens": 4096,
            "system": Formatter.instructions(terms: terms, structured: true)
                + "\n\nAntworte ausschließlich mit einem JSON-Objekt im Format der Beispiele, ohne Codeblock und ohne weiteren Text.",
            "messages": messages,
            // Formatting needs no reasoning; off keeps it fast (allowed up to effort "high").
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
        ]
    }

    static func parse(_ data: Data) throws -> FormattedDictation {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        switch response.stopReason {
        case "end_turn": break
        case "refusal": throw ClaudeError.refusal
        default: throw ClaudeError.incomplete(response.stopReason ?? "unbekannt")
        }
        // Blocks are read by type: a response can start with an (empty) thinking block.
        guard let json = response.content.first(where: { $0.type == "text" })?.text else { throw FormatterError.empty }
        return try FormattedDictation(GeneratedContent(json: json))
    }

    /// What one response cost, in euro cents; 0 without a usage block.
    static func cents(_ data: Data) -> Double {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let usage = try? decoder.decode(Billed.self, from: data).usage else { return 0 }
        let dollars = (Double(usage.inputTokens) * price.input
            + Double(usage.cacheCreationInputTokens ?? 0) * price.cacheWrite
            + Double(usage.cacheReadInputTokens ?? 0) * price.cacheRead
            + Double(usage.outputTokens) * price.output) / 1_000_000
        return dollars * euroPerDollar * 100
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stopReason: String?
    }

    private struct Billed: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
        }
        let usage: Usage
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}

/// The Anthropic key lives in the login keychain, never in a file or the defaults.
enum APIKeyStore {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.colinportisch.ColinWhisper",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func load() -> String? {
        var query = item
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        delete()
        var query = item
        query[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(item as CFDictionary)
    }
}
