import Foundation

/// Platform-specific image access (ImageIO on macOS; test sidecars on Linux). Must be thread-safe.
protocol ImageProvider: AnyObject {
    /// Header-only read: dimensions, format, EXIF. nil = unreadable/corrupt.
    func readMetadata(_ url: URL) -> ImageMetadata?
    /// Upright (EXIF-oriented) pixels, longest side ≤ maxSide, composited over white.
    func decode(_ url: URL, maxSide: Int) -> RGBAImage?
}

/// The five-stage duplicate detection pipeline.
final class ScanEngine {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "raw", "srw", "pef",
    ]
    static let decodeSide = 256

    let provider: ImageProvider
    let settings: DetectionSettings
    let cache: FingerprintCache
    var includeHidden = false

    init(provider: ImageProvider, settings: DetectionSettings, cache: FingerprintCache) {
        self.provider = provider
        self.settings = settings
        self.cache = cache
    }

    func run(roots: [ScanRoot], control: ScanControl, onProgress: @escaping (ScanProgress) -> Void) -> ScanReport {
        let scanStart = Date()
        let progress = ProgressReporter(control: control, start: scanStart, emit: onProgress)
        var stats = ScanStats()
        var stageStart = Date()
        func endStage(_ name: String) {
            stats.stageSeconds.append((name, control.activeTime(since: stageStart)))
            stageStart = Date()
        }
        func partial(_ images: [ScannedImage], _ folders: [String]) -> ScanReport {
            cache.save()
            return ScanReport(images: images, groups: [], folders: folders.map { FolderSummary(path: $0, imageCount: 0, duplicateCount: 0) },
                              stats: stats, cancelled: true, relabeler: nil)
        }

        // ── Stage 1: discovery + header metadata ───────────────────────────────
        progress.beginStage(1, total: 0)
        let (found, folderList) = discover(roots, control: control, progress: progress)
        stats.discovered = found.count
        progress.setFolders(folderList)
        if control.isCancelled { return partial([], folderList) }

        let n = found.count
        progress.beginStage(1, total: n)
        let metaSlots = Slots<CacheEntry>(n)
        let done1 = AtomicCounter()
        let hits = AtomicCounter()
        Parallel.forEach(n, control: control) { i in
            let f = found[i]
            if let e = cache.lookup(f.url.path, size: f.size, mtime: f.mtime) {
                metaSlots.set(i, e)
                _ = hits.add(1)
            } else {
                var e = CacheEntry(size: f.size, mtime: f.mtime, meta: nil, sha256: nil, fingerprint: nil, failed: false)
                if var m = provider.readMetadata(f.url), m.pixelWidth > 0, m.pixelHeight > 0 {
                    if m.format == "JPEG" { m.jpegQuality = JPEGQuality.estimate(f.url) }
                    e.meta = m
                } else {
                    e.failed = true
                }
                metaSlots.set(i, e)
                cache.store(f.url.path, e)
            }
            progress.tick(done: done1.add(1), folder: f.url.deletingLastPathComponent().path)
        }
        if control.isCancelled { return partial([], folderList) }
        stats.cacheHits = hits.current

        var images: [ScannedImage] = []
        var entryOf: [CacheEntry] = []
        for i in 0..<n {
            let f = found[i]
            guard let e = metaSlots.get(i), !e.failed, let m = e.meta else {
                stats.skipped.append((f.url.path, "unreadable or corrupted image"))
                continue
            }
            var img = ScannedImage(index: images.count, url: f.url, size: f.size, modified: f.modified, created: f.created)
            img.meta = m
            img.sha256 = e.sha256
            images.append(img)
            entryOf.append(e)
        }
        stats.valid = images.count
        endStage("1 Discovery & metadata")

        // ── Stage 2: exact duplicates (SHA-256 within equal file sizes) ────────
        let bySize = Dictionary(grouping: images.indices, by: { images[$0].size })
        let needSha = bySize.values.filter { $0.count > 1 }.flatMap { $0 }.filter { images[$0].sha256 == nil }
        progress.beginStage(2, total: needSha.count)
        let shaSlots = Slots<String>(needSha.count)
        let done2 = AtomicCounter()
        Parallel.forEach(needSha.count, control: control) { k in
            let i = needSha[k]
            shaSlots.set(k, FileHasher.sha256(images[i].url))
            progress.tick(done: done2.add(1), folder: images[i].folder)
        }
        if control.isCancelled { return partial(images, folderList) }
        for (k, i) in needSha.enumerated() {
            if let h = shaSlots.get(k) {
                images[i].sha256 = h
                entryOf[i].sha256 = h
                cache.store(images[i].path, entryOf[i])
            }
        }
        // Representatives: one image per identical-content cluster.
        var repOf = [Int](images.indices)
        var copies: [Int: [Int]] = [:]
        var firstWithSha: [String: Int] = [:]
        for i in images.indices {
            let multi = (bySize[images[i].size]?.count ?? 0) > 1
            if multi, let h = images[i].sha256 {
                if let r = firstWithSha[h] { repOf[i] = r } else { firstWithSha[h] = i }
            }
            copies[repOf[i], default: []].append(i)
        }
        let reps = images.indices.filter { repOf[$0] == $0 }
        stats.exactGroups = copies.values.filter { $0.count > 1 }.count
        endStage("2 Exact duplicates")

        // ── Stage 3: perceptual fingerprints ───────────────────────────────────
        var fingerprints: [Int: Fingerprint] = [:]
        if settings.findSimilar {
            let todo = reps.filter { entryOf[$0].fingerprint == nil }
            for r in reps { if let f = entryOf[r].fingerprint { fingerprints[r] = f } }
            progress.beginStage(3, total: todo.count)
            let fpSlots = Slots<Fingerprint>(todo.count)
            let done3 = AtomicCounter()
            Parallel.forEach(todo.count, control: control) { k in
                let i = todo[k]
                if let rgba = provider.decode(images[i].url, maxSide: ScanEngine.decodeSide),
                   let fp = PerceptualHash.fingerprint(rgba) {
                    fpSlots.set(k, fp)
                }
                progress.tick(done: done3.add(1), folder: images[i].folder)
            }
            if control.isCancelled {
                for (k, i) in todo.enumerated() {
                    if let fp = fpSlots.get(k) { entryOf[i].fingerprint = fp; cache.store(images[i].path, entryOf[i]) }
                }
                return partial(images, folderList)
            }
            for (k, i) in todo.enumerated() {
                if let fp = fpSlots.get(k) {
                    fingerprints[i] = fp
                    entryOf[i].fingerprint = fp
                    cache.store(images[i].path, entryOf[i])
                } else {
                    stats.skipped.append((images[i].path, "could not decode pixels (visual check skipped)"))
                }
            }
        }
        endStage("3 Fingerprints")

        let prov = provider
        let urls = images.map { $0.url }
        let relabeler = Relabeler(images: images, repOf: repOf, fingerprints: fingerprints, settings: settings, pairCache: cache,
                                  fineSource: { i in prov.decode(urls[i], maxSide: ScanEngine.decodeSide).map { Imaging.luma($0).0 } })
        var edges: [GroupBuilder.Edge] = []

        // ── Stage 4: candidate index + advanced validation ─────────────────────
        if settings.findSimilar {
            let fr = reps.filter { fingerprints[$0] != nil }
            let fps = fr.map { fingerprints[$0]! }
            let probes: [[[Float]]] = fps.map { MatchView.probes(for: $0) }
            let detail: [Float] = fps.map { MatchView.detail(for: $0) }
            let R = fr.count
            progress.beginStage(4, total: R)
            let candSlots = Slots<[(Int, Int, Int, Int)]>(R)   // (i, j, turns, hashDistance)
            let done4 = AtomicCounter()
            Parallel.forEach(R, control: control) { i in
                var list: [(Int, Int, Int, Int)] = []
                let fa = fps[i]
                var j = i + 1
                while j < R {
                    let fb = fps[j]
                    let (q, hd) = Matcher.bestRotation(fa, fb, allowRotation: settings.detectRotation)
                    let dc = PerceptualHash.distance(fa.centerHash, fb.centerHash)
                    if hd <= 28 || dc <= 26 {
                        let low = min(detail[i], detail[j]) < MatchView.lowDetailThreshold
                        var pass = false
                        if q != 0 {
                            pass = hd <= (low ? 4 : 12)                 // rotated copies keep a near-identical rotated pHash
                        } else if low {
                            pass = hd <= 4 && dc <= 6 && MatchView.probeScore(probes[i], probes[j]) >= 0.9
                        } else {
                            let ps = MatchView.probeScore(probes[i], probes[j])
                            let strong = hd <= 10 || dc <= 10
                            pass = (strong && ps >= 0.6) || ps >= 0.8 || ((hd <= 20 || dc <= 18) && ps >= 0.7)
                        }
                        if pass { list.append((i, j, q, hd)) }
                    }
                    j += 1
                }
                candSlots.set(i, list)
                progress.tick(done: done4.add(1), folder: images[fr[i]].folder)
            }
            if control.isCancelled { return partial(images, folderList) }
            let cands = candSlots.all.compactMap { $0 }.flatMap { $0 }
            stats.hashPairsScreened = R * (R - 1) / 2
            stats.candidatePairs = cands.count

            progress.beginStage(4, total: cands.count)
            let edgeLock = NSLock()
            var found4: [GroupBuilder.Edge] = []
            let validated = AtomicCounter()
            let done5 = AtomicCounter()
            Parallel.forEach(cands.count, control: control) { k in
                let (i, _, _, _) = cands[k]
                let a = fr[i], b = fr[cands[k].1]
                if let m = relabeler.match(a, b) {
                    if m.refined { _ = validated.add(1) }
                    let (c, _) = Classifier.confidence(m, images[a].meta, images[b].meta, settings)
                    if c >= .low {
                        edgeLock.lock()
                        found4.append(GroupBuilder.Edge(a: a, b: b, confidence: c, score: m.score))
                        edgeLock.unlock()
                    }
                }
                progress.tick(done: done5.add(1), folder: images[a].folder)
            }
            if control.isCancelled { return partial(images, folderList) }
            edges = found4
            stats.validatedPairs = validated.current
        }
        endStage("4 Similarity validation")

        // ── Stage 5: groups, originals, confidence ─────────────────────────────
        progress.beginStage(5, total: 1)
        let groups = GroupBuilder.build(reps: reps, copies: copies, edges: edges, relabeler: relabeler)
        var dupCount: [String: Int] = [:]
        var imgCount: [String: Int] = [:]
        for img in images { imgCount[img.folder, default: 0] += 1 }
        for g in groups {
            for m in g.members where m.label != .original { dupCount[images[m.imageIndex].folder, default: 0] += 1 }
        }
        let folders = folderList.map { FolderSummary(path: $0, imageCount: imgCount[$0] ?? 0, duplicateCount: dupCount[$0] ?? 0) }
        progress.tick(done: 1, folder: nil, force: true)
        endStage("5 Grouping")
        cache.save()
        return ScanReport(images: images, groups: groups, folders: folders, stats: stats, cancelled: false, relabeler: relabeler)
    }

    // MARK: - Discovery

    struct Found {
        let url: URL
        let size: Int64
        let mtime: Double
        let modified: Date?
        let created: Date?
    }

    private func discover(_ roots: [ScanRoot], control: ScanControl, progress: ProgressReporter) -> ([Found], [String]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        var seen = Set<String>()
        var folders = Set<String>()
        var out: [Found] = []
        for root in roots {
            let base = root.url.standardizedFileURL
            folders.insert(base.path)
            var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden { opts.insert(.skipsHiddenFiles) }
            if !root.recursive { opts.insert(.skipsSubdirectoryDescendants) }
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: opts) else { continue }
            var count = 0
            while let url = walker.nextObject() as? URL {
                count += 1
                if count % 200 == 0 {
                    if control.isCancelled { break }
                    progress.tick(done: out.count, folder: url.deletingLastPathComponent().path)
                }
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true {
                    if root.recursive { folders.insert(url.standardizedFileURL.path) }
                    continue
                }
                guard v.isRegularFile == true, ScanEngine.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let real = url.resolvingSymlinksInPath().standardizedFileURL
                guard seen.insert(real.path).inserted else { continue }
                let mod = v.contentModificationDate
                out.append(Found(url: real, size: Int64(v.fileSize ?? 0), mtime: mod?.timeIntervalSince1970 ?? 0,
                                 modified: mod, created: v.creationDate))
            }
        }
        out.sort {
            let fa = $0.url.deletingLastPathComponent().path, fb = $1.url.deletingLastPathComponent().path
            return fa != fb ? fa < fb : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        return (out, folders.sorted())
    }
}
