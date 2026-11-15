import Foundation

/// Compact visual fingerprint of one image. Everything needed for matching is here,
/// so it can be cached and later scans never need to decode unchanged files.
struct Fingerprint: Codable {
    static let version = 4
    static let thumbSide = 64

    var aHash: UInt64
    var dHash: UInt64
    var wHash: UInt64
    var pHash: [UInt64]        // pHash of the image rotated 0°, 90°, 180°, 270° clockwise
    var centerHash: UInt64     // pHash of the central 70% (crop-resistant candidate key)
    var thumb: Data            // 64x64 luma, aspect squashed, 8-bit
    var colorMap: Data         // 8x8 mean Cb then 8x8 mean Cr, 8-bit (128 = neutral)
    var stats: ColorStats
    var aspect: Float          // width / height of the upright image

    func thumbImage() -> GrayImage {
        Imaging.fromBytes(thumb, width: Fingerprint.thumbSide, height: Fingerprint.thumbSide)
    }

    /// (Cb, Cr) 8x8 maps in -0.5...0.5, rotated by quarter turns.
    func chromaMaps(quarterTurns q: Int) -> (GrayImage, GrayImage) {
        var cb = [Float](repeating: 0, count: 64), cr = [Float](repeating: 0, count: 64)
        colorMap.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard p.count >= 128 else { return }
            for i in 0..<64 { cb[i] = (Float(p[i]) - 128) / 254; cr[i] = (Float(p[64 + i]) - 128) / 254 }
        }
        return (Imaging.rotate(GrayImage(width: 8, height: 8, px: cb), quarterTurns: q),
                Imaging.rotate(GrayImage(width: 8, height: 8, px: cr), quarterTurns: q))
    }
}

enum PerceptualHash {
    @inline(__always) static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Builds the full fingerprint from a decoded (≤ ~256 px) RGBA image.
    static func fingerprint(_ rgba: RGBAImage) -> Fingerprint? {
        guard rgba.width >= 4, rgba.height >= 4 else { return nil }
        let (gray, stats, cbMap, crMap) = Imaging.luma(rgba)
        let t64 = Imaging.resize(gray, 64, 64)
        let t32 = Imaging.resize(gray, 32, 32)
        var ph: [UInt64] = []
        for q in 0..<4 { ph.append(pHash32(Imaging.rotate(t32, quarterTurns: q))) }
        let center = Imaging.resize(Imaging.crop(gray, x0: 0.15, y0: 0.15, x1: 0.85, y1: 0.85), 32, 32)
        return Fingerprint(aHash: aHash(t64), dHash: dHash(gray), wHash: wHash(t64), pHash: ph,
                           centerHash: pHash32(center), thumb: Imaging.toBytes(t64),
                           colorMap: Data((cbMap + crMap).map { UInt8(max(0, min(255, ($0 * 254 + 128).rounded()))) }), stats: stats,
                           aspect: Float(rgba.width) / Float(rgba.height))
    }

    /// Average hash: 8x8 block means compared with their mean.
    static func aHash(_ t64: GrayImage) -> UInt64 {
        let b = Imaging.resize(t64, 8, 8).px
        let mean = b.reduce(0, +) / Float(b.count)
        var h: UInt64 = 0
        for i in 0..<64 where b[i] > mean { h |= 1 << UInt64(i) }
        return h
    }

    /// Difference hash: horizontal gradient signs on a 9x8 grid.
    static func dHash(_ g: GrayImage) -> UInt64 {
        let s = Imaging.resize(g, 9, 8)
        var h: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if s.at(x, y) > s.at(x + 1, y) { h |= 1 << bit }
                bit += 1
            }
        }
        return h
    }

    /// Wavelet hash: Haar LL band (8x8 of a 64x64 image) with the DC removed, thresholded at its median.
    static func wHash(_ t64: GrayImage) -> UInt64 {
        // Three Haar levels on a 64x64 image leave an 8x8 LL band = scaled block means.
        var ll = t64.px
        var side = 64
        while side > 8 {
            let half = side / 2
            var next = [Float](repeating: 0, count: half * half)
            for y in 0..<half {
                for x in 0..<half {
                    let i = (2 * y) * side + 2 * x
                    next[y * half + x] = (ll[i] + ll[i + 1] + ll[i + side] + ll[i + side + 1]) * 0.5
                }
            }
            ll = next
            side = half
        }
        let mean = ll.reduce(0, +) / Float(ll.count)
        let centred = ll.map { $0 - mean }
        let med = median(centred)
        var h: UInt64 = 0
        for i in 0..<64 where centred[i] > med { h |= 1 << UInt64(i) }
        return h
    }

    /// DCT basis rows for the first 8 frequencies of a 32-point DCT-II.
    private static let dctRows: [[Float]] = (0..<8).map { k in
        (0..<32).map { n in Float(cos(Double.pi * Double(2 * n + 1) * Double(k) / 64.0)) }
    }

    /// Perceptual hash: low-frequency 8x8 DCT block (DC excluded), thresholded at the median.
    static func pHash32(_ g: GrayImage) -> UInt64 {
        precondition(g.width == 32 && g.height == 32)
        // T[u][x] = sum_y C[u][y] * g[y][x]
        var t = [Float](repeating: 0, count: 8 * 32)
        for u in 0..<8 {
            let cu = dctRows[u]
            for y in 0..<32 {
                let c = cu[y]
                let row = y * 32
                for x in 0..<32 { t[u * 32 + x] += c * g.px[row + x] }
            }
        }
        var coef = [Float](repeating: 0, count: 64)
        for u in 0..<8 {
            for v in 0..<8 {
                let cv = dctRows[v]
                var s: Float = 0
                for x in 0..<32 { s += t[u * 32 + x] * cv[x] }
                coef[u * 8 + v] = s
            }
        }
        let ac = Array(coef[1...])
        let med = median(ac)
        var h: UInt64 = 0
        for i in 1..<64 where coef[i] > med { h |= 1 << UInt64(i) }
        return h
    }

    static func median(_ v: [Float]) -> Float {
        let s = v.sorted()
        if s.isEmpty { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
