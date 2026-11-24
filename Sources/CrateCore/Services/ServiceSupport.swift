import CryptoKit
import Foundation
import Network

/// Where service credentials and tokens are kept. The app uses the Keychain.
public protocol SecretStore: Sendable {
    func secret(_ key: String) -> String?
    func setSecret(_ key: String, _ value: String?)
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init(_ values: [String: String] = [:]) { self.values = values }

    public func secret(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func setSecret(_ key: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

/// The network, behind a seam so the clients can be tested with canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError("The server sent an unreadable response.") }
        return (data, http)
    }
}

public struct ServiceError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

enum Form {
    /// application/x-www-form-urlencoded body.
    static func encode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

public enum PKCE {
    public static func verifier() -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in characters.randomElement()! })
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A one-shot web server on this Mac that receives the browser redirect at the
/// end of a sign-in and hands back its query parameters.
public final class LoopbackCallback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "crate.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false

    public init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServiceError("Could not listen on port \(port) for the sign-in to return. Is another sign-in still open?")
        }
    }

    /// Waits for the browser to arrive. Fails after `timeout` seconds.
    public func wait(timeout: TimeInterval = 180) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.listener.stateUpdateHandler = { state in
                    if case .failed(let error) = state { self.finish(.failure(ServiceError("Sign-in listener failed: \(error.localizedDescription)"))) }
                }
                self.listener.newConnectionHandler = { connection in self.serve(connection) }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(ServiceError("Sign-in timed out. Try connecting again.")))
                }
            }
        }
    }

    public func cancel() {
        queue.async { self.finish(.failure(ServiceError("Sign-in was cancelled."))) }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            // "GET /callback?code=…&state=… HTTP/1.1"
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let parameters = Self.queryParameters(target)
            let isCallback = parameters["code"] != nil || parameters["error"] != nil
            let message = isCallback
                ? "You can close this tab and go back to Crate."
                : "Nothing to see here."
            let body = "<!doctype html><meta charset=utf-8><title>Crate</title><body style=\"font: 16px -apple-system; padding: 3em\">\(message)</body>"
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
                // Browsers also ask for /favicon.ico; only the real redirect ends the wait.
                if isCallback { self.finish(.success(parameters)) }
            })
        }
    }

    static func queryParameters(_ target: String) -> [String: String] {
        guard let components = URLComponents(string: "http://127.0.0.1" + target) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
}

enum ISODuration {
    /// "PT4M13S" -> 253. Handles hours and fractional seconds.
    static func seconds(_ text: String) -> Double? {
        guard let match = text.wholeMatch(of: /PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?/) else { return nil }
        let hours = match.1.flatMap { Double($0) } ?? 0
        let minutes = match.2.flatMap { Double($0) } ?? 0
        let seconds = match.3.flatMap { Double($0) } ?? 0
        return hours * 3600 + minutes * 60 + seconds
    }
}
