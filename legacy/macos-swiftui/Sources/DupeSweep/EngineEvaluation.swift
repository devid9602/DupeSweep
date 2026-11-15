import Foundation

/// Ground truth for a generated test library (used by `--selftest` and the Linux harness).
struct TestTruth: Codable {
    struct FileInfo: Codable { var photo: String?; var role: String? }
    struct Group: Codable { var photo: String; var original: String; var members: [String] }
    var files: [String: FileInfo]
    var expect_groups: [Group]
    var expect_separate: [[String]]
}

enum Evaluation {
    static func textReport(report: ScanReport, truthPath: String, libraryRoot: String, seconds: Double) -> String {
        guard let d = FileManager.default.contents(atPath: truthPath),
              let truth = try? JSONDecoder().decode(TestTruth.self, from: d) else { return "cannot read truth file" }
        return textReport(report: report, truth: truth, libraryRoot: libraryRoot, seconds: seconds)
    }

    static func textReport(report: ScanReport, truth: TestTruth, libraryRoot: String, seconds: Double) -> String {
        let root = libraryRoot.hasSuffix("/") ? libraryRoot : libraryRoot + "/"
        func rel(_ i: Int) -> String { String(report.images[i].path.dropFirst(root.count)) }
        var groupOf: [String: Int] = [:]
        var memberOf: [String: GroupMember] = [:]
        for (gi, g) in report.groups.enumerated() {
            for m in g.members { groupOf[rel(m.imageIndex)] = gi; memberOf[rel(m.imageIndex)] = m }
        }
        let shaOf = Dictionary(report.images.map { (rel($0.index), $0.sha256 ?? "") }, uniquingKeysWith: { a, _ in a })

        var lines: [String] = []
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

        let labels = report.groups.flatMap { $0.members }
        let count: (MemberLabel) -> Int = { l in labels.filter { $0.label == l }.count }
        lines.append("DupeSweep detection test report")
        lines.append(String(repeating: "=", count: 72))
        lines.append("Total images scanned:            \(report.stats.valid)  (skipped \(report.stats.skipped.count) unreadable/unsupported)")
        lines.append("Duplicate groups:                \(report.groups.count)  (manual review: \(report.groups.filter { $0.manualReview }.count))")
        lines.append("Exact duplicates detected:       \(count(.exact))")
        lines.append("Visual duplicates detected:      \(count(.visual))")
        lines.append("Edited versions detected:        \(count(.edited))")
        lines.append("Possible matches (needs review): \(count(.possible))")

        // Scenario table
        lines.append("")
        lines.append("Scenario results (each expected copy vs. its original)")
        lines.append(String(repeating: "-", count: 72))
        var byRole: [String: (ok: Int, total: Int)] = [:]
        var missed: [String] = []
        var originalsCorrect = 0
        for g in truth.expect_groups {
            let gi = groupOf[g.original]
            if let gi = gi {
                let rec = rel(report.groups[gi].recommendedIndex)
                if rec == g.original || (shaOf[rec] != nil && shaOf[rec] == shaOf[g.original] && !(shaOf[rec] ?? "").isEmpty) { originalsCorrect += 1 }
            }
            for m in g.members where m != g.original {
                let role = truth.files[m]?.role ?? "?"
                var entry = byRole[role] ?? (0, 0)
                entry.total += 1
                if let gm = groupOf[m], gm == gi, let mm = memberOf[m], mm.label.isConfirmedDuplicate {
                    entry.ok += 1
                } else {
                    let how = memberOf[m].map { "\($0.label.rawValue) (\($0.confidence.title))" } ?? "not grouped"
                    missed.append("\(m) → \(how)")
                }
                byRole[role] = entry
            }
        }
        let roleNames: [(String, String)] = [
            ("exact", "Exact copy, different filename"), ("resized", "Resized to smaller resolution"),
            ("tone", "Brightness & contrast changed"), ("filter", "Colour filter applied"),
            ("compressed", "Heavily JPEG-compressed"), ("png2jpg", "Converted PNG → JPG"),
            ("webp", "Converted to WEBP"), ("png", "Converted JPG → PNG"), ("tiff", "Converted to TIFF"), ("heic", "Converted to HEIC"), ("crop", "Slightly cropped"),
            ("rot90", "Rotated 90°"), ("rot_small", "Tilted 3° + editor export"),
            ("nested", "Copy in nested folder"),
        ]
        for (k, title) in roleNames {
            guard let e = byRole[k] else { continue }
            let mark = e.ok == e.total ? "PASS" : "FAIL"
            lines.append("\(pad(title, 34)) \(e.ok)/\(e.total) detected as confirmed duplicate   \(mark)")
        }
        lines.append("\(pad("Recommended original correct", 34)) \(originalsCorrect)/\(truth.expect_groups.count)")

        // False positives
        var negativeTogether: [String] = []      // wrongly confirmed as the same photograph
        var negativeFlagged: [String] = []       // only shown as a possible match (no deletion recommended)
        for p in truth.expect_separate where p.count == 2 {
            if let a = groupOf[p[0]], let b = groupOf[p[1]], a == b {
                let ma = memberOf[p[0]], mb = memberOf[p[1]]
                let la = ma?.label.rawValue ?? "", lb = mb?.label.rawValue ?? ""
                let line = "\(p[0]) [\(la)] + \(p[1]) [\(lb)]"
                if (ma?.label.isConfirmedDuplicate ?? false) || (mb?.label.isConfirmedDuplicate ?? false) {
                    negativeTogether.append(line)
                } else {
                    negativeFlagged.append(line)
                }
            }
        }
        var mixed: [String] = []
        for g in report.groups {
            let orig = rel(g.recommendedIndex)
            let op = truth.files[orig]?.photo
            for m in g.members where m.label.isConfirmedDuplicate {
                let r = rel(m.imageIndex)
                if let p = truth.files[r]?.photo, p != op { mixed.append("\(r) [\(m.label.rawValue)] grouped with \(orig)") }
            }
        }
        let fpPossible = report.groups.flatMap { g -> [String] in
            let op = truth.files[rel(g.recommendedIndex)]?.photo
            return g.members.filter { $0.label == .possible && truth.files[rel($0.imageIndex)]?.photo != op }.map { rel($0.imageIndex) }
        }
        lines.append("")
        let apart = truth.expect_separate.count - negativeTogether.count - negativeFlagged.count
        lines.append("Different photographs with similar backgrounds (\(truth.expect_separate.count) pairs):")
        lines.append("  kept completely apart:              \(apart)")
        lines.append("  shown only as POSSIBLE MATCH:       \(negativeFlagged.count)  (never auto-selected)")
        lines.append("  wrongly confirmed as duplicates:    \(negativeTogether.count)  \(negativeTogether.isEmpty ? "PASS" : "FAIL")")
        lines.append("False positives (confirmed duplicate of a different photo): \(mixed.count)")
        lines.append("Low-confidence possible matches of a different photo:      \(fpPossible.count)")
        for s in negativeTogether { lines.append("  ! confirmed: \(s)") }
        for s in negativeFlagged { lines.append("  ? possible: \(s)") }
        for s in mixed { lines.append("  ! \(s)") }
        for s in fpPossible where !negativeFlagged.contains(where: { $0.contains(s) }) { lines.append("  ? possible: \(s)") }
        if !missed.isEmpty {
            lines.append("")
            lines.append("Not confirmed (\(missed.count)):")
            for s in missed { lines.append("  - \(s)") }
        }

        lines.append("")
        lines.append(String(format: "Processing time: %.2f s total", seconds))
        for (name, secs) in report.stats.stageSeconds { lines.append(String(format: "  %@: %.2f s", pad(name, 26), secs)) }
        lines.append("  pairs screened by hash index: \(report.stats.hashPairsScreened), candidates: \(report.stats.candidatePairs), fully validated: \(report.stats.validatedPairs)")
        lines.append("  cache hits: \(report.stats.cacheHits)/\(report.stats.discovered)")
        if !report.stats.skipped.isEmpty {
            lines.append("Skipped files:")
            for s in report.stats.skipped.prefix(10) { lines.append("  \(String(s.path.dropFirst(min(s.path.count, root.count)))) – \(s.reason)") }
        }
        return lines.joined(separator: "\n")
    }
}
