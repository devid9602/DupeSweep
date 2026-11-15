import Foundation

/// One file moved into quarantine (restorable until permanently deleted).
struct QuarantineItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var originalPath: String
    var quarantinedPath: String
    var keptOriginalPath: String?
    var date: Date
    var size: Int64
}

/// Moves files into a quarantine folder (keeping their folder structure) and back.
/// A JSON manifest in the quarantine folder records every move.
final class QuarantineStore {
    private(set) var root: URL
    private(set) var items: [QuarantineItem] = []

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/DupeSweep Quarantine", isDirectory: true)
    }
    private static let rootKey = "QuarantineRoot"

    init() {
        if let p = UserDefaults.standard.string(forKey: QuarantineStore.rootKey) {
            root = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            root = QuarantineStore.defaultRoot
        }
        load()
    }

    private var manifest: URL { root.appendingPathComponent("quarantine-manifest.json") }

    func setRoot(_ url: URL) {
        root = url.standardizedFileURL
        UserDefaults.standard.set(root.path, forKey: QuarantineStore.rootKey)
        load()
    }

    func load() {
        guard let d = try? Data(contentsOf: manifest) else { items = []; return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        items = (try? dec.decode([QuarantineItem].self, from: d)) ?? []
        // Drop entries whose file no longer exists in quarantine (deleted outside the app).
        items = items.filter { FileManager.default.fileExists(atPath: $0.quarantinedPath) }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(items) { try? d.write(to: manifest, options: .atomic) }
    }

    /// Moves files into quarantine/<timestamp>/<original path>. Returns moved items and failures.
    func quarantine(_ files: [(url: URL, size: Int64, kept: URL?)]) -> (moved: [QuarantineItem], failures: [String]) {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let batch = root.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        var moved: [QuarantineItem] = []
        var failures: [String] = []
        for file in files {
            if let kept = file.kept, !fm.fileExists(atPath: kept.path) {
                failures.append("\(file.url.path): its original is missing – skipped for safety")
                continue
            }
            let relative = String(file.url.path.drop(while: { $0 == "/" }))
            var dest = batch.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { dest = QuarantineStore.unique(dest) }
                try fm.moveItem(at: file.url, to: dest)
                let item = QuarantineItem(originalPath: file.url.path, quarantinedPath: dest.path,
                                          keptOriginalPath: file.kept?.path, date: Date(), size: file.size)
                moved.append(item)
            } catch {
                failures.append("\(file.url.path): \(error.localizedDescription)")
            }
        }
        items.append(contentsOf: moved)
        save()
        return (moved, failures)
    }

    /// Moves quarantined files back to where they came from.
    func restore(_ ids: Set<UUID>) -> (restored: [String], failures: [String]) {
        let fm = FileManager.default
        var restored: [String] = []
        var failures: [String] = []
        var remaining: [QuarantineItem] = []
        for item in items {
            guard ids.contains(item.id) else { remaining.append(item); continue }
            var dest = URL(fileURLWithPath: item.originalPath)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { dest = QuarantineStore.unique(dest, suffix: " (restored)") }
                try fm.moveItem(at: URL(fileURLWithPath: item.quarantinedPath), to: dest)
                restored.append(dest.path)
            } catch {
                failures.append("\(item.originalPath): \(error.localizedDescription)")
                remaining.append(item)
            }
        }
        items = remaining
        cleanEmptyFolders()
        save()
        return (restored, failures)
    }

    /// Permanently deletes quarantined files (cannot be undone).
    func deletePermanently(_ ids: Set<UUID>) -> (deleted: Int, failures: [String]) {
        let fm = FileManager.default
        var deleted = 0
        var failures: [String] = []
        var remaining: [QuarantineItem] = []
        for item in items {
            guard ids.contains(item.id) else { remaining.append(item); continue }
            do {
                try fm.removeItem(atPath: item.quarantinedPath)
                deleted += 1
            } catch {
                failures.append("\(item.originalPath): \(error.localizedDescription)")
                remaining.append(item)
            }
        }
        items = remaining
        cleanEmptyFolders()
        save()
        return (deleted, failures)
    }

    private func cleanEmptyFolders() {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var dirs: [URL] = []
        while let u = walker.nextObject() as? URL {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(u) }
        }
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let c = try? fm.contentsOfDirectory(atPath: d.path), c.filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.removeItem(at: d)
            }
        }
    }

    static func unique(_ url: URL, suffix: String = "") -> URL {
        let fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 1
        while true {
            let name = base + suffix + (n > 1 ? " \(n)" : "") + (ext.isEmpty ? "" : "." + ext)
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
