import CryptoKit
import Foundation

/// Copying one music file from another Mac.
public enum FileTransfer {
    static let chunk = 256 * 1024

    public enum TransferError: Error, LocalizedError {
        case notHere(String)
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .notHere(let reason): return reason
            case .damaged(let name): return "\"\(name)\" did not arrive intact, so the copy was thrown away. Try again."
            }
        }
    }

    /// The sending side: streams the file from `offset` to the end.
    static func serve(key: String, offset: Int64, store: LibraryStore, channel: PeerChannel) async throws {
        guard let track = try store.track(contentID: key), let path = Volumes.resolvedPath(for: track),
              let handle = FileHandle(forReadingAtPath: path), let size = try? handle.seekToEnd()
        else {
            try await channel.send(.failure("That file is not on \(store.deviceName) right now (its drive may be unplugged)."))
            return
        }
        defer { try? handle.close() }
        try await channel.send(.fileStart(size: Int64(size), name: (path as NSString).lastPathComponent))
        try handle.seek(toOffset: UInt64(max(0, min(offset, Int64(size)))))
        while let data = try handle.read(upToCount: chunk), !data.isEmpty {
            try await channel.send(.fileData(data))
        }
        try await channel.send(.fileEnd)
    }

    /// The receiving side. Asks for the file over a channel that has already exchanged hellos,
    /// picks up where an earlier, interrupted attempt stopped, checks what arrived is the file
    /// that was asked for, and files it under the artist's name.
    /// - Returns: where the file now is.
    public static func fetch(
        key: String, artist: String, over channel: PeerChannel, into folder: URL, progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let files = FileManager.default
        let incoming = folder.appendingPathComponent(".incoming", isDirectory: true)
        try files.createDirectory(at: incoming, withIntermediateDirectories: true)
        let part = incoming.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".part")
        if !files.fileExists(atPath: part.path) { files.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        var written = Int64(try handle.seekToEnd())

        try await channel.send(.fileRequest(key: key, offset: written))
        var size: Int64 = 0
        var name = "track"
        receiving: while true {
            switch try await channel.receive() {
            case .fileStart(let total, let fileName):
                size = total
                name = fileName
                if written > total {
                    // What is on disk is not the start of this file: begin again.
                    try handle.truncate(atOffset: 0)
                    written = 0
                    throw TransferError.damaged(fileName)
                }
            case .fileData(let data):
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                if size > 0 { progress(min(1, Double(written) / Double(size))) }
            case .fileEnd:
                break receiving
            case .failure(let reason):
                throw TransferError.notHere(reason)
            default:
                throw ChannelError.malformed
            }
        }
        try handle.close()
        guard Fingerprint.of(path: part.path) == key else {
            try? files.removeItem(at: part)
            throw TransferError.damaged(name)
        }
        let home = folder.appendingPathComponent(safe(artist.isEmpty ? "Unknown Artist" : artist), isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        var destination = home.appendingPathComponent(safe(name))
        var number = 2
        while files.fileExists(atPath: destination.path) {
            let base = (safe(name) as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            destination = home.appendingPathComponent("\(base) \(number)" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        try files.moveItem(at: part, to: destination)
        return destination
    }

    /// A name that is safe as one path component.
    static func safe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
    }
}
