#if canImport(ImageIO) && canImport(CoreGraphics)
import Foundation
import ImageIO
import CoreGraphics

/// macOS image access through ImageIO: header metadata and fast downscaled decoding.
final class ImageIOProvider: ImageProvider {
    private static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "raw", "srw", "pef"]

    func readMetadata(_ url: URL) -> ImageMetadata? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var m = ImageMetadata()
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation >= 5 { m.pixelWidth = h; m.pixelHeight = w } else { m.pixelWidth = w; m.pixelHeight = h }
        m.format = ImageIOProvider.formatName(type: CGImageSourceGetType(src) as String?, ext: url.pathExtension.lowercased())

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        func clean(_ v: Any?) -> String? {
            guard let s = v as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}")))
            return t.isEmpty ? nil : t
        }
        m.make = clean(tiff?[kCGImagePropertyTIFFMake])
        m.model = clean(tiff?[kCGImagePropertyTIFFModel])
        m.software = clean(tiff?[kCGImagePropertyTIFFSoftware])
        m.dateTimeOriginal = clean(exif?[kCGImagePropertyExifDateTimeOriginal])
        m.subSecTimeOriginal = clean(exif?["SubsecTimeOriginal" as CFString])
        m.hasExif = m.dateTimeOriginal != nil || m.make != nil || m.model != nil
        return m
    }

    func decode(_ url: URL, maxSide: Int) -> RGBAImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,      // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return ImageIOProvider.rgba(cg)
    }

    /// Draws a CGImage into 8-bit sRGB RGBA, composited over white.
    static func rgba(_ cg: CGImage) -> RGBAImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(rect)
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: rect)
            return true
        }
        return ok ? RGBAImage(width: w, height: h, pixels: px) : nil
    }

    static func formatName(type: String?, ext: String) -> String {
        let t = (type ?? "").lowercased()
        if rawExtensions.contains(ext) || t.contains("raw-image") || t.contains("camera-raw") { return "RAW" }
        if t.contains("jpeg") || ["jpg", "jpeg", "jpe", "jfif"].contains(ext) { return "JPEG" }
        if t.contains("png") { return "PNG" }
        if t.contains("heic") || t.contains("heif") { return "HEIC" }
        if t.contains("webp") { return "WEBP" }
        if t.contains("tiff") { return "TIFF" }
        if t.contains("gif") { return "GIF" }
        if t.contains("bmp") { return "BMP" }
        return ext.uppercased()
    }
}
#endif
