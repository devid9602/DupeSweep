import Foundation

// MARK: - Inputs

/// A folder chosen by the user. `recursive == false` scans only that folder's own files.
struct ScanRoot: Hashable {
    var url: URL
    var recursive: Bool
}

/// Header-level facts about an image file (cheap to read, no pixel decode).
struct ImageMetadata: Equatable {
    var pixelWidth = 0
    var pixelHeight = 0
    var format = ""                 // JPEG, PNG, HEIC, WEBP, TIFF, GIF, BMP, RAW …
    var make: String?
    var model: String?
    var software: String?
    var dateTimeOriginal: String?   // "YYYY:MM:DD HH:MM:SS"
    var subSecTimeOriginal: String?
    var hasExif = false
    var jpegQuality: Int?           // estimated from the quantisation tables

    var pixelCount: Int { pixelWidth * pixelHeight }
    var isLossless: Bool { ["PNG", "TIFF", "BMP", "RAW"].contains(format) }
    var hasCameraEvidence: Bool { (make != nil || model != nil) && dateTimeOriginal != nil }

    private static let editorMarkers = [
        "photoshop", "lightroom", "adobe", "gimp", "snapseed", "pixelmator", "affinity", "luminar",
        "capture one", "darktable", "rawtherapee", "picasa", "instagram", "vsco", "canva", "facetune",
        "photos ", "paint.net", "acdsee", "polarr", "picsart", "afterlight", "lightroom mobile", "fotor",
        "photoscape", "irfanview", "xnview", "preview", "skylum", "on1 ", "dxo", "faststone",
    ]

    /// True when the Software tag names an editing/exporting application.
    var editedBySoftware: Bool {
        guard let s = software?.lowercased(), !s.isEmpty else { return false }
        return ImageMetadata.editorMarkers.contains { s.contains($0) }
    }

    /// Capture time in seconds (local, approximate) parsed from EXIF, if present.
    var captureSeconds: Double? {
        guard let d = dateTimeOriginal, d.count >= 19 else { return nil }
        let parts = d.replacingOccurrences(of: ":", with: " ").split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 6, parts[0] > 1900 else { return nil }
        let days = (parts[0] - 1970) * 372 + (parts[1] - 1) * 31 + (parts[2] - 1)
        var t = days * 86400 + parts[3] * 3600 + parts[4] * 60 + parts[5]
        if let ss = subSecTimeOriginal, let frac = Double("0." + ss.filter { $0.isNumber }) { t += frac }
        return t
    }
}

/// One image found on disk.
struct ScannedImage: Identifiable {
    let index: Int
    let url: URL
    let size: Int64
    let modified: Date?
    let created: Date?
    var meta = ImageMetadata()
    var sha256: String?

    var id: Int { index }
    var path: String { url.path }
    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path }
}

// MARK: - Results

enum Confidence: Int, Comparable {
    case none = 0, low, medium, high, exact

    static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .exact: return "Certain"
        }
    }
}

enum MemberLabel: String {
    case original = "ORIGINAL"
    case exact = "EXACT DUPLICATE"
    case visual = "VISUAL DUPLICATE"
    case edited = "EDITED VERSION"
    case possible = "POSSIBLE MATCH"

    /// Whether this label may be auto-selected for removal.
    var isConfirmedDuplicate: Bool { self == .exact || self == .visual || self == .edited }
}

struct GroupMember {
    var imageIndex: Int
    var label: MemberLabel
    var confidence: Confidence
    var similarity: Float          // 0...1
    var method: String
    var notes: [String]
}

enum GroupScope: String {
    case sameFolder = "Same folder"
    case nested = "Nested subfolders"
    case acrossFolders = "Across folders"
}

struct DuplicateGroupResult {
    var members: [GroupMember]       // members[0] is the recommended original
    var recommendedIndex: Int        // image index of the recommended original
    var manualReview: Bool
    var reviewReason: String?
    var scope: GroupScope
    var originalReasons: [String]    // why the original was recommended
}

struct FolderSummary {
    var path: String
    var imageCount: Int
    var duplicateCount: Int          // non-original group members located here
}

struct ScanStats {
    var discovered = 0
    var valid = 0
    var skipped: [(path: String, reason: String)] = []
    var cacheHits = 0
    var exactGroups = 0
    var hashPairsScreened = 0
    var candidatePairs = 0
    var validatedPairs = 0
    var stageSeconds: [(String, Double)] = []
}

struct ScanReport {
    var images: [ScannedImage]
    var groups: [DuplicateGroupResult]
    var folders: [FolderSummary]
    var stats: ScanStats
    var cancelled: Bool
    /// Engine snapshot used to re-label a group when the user picks a different original.
    var relabeler: Relabeler?
}

// MARK: - Progress

struct ScanProgress {
    var stage = 0                    // 1...5
    var stageName = ""
    var done = 0
    var total = 0
    var currentFolder = ""
    var folderIndex = 0
    var folderCount = 0
    var elapsed: TimeInterval = 0
    var stageETA: TimeInterval?
    var paused = false

    static let stageNames = ["", "Discovering files", "Finding exact duplicates", "Fingerprinting images",
                             "Validating similar images", "Building duplicate groups"]
}
