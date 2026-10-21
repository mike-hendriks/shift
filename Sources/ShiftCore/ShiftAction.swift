import Foundation
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg, png, webp, avif, heic, tiff

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        default: return rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .jpeg: return "JPG"
        case .webp: return "WebP"
        default: return rawValue.uppercased()
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .webp: return .webP
        case .avif: return UTType("public.avif") ?? .image
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    var isLossy: Bool { [.jpeg, .webp, .avif, .heic].contains(self) }

    static func of(_ url: URL) -> ImageFormat? {
        guard let type = contentType(of: url) else { return nil }
        if type.conforms(to: UTType("public.heif") ?? .heic) { return .heic }
        return allCases.first { type.conforms(to: $0.utType) }
    }
}

public enum ResizeMode: Hashable, Sendable {
    case percent(Int)
    case longEdge(Int)
}

/// Everything Shift can do to a file. Each action targets one `FileKind`.
public enum ShiftAction: Hashable, Sendable, Identifiable {
    case webPreset
    case convertImage(ImageFormat)
    case resize(ResizeMode)
    case compressImage
    case imagesToPDF
    case textToPDF
    case textToPlain
    case compressPDF
    case pdfToImages(ImageFormat)
    case compressVideo(height: Int)
    case videoToMP4
    case extractAudio
    case audioToM4A
    /// Text out of anything: document conversion, PDF text, OCR for images, transcription for audio and video.
    case toMarkdown(FileKind)

    public var id: String {
        switch self {
        case .webPreset: return "web"
        case .convertImage(let f): return "convert-\(f.rawValue)"
        case .resize(.percent(let p)): return "resize-\(p)pct"
        case .resize(.longEdge(let px)): return "resize-\(px)"
        case .compressImage: return "compress-image"
        case .imagesToPDF: return "images-to-pdf"
        case .textToPDF: return "text-to-pdf"
        case .textToPlain: return "text-to-txt"
        case .compressPDF: return "compress-pdf"
        case .pdfToImages(let f): return "pdf-to-\(f.rawValue)"
        case .compressVideo(let h): return "video-\(h)p"
        case .videoToMP4: return "video-mp4"
        case .extractAudio: return "extract-audio"
        case .audioToM4A: return "audio-m4a"
        case .toMarkdown(let kind): return "markdown-\(kind.rawValue)"
        }
    }

    public init?(id: String) {
        let all: [ShiftAction] = [.webPreset, .compressImage, .imagesToPDF, .textToPDF, .textToPlain, .compressPDF,
                                  .videoToMP4, .extractAudio, .audioToM4A,
                                  .compressVideo(height: 1080), .compressVideo(height: 720)]
            + ImageFormat.allCases.map { .convertImage($0) }
            + ImageFormat.allCases.map { .pdfToImages($0) }
            + FileKind.allCases.map { .toMarkdown($0) }
        if let match = all.first(where: { $0.id == id }) { self = match; return }
        if id.hasPrefix("resize-"), id.hasSuffix("pct"), let p = Int(id.dropFirst(7).dropLast(3)) {
            self = .resize(.percent(p)); return
        }
        if id.hasPrefix("resize-"), let px = Int(id.dropFirst(7)) {
            self = .resize(.longEdge(px)); return
        }
        return nil
    }

    public var kind: FileKind {
        switch self {
        case .webPreset, .convertImage, .resize, .compressImage, .imagesToPDF: return .image
        case .textToPDF, .textToPlain: return .document
        case .compressPDF, .pdfToImages: return .pdf
        case .compressVideo, .videoToMP4, .extractAudio: return .video
        case .audioToM4A: return .audio
        case .toMarkdown(let kind): return kind
        }
    }

    /// Combining actions turn all input files into a single output.
    public var isCombining: Bool { self == .imagesToPDF }

    public var title: String {
        switch self {
        case .webPreset: return "Web preset"
        case .convertImage(let f): return "To \(f.displayName)"
        case .resize(.percent(let p)): return "\(p)%"
        case .resize(.longEdge(let px)): return "Max \(px) px"
        case .compressImage: return "Compress"
        case .imagesToPDF: return "One PDF"
        case .textToPDF: return "To PDF"
        case .textToPlain: return "Plain text"
        case .compressPDF: return "Compress"
        case .pdfToImages(let f): return "Pages to \(f.displayName)"
        case .compressVideo(let h): return "Web \(h)p"
        case .videoToMP4: return "To MP4"
        case .extractAudio: return "Audio only"
        case .audioToM4A: return "To M4A"
        case .toMarkdown: return "To Markdown"
        }
    }

    public var subtitle: String {
        switch self {
        case .webPreset:
            return "WebP · max \(WebPreset.maxLongEdge) px · sRGB · no metadata"
        case .convertImage(.webp): return "Small and sharp, works across the web"
        case .convertImage(.avif): return "Even smaller than WebP"
        case .convertImage(.jpeg): return "Opens everywhere"
        case .convertImage(.png): return "Lossless, keeps transparency"
        case .convertImage(.heic): return "Apple format, small"
        case .convertImage(.tiff): return "Lossless, for print"
        case .resize: return "Scales down, never up"
        case .compressImage: return "Same dimensions, smaller file"
        case .imagesToPDF: return "All images in one document"
        case .textToPDF: return "A4, with page numbers"
        case .textToPlain: return "Formatting stripped, just the text"
        case .compressPDF: return "Images at 144 dpi, JPEG"
        case .pdfToImages: return "Every page at 2x resolution"
        case .compressVideo(let h): return "H.264 MP4, max \(h)p, streams fast"
        case .videoToMP4: return "Same quality, plays everywhere"
        case .extractAudio: return "Audio as M4A"
        case .audioToM4A: return "AAC in M4A"
        case .toMarkdown(.image): return "Recognize text (OCR)"
        case .toMarkdown(.pdf): return "Text with headings and lists"
        case .toMarkdown(.video), .toMarkdown(.audio): return "Transcript with timestamps"
        case .toMarkdown: return "Headings, lists, links and tables"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .webPreset: return "globe"
        case .convertImage: return "arrow.triangle.2.circlepath"
        case .resize: return "arrow.down.right.and.arrow.up.left"
        case .compressImage, .compressPDF: return "arrow.down.to.line.compact"
        case .imagesToPDF, .textToPDF: return "doc.richtext"
        case .textToPlain: return "text.alignleft"
        case .pdfToImages: return "photo.on.rectangle"
        case .compressVideo, .videoToMP4: return "film"
        case .extractAudio, .audioToM4A: return "waveform"
        case .toMarkdown(.image): return "text.viewfinder"
        case .toMarkdown(.video), .toMarkdown(.audio): return "captions.bubble"
        case .toMarkdown: return "number"
        }
    }
}

public enum WebPreset {
    public static let maxLongEdge = 2000
    public static let quality = 0.78
}
