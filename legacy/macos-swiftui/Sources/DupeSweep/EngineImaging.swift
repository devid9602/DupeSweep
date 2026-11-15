import Foundation

// Pure-Swift image primitives used by the detection engine.
// No AppKit/CoreGraphics here, so the engine can be unit-tested anywhere.

/// 8-bit RGBA pixels (already composited over white) produced by a decoder.
struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]          // width * height * 4
}

/// Single-channel float image, values roughly 0...1, row-major.
struct GrayImage {
    let width: Int
    let height: Int
    var px: [Float]

    init(width: Int, height: Int, px: [Float]) {
        self.width = width
        self.height = height
        self.px = px
    }

    init(width: Int, height: Int, fill: Float = 0) {
        self.width = width
        self.height = height
        self.px = [Float](repeating: fill, count: width * height)
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Float { px[y * width + x] }

    /// Bilinear sample at continuous pixel coordinates (pixel centres at integer + 0.5 convention handled by caller).
    @inline(__always) func bilinear(_ x: Float, _ y: Float) -> Float {
        let xc = min(max(x, 0), Float(width - 1))
        let yc = min(max(y, 0), Float(height - 1))
        let x0 = Int(xc), y0 = Int(yc)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = xc - Float(x0), fy = yc - Float(y0)
        let a = px[y0 * width + x0], b = px[y0 * width + x1]
        let c = px[y1 * width + x0], d = px[y1 * width + x1]
        return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
    }
}

/// Global tone/colour statistics of a decoded image (used to describe edits and judge quality).
struct ColorStats: Codable, Equatable {
    var meanY: Float
    var stdY: Float
    var meanCb: Float
    var meanCr: Float
    var chroma: Float        // mean saturation-like magnitude
    var sharpness: Float     // contrast-normalised mean |Laplacian|
}

enum Imaging {
    /// Converts RGBA to luma (Rec.601) and gathers colour statistics.
    /// Returns luma, global stats and 8x8 mean Cb / Cr maps.
    static func luma(_ img: RGBAImage) -> (GrayImage, ColorStats, [Float], [Float]) {
        let n = img.width * img.height
        var g = [Float](repeating: 0, count: n)
        var sumY: Double = 0, sumY2: Double = 0, sumCb: Double = 0, sumCr: Double = 0, sumC: Double = 0
        var mapCb = [Float](repeating: 0, count: 64), mapCr = [Float](repeating: 0, count: 64)
        var mapN = [Float](repeating: 0, count: 64)
        let W = img.width, H = img.height
        img.pixels.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let r = Float(p[i * 4]) / 255, gg = Float(p[i * 4 + 1]) / 255, b = Float(p[i * 4 + 2]) / 255
                let y = 0.299 * r + 0.587 * gg + 0.114 * b
                let cb = (b - y) * 0.564, cr = (r - y) * 0.713
                g[i] = y
                sumY += Double(y); sumY2 += Double(y * y)
                sumCb += Double(cb); sumCr += Double(cr)
                sumC += Double((cb * cb + cr * cr).squareRoot())
                let cell = min(7, (i / W) * 8 / H) * 8 + min(7, (i % W) * 8 / W)
                mapCb[cell] += cb; mapCr[cell] += cr; mapN[cell] += 1
            }
        }
        for c in 0..<64 where mapN[c] > 0 { mapCb[c] /= mapN[c]; mapCr[c] /= mapN[c] }
        let dn = Double(max(n, 1))
        let mean = sumY / dn
        let std = max(0, sumY2 / dn - mean * mean).squareRoot()
        let gray = GrayImage(width: img.width, height: img.height, px: g)
        let stats = ColorStats(meanY: Float(mean), stdY: Float(std),
                               meanCb: Float(sumCb / dn), meanCr: Float(sumCr / dn),
                               chroma: Float(sumC / dn),
                               sharpness: sharpness(gray, std: Float(std)))
        return (gray, stats, mapCb, mapCr)
    }

    static func sharpness(_ g: GrayImage, std: Float) -> Float {
        guard g.width > 2, g.height > 2 else { return 0 }
        var s: Double = 0
        for y in 1..<(g.height - 1) {
            for x in 1..<(g.width - 1) {
                let c = g.at(x, y) * 4
                let l = c - g.at(x - 1, y) - g.at(x + 1, y) - g.at(x, y - 1) - g.at(x, y + 1)
                s += Double(abs(l))
            }
        }
        let mean = Float(s / Double((g.width - 2) * (g.height - 2)))
        return mean / (std + 0.02)
    }

    /// Area-average downscale (bilinear when upscaling). Aspect ratio is NOT preserved.
    static func resize(_ g: GrayImage, _ w: Int, _ h: Int) -> GrayImage {
        if g.width == w && g.height == h { return g }
        var out = GrayImage(width: w, height: h)
        if g.width < w || g.height < h {
            let sx = Float(g.width) / Float(w), sy = Float(g.height) / Float(h)
            for y in 0..<h {
                for x in 0..<w {
                    out.px[y * w + x] = g.bilinear((Float(x) + 0.5) * sx - 0.5, (Float(y) + 0.5) * sy - 0.5)
                }
            }
            return out
        }
        // Box filter with fractional coverage.
        let sx = Double(g.width) / Double(w), sy = Double(g.height) / Double(h)
        var colW = [[(Int, Float)]](repeating: [], count: w)
        for x in 0..<w { colW[x] = spans(Double(x) * sx, Double(x + 1) * sx, g.width) }
        var rowW = [[(Int, Float)]](repeating: [], count: h)
        for y in 0..<h { rowW[y] = spans(Double(y) * sy, Double(y + 1) * sy, g.height) }
        // Horizontal pass
        var tmp = [Float](repeating: 0, count: w * g.height)
        for y in 0..<g.height {
            let row = y * g.width
            for x in 0..<w {
                var s: Float = 0, ws: Float = 0
                for (i, wt) in colW[x] { s += g.px[row + i] * wt; ws += wt }
                tmp[y * w + x] = s / max(ws, 1e-6)
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, ws: Float = 0
                for (i, wt) in rowW[y] { s += tmp[i * w + x] * wt; ws += wt }
                out.px[y * w + x] = s / max(ws, 1e-6)
            }
        }
        return out
    }

    private static func spans(_ a: Double, _ b: Double, _ limit: Int) -> [(Int, Float)] {
        var r: [(Int, Float)] = []
        var i = Int(a.rounded(.down))
        while Double(i) < b && i < limit {
            let lo = max(a, Double(i)), hi = min(b, Double(i + 1))
            if hi > lo { r.append((i, Float(hi - lo))) }
            i += 1
        }
        if r.isEmpty { r.append((min(max(Int(a), 0), limit - 1), 1)) }
        return r
    }

    /// Rotates by quarter turns clockwise.
    static func rotate(_ g: GrayImage, quarterTurns q: Int) -> GrayImage {
        let t = ((q % 4) + 4) % 4
        if t == 0 { return g }
        let W = g.width, H = g.height
        if t == 2 {
            var out = GrayImage(width: W, height: H)
            for i in 0..<(W * H) { out.px[i] = g.px[W * H - 1 - i] }
            return out
        }
        var out = GrayImage(width: H, height: W)        // new width = old height
        for y in 0..<W {
            for x in 0..<H {
                // clockwise: new(x, y) = old(y, H-1-x); counter-clockwise: new(x, y) = old(W-1-y, x)
                let v = t == 1 ? g.px[(H - 1 - x) * W + y] : g.px[x * W + (W - 1 - y)]
                out.px[y * H + x] = v
            }
        }
        return out
    }

    /// Crop by normalised rectangle (0...1).
    static func crop(_ g: GrayImage, x0: Float, y0: Float, x1: Float, y1: Float) -> GrayImage {
        let ax = max(0, min(g.width - 1, Int(x0 * Float(g.width))))
        let ay = max(0, min(g.height - 1, Int(y0 * Float(g.height))))
        let bx = max(ax + 1, min(g.width, Int((x1 * Float(g.width)).rounded(.up))))
        let by = max(ay + 1, min(g.height, Int((y1 * Float(g.height)).rounded(.up))))
        var out = GrayImage(width: bx - ax, height: by - ay)
        for y in ay..<by {
            for x in ax..<bx { out.px[(y - ay) * out.width + (x - ax)] = g.px[y * g.width + x] }
        }
        return out
    }

    static func boxBlur3(_ g: GrayImage) -> GrayImage {
        var out = g
        let W = g.width, H = g.height
        for y in 0..<H {
            for x in 0..<W {
                var s: Float = 0, c: Float = 0
                for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= H { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= W { continue }
                        s += g.px[yy * W + xx]; c += 1
                    }
                }
                out.px[y * W + x] = s / c
            }
        }
        return out
    }

    static func toBytes(_ g: GrayImage) -> Data {
        var d = Data(count: g.px.count)
        d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            for i in 0..<g.px.count { p[i] = UInt8(max(0, min(255, (g.px[i] * 255).rounded()))) }
        }
        return d
    }

    static func fromBytes(_ d: Data, width: Int, height: Int) -> GrayImage {
        var px = [Float](repeating: 0, count: width * height)
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let n = min(p.count, px.count)
            for i in 0..<n { px[i] = Float(p[i]) / 255 }
        }
        return GrayImage(width: width, height: height, px: px)
    }
}
