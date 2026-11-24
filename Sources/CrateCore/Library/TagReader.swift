import AVFoundation
import Foundation

public struct AudioTags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var bpm: Double?
    public var key: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, bpm: Double? = nil, key: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.bpm = bpm
        self.key = key
    }
}

/// Reads Vorbis comments from a FLAC file. AVFoundation plays FLAC but exposes
/// little of its metadata, and the tagged files in this library are FLAC.
public enum FLACTags {
    public static func read(path: String) -> AudioTags? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return read(from: handle)
    }

    static func read(from handle: FileHandle) -> AudioTags? {
        func bytes(_ count: Int) -> Data? {
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return data
        }
        guard var magic = bytes(4) else { return nil }
        // Some files carry an ID3v2 tag in front of the FLAC stream.
        if magic.prefix(3) == Data("ID3".utf8) {
            guard let rest = bytes(6) else { return nil }
            let size = rest.suffix(4).reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
            guard (try? handle.seek(toOffset: UInt64(10 + size))) != nil, let next = bytes(4) else { return nil }
            magic = next
        }
        guard magic == Data("fLaC".utf8) else { return nil }

        while true {
            guard let header = bytes(4) else { return nil }
            let isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            if type == 4 {
                guard let block = bytes(length) else { return nil }
                return parseVorbisComment(block)
            }
            guard let offset = try? handle.offset(), (try? handle.seek(toOffset: offset + UInt64(length))) != nil else {
                return nil
            }
            if isLast { return AudioTags() }
        }
    }

    static func parseVorbisComment(_ block: Data) -> AudioTags {
        var tags = AudioTags()
        var cursor = block.startIndex
        func readLength() -> Int? {
            guard block.endIndex - cursor >= 4 else { return nil }
            let value = block[cursor..<(cursor + 4)].reversed().reduce(0) { ($0 << 8) | Int($1) }
            cursor += 4
            return value
        }
        guard let vendorLength = readLength(), block.endIndex - cursor >= vendorLength else { return tags }
        cursor += vendorLength
        guard let count = readLength() else { return tags }
        for _ in 0..<count {
            guard let length = readLength(), block.endIndex - cursor >= length else { break }
            let entry = String(decoding: block[cursor..<(cursor + length)], as: UTF8.self)
            cursor += length
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = entry[..<equals].uppercased()
            let value = String(entry[entry.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch name {
            case "TITLE": tags.title = tags.title ?? value
            // Several ARTIST entries mean several artists.
            case "ARTIST": tags.artist = tags.artist.map { "\($0), \(value)" } ?? value
            case "ALBUM": tags.album = tags.album ?? value
            case "BPM", "TEMPO": tags.bpm = tags.bpm ?? TagReader.parseBPM(value)
            case "INITIALKEY", "INITIAL KEY", "KEY": tags.key = tags.key ?? value
            default: break
            }
        }
        return tags
    }
}

public enum TagReader {
    static func parseBPM(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value >= 30, value <= 300 else {
            return nil
        }
        return value
    }

    /// Duration in seconds, or nil if this Mac cannot decode the file.
    public static func duration(path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    public static func read(path: String) async -> AudioTags {
        if path.lowercased().hasSuffix(".flac"), let tags = FLACTags.read(path: path) { return tags }

        var tags = AudioTags()
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let items = try? await asset.load(.metadata) else { return tags }
        for item in items {
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            let common = item.commonKey
            let isBPM = identifier.hasSuffix("tbpm") || identifier.hasSuffix("tmpo") || identifier.hasSuffix("bpm")
            let isKey = identifier.hasSuffix("tkey") || identifier.hasSuffix("initialkey")
            guard common == .commonKeyTitle || common == .commonKeyArtist || common == .commonKeyAlbumName
                || isBPM || isKey
            else { continue }

            var text = (try? await item.load(.stringValue))?.nonEmpty
            if text == nil, isBPM, let number = try? await item.load(.numberValue) { text = number.stringValue }
            guard let text else { continue }

            if common == .commonKeyTitle {
                if tags.title == nil { tags.title = text }
            } else if common == .commonKeyArtist {
                if tags.artist == nil { tags.artist = text }
            } else if common == .commonKeyAlbumName {
                if tags.album == nil { tags.album = text }
            } else if isBPM {
                if tags.bpm == nil { tags.bpm = parseBPM(text) }
            } else if isKey {
                if tags.key == nil { tags.key = text }
            }
        }
        return tags
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
