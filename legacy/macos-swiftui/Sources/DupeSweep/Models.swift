import Foundation

/// A folder added in the sidebar.
struct FolderEntry: Identifiable, Hashable {
    var url: URL
    var recursive = true
    var id: URL { url }
}

/// UI-side duplicate group: the engine's result plus the user's current choices.
struct DuplicateGroup: Identifiable {
    let id = UUID()
    var result: DuplicateGroupResult
    var originalIndex: Int                 // image index currently kept as original
    var markedForDeletion: Set<Int> = []   // image indices

    var members: [GroupMember] { result.members }
    var imageIndices: [Int] { result.members.map { $0.imageIndex } }
    var isUserOverride: Bool { originalIndex != result.recommendedIndex }
}

/// How the original is chosen. `.recommended` uses the engine's evidence-based scoring.
enum OriginalRule: String, CaseIterable, Identifiable {
    case recommended = "Recommended (best quality)"
    case highestResolution = "Highest resolution"
    case oldest = "Oldest date"
    case newest = "Newest date"
    case largestFile = "Largest file size"
    case shortestPath = "Shortest path"
    case preferredFolder = "Inside preferred folder"

    var id: String { rawValue }

    /// Picks an image index for the manual rules (nil for `.recommended`).
    func pick(_ indices: [Int], images: [ScannedImage], preferredFolder: URL?) -> Int? {
        guard !indices.isEmpty, self != .recommended else { return nil }
        func better(_ a: Int, _ b: Int) -> Bool {
            let x = images[a], y = images[b]
            if x.meta.pixelCount != y.meta.pixelCount { return x.meta.pixelCount > y.meta.pixelCount }
            if x.size != y.size { return x.size > y.size }
            return x.path.count < y.path.count
        }
        func date(_ i: Int) -> Date? { images[i].created ?? images[i].modified }
        switch self {
        case .recommended:
            return nil
        case .highestResolution:
            return indices.sorted(by: better).first
        case .oldest:
            return indices.sorted {
                let a = date($0) ?? .distantFuture, b = date($1) ?? .distantFuture
                return a != b ? a < b : better($0, $1)
            }.first
        case .newest:
            return indices.sorted {
                let a = date($0) ?? .distantPast, b = date($1) ?? .distantPast
                return a != b ? a > b : better($0, $1)
            }.first
        case .largestFile:
            return indices.sorted { images[$0].size != images[$1].size ? images[$0].size > images[$1].size : better($0, $1) }.first
        case .shortestPath:
            return indices.sorted { images[$0].path.count != images[$1].path.count ? images[$0].path.count < images[$1].path.count : better($0, $1) }.first
        case .preferredFolder:
            if let f = preferredFolder {
                let prefix = f.standardizedFileURL.path + "/"
                if let p = indices.filter({ images[$0].path.hasPrefix(prefix) }).sorted(by: better).first { return p }
            }
            return indices.sorted(by: better).first
        }
    }
}

enum ResultsMode: String, CaseIterable, Identifiable {
    case groups = "Groups"
    case folders = "Folders"
    var id: String { rawValue }
}

enum ResultsFilter: String, CaseIterable, Identifiable {
    case all = "All groups"
    case review = "Needs review"
    case confirmed = "Confirmed duplicates"
    case crossFolder = "Across folders"
    var id: String { rawValue }
}

/// A destructive or moving action waiting for the user's confirmation.
struct PendingAction: Identifiable {
    enum Kind { case quarantine, trash, deletePermanently }
    let id = UUID()
    var kind: Kind
    var paths: [String]
    var totalBytes: Int64
    var quarantineIDs: [UUID] = []

    var title: String {
        switch kind {
        case .quarantine: return "Move \(paths.count) file\(paths.count == 1 ? "" : "s") to the quarantine folder?"
        case .trash: return "Move \(paths.count) file\(paths.count == 1 ? "" : "s") to the Trash?"
        case .deletePermanently: return "Permanently delete \(paths.count) file\(paths.count == 1 ? "" : "s")?"
        }
    }

    var confirmTitle: String {
        switch kind {
        case .quarantine: return "Move to Quarantine"
        case .trash: return "Move to Trash"
        case .deletePermanently: return "Delete Permanently"
        }
    }

    struct FolderCount: Hashable {
        var folder: String
        var count: Int
    }

    /// Folder → number of files, sorted by folder.
    var byFolder: [FolderCount] {
        var d: [String: Int] = [:]
        for p in paths { d[(p as NSString).deletingLastPathComponent, default: 0] += 1 }
        return d.sorted { $0.key < $1.key }.map { FolderCount(folder: $0.key, count: $0.value) }
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
