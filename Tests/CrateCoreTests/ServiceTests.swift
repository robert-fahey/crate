import XCTest
@testable import CrateCore

/// Answers requests from a script and records what was asked.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Call { let url: String; let method: String; let headers: [String: String]; let body: String }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (URLRequest) -> (Int, String)

    init(_ respond: @escaping @Sendable (URLRequest) -> (Int, String)) { self.respond = respond }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(Call(
            url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:], body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
        lock.unlock()
        let (status, body) = respond(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class SpotifyTests: XCTestCase {
    private let searchBody = """
        {"tracks":{"items":[
          {"uri":"spotify:track:abc","name":"Hit and Run","duration_ms":421000,
           "artists":[{"name":"Loleatta Holloway"},{"name":"Walter Gibbons"}],"album":{"name":"Loleatta"}},
          {"uri":"spotify:episode:nope","name":"A podcast"},
          {"uri":"spotify:track:def","name":"Paradise","duration_ms":310500,"artists":[{"name":"Change"}],"album":{}}
        ]}}
        """

    func testPKCEChallengeMatchesTheSpecExample() {
        // RFC 7636, appendix B.
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.verifier().count, 64)
        XCTAssertNotEqual(PKCE.verifier(), PKCE.verifier())
    }

    func testSignInThenSearchUsesAndCachesTheToken() async throws {
        let transport = StubTransport { request in
            if request.url!.host == "accounts.spotify.com" {
                return (200, #"{"access_token":"AT1","refresh_token":"RT1","expires_in":3600}"#)
            }
            return (200, self.searchBody)
        }
        let secrets = MemorySecretStore()
        let api = SpotifyAPI(secrets: secrets, http: transport)
        XCTAssertThrowsError(try api.beginSignIn(), "a client ID is needed first")
        api.clientID = " client-123 \n"
        XCTAssertFalse(api.isConnected)

        let signIn = try api.beginSignIn()
        let query = LoopbackCallback.queryParameters("/?" + (signIn.url.query ?? ""))
        XCTAssertEqual(query["client_id"], "client-123")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:8888/callback")
        XCTAssertEqual(query["code_challenge"], PKCE.challenge(for: signIn.verifier))
        XCTAssertNil(query["scope"], "search needs no access to the user's account")

        try await api.finishSignIn(signIn, callback: ["code": "the-code", "state": signIn.state])
        XCTAssertTrue(api.isConnected)
        XCTAssertEqual(secrets.secret("spotify.refreshToken"), "RT1")
        XCTAssertTrue(transport.calls[0].body.contains("code=the-code"))
        XCTAssertTrue(transport.calls[0].body.contains("code_verifier=\(signIn.verifier)"))

        let tracks = try await api.search("loleatta & co", limit: 5)
        XCTAssertEqual(tracks.map(\.uri), ["spotify:track:abc", "spotify:track:def"])
        XCTAssertEqual(tracks[0].artist, "Loleatta Holloway, Walter Gibbons")
        XCTAssertEqual(tracks[0].duration, 421)
        XCTAssertEqual(tracks[1].album, "")
        let search = try XCTUnwrap(transport.calls.last)
        XCTAssertEqual(search.headers["Authorization"], "Bearer AT1")
        XCTAssertTrue(search.url.contains("q=loleatta%20%26%20co"), search.url)

        _ = try await api.search("again")
        XCTAssertEqual(transport.calls.filter { $0.url.contains("api/token") }.count, 1, "the access token is reused")
    }

    func testAMismatchedStateOrADeclinedSignInIsRejected() async throws {
        let api = SpotifyAPI(secrets: MemorySecretStore(["spotify.clientID": "c"]), http: StubTransport { _ in (500, "") })
        let signIn = try api.beginSignIn()
        do {
            try await api.finishSignIn(signIn, callback: ["code": "x", "state": "someone-else"])
            XCTFail("expected an error")
        } catch {}
        do {
            try await api.finishSignIn(signIn, callback: ["error": "access_denied", "state": signIn.state])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Spotify sign-in was declined.")
        }
        XCTAssertFalse(api.isConnected)
    }

    func testSearchWithoutAConnectionSaysHowToFixIt() async {
        let api = SpotifyAPI(secrets: MemorySecretStore(), http: StubTransport { _ in (200, "{}") })
        do {
            _ = try await api.search("x")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Settings"))
        }
    }

    func testARevokedRefreshTokenDisconnects() async {
        let secrets = MemorySecretStore(["spotify.clientID": "c", "spotify.refreshToken": "old"])
        let api = SpotifyAPI(secrets: secrets, http: StubTransport { _ in (400, #"{"error":"invalid_grant"}"#) })
        do {
            _ = try await api.search("x")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Connect Spotify again"))
        }
        XCTAssertFalse(api.isConnected)
    }
}

final class TidalTests: XCTestCase {
    private let searchBody = """
        {"data":[{"id":"q1","type":"searchResults","attributes":{"query":"change"},
          "relationships":{"tracks":{"data":[{"id":"222","type":"tracks"},{"id":"111","type":"tracks"},{"id":"9","type":"videos"}]}}}]}
        """
    private let tracksBody = """
        {"data":[
          {"id":"111","type":"tracks","attributes":{"title":"Paradise","duration":"PT5M10S","bpm":118.0,"key":"A","keyScale":"MINOR"},
           "relationships":{"artists":{"data":[{"id":"a1","type":"artists"}]},"albums":{"data":[{"id":"al1","type":"albums"}]}}},
          {"id":"222","type":"tracks","attributes":{"title":"Hit and Run","version":"12\\" Mix","duration":"PT1H2M3.5S","key":"FSharp","keyScale":"DORIAN","bpm":0},
           "relationships":{"artists":{"data":[{"id":"a2","type":"artists"},{"id":"a1","type":"artists"}]},"albums":{"data":[]}}}
        ],
        "included":[
          {"id":"a1","type":"artists","attributes":{"name":"Change"}},
          {"id":"a2","type":"artists","attributes":{"name":"Loleatta Holloway"}},
          {"id":"al1","type":"albums","attributes":{"title":"The Glow of Love"}}
        ]}
        """

    func testSearchFetchesATokenThenIdsThenDetailsInRankedOrder() async throws {
        let transport = StubTransport { request in
            let url = request.url!.absoluteString
            if url.contains("oauth2/token") { return (200, #"{"access_token":"T","expires_in":86400}"#) }
            if url.contains("/searchResults") { return (200, self.searchBody) }
            return (200, self.tracksBody)
        }
        let api = TidalAPI(secrets: MemorySecretStore(), http: transport)
        XCTAssertFalse(api.isConfigured)
        api.configure(clientID: "id", clientSecret: "secret")

        let tracks = try await api.search("change", countryCode: "GB")
        XCTAssertEqual(tracks.map(\.uri), ["tidal:track:222", "tidal:track:111"], "search rank is kept")
        XCTAssertEqual(tracks[0].title, "Hit and Run (12\" Mix)")
        XCTAssertEqual(tracks[0].artist, "Loleatta Holloway, Change")
        XCTAssertEqual(tracks[0].duration, 3723.5)
        XCTAssertNil(tracks[0].key, "a modal scale is not passed off as major or minor")
        XCTAssertNil(tracks[0].bpm, "a zero BPM means unknown")
        XCTAssertEqual(tracks[1].album, "The Glow of Love")
        XCTAssertEqual(tracks[1].bpm, 118)
        XCTAssertEqual(tracks[1].key.flatMap(CamelotKey.init(parsing:))?.description, "8A")

        let calls = transport.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].headers["Authorization"], "Basic " + Data("id:secret".utf8).base64EncodedString())
        XCTAssertEqual(calls[0].body, "grant_type=client_credentials")
        XCTAssertTrue(calls[1].url.contains("filter%5Bquery%5D=change") || calls[1].url.contains("filter[query]=change"), calls[1].url)
        XCTAssertTrue(calls[1].url.contains("countryCode=GB"))
        XCTAssertEqual(calls[1].headers["Accept"], "application/vnd.api+json")
        XCTAssertTrue(calls[2].url.contains("222,111") || calls[2].url.contains("222%2C111"), calls[2].url)
    }

    func testKeyNamesFromTidal() {
        XCTAssertEqual(TidalAPI.key(note: "FSharp", scale: "MINOR").flatMap(CamelotKey.init(parsing:))?.description, "11A")
        XCTAssertEqual(TidalAPI.key(note: "Eb", scale: "MAJOR").flatMap(CamelotKey.init(parsing:))?.description, "5B")
        XCTAssertEqual(TidalAPI.key(note: "A", scale: "AEOLIAN").flatMap(CamelotKey.init(parsing:))?.description, "8A")
        XCTAssertNil(TidalAPI.key(note: "UNKNOWN", scale: "MAJOR"))
        XCTAssertNil(TidalAPI.key(note: "C", scale: "UNKNOWN"))
    }

    func testBadCredentialsAndAnEmptySearch() async {
        var api = TidalAPI(secrets: MemorySecretStore(), http: StubTransport { _ in (401, #"{"error":"invalid_client"}"#) })
        api.configure(clientID: "id", clientSecret: "wrong")
        do {
            try await api.validToken()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid_client"))
        }

        api = TidalAPI(secrets: MemorySecretStore(), http: StubTransport { request in
            request.url!.absoluteString.contains("token") ? (200, #"{"access_token":"T"}"#) : (200, #"{"data":[]}"#)
        })
        api.configure(clientID: "id", clientSecret: "secret")
        let tracks = try? await api.search("zzzz")
        XCTAssertEqual(tracks, [])
    }

    func testISODurations() {
        XCTAssertEqual(ISODuration.seconds("PT2M58S"), 178)
        XCTAssertEqual(ISODuration.seconds("PT45S"), 45)
        XCTAssertEqual(ISODuration.seconds("PT1H"), 3600)
        XCTAssertNil(ISODuration.seconds("4:13"))
    }
}

final class ServiceToolTests: XCTestCase {
    func testSearchResultsCanGoStraightIntoACrate() async throws {
        let store = try LibraryStore(path: ":memory:")
        let context = LibraryToolContext(store: store, scanner: LibraryScanner(store: store), catalog: StreamingCatalog())
        let registry = ToolRegistry()
        LibraryTools.register(into: registry, context: context)
        let spotify = SpotifyAPI(
            secrets: MemorySecretStore(["spotify.clientID": "c", "spotify.refreshToken": "r"]),
            http: StubTransport { request in
                request.url!.host == "accounts.spotify.com"
                    ? (200, #"{"access_token":"AT","expires_in":3600}"#)
                    : (200, #"{"tracks":{"items":[{"uri":"spotify:track:abc","name":"Hit and Run","duration_ms":421000,"artists":[{"name":"Loleatta Holloway"}]}]}}"#)
            })
        let tidal = TidalAPI(secrets: MemorySecretStore(), http: StubTransport { _ in (500, "") })
        ServiceTools.register(into: registry, context: context, spotify: spotify, tidal: tidal)

        let found = await registry.call(name: "spotify_search", args: ["query": "hit and run"])
        XCTAssertTrue(found.ok, "\(found.content)")
        XCTAssertEqual(found.content.arrayValue?.first?["uri"], "spotify:track:abc")
        XCTAssertNil(found.content.arrayValue?.first?["in_library"])
        XCTAssertEqual(try store.stats().tracks, 0, "searching alone adds nothing to the library")

        let created = await registry.call(name: "crate_create", args: ["name": "Finds", "tracks": ["spotify:track:abc"]])
        XCTAssertTrue(created.ok, "\(created.content)")
        XCTAssertEqual(try store.stats().spotify, 1)

        let again = await registry.call(name: "spotify_search", args: ["query": "hit and run"])
        XCTAssertEqual(again.content.arrayValue?.first?["in_library"], true)

        let unconfigured = await registry.call(name: "tidal_search", args: ["query": "x"])
        XCTAssertFalse(unconfigured.ok)
        XCTAssertTrue(unconfigured.content.stringValue?.contains("Settings") == true)
    }

    func testTheSignInCallbackServerReturnsTheBrowsersParameters() async throws {
        let port: UInt16 = 18_888
        let server = try LoopbackCallback(port: port)
        async let received = server.wait(timeout: 10)
        try await Task.sleep(nanoseconds: 300_000_000)
        // A stray request first, as a browser makes for the favicon.
        _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        let (page, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=abc%20123&state=xyz")!)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("go back to Crate"))
        let parameters = try await received
        XCTAssertEqual(parameters, ["code": "abc 123", "state": "xyz"])
    }
}
