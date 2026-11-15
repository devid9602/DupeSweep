import Foundation

/// Lazily built, shared MatchViews (keyed by representative index and rotation).
final class ViewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var views: [Int: MatchView] = [:]
    private let fingerprint: (Int) -> Fingerprint?

    init(fingerprint: @escaping (Int) -> Fingerprint?) { self.fingerprint = fingerprint }

    func view(_ index: Int, _ quarterTurns: Int) -> MatchView? {
        let key = index * 4 + quarterTurns
        lock.lock()
        if let v = views[key] { lock.unlock(); return v }
        lock.unlock()
        guard let fp = fingerprint(index) else { return nil }
        let v = MatchView(fp: fp, quarterTurns: quarterTurns)
        lock.lock(); views[key] = v; lock.unlock()
        return v
    }
}

enum Classifier {
    /// Confidence that two images show the same photograph, plus a note when metadata disagrees.
    static func confidence(_ m: PairMatch, _ a: ImageMetadata, _ b: ImageMetadata,
                           _ s: DetectionSettings) -> (Confidence, String?) {
        func passes(_ t: Float) -> Bool { m.score >= t && m.ssim >= t - 0.02 && m.structureP10 >= t - 0.42 }
        var c: Confidence = passes(s.highThreshold) ? .high
            : passes(s.mediumThreshold) ? .medium
            : passes(s.lowThreshold) ? .low : .none
        guard c > .none else { return (.none, nil) }

        var conflict: String?
        var metaConflict = false
        if c == .high && m.coverage < 0.95 && m.score < s.highThreshold + 0.05 {
            // Matches that only align after cropping need stronger evidence.
            c = .medium
            conflict = "Only part of the frame matches – verify it is the same photograph"
        }
        if c == .high && m.fineLocal > s.maxFineDifference {
            c = .medium
            conflict = "At full detail part of the picture differs (moved subject or a different moment) – verify"
        }
        if c == .high && m.localDifference > s.maxLocalDifference {
            c = .medium
            conflict = "Part of the picture differs (moved subject or local edit) – verify"
        }
        if let ta = a.captureSeconds, let tb = b.captureSeconds {
            let bothSub = a.subSecTimeOriginal != nil && b.subSecTimeOriginal != nil
            let dt = abs(ta - tb)
            if bothSub ? dt > 0.005 : dt >= 1 {
                conflict = "EXIF capture times differ – likely a different shot (burst or re-take)"
                metaConflict = true
            } else if bothSub, c == .medium, a.model == b.model, m.localDifference <= s.maxLocalDifference {
                c = .high      // identical capture instant incl. sub-seconds supports the visual match
            }
        }
        if !metaConflict, let ma = a.model, let mb = b.model, !ma.isEmpty, !mb.isEmpty, ma != mb {
            conflict = "Taken with different cameras (\(ma) vs \(mb))"
            metaConflict = true
        }
        if metaConflict {
            c = (c == .high && m.score >= 0.95) ? .medium : min(c, .low)
        }
        if m.lowDetail && !metaConflict {
            // Featureless frames (sky, fog, blank wall) can't be told apart visually.
            // Only an identical EXIF capture time can confirm them.
            let sameCapture = a.captureSeconds != nil && a.captureSeconds == b.captureSeconds
            if !sameCapture && c > .low {
                c = .low
                conflict = "Very little detail – can't confirm visually, please verify"
            }
        }
        return (c, conflict)
    }
}

/// Owns everything needed to describe group members and to re-label a group
/// when the user chooses a different original after the scan.
final class Relabeler: @unchecked Sendable {
    let images: [ScannedImage]
    let repOf: [Int]                        // image index → representative image index
    let settings: DetectionSettings
    private let fingerprints: [Int: Fingerprint]
    private let views: ViewCache
    private let lock = NSLock()
    private var matches: [Int64: PairMatch] = [:]

    private let pairCache: FingerprintCache?
    private let contentKeys: [UInt64]
    private let settingsKey: UInt32

    /// Decodes an image (by index) to upright luma ≤ 256 px for the full-detail re-check.
    private let fineSource: ((Int) -> GrayImage?)?
    private var fineImages: [Int: GrayImage] = [:]
    private var fineOrder: [Int] = []

    init(images: [ScannedImage], repOf: [Int], fingerprints: [Int: Fingerprint], settings: DetectionSettings,
         pairCache: FingerprintCache? = nil, fineSource: ((Int) -> GrayImage?)? = nil) {
        self.fineSource = fineSource
        self.images = images
        self.repOf = repOf
        self.settings = settings
        self.fingerprints = fingerprints
        self.pairCache = pairCache
        self.contentKeys = images.map {
            FingerprintCache.contentKey(path: $0.path, size: $0.size, mtime: $0.modified?.timeIntervalSince1970 ?? 0)
        }
        self.settingsKey = FingerprintCache.settingsKey(settings)
        let fps = fingerprints
        self.views = ViewCache(fingerprint: { fps[$0] })
        var d: [Int: Float] = [:]
        for (k, f) in fingerprints { d[k] = MatchView.detail(for: f) }
        self.details = d
    }

    private let details: [Int: Float]

    private func lowDetail(_ a: Int, _ b: Int) -> Bool {
        min(details[a] ?? 1, details[b] ?? 1) < MatchView.lowDetailThreshold
    }

    func fingerprint(_ rep: Int) -> Fingerprint? { fingerprints[rep] }
    var viewCache: ViewCache { views }

    private func key(_ a: Int, _ b: Int) -> Int64 { Int64(a) << 32 | Int64(b) }

    func remember(_ a: Int, _ b: Int, _ m: PairMatch) {
        lock.lock(); matches[key(a, b)] = m; lock.unlock()
    }

    func knownMatch(_ a: Int, _ b: Int) -> PairMatch? {
        lock.lock(); defer { lock.unlock() }
        return matches[key(a, b)]
    }

    /// Alignment of rep `b` against reference rep `a` (computed on demand, cached).
    func match(_ a: Int, _ b: Int) -> PairMatch? {
        if let m = knownMatch(a, b) { return m }
        let pk = PairKey(a: contentKeys[a], b: contentKeys[b], settings: settingsKey)
        if var m = pairCache?.pair(pk) { m.lowDetail = lowDetail(a, b); remember(a, b, m); return m }
        guard let fa = fingerprints[a], let fb = fingerprints[b] else { return nil }
        var m = Matcher.compare(fa, fb, settings: settings, views: { [views] i, q in views.view(i, q) }, aIndex: a, bIndex: b)
        m.lowDetail = lowDetail(a, b)
        if m.refined && m.score >= settings.mediumThreshold - 0.05 { m.fineLocal = fineCheck(a, b, m) }
        remember(a, b, m)
        pairCache?.storePair(pk, m)
        return m
    }

    private func fineImage(_ i: Int) -> GrayImage? {
        lock.lock()
        if let g = fineImages[i] { lock.unlock(); return g }
        lock.unlock()
        guard let g = fineSource?(i) else { return nil }
        lock.lock()
        fineImages[i] = g
        fineOrder.append(i)
        if fineOrder.count > 400 { fineImages[fineOrder.removeFirst()] = nil }   // bounded memory
        lock.unlock()
        return g
    }

    /// Re-checks an aligned pair at full detail; -1 when pixels are unavailable.
    private func fineCheck(_ a: Int, _ b: Int, _ m: PairMatch) -> Float {
        guard fineSource != nil, let ga = fineImage(a), let gb = fineImage(b) else { return -1 }
        let rb = Imaging.rotate(gb, quarterTurns: m.quarterTurns)
        return m.otherIsInside
            ? Matcher.fineLocalDifference(ref: ga, mov: rb, match: m)
            : Matcher.fineLocalDifference(ref: rb, mov: ga, match: m)
    }

    func confidence(_ a: Int, _ b: Int) -> (Confidence, PairMatch?, String?) {
        if a == b { return (.exact, nil, nil) }
        guard let m = match(a, b) else { return (.none, nil, nil) }
        let (c, note) = Classifier.confidence(m, images[a].meta, images[b].meta, settings)
        return (c, m, note)
    }

    // MARK: Original selection

    struct OriginalChoice {
        var index: Int
        var manualReview: Bool
        var reviewReason: String?
        var reasons: [String]
    }

    private static let copyMarkers = ["copy", "kopie", "(1)", "(2)", "(3)", "duplicate", "backup", " - ", "_edited", "-edited", "export"]

    private func isCroppedVersion(_ rep: Int, within reps: [Int]) -> Bool {
        for other in reps where other != rep {
            if let m = knownMatch(other, rep), m.otherIsInside, m.coverage < 0.95, m.score >= settings.mediumThreshold { return true }
            if let m = knownMatch(rep, other), !m.otherIsInside, m.coverage < 0.95, m.score >= settings.mediumThreshold { return true }
        }
        return false
    }

    /// Scores every distinct version and recommends the best one to keep.
    func chooseOriginal(_ members: [Int]) -> OriginalChoice {
        let reps = Array(Set(members.map { repOf[$0] })).sorted()
        let maxPixels = max(1, reps.map { images[$0].meta.pixelCount }.max() ?? 1)
        let maxSharp = max(1e-6, reps.compactMap { fingerprints[$0]?.stats.sharpness }.max() ?? 1e-6)

        func quality(_ m: ImageMetadata) -> Float {
            switch m.format {
            case "PNG", "TIFF", "BMP", "RAW": return 1.0
            case "JPEG": return Float(m.jpegQuality ?? 85) / 100
            case "HEIC": return 0.90
            case "WEBP": return 0.80
            case "GIF": return 0.40
            default: return 0.75
            }
        }

        var scored: [(rep: Int, score: Float)] = []
        for r in reps {
            let m = images[r].meta
            let res = Float(m.pixelCount) / Float(maxPixels)
            let camera: Float = m.hasCameraEvidence ? 1 : (m.dateTimeOriginal != nil ? 0.5 : 0)
            var unedited: Float = m.editedBySoftware ? 0 : 1
            if isCroppedVersion(r, within: reps) { unedited -= 0.5 }
            let sharp = (fingerprints[r]?.stats.sharpness ?? 0) / maxSharp
            let s = 0.40 * res + 0.20 * quality(m) + 0.20 * camera + 0.15 * unedited + 0.05 * sharp
            scored.append((r, s))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : images[$0.rep].path < images[$1.rep].path }
        let bestRep = scored[0].rep

        // Among identical copies of the best version prefer the one that doesn't look like a copy.
        let copies = members.filter { repOf[$0] == bestRep }
        func copyPenalty(_ i: Int) -> Int {
            let n = images[i].path.lowercased()
            return Relabeler.copyMarkers.filter { n.contains($0) }.count
        }
        let pick = copies.sorted {
            let pa = copyPenalty($0), pb = copyPenalty($1)
            if pa != pb { return pa < pb }
            let da = images[$0].path.split(separator: "/").count, db = images[$1].path.split(separator: "/").count
            if da != db { return da < db }
            return images[$0].path < images[$1].path
        }[0]

        let m = images[bestRep].meta
        var reasons: [String] = []
        if m.pixelCount >= maxPixels { reasons.append("highest resolution (\(m.pixelWidth)×\(m.pixelHeight))") }
        if m.isLossless { reasons.append("lossless \(m.format)") } else if let q = m.jpegQuality { reasons.append("JPEG quality ~\(q)") }
        if m.hasCameraEvidence { reasons.append("original camera EXIF" + (m.model.map { " (\($0))" } ?? "")) }
        if !m.editedBySoftware { reasons.append("no editing software recorded") }

        var review = false
        var why: String?
        if scored.count >= 2 && scored[0].score - scored[1].score < 0.05 {
            review = true
            why = "Two versions are almost equally good: \(images[scored[0].rep].name) and \(images[scored[1].rep].name)"
        } else if m.pixelCount < Int(Double(maxPixels) * 0.98) {
            review = true
            let big = reps.first { images[$0].meta.pixelCount == maxPixels } ?? bestRep
            why = "A higher-resolution version (\(images[big].name)) exists but looks edited or upscaled"
        }
        return OriginalChoice(index: pick, manualReview: review, reviewReason: why, reasons: reasons)
    }

    // MARK: Describing members

    func describe(original o: Int, member i: Int) -> GroupMember {
        let ro = repOf[o], ri = repOf[i]
        let img = images[i], orig = images[o]
        if i == o {
            return GroupMember(imageIndex: i, label: .original, confidence: .exact, similarity: 1, method: "Recommended original", notes: [])
        }
        if ro == ri {
            var notes = ["byte-for-byte identical"]
            if img.name != orig.name { notes.append("different filename") }
            if img.folder != orig.folder { notes.append("different folder") }
            return GroupMember(imageIndex: i, label: .exact, confidence: .exact, similarity: 1, method: "SHA-256 identical", notes: notes)
        }
        let (c, mm, conflict) = confidence(ro, ri)
        guard let m = mm else {
            return GroupMember(imageIndex: i, label: .possible, confidence: .low, similarity: 0, method: "Not comparable", notes: ["could not be compared"])
        }
        var notes: [String] = []
        var edited = false
        if m.quarterTurns != 0 { notes.append("rotated \(m.quarterTurns * 90)°"); edited = true }
        if abs(m.angle) >= 1 { notes.append(String(format: "tilted %.0f°", m.angle)); edited = true }
        if m.coverage < 0.95 {
            let pct = Int(((1 - m.coverage) * 100).rounded())
            notes.append(m.otherIsInside ? "cropped (~\(pct)% removed)" : "shows ~\(pct)% more of the scene than the original")
            edited = true
        }
        if let fa = fingerprints[ro], let fb = fingerprints[ri] {
            let a = fa.stats, b = fb.stats
            let dy = b.meanY - a.meanY
            if abs(dy) > 0.03 { notes.append(dy > 0 ? "brighter" : "darker"); edited = true }
            let cr = b.stdY / max(a.stdY, 1e-3)
            if cr > 1.08 { notes.append("more contrast"); edited = true } else if cr < 0.92 { notes.append("less contrast"); edited = true }
            var colourShift: Float = 0
            if m.coverage >= 0.9 {
                // Compare the 8x8 colour maps in the aligned orientation.
                let ref = m.otherIsInside ? fa : fb, oth = m.otherIsInside ? fb : fa
                let (rcb, rcr) = ref.chromaMaps(quarterTurns: 0)
                let (ocb, ocr) = oth.chromaMaps(quarterTurns: m.otherIsInside ? m.quarterTurns : (4 - m.quarterTurns) % 4)
                for k in 0..<64 { colourShift += abs(rcb.px[k] - ocb.px[k]) + abs(rcr.px[k] - ocr.px[k]) }
                colourShift /= 64
            }
            if a.chroma > 0.02 && b.chroma < a.chroma * 0.3 { notes.append("black & white"); edited = true }
            else if colourShift > 0.025 || abs(b.meanCb - a.meanCb) > 0.015 || abs(b.meanCr - a.meanCr) > 0.015
                        || (a.chroma > 0.01 && abs(b.chroma / a.chroma - 1) > 0.15) {
                notes.append("colours changed / filter"); edited = true
            }
        }
        let pr = Double(img.meta.pixelCount) / Double(max(1, orig.meta.pixelCount))
        if pr < 0.95 && m.coverage >= 0.95 { notes.append("resized to \(Int((pr.squareRoot() * 100).rounded()))%") }
        if pr > 1.05 { notes.append("larger than the original (upscaled?)") }
        if img.meta.format != orig.meta.format { notes.append("converted \(orig.meta.format) → \(img.meta.format)") }
        if let qi = img.meta.jpegQuality, qi < (orig.meta.jpegQuality ?? 100) - 10 { notes.append("re-compressed (quality ~\(qi))") }
        if orig.meta.hasExif && !img.meta.hasExif { notes.append("metadata stripped") }
        if img.meta.editedBySoftware, let sw = img.meta.software { notes.append("exported by \(sw)") }
        if m.localDifference > 0.01 && m.localDifference <= settings.maxLocalDifference { notes.append("small local differences"); edited = true }
        if let cn = conflict { notes.append(cn) }

        var method = "pHash Δ\(m.hashDistance) → aligned SSIM \(Int((m.ssim * 100).rounded()))%"
        if m.quarterTurns != 0 { method += " · rotation-invariant" }
        if m.coverage < 0.95 { method += " · crop search" }
        if abs(m.angle) >= 1 { method += " · angle search" }

        let label: MemberLabel
        switch c {
        case .high, .exact: label = edited ? .edited : .visual
        default: label = .possible
        }
        return GroupMember(imageIndex: i, label: label, confidence: c == .none ? .low : c,
                           similarity: m.score, method: method, notes: notes)
    }

    /// Builds a group for the given images. `forcedOriginal` keeps the user's choice.
    func buildGroup(_ members: [Int], forcedOriginal: Int? = nil) -> DuplicateGroupResult {
        let choice = chooseOriginal(members)
        let o = forcedOriginal ?? choice.index
        let order: [MemberLabel: Int] = [.original: 0, .exact: 1, .visual: 2, .edited: 3, .possible: 4]
        var described = members.map { describe(original: o, member: $0) }
        described.sort {
            let a = order[$0.label] ?? 9, b = order[$1.label] ?? 9
            if a != b { return a < b }
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return images[$0.imageIndex].path < images[$1.imageIndex].path
        }
        var review = choice.manualReview
        var reason = choice.reviewReason
        if let f = forcedOriginal, f != choice.index {
            review = false
            reason = nil
        }
        if forcedOriginal == nil && repOf[o] == repOf[choice.index] && Set(members.map { repOf[$0] }).count == 1 {
            review = false     // only identical copies – any of them is the original
            reason = nil
        }
        return DuplicateGroupResult(members: described, recommendedIndex: choice.index,
                                    manualReview: review, reviewReason: reason,
                                    scope: scope(members), originalReasons: choice.reasons)
    }

    func scope(_ members: [Int]) -> GroupScope {
        let folders = Set(members.map { images[$0].folder })
        if folders.count <= 1 { return .sameFolder }
        let sorted = folders.sorted { $0.count < $1.count }
        let top = sorted[0] + "/"
        if sorted.dropFirst().allSatisfy({ $0.hasPrefix(top) }) { return .nested }
        return .acrossFolders
    }
}

/// Turns verified pairwise matches into duplicate groups without chaining weak links.
enum GroupBuilder {
    struct Edge {
        var a: Int
        var b: Int
        var confidence: Confidence
        var score: Float
    }

    static func build(reps: [Int], copies: [Int: [Int]], edges: [Edge], relabeler R: Relabeler) -> [DuplicateGroupResult] {
        let s = R.settings
        // 1. Union only high-confidence links.
        var parent: [Int: Int] = [:]
        for r in reps { parent[r] = r }
        func find(_ x: Int) -> Int {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        for e in edges where e.confidence >= .high {
            let ra = find(e.a), rb = find(e.b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var comps: [Int: [Int]] = [:]
        for r in reps { comps[find(r), default: []].append(r) }

        var groups: [[Int]] = []         // lists of reps
        var free = Set<Int>()
        func images(of repsList: [Int]) -> [Int] { repsList.flatMap { copies[$0] ?? [$0] } }

        // 2. Verify every member directly against the chosen original (star check).
        for (_, compReps) in comps.sorted(by: { $0.key < $1.key }) {
            if compReps.count == 1 {
                if (copies[compReps[0]]?.count ?? 1) > 1 { groups.append(compReps) } else { free.insert(compReps[0]) }
                continue
            }
            var keep = compReps
            for _ in 0..<2 {
                let orig = R.repOf[R.chooseOriginal(images(of: keep)).index]
                let verified = keep.filter { $0 == orig || R.confidence(orig, $0).0 >= .medium }
                if verified.count == keep.count { break }
                for r in keep where !verified.contains(r) { free.insert(r) }
                keep = verified
            }
            if keep.count == 1 && (copies[keep[0]]?.count ?? 1) == 1 { free.insert(keep[0]) } else { groups.append(keep) }
        }

        // 3. Attach leftover images to an existing group when they match that group's original.
        var neighbours: [Int: [Int]] = [:]
        for e in edges where e.confidence >= .low {
            neighbours[e.a, default: []].append(e.b)
            neighbours[e.b, default: []].append(e.a)
        }
        func attach(_ candidates: [Int]) {
            var groupOfRep: [Int: Int] = [:]
            for (gi, g) in groups.enumerated() { for r in g { groupOfRep[r] = gi } }
            var originals: [Int: Int] = [:]
            for f in candidates.sorted() where free.contains(f) {
                let gs = Set((neighbours[f] ?? []).compactMap { groupOfRep[$0] })
                var best: (gi: Int, score: Float)?
                for gi in gs {
                    let o = originals[gi] ?? R.repOf[R.chooseOriginal(images(of: groups[gi])).index]
                    originals[gi] = o
                    let (c, m, _) = R.confidence(o, f)
                    if c >= .low, let m = m, m.score > (best?.score ?? -1) { best = (gi, m.score) }
                }
                if let b = best {
                    groups[b.gi].append(f)
                    free.remove(f)
                    groupOfRep[f] = b.gi
                }
            }
        }
        attach(Array(free))

        // 4. Pair up remaining images that only have possible/likely matches among themselves.
        let looseEdges = edges.filter { $0.confidence >= .low && free.contains($0.a) && free.contains($0.b) }
            .sorted { $0.score > $1.score }
        for e in looseEdges where free.contains(e.a) && free.contains(e.b) {
            groups.append([e.a, e.b])
            free.remove(e.a)
            free.remove(e.b)
        }
        attach(Array(free))
        _ = s

        // 5. Describe.
        return groups.map { R.buildGroup(images(of: $0)) }
            .sorted { a, b in
                if a.members.count != b.members.count { return a.members.count > b.members.count }
                return R.images[a.recommendedIndex].path < R.images[b.recommendedIndex].path
            }
    }
}
