import Foundation

/// TIDAL developer API client (openapi.tidal.com v2, JSON:API): catalogue
/// search with an app-level token. No user sign-in is involved. Playback is
/// handed to the TIDAL app.
///
/// Shapes follow TIDAL's published OpenAPI spec (1.10.x). The spec leaves two
/// things open, which this client handles defensively: track details may or
/// may not arrive with the search itself, and array filters are sent
/// comma-separated.
public final class TidalAPI: @unchecked Sendable {
    static let base = "https://openapi.tidal.com/v2"

    private let secrets: SecretStore
    private let http: HTTPTransport
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private let lock = NSLock()

    public init(secrets: SecretStore, http: HTTPTransport = URLSessionTransport()) {
        self.secrets = secrets
        self.http = http
    }

    public var clientID: String? { secrets.secret("tidal.clientID") }
    public var isConfigured: Bool {
        !(secrets.secret("tidal.clientID") ?? "").isEmpty && !(secrets.secret("tidal.clientSecret") ?? "").isEmpty
    }

    public func configure(clientID: String?, clientSecret: String?) {
        secrets.setSecret("tidal.clientID", clientID?.trimmingCharacters(in: .whitespacesAndNewlines))
        secrets.setSecret("tidal.clientSecret", clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines))
        lock.withLock {
            accessToken = nil
            accessExpiry = .distantPast
        }
    }

    /// Fetches a token, which proves the client id and secret work.
    @discardableResult
    public func validToken() async throws -> String {
        let cached = lock.withLock { accessExpiry > Date() ? accessToken : nil }
        if let cached { return cached }
        guard isConfigured, let id = secrets.secret("tidal.clientID"), let secret = secrets.secret("tidal.clientSecret") else {
            throw ServiceError("TIDAL is not set up. The user can add a TIDAL client ID and secret in Crate's Settings, under Services.")
        }
        var request = URLRequest(url: URL(string: "https://auth.tidal.com/v1/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Form.encode([("grant_type", "client_credentials")])
        let (data, response) = try await http.send(request)
        let body = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard response.statusCode == 200, let token = body["access_token"]?.stringValue else {
            let detail = body["error_description"]?.stringValue ?? body["error"]?.stringValue ?? "HTTP \(response.statusCode)"
            throw ServiceError("TIDAL did not accept the client ID and secret: \(detail).")
        }
        let expiry = Date().addingTimeInterval((body["expires_in"]?.doubleValue ?? 3600) - 60)
        lock.withLock {
            accessToken = token
            accessExpiry = expiry
        }
        return token
    }

    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> JSON {
        let token = try await validToken()
        var components = URLComponents(string: Self.base + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        let body = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 { throw ServiceError("TIDAL is rate-limiting requests. Wait a minute and try again.") }
            let detail = body["errors"]?.arrayValue?.first?["detail"]?.stringValue ?? "HTTP \(response.statusCode)"
            throw ServiceError("TIDAL request failed: \(detail).")
        }
        return body
    }

    public func search(_ query: String, limit: Int = 20, countryCode: String? = nil) async throws -> [StreamingTrack] {
        let country = countryCode ?? Locale.current.region?.identifier ?? "US"
        let found = try await get("/searchResults", [
            URLQueryItem(name: "filter[query]", value: String(query.prefix(256))),
            URLQueryItem(name: "countryCode", value: country),
            URLQueryItem(name: "include", value: "tracks"),
        ])
        // Details are fetched 20 at a time: the documented maximum for filter[id].
        let ids = Array(Self.trackIDs(inSearch: found).prefix(max(1, min(20, limit))))
        guard !ids.isEmpty else { return [] }
        let details = try await get("/tracks", [
            URLQueryItem(name: "countryCode", value: country),
            URLQueryItem(name: "filter[id]", value: ids.joined(separator: ",")),
            URLQueryItem(name: "include", value: "artists,albums"),
        ])
        return Self.parseTracks(details, order: ids)
    }

    /// Track ids from a /searchResults response, in ranked order.
    static func trackIDs(inSearch body: JSON) -> [String] {
        // `data` is documented as an array of searchResults; accept a single object too.
        let results = body["data"]?.arrayValue ?? [body["data"] ?? .null]
        var ids: [String] = []
        for result in results {
            for item in result["relationships"]?["tracks"]?["data"]?.arrayValue ?? [] where item["type"]?.stringValue == "tracks" {
                if let id = item["id"]?.stringValue, !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }

    /// Builds tracks from a /tracks response with artists and albums included.
    static func parseTracks(_ body: JSON, order: [String]) -> [StreamingTrack] {
        var artistNames: [String: String] = [:], albumTitles: [String: String] = [:]
        for item in body["included"]?.arrayValue ?? [] {
            guard let id = item["id"]?.stringValue else { continue }
            switch item["type"]?.stringValue {
            case "artists": artistNames[id] = item["attributes"]?["name"]?.stringValue
            case "albums": albumTitles[id] = item["attributes"]?["title"]?.stringValue
            default: break
            }
        }
        var byID: [String: StreamingTrack] = [:]
        for item in body["data"]?.arrayValue ?? [] where item["type"]?.stringValue == "tracks" {
            guard let id = item["id"]?.stringValue, let attributes = item["attributes"],
                  var title = attributes["title"]?.stringValue
            else { continue }
            if let version = attributes["version"]?.stringValue, !version.isEmpty { title += " (\(version))" }
            let artists = (item["relationships"]?["artists"]?["data"]?.arrayValue ?? [])
                .compactMap { $0["id"]?.stringValue }.compactMap { artistNames[$0] }
            let album = (item["relationships"]?["albums"]?["data"]?.arrayValue ?? [])
                .compactMap { $0["id"]?.stringValue }.compactMap { albumTitles[$0] }.first
            let bpm = attributes["bpm"]?.doubleValue.flatMap { $0 >= 30 && $0 <= 300 ? $0 : nil }
            byID[id] = StreamingTrack(
                source: .tidal, uri: "tidal:track:\(id)", title: title, artist: artists.joined(separator: ", "),
                album: album ?? "", duration: attributes["duration"]?.stringValue.flatMap(ISODuration.seconds) ?? 0,
                bpm: bpm, key: key(note: attributes["key"]?.stringValue, scale: attributes["keyScale"]?.stringValue))
        }
        return order.compactMap { byID[$0] }
    }

    /// TIDAL's key ("FSharp", "Eb") and scale ("MINOR") as text CamelotKey can read.
    /// Modal scales other than plain major and minor are left out rather than guessed.
    static func key(note: String?, scale: String?) -> String? {
        guard let note, note != "UNKNOWN", let scale else { return nil }
        let name = note.replacingOccurrences(of: "Sharp", with: "#")
        switch scale {
        case "MAJOR": return name
        case "MINOR", "AEOLIAN": return name + "m"
        default: return nil
        }
    }
}

public enum ServiceTools {
    public static func register(
        into registry: ToolRegistry, context: LibraryToolContext, spotify: SpotifyAPI, tidal: TidalAPI
    ) {
        @Sendable func results(_ tracks: [StreamingTrack]) -> JSON {
            context.catalog.remember(tracks)
            return .array(tracks.map { track in
                var object: [String: JSON] = [
                    "uri": .string(track.uri), "title": .string(track.title), "artist": .string(track.artist),
                    "duration": .string(TrackFormat.duration(track.duration)),
                ]
                if !track.album.isEmpty { object["album"] = .string(track.album) }
                if let bpm = track.bpm { object["bpm"] = .number((bpm * 10).rounded() / 10) }
                if let key = track.key.flatMap(CamelotKey.init(parsing:)) { object["key"] = .string(key.description) }
                if (try? context.store.track(uri: track.uri)) != nil { object["in_library"] = true }
                return .object(object)
            })
        }
        let properties: [String: JSON] = [
            "query": Schema.string("What to search for: artist, title, or both."),
            "limit": Schema.integer("Maximum results. Default 10, maximum 20."),
        ]

        registry.register(AgentTool(
            name: "spotify_search",
            description: """
                Search Spotify's catalogue for tracks. Each result has a `uri`; pass it to crate_add_tracks, \
                crate_create, player_play or player_queue_add to use the track. Spotify gives no BPM or key.
                """,
            properties: properties, required: ["query"], readOnly: true
        ) { args in
            let limit = max(1, min(20, try args.optionalInt("limit") ?? 10))
            return results(try await spotify.search(try args.requiredString("query"), limit: limit))
        })

        registry.register(AgentTool(
            name: "tidal_search",
            description: """
                Search TIDAL's catalogue for tracks. Each result has a `uri`; pass it to crate_add_tracks, \
                crate_create, player_play or player_queue_add to use the track. Results include BPM and key when \
                TIDAL has them.
                """,
            properties: properties, required: ["query"], readOnly: true
        ) { args in
            let limit = max(1, min(20, try args.optionalInt("limit") ?? 10))
            return results(try await tidal.search(try args.requiredString("query"), limit: limit))
        })
    }
}
