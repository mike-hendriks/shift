import CoreGraphics
import Foundation
import ImageIO

/// A decoded image, already oriented, resized and converted to sRGB.
struct PreparedImage {
    let cgImage: CGImage
    /// True when at least one pixel is not fully opaque.
    let isTransparent: Bool
}

enum ImageProcessor {
    /// Decodes, orients and optionally downsizes an image. Never upscales.
    static func load(_ url: URL, resize: ResizeMode? = nil) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let size = imagePixelSize(url) else {
            throw ShiftError.unreadable(url)
        }
        let longEdge = Int(max(size.width, size.height))
        var target = longEdge
        switch resize {
        case .percent(let p): target = longEdge * p / 100
        case .longEdge(let px): target = min(longEdge, px)
        case nil: break
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, target),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShiftError.unreadable(url)
        }
        return try toSRGB(image)
    }

    /// Redraws into an 8-bit sRGB bitmap so colours look the same in every browser, and checks for real transparency.
    private static func toSRGB(_ image: CGImage) throws -> PreparedImage {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ShiftError.failed("Could not create an sRGB bitmap")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var transparent = false
        if hasAlphaChannel(image), let data = ctx.data {
            let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            var i = 3
            let end = width * height * 4
            while i < end {
                if pixels[i] < 255 { transparent = true; break }
                i += 4
            }
        }
        guard let output = ctx.makeImage() else { throw ShiftError.failed("Could not convert the image") }
        return PreparedImage(cgImage: output, isTransparent: transparent)
    }

    private static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Encodes without metadata. JPEG output is flattened onto white.
    static func write(_ image: PreparedImage, as format: ImageFormat, quality: Double, to url: URL) throws {
        if format == .webp {
            try writeWebP(image.cgImage, quality: quality, to: url)
            return
        }
        var cgImage = image.cgImage
        if format == .jpeg, image.isTransparent { cgImage = flattened(cgImage) }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ShiftError.failed("\(format.displayName) is not supported")
        }
        var props: [CFString: Any] = [:]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ShiftError.failed("Could not save as \(format.displayName)") }
    }

    private static func flattened(_ image: CGImage) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    // MARK: WebP

    /// macOS can read WebP but not write it, so encoding goes through `cwebp` (brew install webp).
    static var cwebpPath: String? {
        let candidates = ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp", "/usr/bin/cwebp"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func writeWebP(_ image: CGImage, quality: Double, to url: URL) throws {
        guard let cwebp = cwebpPath else { throw ShiftError.missingTool("cwebp", install: "brew install webp") }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(PreparedImage(cgImage: image, isTransparent: true), as: .png, quality: 1, to: temp)

        let q = String(Int((quality * 100).rounded()))
        try run(cwebp, ["-quiet", "-q", q, "-m", "6", "-sharp_yuv", "-alpha_q", "90", "-metadata", "none",
                        temp.path, "-o", url.path])
    }

    // MARK: Images to PDF

    /// One page per image, each page sized to its image (long edge at most A4 height).
    static func combineIntoPDF(_ urls: [URL], to output: URL) throws {
        var mediaBox = CGRect.zero
        guard let ctx = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw ShiftError.failed("Could not create the PDF")
        }
        for url in urls {
            let image = try pdfReady(load(url, resize: .longEdge(3000)))
            let scale = min(1, 842 / CGFloat(max(image.width, image.height)))
            var page = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.beginPage(mediaBox: &page)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: page)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// Opaque images go through JPEG first: Quartz embeds JPEG-backed images as-is instead of as raw pixels.
    private static func pdfReady(_ image: PreparedImage) throws -> CGImage {
        guard !image.isTransparent else { return image.cgImage }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, ImageFormat.jpeg.utType.identifier as CFString, 1, nil) else {
            return image.cgImage
        }
        CGImageDestinationAddImage(dest, image.cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              let source = CGImageSourceCreateWithData(data, nil),
              let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return image.cgImage }
        return jpeg
    }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw ShiftError.failed("\((executable as NSString).lastPathComponent) faalde: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}
