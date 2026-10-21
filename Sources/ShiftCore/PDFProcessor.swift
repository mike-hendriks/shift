import AppKit
import PDFKit
import Quartz

enum PDFProcessor {
    /// Re-renders images in the PDF with the system "Reduce File Size" Quartz filter (JPEG, 144 dpi).
    static func compress(_ url: URL, output: URL) throws {
        guard let document = PDFDocument(url: url) else { throw ShiftError.unreadable(url) }
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else { throw ShiftError.failed("Quartz filter not found") }
        let options = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]
        guard document.write(to: output, withOptions: options) else { throw ShiftError.failed("Could not save the PDF") }
    }

    /// Renders every page at 2x into separate image files.
    static func toImages(_ url: URL, format: ImageFormat, outputDirectory: URL) throws -> [URL] {
        guard let document = PDFDocument(url: url) else { throw ShiftError.unreadable(url) }
        let base = url.deletingPathExtension().lastPathComponent
        let digits = max(2, String(document.pageCount).count)
        var outputs: [URL] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var size = page.bounds(for: .mediaBox).size
            if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            let pixels = CGSize(width: size.width * 2, height: size.height * 2)

            guard let ctx = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: pixels))
            ctx.scaleBy(x: 2, y: 2)
            ctx.interpolationQuality = .high
            page.draw(with: .mediaBox, to: ctx)
            guard let image = ctx.makeImage() else { continue }

            let name = "\(base)-p\(String(format: "%0\(digits)d", index + 1))"
            let out = OutputNamer.unique(outputDirectory.appendingPathComponent(name).appendingPathExtension(format.fileExtension))
            try ImageProcessor.write(PreparedImage(cgImage: image, isTransparent: false), as: format, quality: 0.9, to: out)
            outputs.append(out)
        }
        return outputs
    }
}
