import CryptoKit
import Foundation
import Network

/// A channel over the network: TCP, with TLS keyed by the sharing code, so only
/// copies of Crate that were given the code can connect, whatever network they are on.
public final class NetworkChannel: PeerChannel, @unchecked Sendable {
    /// Refuses frames larger than this: nothing Crate sends comes near it.
    static let largestFrame = 256 * 1024 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "crate.sync.connection")

    public init(connection: NWConnection) {
        self.connection = connection
    }

    /// The parameters both ends use. The key is derived from the sharing code; without the same code the handshake fails.
    public static func parameters(secret: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = Data(SHA256.hash(data: Data("crate sharing v1 \(secret)".utf8)))
        let identity = Data("crate".utf8)
        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(
                    tls.securityProtocolOptions, DispatchData(bytes: keyBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.noDelay = true
        tcp.connectionTimeout = 6
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// The other end's address, as far as the connection knows it.
    public var remoteHost: String? {
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .name(let name, _): return name
            case .ipv4(let address): return "\(address)".components(separatedBy: "%")[0]
            case .ipv6(let address): return "\(address)".components(separatedBy: "%")[0]
            @unknown default: return nil
            }
        }
        return nil
    }

    /// Starts the connection and waits until it is usable (the secure handshake included) or has failed.
    public func open(timeout: Double = 8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            @Sendable func finish(_ result: Result<Void, Error>) {
                if once.claim() { continuation.resume(with: result) }
            }
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error), .waiting(let error):
                    connection.cancel()
                    finish(.failure(error))
                case .cancelled: finish(.failure(ChannelError.closed))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if !once.isClaimed { connection.cancel() }
                finish(.failure(ChannelError.closed))
            }
        }
    }

    public func send(_ message: SyncMessage) async throws {
        let frame = try message.encoded()
        var data = Data(capacity: frame.body.count + 5)
        withUnsafeBytes(of: UInt32(frame.body.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(frame.kind)
        data.append(frame.body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func receive() async throws -> SyncMessage {
        let header = try await read(5)
        let length = Int(header.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= Self.largestFrame else { throw ChannelError.malformed }
        return try SyncMessage(kind: header[header.startIndex + 4], body: length > 0 ? try await read(length) : Data())
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ChannelError.closed)
                }
            }
        }
    }

    public func close() { connection.cancel() }
}

/// Lets exactly one of several racing callers through.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    var isClaimed: Bool { lock.withLock { claimed } }

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
