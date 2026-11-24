import Foundation

/// Spotify Web API client: sign-in (authorization code with PKCE, so no client
/// secret is needed) and track search. Playback is not done here; the app
/// remote-controls Spotify.app.
public final class SpotifyAPI: @unchecked Sendable {
    public static let redirectPort: UInt16 = 8888
    public static let redirectURI = "http://127.0.0.1:8888/callback"

    private let secrets: SecretStore
    private let http: HTTPTransport
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private let lock = NSLock()

    public init(secrets: SecretStore, http: HTTPTransport = URLSessionTransport()) {
        self.secrets = secrets
        self.http = http
    }

    public var clientID: String? {
        get { secrets.secret("spotify.clientID") }
        set { secrets.setSecret("spotify.clientID", newValue?.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public var isConnected: Bool { secrets.secret("spotify.refreshToken") != nil }

    public func disconnect() {
        secrets.setSecret("spotify.refreshToken", nil)
        lock.withLock {
            accessToken = nil
            accessExpiry = .distantPast
        }
    }

    // MARK: Sign-in

    public struct SignIn: Sendable {
        public let url: URL
        public let verifier: String
        public let state: String
    }

    /// The page to open in the browser, and the values needed to finish afterwards.
    public func beginSignIn() throws -> SignIn {
        guard let clientID, !clientID.isEmpty else {
            throw ServiceError("Enter your Spotify app's Client ID first.")
        }
        let verifier = PKCE.verifier()
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
        ]
        return SignIn(url: components.url!, verifier: verifier, state: state)
    }

    /// Completes sign-in with the parameters the browser brought back.
    public func finishSignIn(_ signIn: SignIn, callback: [String: String]) async throws {
        if let error = callback["error"] {
            throw ServiceError(error == "access_denied" ? "Spotify sign-in was declined." : "Spotify sign-in failed: \(error).")
        }
        guard callback["state"] == signIn.state, let code = callback["code"] else {
            throw ServiceError("Spotify sign-in returned something unexpected. Try connecting again.")
        }
        let token = try await token(fields: [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", Self.redirectURI),
            ("client_id", clientID ?? ""), ("code_verifier", signIn.verifier),
        ])
        guard token["refresh_token"]?.stringValue != nil else {
            throw ServiceError("Spotify did not grant ongoing access. Try connecting again.")
        }
    }

    private func token(fields: [(String, String)]) async throws -> JSON {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Form.encode(fields)
        let (data, response) = try await http.send(request)
        let body = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard response.statusCode == 200, let access = body["access_token"]?.stringValue else {
            let detail = body["error_description"]?.stringValue ?? body["error"]?.stringValue ?? "HTTP \(response.statusCode)"
            if body["error"]?.stringValue == "invalid_grant" {
                secrets.setSecret("spotify.refreshToken", nil)
                throw ServiceError("Spotify access has expired or was revoked. Connect Spotify again in Settings.")
            }
            throw ServiceError("Spotify refused the sign-in: \(detail).")
        }
        // Spotify may rotate the refresh token; keep whichever is newest.
        if let refresh = body["refresh_token"]?.stringValue { secrets.setSecret("spotify.refreshToken", refresh) }
        let expiry = Date().addingTimeInterval((body["expires_in"]?.doubleValue ?? 3600) - 60)
        lock.withLock {
            accessToken = access
            accessExpiry = expiry
        }
        return body
    }

    private func validToken() async throws -> String {
        let cached = lock.withLock { accessExpiry > Date() ? accessToken : nil }
        if let cached { return cached }
        guard let refresh = secrets.secret("spotify.refreshToken") else {
            throw ServiceError("Spotify is not connected. The user can connect it in Crate's Settings, under Services.")
        }
        let body = try await token(fields: [
            ("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", clientID ?? ""),
        ])
        return body["access_token"]?.stringValue ?? ""
    }

    // MARK: Search

    public func search(_ query: String, limit: Int = 20) async throws -> [StreamingTrack] {
        let token = try await validToken()
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(max(1, min(50, limit)))),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 429 { throw ServiceError("Spotify is rate-limiting requests. Wait a minute and try again.") }
            let body = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
            throw ServiceError("Spotify search failed: \(body["error"]?["message"]?.stringValue ?? "HTTP \(response.statusCode)").")
        }
        return Self.parseSearch(try JSONDecoder().decode(JSON.self, from: data))
    }

    static func parseSearch(_ body: JSON) -> [StreamingTrack] {
        (body["tracks"]?["items"]?.arrayValue ?? []).compactMap { item in
            guard let uri = item["uri"]?.stringValue, uri.hasPrefix("spotify:track:"), let title = item["name"]?.stringValue
            else { return nil }
            let artists = (item["artists"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            return StreamingTrack(
                source: .spotify, uri: uri, title: title, artist: artists.joined(separator: ", "),
                album: item["album"]?["name"]?.stringValue ?? "",
                duration: (item["duration_ms"]?.doubleValue ?? 0) / 1000)
        }
    }
}
