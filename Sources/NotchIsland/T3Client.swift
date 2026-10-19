import Foundation
import Security

enum T3ClientError: LocalizedError {
    case http(status: Int)
    case server(tag: String, message: String)
    case timedOut(method: String)
    case badReply(String)
    case command(String)

    /// The token is missing, expired, revoked, or lacks a scope; minting a new one may fix it.
    var isUnauthorized: Bool {
        switch self {
        case .http(let status): return status == 401
        case .server(let tag, _): return tag == "EnvironmentAuthorizationError"
        case .timedOut, .badReply, .command: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .http(401): return "T3 rejected the token (HTTP 401)"
        case .http(426): return "T3 wants a newer orchestration protocol (HTTP 426)"
        case .http(let status): return "T3 returned HTTP \(status)"
        case .server(let tag, let message): return "\(tag): \(message)"
        case .timedOut(let method): return "T3 did not answer \(method) in time"
        case .badReply(let detail): return "Unexpected reply from T3: \(detail)"
        case .command(let detail): return detail
        }
    }
}

/// Answers pending T3 Code requests over the server's Effect RPC WebSocket (`/ws`, JSON frames).
/// Each call opens its own socket, sends one `Request`, and waits for the matching `Exit`.
final class T3Client {
    static let decisions: Set<String> = ["accept", "acceptForSession", "acceptAlways", "decline", "cancel"]

    let baseURL: URL
    private let token: String
    private let session: URLSession
    private let timeout: TimeInterval = 20

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        // The server prefers a session cookie over the bearer token, so never send cookies.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func environmentID() async throws -> String {
        struct Descriptor: Decodable { let environmentId: String }
        var request = URLRequest(url: baseURL.appending(path: ".well-known/t3/environment"))
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw T3ClientError.http(status: status)
        }
        return try JSONDecoder().decode(Descriptor.self, from: data).environmentId
    }

    /// Answers a question. Keys are question ids; values are free text or `option.value ?? option.label`.
    func respond(threadID: String, requestID: String, answers: [String: String]) async throws {
        try await dispatch(["type": "runtime-request.respond", "threadId": threadID, "requestId": requestID, "answers": answers])
    }

    /// Resolves an approval with accept, acceptForSession, acceptAlways, decline, or cancel.
    func decide(threadID: String, requestID: String, decision: String) async throws {
        guard Self.decisions.contains(decision) else { throw T3ClientError.command("Unknown decision \(decision)") }
        try await dispatch(["type": "runtime-request.respond", "threadId": threadID, "requestId": requestID, "decision": decision])
    }

    private func dispatch(_ command: [String: Any]) async throws {
        var command = command
        command["commandId"] = UUID().uuidString.lowercased()
        try await call("orchestration.dispatchCommand", payload: command)
    }

    /// Sends one RPC and returns the success value of its `Exit`, or throws the server's error.
    @discardableResult
    func call(_ method: String, payload: [String: Any]) async throws -> Any {
        let task = session.webSocketTask(with: socketRequest())
        task.maximumMessageSize = 16 << 20
        let started = Date()
        let watchdog = Task { [timeout] in
            try await Task.sleep(for: .seconds(timeout))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            watchdog.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
        task.resume()
        do {
            let request: [String: Any] = ["_tag": "Request", "id": "1", "tag": method, "payload": payload, "headers": [Any]()]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            try await task.send(.string(text))
            while true {
                let reply = try Self.decode(try await task.receive())
                switch reply["_tag"] as? String {
                case "Exit" where reply["requestId"] as? String == "1":
                    return try Self.value(of: reply["exit"])
                case "Defect":
                    throw T3ClientError.server(tag: "Defect", message: Self.describe(reply["defect"]))
                default:
                    continue
                }
            }
        } catch let error as T3ClientError {
            throw error
        } catch {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
                throw T3ClientError.http(status: status)
            }
            if Date().timeIntervalSince(started) >= timeout { throw T3ClientError.timedOut(method: method) }
            throw error
        }
    }

    private func socketRequest() -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw T3ClientError.badReply("unknown frame type")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw T3ClientError.badReply(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return object
    }

    /// `exit` is `{_tag: "Success", value}` or `{_tag: "Failure", cause: [{_tag: "Fail", error} | {_tag: "Die", defect} | {_tag: "Interrupt"}]}`.
    private static func value(of exit: Any?) throws -> Any {
        guard let exit = exit as? [String: Any] else { throw T3ClientError.badReply("Exit without a result") }
        if exit["_tag"] as? String == "Success" { return exit["value"] ?? NSNull() }
        let reasons = exit["cause"] as? [[String: Any]] ?? []
        let reason = reasons.first { $0["_tag"] as? String == "Fail" } ?? reasons.first
        switch reason?["_tag"] as? String {
        case "Fail":
            let error = reason?["error"] as? [String: Any] ?? [:]
            throw T3ClientError.server(tag: error["_tag"] as? String ?? "Fail", message: error["message"] as? String ?? describe(error))
        case "Die":
            throw T3ClientError.server(tag: "Defect", message: describe(reason?["defect"]))
        default:
            throw T3ClientError.server(tag: "Interrupted", message: "T3 stopped the request")
        }
    }

    private static func describe(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any], let message = object["message"] as? String { return message }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return "unknown error" }
        return String(decoding: data.prefix(500), as: UTF8.self)
    }

    /// Runs a token-issuing command (local `t3` or `ssh host t3 ...`) and returns its trimmed stdout.
    static func issueToken(using command: [String]) async throws -> String {
        guard let executable = command.first else { throw T3ClientError.command("Empty token command") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = Array(command.dropFirst())
                let output = Pipe()
                let errors = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let token = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, !token.isEmpty, !token.contains(where: \.isWhitespace) {
                    continuation.resume(returning: token)
                } else {
                    let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: T3ClientError.command(
                        "Token command exited with \(process.terminationStatus): \(message.isEmpty ? "no token printed" : message)"
                    ))
                }
            }
        }
    }
}

/// Bearer tokens per T3 host, kept as generic passwords in the login keychain.
enum T3TokenStore {
    private static let service = "com.jmqcooper.NotchIsland.t3"

    static func token(for host: String) -> String? {
        var query = baseQuery(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for host: String) {
        let query = baseQuery(host)
        let data = Data(token.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Log.write("saving the T3 token for \(host) failed with status \(status)")
        }
    }

    private static func baseQuery(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: host]
    }
}
