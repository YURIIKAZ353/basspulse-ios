import Foundation

enum ImportedAudioStore {
    // Directory enumeration may return a different URL spelling for the same
    // file (/var vs /private/var, relative bases, percent escaping). Never use
    // URL != to decide whether to delete the file just selected for playback.
    static func removePreviousFiles(in folder: URL, keeping current: URL) throws {
        let canonicalFolder = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let currentFolder = current.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard canonicalFolder == currentFolder else { return }
        let protectedName = current.lastPathComponent
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        for candidate in files {
            guard candidate.lastPathComponent != protectedName,
                  candidate.pathExtension.lowercased() == "caf",
                  (try candidate.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            try FileManager.default.removeItem(at: candidate)
        }
    }

    static func fileSummary(_ url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "Локальный файл отсутствует" }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return "Локальный файл: \(bytes) байт • \(url.pathExtension.uppercased())"
    }
}
