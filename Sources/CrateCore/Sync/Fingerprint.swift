import CryptoKit
import Foundation

/// What makes a music file the same file on every Mac: its content, not where it sits.
///
/// The whole file is not read. Its size and a hash of its first and last megabyte
/// tell two tracks apart as surely as anyone needs, and cost the same two megabytes
/// of reading whether the file is a three-minute MP3 or an hour-long WAV on a slow
/// drive. Editing a file's tags changes it, and so makes it a different file.
public enum Fingerprint {
    static let edge = 1 << 20

    /// "c1:<size>:<32 hex digits>", or nil if the file cannot be read.
    public static func of(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        do {
            try handle.seek(toOffset: 0)
            hasher.update(data: try handle.read(upToCount: edge) ?? Data())
            if size > UInt64(edge) {
                try handle.seek(toOffset: size - UInt64(min(UInt64(edge), size - UInt64(edge))))
                hasher.update(data: try handle.readToEnd() ?? Data())
            }
        } catch {
            return nil
        }
        let digest = hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        return "c1:\(size):\(digest)"
    }

    /// The file size a fingerprint records.
    public static func size(of fingerprint: String) -> Int64? {
        let parts = fingerprint.split(separator: ":")
        return parts.count == 3 && parts[0] == "c1" ? Int64(parts[1]) : nil
    }
}
