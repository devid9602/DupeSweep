import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Pause / resume / cancel

/// Shared between the UI and worker threads. Workers call `checkpoint()` between items.
final class ScanControl: @unchecked Sendable {
    private let cond = NSCondition()
    private var paused = false
    private var cancelled = false
    private var pauseStart: Date?
    private var pausedTotal: TimeInterval = 0

    func pause() {
        cond.lock()
        if !paused { paused = true; pauseStart = Date() }
        cond.unlock()
    }

    func resume() {
        cond.lock()
        if paused {
            paused = false
            if let s = pauseStart { pausedTotal += Date().timeIntervalSince(s) }
            pauseStart = nil
        }
        cond.broadcast()
        cond.unlock()
    }

    func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelled }
    var isPaused: Bool { cond.lock(); defer { cond.unlock() }; return paused }

    /// Blocks while paused. Returns false once cancelled.
    func checkpoint() -> Bool {
        cond.lock()
        while paused && !cancelled { cond.wait() }
        let ok = !cancelled
        cond.unlock()
        return ok
    }

    /// Wall time since `start`, excluding time spent paused.
    func activeTime(since start: Date) -> TimeInterval {
        cond.lock()
        var p = pausedTotal
        if let s = pauseStart { p += Date().timeIntervalSince(s) }
        cond.unlock()
        return max(0, Date().timeIntervalSince(start) - p)
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = value; value += 1; return v }
    func add(_ n: Int) -> Int { lock.lock(); defer { lock.unlock() }; value += n; return value }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Fixed-size result buffer written from many threads (each index written by one worker).
final class Slots<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T?]
    init(_ count: Int) { items = [T?](repeating: nil, count: count) }
    func set(_ i: Int, _ v: T?) { lock.lock(); items[i] = v; lock.unlock() }
    func get(_ i: Int) -> T? { lock.lock(); defer { lock.unlock() }; return items[i] }
    var all: [T?] { lock.lock(); defer { lock.unlock() }; return items }
}

enum Parallel {
    static var workerCount: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }

    /// Runs `body(i)` for i in 0..<count on all cores, honouring pause/cancel.
    static func forEach(_ count: Int, control: ScanControl, _ body: (Int) -> Void) {
        guard count > 0 else { return }
        let next = AtomicCounter()
        let workers = min(workerCount, count)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while control.checkpoint() {
                let i = next.next()
                if i >= count { break }
                body(i)
            }
        }
    }
}

/// Throttles progress callbacks to ~8 per second.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let emit: (ScanProgress) -> Void
    private let control: ScanControl
    private let scanStart: Date
    private var stageStart = Date()
    private var base = ScanProgress()
    private var folderOrder: [String: Int] = [:]

    init(control: ScanControl, start: Date, emit: @escaping (ScanProgress) -> Void) {
        self.control = control
        self.scanStart = start
        self.emit = emit
    }

    func setFolders(_ folders: [String]) {
        lock.lock()
        folderOrder = [:]
        for (i, f) in folders.enumerated() { folderOrder[f] = i + 1 }
        base.folderCount = folders.count
        lock.unlock()
    }

    func beginStage(_ stage: Int, total: Int) {
        lock.lock()
        base.stage = stage
        base.stageName = ScanProgress.stageNames[stage]
        base.total = total
        base.done = 0
        base.stageETA = nil
        stageStart = Date()
        last = .distantPast
        lock.unlock()
        tick(done: 0, folder: nil, force: true)
    }

    func tick(done: Int, folder: String?, force: Bool = false) {
        lock.lock()
        let now = Date()
        if !force && now.timeIntervalSince(last) < 0.12 && done < base.total { lock.unlock(); return }
        last = now
        var p = base
        p.done = done
        if let f = folder {
            p.currentFolder = f
            p.folderIndex = folderOrder[f] ?? 0
            base.currentFolder = f
            base.folderIndex = p.folderIndex
        }
        p.elapsed = control.activeTime(since: scanStart)
        let stageActive = control.activeTime(since: stageStart)
        if done > 0 && p.total > done && stageActive > 0.5 {
            p.stageETA = stageActive / Double(done) * Double(p.total - done)
        }
        p.paused = control.isPaused
        lock.unlock()
        emit(p)
    }
}

// MARK: - Hashing

enum FileHasher {
    /// SHA-256 of the file contents, streamed in 1 MB chunks.
    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        #if canImport(CryptoKit)
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try h.read(upToCount: 1 << 20) } catch { return nil }
            guard let c = chunk, !c.isEmpty else { break }      // nil or empty = end of file
            hasher.update(data: c)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        var s = PortableSHA256()
        while true {
            let chunk: Data?
            do { chunk = try h.read(upToCount: 1 << 20) } catch { return nil }
            guard let c = chunk, !c.isEmpty else { break }
            s.update(c)
        }
        return s.finalize().map { String(format: "%02x", $0) }.joined()
        #endif
    }
}

#if !canImport(CryptoKit)
/// Minimal SHA-256 for platforms without CryptoKit (used by the Linux test harness).
struct PortableSHA256 {
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer = [UInt8]()
    private var length: UInt64 = 0
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
        0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
        0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    mutating func update(_ data: Data) {
        length += UInt64(data.count)
        buffer.append(contentsOf: data)
        var off = 0
        while buffer.count - off >= 64 { block(buffer, off); off += 64 }
        buffer.removeFirst(off)
    }

    mutating func finalize() -> [UInt8] {
        let bits = length * 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for i in (0..<8).reversed() { buffer.append(UInt8((bits >> (UInt64(i) * 8)) & 0xff)) }
        var off = 0
        while off < buffer.count { block(buffer, off); off += 64 }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }

    private mutating func block(_ b: [UInt8], _ o: Int) {
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(b[o + i * 4]) << 24 | UInt32(b[o + i * 4 + 1]) << 16 | UInt32(b[o + i * 4 + 2]) << 8 | UInt32(b[o + i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ PortableSHA256.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & bb) ^ (a & c) ^ (bb & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = bb; bb = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ bb; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
}
#endif

// MARK: - JPEG quality estimate

enum JPEGQuality {
    /// Standard IJG luminance quantisation table (quality 50).
    private static let stdLuma: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]

    /// Estimates the IJG-equivalent quality (1–100) from the first luminance DQT table.
    static func estimate(_ url: URL) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 256 * 1024) else { return nil }
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0xFF { i += 1; continue }
            if marker == 0xDA || marker == 0xD9 { break }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if len < 2 { return nil }
            if marker == 0xDB {
                var p = i + 4
                let end = min(b.count, i + 2 + len)
                while p < end {
                    let pq = b[p] >> 4, tq = b[p] & 0x0F
                    p += 1
                    var table: [Int] = []
                    for _ in 0..<64 {
                        if pq == 0 { if p < end { table.append(Int(b[p])) }; p += 1 } else {
                            if p + 1 < end { table.append(Int(b[p]) << 8 | Int(b[p + 1])) }; p += 2
                        }
                    }
                    if tq == 0 && table.count == 64 { return qualityFrom(table) }
                }
            }
            i += 2 + len
        }
        return nil
    }

    private static func qualityFrom(_ table: [Int]) -> Int {
        let target = table.reduce(0, +)
        var best = 50, bestDiff = Int.max
        for q in 1...100 {
            let scale = q < 50 ? 5000 / q : 200 - 2 * q
            var s = 0
            for v in stdLuma { s += min(255, max(1, (v * scale + 50) / 100)) }
            let d = abs(s - target)
            if d < bestDiff { bestDiff = d; best = q }
        }
        return best
    }
}

// MARK: - Fingerprint cache (compact binary file)

/// Everything computed for one file, reused while its size and modification time are unchanged.
struct CacheEntry {
    var size: Int64
    var mtime: Double
    var meta: ImageMetadata?
    var sha256: String?
    var fingerprint: Fingerprint?
    var failed: Bool
}

/// Identifies a cached pair verdict: both files' content keys plus the settings that affect alignment.
struct PairKey: Hashable {
    var a: UInt64
    var b: UInt64
    var settings: UInt32
}

final class FingerprintCache: @unchecked Sendable {
    private static let magic: UInt32 = 0x44535743      // "DSWC"
    private static let pairMagic: UInt32 = 0x50414933  // "PAI3"
    private let lock = NSLock()
    private var entries: [String: CacheEntry] = [:]
    private var pairs: [PairKey: PairMatch] = [:]

    /// Stable 64-bit key of a file version (path + size + modification time).
    static func contentKey(path: String, size: Int64, mtime: Double) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ b: UInt8) { h ^= UInt64(b); h = h &* 0x100000001b3 }
        for b in path.utf8 { mix(b) }
        var v = UInt64(bitPattern: size)
        for _ in 0..<8 { mix(UInt8(v & 0xff)); v >>= 8 }
        var t = mtime.bitPattern
        for _ in 0..<8 { mix(UInt8(t & 0xff)); t >>= 8 }
        return h
    }

    static func settingsKey(_ s: DetectionSettings) -> UInt32 {
        var h: UInt32 = 2166136261
        for v in [UInt32(Fingerprint.version), s.maxCrop.bitPattern, s.detectRotation ? 1 : 0, 8] { h = (h ^ v) &* 16777619 }
        return h
    }

    func pair(_ k: PairKey) -> PairMatch? { lock.lock(); defer { lock.unlock() }; return pairs[k] }
    func storePair(_ k: PairKey, _ m: PairMatch) { lock.lock(); pairs[k] = m; dirty = true; lock.unlock() }
    var pairCount: Int { lock.lock(); defer { lock.unlock() }; return pairs.count }
    private var dirty = false
    let url: URL?

    init(url: URL?) {
        self.url = url
        if let u = url { load(u) }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func lookup(_ path: String, size: Int64, mtime: Double) -> CacheEntry? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[path], e.size == size, abs(e.mtime - mtime) < 0.001 else { return nil }
        return e
    }

    func store(_ path: String, _ e: CacheEntry) {
        lock.lock(); entries[path] = e; dirty = true; lock.unlock()
    }

    func clear() {
        lock.lock(); entries = [:]; pairs = [:]; dirty = true; lock.unlock()
        save()
    }

    func save() {
        guard let u = url else { return }
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = entries
        let livePairs = pairs
        dirty = false
        lock.unlock()
        var liveKeys = Set<UInt64>()
        for (path, e) in snapshot { liveKeys.insert(FingerprintCache.contentKey(path: path, size: e.size, mtime: e.mtime)) }
        var w = BinaryWriter()
        w.u32(FingerprintCache.magic)
        w.u32(UInt32(Fingerprint.version))
        w.u32(UInt32(snapshot.count))
        for (path, e) in snapshot {
            w.str(path); w.i64(e.size); w.f64(e.mtime); w.u8(e.failed ? 1 : 0)
            w.optStr(e.sha256)
            if let m = e.meta {
                w.u8(1)
                w.i64(Int64(m.pixelWidth)); w.i64(Int64(m.pixelHeight)); w.str(m.format)
                w.optStr(m.make); w.optStr(m.model); w.optStr(m.software)
                w.optStr(m.dateTimeOriginal); w.optStr(m.subSecTimeOriginal)
                w.u8(m.hasExif ? 1 : 0); w.i64(Int64(m.jpegQuality ?? -1))
            } else { w.u8(0) }
            if let f = e.fingerprint {
                w.u8(1)
                w.u64(f.aHash); w.u64(f.dHash); w.u64(f.wHash); w.u64(f.centerHash)
                for q in 0..<4 { w.u64(f.pHash[q]) }
                for v in [f.stats.meanY, f.stats.stdY, f.stats.meanCb, f.stats.meanCr, f.stats.chroma, f.stats.sharpness, f.aspect] { w.f32(v) }
                w.data(f.thumb)
                w.data(f.colorMap)
            } else { w.u8(0) }
        }
        // Pair verdicts (only for files that still exist unchanged).
        let keep = livePairs.filter { liveKeys.contains($0.key.a) && liveKeys.contains($0.key.b) }
        w.u32(FingerprintCache.pairMagic)
        w.u32(UInt32(keep.count))
        for (k, m) in keep {
            w.u64(k.a); w.u64(k.b); w.u32(k.settings)
            w.u8(UInt8(m.quarterTurns)); w.u8(m.otherIsInside ? 1 : 0); w.u8(m.refined ? 1 : 0); w.u8(UInt8(min(64, m.hashDistance)))
            for v in [m.angle, m.coverage, m.ncc, m.structure, m.structureP10, m.ssim, m.localDifference, m.score, m.fx, m.cx, m.cy, m.fineLocal] { w.f32(v) }
        }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? w.bytes.write(to: u, options: .atomic)
    }

    private func load(_ u: URL) {
        guard let d = try? Data(contentsOf: u) else { return }
        var r = BinaryReader(d)
        guard r.u32() == FingerprintCache.magic, r.u32() == UInt32(Fingerprint.version) else { return }
        let n = Int(r.u32())
        var out: [String: CacheEntry] = [:]
        out.reserveCapacity(n)
        for _ in 0..<n {
            guard r.ok else { break }
            let path = r.str()
            var e = CacheEntry(size: r.i64(), mtime: r.f64(), meta: nil, sha256: nil, fingerprint: nil, failed: r.u8() == 1)
            e.sha256 = r.optStr()
            if r.u8() == 1 {
                var m = ImageMetadata()
                m.pixelWidth = Int(r.i64()); m.pixelHeight = Int(r.i64()); m.format = r.str()
                m.make = r.optStr(); m.model = r.optStr(); m.software = r.optStr()
                m.dateTimeOriginal = r.optStr(); m.subSecTimeOriginal = r.optStr()
                m.hasExif = r.u8() == 1
                let q = r.i64(); m.jpegQuality = q >= 0 ? Int(q) : nil
                e.meta = m
            }
            if r.u8() == 1 {
                let a = r.u64(), dh = r.u64(), wh = r.u64(), ch = r.u64()
                let ph = (0..<4).map { _ in r.u64() }
                let v = (0..<7).map { _ in r.f32() }
                let thumb = r.data()
                let cmap = r.data()
                e.fingerprint = Fingerprint(aHash: a, dHash: dh, wHash: wh, pHash: ph, centerHash: ch, thumb: thumb, colorMap: cmap,
                                            stats: ColorStats(meanY: v[0], stdY: v[1], meanCb: v[2], meanCr: v[3], chroma: v[4], sharpness: v[5]),
                                            aspect: v[6])
            }
            if r.ok { out[path] = e }
        }
        guard r.ok else { return }
        entries = out
        if r.u32() == FingerprintCache.pairMagic {
            let pc = Int(r.u32())
            var ps: [PairKey: PairMatch] = [:]
            for _ in 0..<pc {
                let k = PairKey(a: r.u64(), b: r.u64(), settings: r.u32())
                var m = PairMatch()
                m.quarterTurns = Int(r.u8()); m.otherIsInside = r.u8() == 1; m.refined = r.u8() == 1; m.hashDistance = Int(r.u8())
                m.angle = r.f32(); m.coverage = r.f32(); m.ncc = r.f32(); m.structure = r.f32()
                m.structureP10 = r.f32(); m.ssim = r.f32(); m.localDifference = r.f32(); m.score = r.f32()
                m.fx = r.f32(); m.cx = r.f32(); m.cy = r.f32(); m.fineLocal = r.f32()
                guard r.ok else { break }
                ps[k] = m
            }
            if r.ok { pairs = ps }
        }
    }
}

struct BinaryWriter {
    var bytes = Data()
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func data(_ d: Data) { u32(UInt32(d.count)); bytes.append(d) }
    mutating func str(_ s: String) { data(Data(s.utf8)) }
    mutating func optStr(_ s: String?) { if let s = s { u8(1); str(s) } else { u8(0) } }
}

struct BinaryReader {
    private let d: [UInt8]
    private var p = 0
    private(set) var ok = true
    init(_ data: Data) { d = [UInt8](data) }

    private mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard ok, n >= 0, p + n <= d.count else { ok = false; return nil }
        defer { p += n }
        return d[p..<(p + n)]
    }
    mutating func u8() -> UInt8 { take(1)?.first ?? 0 }
    mutating func u32() -> UInt32 {
        guard let s = take(4) else { return 0 }
        var v: UInt32 = 0
        for (i, b) in s.enumerated() { v |= UInt32(b) << (UInt32(i) * 8) }
        return v
    }
    mutating func u64() -> UInt64 {
        guard let s = take(8) else { return 0 }
        var v: UInt64 = 0
        for (i, b) in s.enumerated() { v |= UInt64(b) << (UInt64(i) * 8) }
        return v
    }
    mutating func i64() -> Int64 { Int64(bitPattern: u64()) }
    mutating func f64() -> Double { Double(bitPattern: u64()) }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
    mutating func data() -> Data { let n = Int(u32()); guard let s = take(n) else { return Data() }; return Data(s) }
    mutating func str() -> String { String(decoding: data(), as: UTF8.self) }
    mutating func optStr() -> String? { u8() == 1 ? str() : nil }
}
