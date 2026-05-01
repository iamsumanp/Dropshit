import Foundation

/// Finder-style "(1), (2), ..." suffix resolver. Stateless; only reads
/// the filesystem to test for existence.
enum UniqueDestination {
    static func url(preferred: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let dir = preferred.deletingLastPathComponent()
        let ext = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            let withSuffix = "\(stem) (\(i))"
            var candidate = dir.appendingPathComponent(withSuffix)
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
