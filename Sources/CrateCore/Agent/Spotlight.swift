import Foundation

/// Finds audio files through the Spotlight index (`mdfind`), which is far
/// faster than walking the disk and already knows each file's duration.
public enum Spotlight {
    static func query(nameContains: String?, minimumSeconds: Double?) -> String {
        var clauses = ["kMDItemContentTypeTree == \"public.audio\""]
        if let name = nameContains?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            // Quotes, backslashes and wildcards in the text are matched literally.
            var escaped = ""
            for character in name {
                if "\\\"*?".contains(character) { escaped.append("\\") }
                escaped.append(character)
            }
            clauses.append("kMDItemFSName == \"*\(escaped)*\"cd")
        }
        if let minimumSeconds, minimumSeconds > 0 {
            clauses.append("kMDItemDurationSeconds >= \(Int(minimumSeconds))")
        }
        return clauses.joined(separator: " && ")
    }

    public static func audioFiles(nameContains: String?, folder: String?, minimumSeconds: Double?) async throws -> [String] {
        var arguments: [String] = []
        if let folder {
            let expanded = (folder as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ToolError("\(expanded) is not a folder I can read.")
            }
            arguments += ["-onlyin", expanded]
        }
        arguments.append(query(nameContains: nameContains, minimumSeconds: minimumSeconds))
        let result = try await ProcessRunner.run(executable: "/usr/bin/mdfind", arguments: arguments, timeout: 30)
        guard result.exitCode == 0 else {
            throw ToolError("Spotlight search failed: \(result.output.prefix(300))")
        }
        return result.output.split(separator: "\n").map(String.init)
            .filter { LibraryScanner.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }
}
