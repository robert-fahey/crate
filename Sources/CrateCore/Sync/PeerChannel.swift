import Foundation

/// One message between two Macs.
public enum SyncMessage: Sendable {
    /// First thing each side says. `purpose` is "sync" for the standing connection that keeps two
    /// libraries in line, or "file" for a short one that fetches a single file. `port` is where
    /// the sender listens, so the other side can call back.
    case hello(DeviceInfo, version: Int, purpose: String, port: Int)
    case manifest(SyncManifest)
    case wants(SyncWants)
    case records(tracks: [TrackRecord], crates: [CrateRecord], analysis: [AnalysisRecord])
    case fileRequest(key: String, offset: Int64)
    case fileStart(size: Int64, name: String)
    case fileData(Data)
    case fileEnd
    case failure(String)
}

/// A two-way line to another Mac. The app's is a network connection; tests join two in memory.
public protocol PeerChannel: AnyObject, Sendable {
    func send(_ message: SyncMessage) async throws
    func receive() async throws -> SyncMessage
    func close()
}

public enum ChannelError: Error, LocalizedError {
    case closed
    case malformed
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .closed: return "The connection to the other Mac closed."
        case .malformed: return "The other Mac sent something Crate could not read. Both Macs need the same version of Crate."
        case .refused(let reason): return reason
        }
    }
}

// MARK: - On the wire

/// A message as bytes: a kind, and a body that is JSON for everything except file data, which goes as it is.
extension SyncMessage {
    private struct Hello: Codable { var device: DeviceInfo; var version: Int; var purpose: String; var port: Int }
    private struct Records: Codable { var tracks: [TrackRecord]; var crates: [CrateRecord]; var analysis: [AnalysisRecord] }
    private struct FileRequest: Codable { var key: String; var offset: Int64 }
    private struct FileStart: Codable { var size: Int64; var name: String }

    func encoded() throws -> (kind: UInt8, body: Data) {
        let json = JSONEncoder()
        switch self {
        case .hello(let device, let version, let purpose, let port):
            return (1, try json.encode(Hello(device: device, version: version, purpose: purpose, port: port)))
        case .manifest(let manifest): return (2, try json.encode(manifest))
        case .wants(let wants): return (3, try json.encode(wants))
        case .records(let tracks, let crates, let analysis):
            return (4, try json.encode(Records(tracks: tracks, crates: crates, analysis: analysis)))
        case .fileRequest(let key, let offset): return (5, try json.encode(FileRequest(key: key, offset: offset)))
        case .fileStart(let size, let name): return (6, try json.encode(FileStart(size: size, name: name)))
        case .fileData(let data): return (7, data)
        case .fileEnd: return (8, Data())
        case .failure(let reason): return (9, Data(reason.utf8))
        }
    }

    init(kind: UInt8, body: Data) throws {
        let json = JSONDecoder()
        do {
            switch kind {
            case 1:
                let hello = try json.decode(Hello.self, from: body)
                self = .hello(hello.device, version: hello.version, purpose: hello.purpose, port: hello.port)
            case 2: self = .manifest(try json.decode(SyncManifest.self, from: body))
            case 3: self = .wants(try json.decode(SyncWants.self, from: body))
            case 4:
                let records = try json.decode(Records.self, from: body)
                self = .records(tracks: records.tracks, crates: records.crates, analysis: records.analysis)
            case 5:
                let request = try json.decode(FileRequest.self, from: body)
                self = .fileRequest(key: request.key, offset: request.offset)
            case 6:
                let start = try json.decode(FileStart.self, from: body)
                self = .fileStart(size: start.size, name: start.name)
            case 7: self = .fileData(body)
            case 8: self = .fileEnd
            case 9: self = .failure(String(decoding: body, as: UTF8.self))
            default: throw ChannelError.malformed
            }
        } catch is DecodingError {
            throw ChannelError.malformed
        }
    }
}

// MARK: - In memory, for tests

/// One end of a pair of channels joined in memory. Messages are turned into bytes and back on the way, as on a network.
public final class MemoryChannel: PeerChannel, @unchecked Sendable {
    private let incoming: AsyncThrowingStream<(UInt8, Data), Error>
    private var iterator: AsyncThrowingStream<(UInt8, Data), Error>.AsyncIterator
    private let outgoing: AsyncThrowingStream<(UInt8, Data), Error>.Continuation
    private let own: AsyncThrowingStream<(UInt8, Data), Error>.Continuation

    private init(
        incoming: AsyncThrowingStream<(UInt8, Data), Error>, own: AsyncThrowingStream<(UInt8, Data), Error>.Continuation,
        outgoing: AsyncThrowingStream<(UInt8, Data), Error>.Continuation
    ) {
        self.incoming = incoming
        iterator = incoming.makeAsyncIterator()
        self.own = own
        self.outgoing = outgoing
    }

    public static func pair() -> (MemoryChannel, MemoryChannel) {
        let (first, firstContinuation) = AsyncThrowingStream<(UInt8, Data), Error>.makeStream()
        let (second, secondContinuation) = AsyncThrowingStream<(UInt8, Data), Error>.makeStream()
        return (
            MemoryChannel(incoming: first, own: firstContinuation, outgoing: secondContinuation),
            MemoryChannel(incoming: second, own: secondContinuation, outgoing: firstContinuation)
        )
    }

    public func send(_ message: SyncMessage) async throws {
        let frame = try message.encoded()
        if case .terminated = outgoing.yield((frame.kind, frame.body)) { throw ChannelError.closed }
    }

    /// Only ever called from one task at a time (a session's loop).
    public func receive() async throws -> SyncMessage {
        guard let frame = try await iterator.next() else { throw ChannelError.closed }
        return try SyncMessage(kind: frame.0, body: frame.1)
    }

    public func close() {
        outgoing.finish()
        own.finish()
    }
}
