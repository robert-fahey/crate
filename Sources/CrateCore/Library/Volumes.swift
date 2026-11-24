import Foundation

/// Removable drives can remount under a different name ("Transcend 1"), so
/// files on them are identified by volume UUID plus path within the volume.
public enum Volumes {
    public struct Location: Equatable {
        public var uuid: String
        public var relativePath: String
    }

    /// Returns a volume-relative location for paths on an external volume, nil for the startup disk.
    public static func location(forPath path: String) -> Location? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey]),
              let uuid = values.volumeUUIDString, let volume = values.volume
        else { return nil }
        let root = volume.standardizedFileURL.path
        guard root != "/" else { return nil }
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(root) else { return nil }
        var relative = String(full.dropFirst(root.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return Location(uuid: uuid, relativePath: relative)
    }

    /// Where a volume is mounted right now, or nil if it is not connected.
    public static func mountPoint(uuid: String) -> String? {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            if (try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == uuid {
                return volume.standardizedFileURL.path
            }
        }
        return nil
    }

    /// The file for a local track if it can be reached now.
    public static func resolvedPath(for track: Track) -> String? {
        guard track.source == .local else { return nil }
        if let uuid = track.volumeUUID, let relative = track.relativePath {
            guard let mount = mountPoint(uuid: uuid) else { return nil }
            let path = (mount as NSString).appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        guard let path = track.path, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
}
