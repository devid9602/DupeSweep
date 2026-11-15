import Foundation

/// User-tunable detection settings.
struct DetectionSettings: Codable, Equatable {
    var findSimilar = true             // visual stage on/off (exact duplicates are always found)
    var detectRotation = true          // 90°/180°/270° rotated versions
    var maxCrop: Float = 0.25          // largest crop tolerated per side (fraction of width/height)
    var highThreshold: Float = 0.80    // ≥ → same photograph, high confidence
    var mediumThreshold: Float = 0.70  // ≥ → likely, needs verification
    var lowThreshold: Float = 0.60     // ≥ → possible match
    var maxLocalDifference: Float = 0.025 // above this share of disagreeing regions, never "high"
    var maxFineDifference: Float = 0.035  // same, measured in the full-detail re-check
}

/// Result of aligning two images and measuring how alike they are.
struct PairMatch {
    var quarterTurns = 0          // clockwise quarter turns applied to `other` to align it with `ref`
    var angle: Float = 0          // residual fine rotation, degrees
    var coverage: Float = 1       // area of the smaller frame / area of the larger (1 = not cropped)
    var otherIsInside = true      // true: `other` is (a crop of) `ref`; false: `ref` is inside `other`
    var ncc: Float = 0            // global normalised cross-correlation
    var structure: Float = 0      // mean windowed structure correlation
    var structureP10: Float = 0   // 10th-percentile window — catches local differences (moved subjects)
    var ssim: Float = 0           // SSIM on contrast-normalised images
    var localDifference: Float = 0 // fraction of informative windows that disagree (moved subject, local edit)
    var hashDistance = 64
    var score: Float = 0          // combined similarity 0...1
    var refined = false           // passed the coarse gate and was fully aligned
    var lowDetail = false         // at least one image is nearly featureless (set by the caller)
    var fx: Float = 1             // alignment placement (for the full-detail re-check)
    var cx: Float = 0.5
    var cy: Float = 0.5
    var fineLocal: Float = -1     // share of disagreeing regions at full detail (-1 = not checked)

    var isTransformed: Bool { quarterTurns != 0 || abs(angle) >= 1 || coverage < 0.95 }
}

/// Pre-scaled views of one fingerprint in one orientation.
final class MatchView {
    let t64: GrayImage
    let t32: GrayImage
    let t16: GrayImage
    let aspect: Float
    /// Zero-mean, unit-norm 16x16 vectors of the full frame and of centred crops (88%, 76%).
    let probes: [[Float]]

    static let probeScales: [Float] = [1.0, 0.88, 0.76]
    /// Below this `detail`, an image is treated as featureless (see `detail(for:)`).
    static let lowDetailThreshold: Float = 0.04

    init(fp: Fingerprint, quarterTurns q: Int) {
        let base = Imaging.boxBlur3(Imaging.rotate(fp.thumbImage(), quarterTurns: q))
        t64 = base
        t32 = Imaging.resize(base, 32, 32)
        t16 = Imaging.resize(base, 16, 16)
        aspect = q % 2 == 1 ? 1 / fp.aspect : fp.aspect
        probes = MatchView.probes(base)
    }

    /// Amount of fine structure in the 64 px thumbnail, relative to its contrast.
    /// Near zero for featureless frames (clear sky, fog, blank wall, gradients) where
    /// low-resolution comparison cannot tell different photos apart.
    static func detail(for fp: Fingerprint) -> Float {
        let t = fp.thumbImage()
        let b = Imaging.boxBlur3(t)
        let n = t.width
        var sum: Float = 0, mean: Float = 0, sq: Float = 0
        var c: Float = 0
        for y in 2..<(n - 2) {
            for x in 2..<(n - 2) {
                let v = t.px[y * n + x]
                sum += abs(v - b.px[y * n + x]); mean += v; sq += v * v; c += 1
            }
        }
        mean /= c
        let sd = max(0, sq / c - mean * mean).squareRoot()
        return (sum / c) / (sd + 0.02)
    }

    /// Probe vectors of an upright fingerprint (no full MatchView needed).
    static func probes(for fp: Fingerprint) -> [[Float]] {
        probes(Imaging.boxBlur3(fp.thumbImage()))
    }

    private static func probes(_ base: GrayImage) -> [[Float]] {
        probeScales.map { s in
            let g = s >= 0.999 ? Imaging.resize(base, 16, 16)
                : Imaging.resize(Imaging.crop(base, x0: (1 - s) / 2, y0: (1 - s) / 2, x1: (1 + s) / 2, y1: (1 + s) / 2), 16, 16)
            return normalise(g.px)
        }
    }

    static func normalise(_ v: [Float]) -> [Float] {
        let m = v.reduce(0, +) / Float(v.count)
        var out = v.map { $0 - m }
        let n = out.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if n > 1e-6 { for i in 0..<out.count { out[i] /= n } }
        return out
    }

    /// Probes of the image rotated by quarter turns (pure index permutation of the 16x16 grids).
    static func rotatedProbes(_ probes: [[Float]], quarterTurns q: Int) -> [[Float]] {
        if q % 4 == 0 { return probes }
        return probes.map { Imaging.rotate(GrayImage(width: 16, height: 16, px: $0), quarterTurns: q).px }
    }

    @inline(__always) static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 0..<pa.count { s += pa[i] * pb[i] }
            }
        }
        return s
    }

    /// Best correlation between the two images allowing a centred crop of either one.
    static func probeScore(_ a: MatchView, _ b: MatchView) -> Float { probeScore(a.probes, b.probes) }

    static func probeScore(_ a: [[Float]], _ b: [[Float]]) -> Float {
        var best = dot(a[0], b[0])
        for k in 1..<a.count {
            best = max(best, dot(a[k], b[0]), dot(a[0], b[k]))
        }
        return best
    }
}

enum Matcher {
    struct Placement {
        var fx: Float
        var cx: Float
        var cy: Float
        var theta: Float      // degrees
    }

    private struct Frame {
        let fxMin: Float
        let fxMax: Float
        let refAspect: Float
        let movAspect: Float
        func fy(_ fx: Float) -> Float { fx * refAspect / movAspect }
    }

    /// Full comparison of two fingerprints: coarse search over every rotation/direction,
    /// early rejection, then refinement of the most promising alignment only.
    static func compare(_ a: Fingerprint, _ b: Fingerprint, settings: DetectionSettings,
                        views: (Int, Int) -> MatchView? = { _, _ in nil },
                        aIndex: Int = -1, bIndex: Int = -1) -> PairMatch {
        let (hintTurns, hd) = bestRotation(a, b, allowRotation: settings.detectRotation)
        var turns = [hintTurns]
        if hintTurns != 0 { turns.append(0) }
        let va = views(aIndex, 0) ?? MatchView(fp: a, quarterTurns: 0)

        struct Trial { let ref: MatchView; let mov: MatchView; let f: Frame; let q: Int; let inside: Bool; let seeds: [Placement]; let best: Float }
        var trials: [Trial] = []
        for q in turns {
            let vb = views(bIndex, q) ?? MatchView(fp: b, quarterTurns: q)
            for inside in [true, false] {
                let ref = inside ? va : vb, mov = inside ? vb : va
                guard let f = frame(ref: ref, mov: mov, maxCrop: settings.maxCrop) else { continue }
                let (seeds, best) = coarse(ref: ref, mov: mov, f: f)
                trials.append(Trial(ref: ref, mov: mov, f: f, q: q, inside: inside, seeds: seeds, best: best))
            }
        }
        var result = PairMatch()
        result.hashDistance = hd
        trials.sort { $0.best > $1.best }
        guard let top = trials.first else { return result }
        result.ncc = top.best
        if top.best < 0.5 { return result }                       // clearly different – skip refinement

        let identity = top.seeds.first.map { isIdentity($0, top.f) } ?? false
        let toRefine = (identity && top.best >= 0.95) ? [top] : Array(trials.prefix { $0.best >= top.best - 0.03 }.prefix(2))
        for t in toRefine {
            var m = refineAndMeasure(ref: t.ref, mov: t.mov, f: t.f, seeds: t.seeds, coarseBest: t.best)
            m.quarterTurns = t.q
            m.otherIsInside = t.inside
            m.hashDistance = hd
            m.refined = true
            if m.score > result.score || !result.refined { result = m }
        }
        return result
    }

    static func bestRotation(_ a: Fingerprint, _ b: Fingerprint, allowRotation: Bool) -> (Int, Int) {
        var bestQ = 0
        var bestD = PerceptualHash.distance(a.pHash[0], b.pHash[0])
        if allowRotation {
            for q in 1..<4 {
                let d = PerceptualHash.distance(a.pHash[0], b.pHash[q])
                if d < bestD - 2 { bestD = d; bestQ = q }       // prefer upright unless clearly better
            }
        }
        return (bestQ, bestD)
    }

    // MARK: - Alignment

    private static func frame(ref: MatchView, mov: MatchView, maxCrop: Float) -> Frame? {
        let minDim = 1 - maxCrop
        let fxMax = min(1, 1.03 * mov.aspect / ref.aspect)
        let fxMin = max(minDim, minDim * mov.aspect / ref.aspect)
        if fxMin > fxMax + 1e-4 { return nil }
        return Frame(fxMin: min(fxMin, fxMax), fxMax: fxMax, refAspect: ref.aspect, movAspect: mov.aspect)
    }

    private static func coarsePlacements(_ f: Frame, step: Float, cStep: Float) -> [Placement] {
        var fxs: [Float] = []
        var v = f.fxMax
        while v > f.fxMin + 1e-4 { fxs.append(v); v -= step }
        fxs.append(f.fxMin)
        var out: [Placement] = []
        for fx in fxs {
            let fy = min(1, f.fy(fx))
            for cx in centres(fx, cStep) {
                for cy in centres(fy, cStep) { out.append(Placement(fx: fx, cx: cx, cy: cy, theta: 0)) }
            }
        }
        return out
    }

    private static func centres(_ extent: Float, _ step: Float) -> [Float] {
        if extent >= 0.995 { return [0.5] }
        let lo = extent / 2, hi = 1 - extent / 2
        var r: [Float] = []
        var c = lo
        while c < hi - 1e-4 { r.append(c); c += step }
        r.append(hi)
        return r
    }

    private static func isIdentity(_ p: Placement, _ f: Frame) -> Bool {
        abs(p.fx - f.fxMax) < 1e-3 && abs(p.cx - 0.5) < 0.01 && abs(p.cy - 0.5) < 0.01 && abs(f.fy(p.fx) - 1) < 0.02
    }

    /// Level 1: 16 px grid search. Returns up to two distinct seeds and the best NCC.
    private static func coarse(ref: MatchView, mov: MatchView, f: Frame) -> ([Placement], Float) {
        var scored: [(Float, Placement)] = []
        for p in coarsePlacements(f, step: 0.04, cStep: 0.035) {
            scored.append((nccAt(ref: ref.t32, mov: mov.t16, f: f, p: p).0, p))
        }
        scored.sort { $0.0 > $1.0 }
        var seeds: [Placement] = []
        for (_, p) in scored {
            if seeds.count >= 2 { break }
            if !seeds.contains(where: { abs($0.fx - p.fx) < 0.03 && abs($0.cx - p.cx) < 0.04 && abs($0.cy - p.cy) < 0.04 }) {
                seeds.append(p)
            }
        }
        return (seeds, scored.first?.0 ?? -1)
    }

    /// Levels 2–3: coordinate descent at 32 px (incl. small rotation), polish at 64 px, then measure.
    private static func refineAndMeasure(ref: MatchView, mov: MatchView, f: Frame, seeds: [Placement], coarseBest: Float) -> PairMatch {
        var bestP = seeds.first ?? Placement(fx: f.fxMax, cx: 0.5, cy: 0.5, theta: 0)
        if !(isIdentity(bestP, f) && coarseBest >= 0.97) {
            var bestS: Float = -2
            for s in seeds {
                let (p, sc) = refine(ref: ref.t64, mov: mov.t32, f: f, start: s, steps: (0.02, 0.02, 2.0), rounds: 3)
                if sc > bestS { bestS = sc; bestP = p }
            }
        }
        let (fp, _) = refine(ref: ref.t64, mov: mov.t64, f: f, start: bestP, steps: (0.006, 0.006, 0.6), rounds: 1)
        return measure(ref: ref.t64, mov: mov.t64, f: f, p: fp)
    }

    private static func clampP(_ p: Placement, _ f: Frame) -> Placement {
        var q = p
        q.fx = min(max(q.fx, f.fxMin), f.fxMax)
        let fy = min(1, f.fy(q.fx))
        q.cx = min(max(q.cx, q.fx / 2 - 0.01), 1 - q.fx / 2 + 0.01)
        q.cy = min(max(q.cy, fy / 2 - 0.01), 1 - fy / 2 + 0.01)
        q.theta = min(max(q.theta, -6), 6)
        return q
    }

    private static func refine(ref: GrayImage, mov: GrayImage, f: Frame, start: Placement,
                               steps: (Float, Float, Float), rounds: Int) -> (Placement, Float) {
        var p = clampP(start, f)
        var s = penalised(nccAt(ref: ref, mov: mov, f: f, p: p))
        var (sf, sc, st) = steps
        for _ in 0..<rounds {
            var improved = true
            var guardCount = 0
            while improved && guardCount < 6 {
                improved = false
                guardCount += 1
                for k in 0..<4 {
                    for sign in [Float(1), Float(-1)] {
                        var q = p
                        switch k {
                        case 0: q.fx += sign * sf
                        case 1: q.cx += sign * sc
                        case 2: q.cy += sign * sc
                        default: q.theta += sign * st
                        }
                        q = clampP(q, f)
                        let v = penalised(nccAt(ref: ref, mov: mov, f: f, p: q))
                        if v > s + 1e-5 { s = v; p = q; improved = true }
                    }
                }
            }
            sf /= 2; sc /= 2; st /= 2
        }
        return (p, s)
    }

    private static func penalised(_ r: (Float, Float)) -> Float {
        let (ncc, invalid) = r
        return ncc - max(0, invalid - 0.02) * 2
    }

    /// Samples `ref` at the placement on an n×n grid matching `mov`. Returns values + validity.
    private static func warp(ref: GrayImage, n: Int, f: Frame, p: Placement,
                             into out: inout [Float], valid: inout [Bool]) -> Int {
        let k = p.fx * f.refAspect / f.movAspect
        let th = p.theta * Float.pi / 180
        let ct = cos(th), st = sin(th)
        let W = Float(ref.width), H = Float(ref.height)
        var count = 0
        for i in 0..<n {
            let dy = (Float(i) + 0.5) / Float(n) - 0.5
            for j in 0..<n {
                let dx = ((Float(j) + 0.5) / Float(n) - 0.5) * f.movAspect
                let rx = ct * dx - st * dy, ry = st * dx + ct * dy
                let xa = p.cx + k * rx / f.refAspect
                let ya = p.cy + k * ry
                let idx = i * n + j
                if xa < -0.015 || xa > 1.015 || ya < -0.015 || ya > 1.015 {
                    valid[idx] = false
                    continue
                }
                out[idx] = ref.bilinear(xa * W - 0.5, ya * H - 0.5)
                valid[idx] = true
                count += 1
            }
        }
        return count
    }

    /// (NCC over valid pixels, invalid fraction)
    private static func nccAt(ref: GrayImage, mov: GrayImage, f: Frame, p: Placement) -> (Float, Float) {
        let n = mov.width
        var buf = [Float](repeating: 0, count: n * n)
        var valid = [Bool](repeating: false, count: n * n)
        let c = warp(ref: ref, n: n, f: f, p: p, into: &buf, valid: &valid)
        if c < n * n / 2 { return (-1, 1) }
        return (ncc(buf, mov.px, valid), 1 - Float(c) / Float(n * n))
    }

    static func ncc(_ a: [Float], _ b: [Float], _ valid: [Bool]) -> Float {
        var sa: Double = 0, sb: Double = 0, c: Double = 0
        for i in 0..<a.count where valid[i] { sa += Double(a[i]); sb += Double(b[i]); c += 1 }
        guard c > 1 else { return -1 }
        let ma = sa / c, mb = sb / c
        var sab: Double = 0, saa: Double = 0, sbb: Double = 0
        for i in 0..<a.count where valid[i] {
            let x = Double(a[i]) - ma, y = Double(b[i]) - mb
            sab += x * y; saa += x * x; sbb += y * y
        }
        if saa < 1e-9 || sbb < 1e-9 { return (saa < 1e-9 && sbb < 1e-9) ? 1 : 0 }
        return Float(sab / (saa * sbb).squareRoot())
    }

    // MARK: - Final measurement

    private static func measure(ref: GrayImage, mov: GrayImage, f: Frame, p: Placement) -> PairMatch {
        let n = mov.width
        var r = [Float](repeating: 0, count: n * n)
        var valid = [Bool](repeating: false, count: n * n)
        let cnt = warp(ref: ref, n: n, f: f, p: p, into: &r, valid: &valid)
        var m = PairMatch()
        let fy = min(1, f.fy(p.fx))
        m.coverage = p.fx * fy
        m.angle = p.theta
        guard cnt > n * n / 2 else { return m }
        m.ncc = ncc(r, mov.px, valid)

        let rz = zscore(r, valid), mz = zscore(mov.px, valid)
        let scores = windowScores(r: r, m: mov.px, rz: rz, mz: mz, valid: valid, n: n, win: 8)
        m.fx = p.fx; m.cx = p.cx; m.cy = p.cy
        if !scores.isEmpty {
            m.structure = scores.reduce(0, +) / Float(scores.count)
            let sorted = scores.sorted()
            m.structureP10 = sorted[min(sorted.count - 1, sorted.count / 10)]
            m.localDifference = Float(scores.filter { $0 < 0.35 }.count) / Float(scores.count)
        }
        m.ssim = ssim(rz, mz, valid, n: n)
        m.score = combine(m)
        return m
    }

    /// Structure correlation of every informative window (flat-vs-flat compares levels,
    /// clipped highlights/shadows are ignored).
    private static func windowScores(r: [Float], m mov: [Float], rz: [Float], mz: [Float], valid: [Bool], n: Int, win: Int) -> [Float] {
        var scores: [Float] = []
        var y0 = 0
        while y0 < n {
            var x0 = 0
            while x0 < n {
                var c = 0
                var sa: Float = 0, sb: Float = 0, ra: Float = 0, rb: Float = 0
                for y in y0..<min(y0 + win, n) {
                    for x in x0..<min(x0 + win, n) where valid[y * n + x] {
                        let k = y * n + x
                        sa += rz[k]; sb += mz[k]; ra += r[k]; rb += mov[k]; c += 1
                    }
                }
                if c >= win * win * 2 / 3 {
                    let fc = Float(c)
                    let ma = sa / fc, mb = sb / fc
                    var vab: Float = 0, vaa: Float = 0, vbb: Float = 0
                    for y in y0..<min(y0 + win, n) {
                        for x in x0..<min(x0 + win, n) where valid[y * n + x] {
                            let da = rz[y * n + x] - ma, db = mz[y * n + x] - mb
                            vab += da * db; vaa += da * da; vbb += db * db
                        }
                    }
                    let sdA = (vaa / fc).squareRoot(), sdB = (vbb / fc).squareRoot()
                    let rawA = ra / fc, rawB = rb / fc
                    let flat: Float = 0.10
                    var s: Float? = nil
                    if sdA < flat && sdB < flat {
                        s = 1 - min(1, abs(ma - mb) / 0.5)                     // both flat: compare levels
                    } else if sdA < flat * 0.5 || sdB < flat * 0.5 {
                        // Texture vs flat. A flat side that is clipped to white/black carries no
                        // information (blown highlights after a brightness edit) – ignore it.
                        let clipped = (sdA < flat * 0.5 && (rawA > 0.9 || rawA < 0.08))
                                   || (sdB < flat * 0.5 && (rawB > 0.9 || rawB < 0.08))
                        s = clipped ? nil : 0
                    } else {
                        var v = vab / (vaa * vbb).squareRoot()
                        v *= 1 - min(1, abs(ma - mb) / 1.5) * 0.5               // penalise level shifts
                        s = v
                    }
                    if let v = s { scores.append(max(-1, min(1, v))) }
                }
                x0 += win
            }
            y0 += win
        }
        return scores
    }

    /// Full-detail re-check of an aligned pair: share of disagreeing regions at 128 px
    /// (catches moved subjects / different moments that a 64 px thumbnail can't see).
    /// `ref`/`mov` are upright luma images (≤ 256 px); `mov` already rotated to match.
    static var fineCut: Float = 0.5      // a window "disagrees" below this structure correlation

    static func fineLocalDifference(ref: GrayImage, mov: GrayImage, match m: PairMatch) -> Float {
        let n = 128
        let refB = Imaging.boxBlur3(ref)
        let movB = Imaging.boxBlur3(Imaging.resize(mov, n, n))
        let ra = Float(ref.width) / Float(ref.height), ma = Float(mov.width) / Float(mov.height)
        let f = Frame(fxMin: max(0.3, m.fx - 0.03), fxMax: min(1.2, m.fx + 0.03), refAspect: ra, movAspect: ma)
        let start = Placement(fx: m.fx, cx: m.cx, cy: m.cy, theta: m.angle)
        let (p, _) = refine(ref: refB, mov: movB, f: f, start: start, steps: (0.004, 0.004, 0.4), rounds: 2)
        var r = [Float](repeating: 0, count: n * n)
        var valid = [Bool](repeating: false, count: n * n)
        guard warp(ref: refB, n: n, f: f, p: p, into: &r, valid: &valid) > n * n / 2 else { return 1 }
        // Clipped highlights / shadows carry no detail – leave them out.
        for k in 0..<(n * n) where valid[k] {
            let a = r[k], b = movB.px[k]
            if a > 0.96 || b > 0.96 || a < 0.03 || b < 0.03 { valid[k] = false }
        }
        let rz = zscore(r, valid), mz = zscore(movB.px, valid)
        let scores = windowScores(r: r, m: movB.px, rz: rz, mz: mz, valid: valid, n: n, win: 8)
        guard scores.count >= 16 else { return 0 }
        return Float(scores.filter { $0 < fineCut }.count) / Float(scores.count)
    }

    static func combine(_ m: PairMatch) -> Float {
        let s = 0.30 * m.ncc + 0.25 * m.ssim + 0.25 * m.structure + 0.20 * max(m.structureP10, 0)
        return max(0, min(1, s))
    }

    private static func zscore(_ v: [Float], _ valid: [Bool]) -> [Float] {
        var s: Double = 0, ss: Double = 0, c: Double = 0
        for i in 0..<v.count where valid[i] { s += Double(v[i]); ss += Double(v[i] * v[i]); c += 1 }
        let mean = s / max(c, 1)
        let sd = max(1e-4, (ss / max(c, 1) - mean * mean)).squareRoot()
        return v.map { Float((Double($0) - mean) / sd) }
    }

    /// SSIM with 8x8 windows, stride 4, on z-normalised images.
    private static func ssim(_ a: [Float], _ b: [Float], _ valid: [Bool], n: Int) -> Float {
        let L: Float = 6, c1 = (0.01 * L) * (0.01 * L), c2 = (0.03 * L) * (0.03 * L)
        var total: Float = 0
        var count = 0
        var y0 = 0
        while y0 + 8 <= n {
            var x0 = 0
            while x0 + 8 <= n {
                var c: Float = 0, sa: Float = 0, sb: Float = 0
                for y in y0..<(y0 + 8) {
                    for x in x0..<(x0 + 8) where valid[y * n + x] { sa += a[y * n + x]; sb += b[y * n + x]; c += 1 }
                }
                if c >= 40 {
                    let ma = sa / c, mb = sb / c
                    var vaa: Float = 0, vbb: Float = 0, vab: Float = 0
                    for y in y0..<(y0 + 8) {
                        for x in x0..<(x0 + 8) where valid[y * n + x] {
                            let da = a[y * n + x] - ma, db = b[y * n + x] - mb
                            vaa += da * da; vbb += db * db; vab += da * db
                        }
                    }
                    vaa /= c; vbb /= c; vab /= c
                    total += ((2 * ma * mb + c1) * (2 * vab + c2)) / ((ma * ma + mb * mb + c1) * (vaa + vbb + c2))
                    count += 1
                }
                x0 += 4
            }
            y0 += 4
        }
        return count > 0 ? total / Float(count) : 0
    }
}
