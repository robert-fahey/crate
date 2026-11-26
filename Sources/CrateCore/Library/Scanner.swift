import Foundation

/// Walks a library folder and records the full-length tracks in it.
public final class LibraryScanner {
    public struct Options: Sendable {
        /// Shorter files are treated as samples and left out.
        public var minimumDuration: Double = 60
        public init() {}
    }

    public struct Summary: Equatable, Sendable {
        public var found = 0
        public var added = 0
        public var updated = 0
        public var unchanged = 0
        public var tooShort = 0
        public var unreadable = 0

        public var description: String {
            var parts = ["\(added) added"]
            if updated > 0 { parts.append("\(updated) updated") }
            if unchanged > 0 { parts.append("\(unchanged) unchanged") }
            if tooShort > 0 { parts.append("\(tooShort) skipped as samples (under a minute)") }
            if unreadable > 0 { parts.append("\(unreadable) unreadable") }
            return parts.joined(separator: ", ")
        }
    }

    public static let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "wav", "wave", "aif", "aiff"]
    /// Nothing a minute long is smaller than this, so smaller files are skipped unopened.
    static let minimumBytes: Int64 = 400_000

    private let store: LibraryStore
    public var options = Options()

    public init(store: LibraryStore) {
        self.store = store
    }

    /// The audio files under a folder, skipping hidden files, packages and AppleDouble ("._x") files.
    public static func audioFiles(in folder: String) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  !url.lastPathComponent.hasPrefix("._")
            else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    public enum ScanError: Error, LocalizedError {
        case notAFolder(String)

        public var errorDescription: String? {
            switch self {
            case .notAFolder(let path):
                return "\(path) is not a folder I can read. If it is on an external drive, check the drive is connected."
            }
        }
    }

    /// Adds the folder to the library (if new) and scans it.
    @discardableResult
    public func scan(folder: String, progress: (@Sendable (Summary) -> Void)? = nil) async throws -> Summary {
        let folder = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ScanError.notAFolder(folder)
        }
        let folderLocation = Volumes.location(forPath: folder)
        try store.addFolder(path: folder, volumeUUID: folderLocation?.uuid, relativePath: folderLocation?.relativePath)

        var summary = Summary()
        for url in Self.audioFiles(in: folder) {
            try Task.checkCancellation()
            summary.found += 1
            switch try await take(url, root: folder, minimumDuration: options.minimumDuration) {
            case .unchanged: summary.unchanged += 1
            case .tooShort: summary.tooShort += 1
            case .unreadable: summary.unreadable += 1
            case .added: summary.added += 1
            case .updated: summary.updated += 1
            }

            if (summary.added + summary.updated) % 20 == 0, summary.added + summary.updated > 0 {
                NotificationCenter.default.post(name: .libraryDidChange, object: store)
                progress?(summary)
            }
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: store)
        progress?(summary)
        return summary
    }

    private enum Taken {
        case unchanged, tooShort, unreadable, added, updated
    }

    /// Records one file, unless it is already recorded as it stands.
    private func take(_ url: URL, root: String, minimumDuration: Double) async throws -> Taken {
        let path = url.path
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

        guard minimumDuration <= 0 || size >= Self.minimumBytes else { return .tooShort }
        let location = Volumes.location(forPath: path)
        let uri = ScannedFile.uri(path: path, volumeUUID: location?.uuid, relativePath: location?.relativePath)
        let known = try store.fileStamp(uri: uri)
        if let known, known.size == size, abs(known.modified - modified) < 1 { return .unchanged }
        guard let duration = TagReader.duration(path: path) else { return .unreadable }
        guard duration >= minimumDuration else { return .tooShort }

        let tags = await TagReader.read(path: path)
        let guess = FilenameParser.guess(path: path, root: root)
        let content = Fingerprint.of(path: path)
        try store.upsertLocal(
            ScannedFile(
                path: path, volumeUUID: location?.uuid, relativePath: location?.relativePath,
                title: tags.title ?? guess.title,
                // A tag wins; the filename fills in whatever the tags lack.
                artist: tags.artist ?? guess.artist,
                album: tags.album ?? guess.album,
                duration: duration, bpm: tags.bpm, key: tags.key,
                format: url.pathExtension.lowercased(), size: size, modified: modified, contentID: content),
            notify: false)
        return known == nil ? .added : .updated
    }

    /// Adds one file the user asked for by name, whatever its length, and returns its track.
    /// The folder it is in becomes a library folder unless a library folder already holds it, so
    /// that the file is looked after like the rest.
    /// - Parameter root: the folder to add, which the file is somewhere under.
    @discardableResult
    public func add(file: String, root: String) async throws -> Track? {
        let root = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL.path
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        let folders = try store.folders().map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        if !folders.contains(where: { path.hasPrefix($0) }) {
            let location = Volumes.location(forPath: root)
            try store.addFolder(path: root, volumeUUID: location?.uuid, relativePath: location?.relativePath)
        }
        _ = try await take(URL(fileURLWithPath: path), root: root, minimumDuration: 0)
        NotificationCenter.default.post(name: .libraryDidChange, object: store)
        let location = Volumes.location(forPath: path)
        return try store.track(uri: ScannedFile.uri(path: path, volumeUUID: location?.uuid, relativePath: location?.relativePath))
    }

    /// Rescans every library folder that is currently reachable.
    public func scanAll(progress: (@Sendable (Summary) -> Void)? = nil) async -> Summary {
        var total = Summary()
        for folder in (try? store.folders()) ?? [] {
            var path = folder.path
            if let uuid = folder.volumeUUID, let relative = folder.relativePath {
                guard let mount = Volumes.mountPoint(uuid: uuid) else { continue }
                path = (mount as NSString).appendingPathComponent(relative)
            }
            guard let summary = try? await scan(folder: path, progress: nil) else { continue }
            total.found += summary.found
            total.added += summary.added
            total.updated += summary.updated
            total.unchanged += summary.unchanged
            total.tooShort += summary.tooShort
            total.unreadable += summary.unreadable
            progress?(total)
        }
        return total
    }
}
