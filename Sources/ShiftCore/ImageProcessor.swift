import CoreGraphics
import Foundation
import ImageIO
import libwebp

/// A decoded image, already oriented, resized and converted to sRGB.
struct PreparedImage {
    let cgImage: CGImage
    /// True when at least one pixel is not fully opaque.
    let isTransparent: Bool
}

enum ImageProcessor {
    /// Decodes, orients, optionally crops and downsizes an image. Never upscales.
    static func load(_ url: URL, crop: ImageCrop = ImageCrop(), resize: ResizeMode? = nil) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let size = imagePixelSize(url) else {
            throw ShiftError.unreadable(url)
        }
        if !crop.isEmpty { return try loadCropped(source, size: size, crop: crop, resize: resize, url: url) }

        let longEdge = Int(max(size.width, size.height))
        let target = targetLongEdge(longEdge, resize)
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

    private static func targetLongEdge(_ longEdge: Int, _ resize: ResizeMode?) -> Int {
        switch resize {
        case .percent(let p): return longEdge * p / 100
        case .longEdge(let px): return min(longEdge, px)
        case nil: return longEdge
        }
    }

    /// Crops at full resolution, so pixel amounts match the original, then scales the rest.
    private static func loadCropped(_ source: CGImageSource, size: CGSize, crop: ImageCrop, resize: ResizeMode?,
                                    url: URL) throws -> PreparedImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)),
        ]
        guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShiftError.unreadable(url)
        }
        guard let rect = crop.rect(in: CGSize(width: full.width, height: full.height)), let cropped = full.cropping(to: rect) else {
            throw ShiftError.failed("\(url.lastPathComponent) is \(full.width)×\(full.height) px, too small for \(crop.summary)")
        }
        let longEdge = max(cropped.width, cropped.height)
        let scale = CGFloat(targetLongEdge(longEdge, resize)) / CGFloat(longEdge)
        let target = CGSize(width: max(1, (CGFloat(cropped.width) * scale).rounded()),
                            height: max(1, (CGFloat(cropped.height) * scale).rounded()))
        return try toSRGB(cropped, size: target)
    }

    /// Redraws into an 8-bit sRGB bitmap so colours look the same in every browser, and checks for real transparency.
    private static func toSRGB(_ image: CGImage, size: CGSize? = nil) throws -> PreparedImage {
        let width = Int(size?.width ?? CGFloat(image.width)), height = Int(size?.height ?? CGFloat(image.height))
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

    /// macOS reads WebP but cannot write it, so Shift encodes with libwebp, built into the app.
    /// Same settings as `cwebp -m 6 -sharp_yuv -alpha_q 90`; no metadata is written.
    private static func writeWebP(_ image: CGImage, quality: Double, to url: URL) throws {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ShiftError.failed("Could not prepare the image for WebP")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // CoreGraphics premultiplies alpha; WebP expects straight alpha.
        var i = 0
        while i < pixels.count {
            let alpha = Int(pixels[i + 3])
            if alpha > 0 && alpha < 255 {
                for c in 0..<3 { pixels[i + c] = UInt8(min(255, (Int(pixels[i + c]) * 255 + alpha / 2) / alpha)) }
            }
            i += 4
        }

        var config = WebPConfig()
        guard WebPConfigInitInternal(&config, WEBP_PRESET_PICTURE, Float(quality * 100), WEBP_ENCODER_ABI_VERSION) != 0 else {
            throw ShiftError.failed("Could not set up the WebP encoder")
        }
        config.method = 6
        config.use_sharp_yuv = 1
        config.alpha_quality = 90

        var picture = WebPPicture()
        guard WebPPictureInitInternal(&picture, WEBP_ENCODER_ABI_VERSION) != 0 else {
            throw ShiftError.failed("Could not set up the WebP encoder")
        }
        defer { WebPPictureFree(&picture) }
        picture.use_argb = 1
        picture.width = Int32(width)
        picture.height = Int32(height)
        guard WebPPictureImportRGBA(&picture, pixels, Int32(width * 4)) != 0 else {
            throw ShiftError.failed("Could not read the image into the WebP encoder")
        }

        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        defer {
            WebPMemoryWriterClear(writer)
            writer.deallocate()
        }
        WebPMemoryWriterInit(writer)
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writer)

        guard WebPEncode(&config, &picture) != 0, let bytes = writer.pointee.mem else {
            throw ShiftError.failed("WebP encoding failed (error \(picture.error_code.rawValue))")
        }
        try Data(bytes: bytes, count: writer.pointee.size).write(to: url)
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
