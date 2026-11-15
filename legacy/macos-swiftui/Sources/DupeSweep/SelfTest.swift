#if canImport(ImageIO) && canImport(CoreGraphics)
import Foundation
import ImageIO
import CoreGraphics

/// Command-line tools:
///   DupeSweep --selftest [photo or folder …]   builds every test scenario from your photos and grades the engine
///   DupeSweep --benchmark <folder>             read-only timing + summary of a real library (cold and warm cache)
enum SelfTest {
    private struct Variant {
        var img: CGImage?
        var rel: String
        var type: String
        var q: Double
        var role: String
        var exif: (String, String, String?)?
    }

    // MARK: Entry points

    static func run(_ args: [String]) {
        let sources = collectSources(args)
        guard sources.count >= 2 else {
            print("Usage: DupeSweep --selftest <folder with at least 2 photos>   (or list photo files)")
            print("Found \(sources.count) usable photo(s). Each must be at least 600 px on its long side.")
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DupeSweep-SelfTest-\(stamp)", isDirectory: true)
        let lib = root.appendingPathComponent("library", isDirectory: true)
        print("Building test library from \(sources.count) photos in \(lib.path) …")
        guard let truth = buildLibrary(sources: sources, lib: lib) else { print("Could not build the test library."); return }

        let cache = FingerprintCache(url: root.appendingPathComponent("cache.bin"))
        let engine = ScanEngine(provider: ImageIOProvider(), settings: DetectionSettings(), cache: cache)
        let t0 = Date()
        let report = engine.run(roots: [ScanRoot(url: lib, recursive: true)], control: ScanControl()) { _ in }
        let secs = Date().timeIntervalSince(t0)
        print("")
        print(Evaluation.textReport(report: report, truth: truth, libraryRoot: lib.path, seconds: secs))
        print("")
        print("Test library kept at: \(lib.path)  (open it in the app to see the results visually)")
    }

    static func benchmark(_ args: [String]) {
        guard let path = args.first else { print("Usage: DupeSweep --benchmark <folder>"); return }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DupeSweep-bench-\(Int(Date().timeIntervalSince1970)).bin")
        print("Benchmark of \(folder.path) – read-only, nothing is moved or deleted.")
        print("Cores: \(Parallel.workerCount)")
        for pass in ["Cold (empty cache)", "Warm (cached rescan)"] {
            let engine = ScanEngine(provider: ImageIOProvider(), settings: DetectionSettings(), cache: FingerprintCache(url: tmp))
            var lastStage = 0
            let t0 = Date()
            let r = engine.run(roots: [ScanRoot(url: folder, recursive: true)], control: ScanControl()) { p in
                if p.stage != lastStage { lastStage = p.stage; print("   … stage \(p.stage): \(p.stageName)") }
            }
            let secs = Date().timeIntervalSince(t0)
            let members = r.groups.flatMap { $0.members }
            func n(_ l: MemberLabel) -> Int { members.filter { $0.label == l }.count }
            print("")
            print("== \(pass): \(String(format: "%.1f", secs)) s ==")
            print("Images: \(r.stats.valid) valid of \(r.stats.discovered) found, \(r.stats.skipped.count) skipped, cache hits \(r.stats.cacheHits)")
            print("Groups: \(r.groups.count) (manual review \(r.groups.filter { $0.manualReview }.count))")
            print("Exact \(n(.exact)) · Visual \(n(.visual)) · Edited \(n(.edited)) · Possible \(n(.possible))")
            for (name, s) in r.stats.stageSeconds { print(String(format: "  %@: %.1f s", name, s)) }
            print("  pairs screened \(r.stats.hashPairsScreened), candidates \(r.stats.candidatePairs), validated \(r.stats.validatedPairs)")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Library construction

    private static func collectSources(_ args: [String]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for a in args {
            let u = URL(fileURLWithPath: (a as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let list = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                files += list.filter { ["jpg", "jpeg", "heic", "png", "tif", "tiff"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            } else {
                files.append(u)
            }
        }
        // The test needs distinct photographs: skip any photo that the engine itself sees as
        // the same scene as one already chosen (burst shots, re-saved copies, …).
        let provider = ImageIOProvider()
        var ok: [URL] = []
        var chosen: [(Fingerprint, ImageMetadata)] = []
        for f in files {
            if ok.count >= 6 { break }
            guard let m = provider.readMetadata(f), max(m.pixelWidth, m.pixelHeight) >= 600,
                  let rgba = provider.decode(f, maxSide: ScanEngine.decodeSide),
                  let fp = PerceptualHash.fingerprint(rgba) else { continue }
            var similarTo: Int? = nil
            for (k, c) in chosen.enumerated() {
                let pm = Matcher.compare(c.0, fp, settings: DetectionSettings())
                if pm.score >= 0.6 || pm.hashDistance <= 12 { similarTo = k; break }
            }
            if let k = similarTo {
                print("Note: \(f.lastPathComponent) looks like the same scene as \(ok[k].lastPathComponent) – using only one of them.")
                continue
            }
            ok.append(f)
            chosen.append((fp, m))
        }
        return ok
    }

    private static func buildLibrary(sources: [URL], lib: URL) -> TestTruth? {
        var truth = TestTruth(files: [:], expect_groups: [], expect_separate: [])
        let bases = sources.compactMap { load($0, maxSide: 2400) }
        guard bases.count >= 2 else { return nil }
        let photos = Array(bases.dropLast())          // last photo is used for negatives/patches
        let other = bases[bases.count - 1]

        func add(_ img: CGImage?, _ rel: String, type: String = "public.jpeg", q: Double = 0.92,
                 exif: (String, String, String?)? = nil, role: String, photo: String) -> String? {
            guard let img = img else { return nil }
            let url = lib.appendingPathComponent(rel)
            guard write(img, to: url, type: type, quality: q, exif: exif) else { return nil }
            truth.files[rel] = TestTruth.FileInfo(photo: photo, role: role)
            return rel
        }

        for (n, base) in photos.enumerated() {
            let pid = "P0\(n + 1)"
            let dto = "2023:0\(1 + n % 9):1\(n % 10) 10:2\(n % 10):3\(n % 10)"
            var members: [String] = []
            guard let orig = add(base, "Camera/2023/IMG_\(1000 + n).JPG", q: 0.95, exif: (dto, "12", nil), role: "original", photo: pid) else { continue }
            members.append(orig)
            // Exact copy under another name and folder.
            let copyRel = "Backup/Phone dump/photo_\(n).jpg"
            let copyURL = lib.appendingPathComponent(copyRel)
            try? FileManager.default.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: lib.appendingPathComponent(orig), to: copyURL)) != nil {
                truth.files[copyRel] = TestTruth.FileInfo(photo: pid, role: "exact"); members.append(copyRel)
            }
            let lightroom: (String, String, String?) = (dto, "12", "Adobe Lightroom 6.0")
            let photoshop: (String, String, String?) = (dto, "12", "Adobe Photoshop CC 2019 (Macintosh)")
            let bright = pixels(base) { r, g, b in tone(&r, &g, &b, brightness: 1.2, contrast: 1.3) }
            let filtered = pixels(base) { r, g, b in
                if n % 2 == 0 { sepia(&r, &g, &b) } else { tealOrange(&r, &g, &b) }
            }
            let exported = tilted(pixels(base) { r, g, b in tone(&r, &g, &b, brightness: 1.05, contrast: 1.1) }, 3)
            var variants: [Variant] = []
            variants.append(Variant(img: resized(base, 0.4), rel: "Exports/Small/\(pid)_small.jpg", type: "public.jpeg", q: 0.85, role: "resized", exif: nil))
            variants.append(Variant(img: bright, rel: "Edited/\(pid)_bright.jpg", type: "public.jpeg", q: 0.9, role: "tone", exif: lightroom))
            variants.append(Variant(img: filtered, rel: "Edited/Filters/\(pid)_filter.jpg", type: "public.jpeg", q: 0.88, role: "filter", exif: nil))
            variants.append(Variant(img: resized(base, 0.66), rel: "WhatsApp Images/IMG-2023-WA000\(n).jpg", type: "public.jpeg", q: 0.35, role: "compressed", exif: nil))
            variants.append(Variant(img: base, rel: "Converted/\(pid).png", type: "public.png", q: 1, role: "png", exif: nil))
            variants.append(Variant(img: resized(base, 0.5), rel: "Converted/\(pid).heic", type: "public.heic", q: 0.7, role: "heic", exif: nil))
            variants.append(Variant(img: base, rel: "Converted/\(pid).tif", type: "public.tiff", q: 1, role: "tiff", exif: nil))
            variants.append(Variant(img: cropped(base, 0.88, 0.4, 0.55), rel: "Edited/\(pid)_crop.jpg", type: "public.jpeg", q: 0.9, role: "crop", exif: nil))
            variants.append(Variant(img: rotated90(base), rel: "Edited/\(pid)_rot90.jpg", type: "public.jpeg", q: 0.9, role: "rot90", exif: nil))
            variants.append(Variant(img: exported, rel: "Exports/Photoshop/\(pid)_export.jpg", type: "public.jpeg", q: 0.85, role: "rot_small", exif: photoshop))
            variants.append(Variant(img: base, rel: "Albums/2023/Trip/Day 2/\(pid)_dup.jpg", type: "public.jpeg", q: 0.8, role: "nested", exif: nil))
            for v in variants {
                if let rel = add(v.img, v.rel, type: v.type, q: v.q, exif: v.exif, role: v.role, photo: pid) { members.append(rel) }
            }
            truth.expect_groups.append(TestTruth.Group(photo: pid, original: orig, members: members))
        }

        // PNG original converted to JPG.
        if let png = add(other, "Scans/scan.png", type: "public.png", q: 1, role: "original", photo: "P99"),
           let jpg = add(other, "Converted/scan.jpg", q: 0.88, role: "png2jpg", photo: "P99") {
            truth.expect_groups.append(TestTruth.Group(photo: "P99", original: png, members: [png, jpg]))
        }

        // Negatives: halves of one scene (similar colours/background) and a burst with a moving subject.
        let w = other.width, h = other.height
        if let l = other.cropping(to: CGRect(x: 0, y: 0, width: w / 2, height: h)),
           let r = other.cropping(to: CGRect(x: w / 2, y: 0, width: w - w / 2, height: h)),
           let a = add(l, "Landscapes/left.jpg", role: "neg", photo: "N1a"), let b = add(r, "Landscapes/right.jpg", role: "neg", photo: "N1b") {
            truth.expect_separate.append([a, b])
        }
        if let scene = cropped(mirrored(photos[0]), 0.8, 0.3, 0.6),
           let patch = other.cropping(to: CGRect(x: w / 3, y: h / 3, width: min(w, h) / 4, height: min(w, h) / 4)) {
            let pw = CGFloat(scene.width) / 6
            let a = paste(patch, on: scene, at: CGPoint(x: CGFloat(scene.width) * 0.15, y: CGFloat(scene.height) * 0.35), side: pw)
            let b = paste(patch, on: scene, at: CGPoint(x: CGFloat(scene.width) * 0.27, y: CGFloat(scene.height) * 0.33), side: pw)
            if let x = add(a, "Burst/burst_1.jpg", exif: ("2023:07:04 18:30:05", "10", nil), role: "neg", photo: "N2a"),
               let y = add(b, "Burst/burst_2.jpg", exif: ("2023:07:04 18:30:05", "43", nil), role: "neg", photo: "N2b") {
                truth.expect_separate.append([x, y])
            }
            if let x = add(a, "Burst/no_exif_1.jpg", q: 0.9, role: "neg", photo: "N2a"),
               let y = add(b, "Burst/no_exif_2.jpg", q: 0.9, role: "neg", photo: "N2b") {
                truth.expect_separate.append([x, y])
            }
        }
        // A corrupt file must be skipped gracefully.
        let broken = lib.appendingPathComponent("Misc/broken.jpg")
        try? FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00]).write(to: broken)
        return truth
    }

    // MARK: Image helpers (CoreGraphics only)

    static func load(_ url: URL, maxSide: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    static func resized(_ img: CGImage, _ s: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(img.width) * s)), h = max(1, Int(CGFloat(img.height) * s))
        guard let ctx = context(w, h) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func cropped(_ img: CGImage?, _ f: CGFloat, _ cx: CGFloat, _ cy: CGFloat) -> CGImage? {
        guard let img = img else { return nil }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let cw = w * f, ch = h * f
        return img.cropping(to: CGRect(x: ((w - cw) * cx).rounded(), y: ((h - ch) * cy).rounded(), width: cw.rounded(), height: ch.rounded()))
    }

    static func rotated90(_ img: CGImage) -> CGImage? {
        guard let ctx = context(img.height, img.width) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(img.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    static func mirrored(_ img: CGImage) -> CGImage? {
        guard let ctx = context(img.width, img.height) else { return nil }
        ctx.translateBy(x: CGFloat(img.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    static func tilted(_ img: CGImage?, _ degrees: CGFloat) -> CGImage? {
        guard let img = img, let ctx = context(img.width, img.height) else { return nil }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        ctx.translateBy(x: w / 2, y: h / 2)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.translateBy(x: -w / 2, y: -h / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return cropped(ctx.makeImage(), 0.9, 0.5, 0.5)
    }

    static func paste(_ patch: CGImage, on base: CGImage?, at p: CGPoint, side: CGFloat) -> CGImage? {
        guard let base = base, let ctx = context(base.width, base.height) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.draw(patch, in: CGRect(x: p.x, y: p.y, width: side, height: side))
        return ctx.makeImage()
    }

    /// Applies a per-pixel colour operation (values 0…1).
    static func pixels(_ img: CGImage, _ op: (inout Float, inout Float, inout Float) -> Void) -> CGImage? {
        guard var rgba = ImageIOProvider.rgba(img) else { return nil }
        for i in stride(from: 0, to: rgba.pixels.count, by: 4) {
            var r = Float(rgba.pixels[i]) / 255, g = Float(rgba.pixels[i + 1]) / 255, b = Float(rgba.pixels[i + 2]) / 255
            op(&r, &g, &b)
            rgba.pixels[i] = UInt8(max(0, min(255, r * 255)))
            rgba.pixels[i + 1] = UInt8(max(0, min(255, g * 255)))
            rgba.pixels[i + 2] = UInt8(max(0, min(255, b * 255)))
        }
        let w = rgba.width, h = rgba.height
        var data = rgba.pixels
        return data.withUnsafeMutableBytes { buf -> CGImage? in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return ctx?.makeImage()
        }
    }

    static func tone(_ r: inout Float, _ g: inout Float, _ b: inout Float, brightness: Float, contrast: Float) {
        r = (r * brightness - 0.5) * contrast + 0.5
        g = (g * brightness - 0.5) * contrast + 0.5
        b = (b * brightness - 0.5) * contrast + 0.5
    }

    static func sepia(_ r: inout Float, _ g: inout Float, _ b: inout Float) {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        r = y * 1.07 + 0.08; g = y * 0.95 + 0.03; b = y * 0.72
    }

    static func tealOrange(_ r: inout Float, _ g: inout Float, _ b: inout Float) {
        r = powf(max(r, 0), 0.85); b = powf(max(b, 0), 1.2) * 0.85 + 0.12
    }

    static func write(_ img: CGImage, to url: URL, type: String, quality: Double, exif: (String, String, String?)?) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let e = exif {
            let (dto, subsec, software) = e
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dto,
                                                     "SubsecTimeOriginal" as CFString: subsec] as [CFString: Any]
            var tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS 80D"]
            if let s = software { tiff[kCGImagePropertyTIFFSoftware] = s }
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        let ok = CGImageDestinationFinalize(dest)
        if !ok { try? FileManager.default.removeItem(at: url) }
        return ok
    }
}
#endif
