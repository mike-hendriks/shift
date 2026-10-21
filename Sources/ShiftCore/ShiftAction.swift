import Foundation
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Codable, Sendable {
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

    public var isLossy: Bool { [.jpeg, .webp, .avif, .heic].contains(self) }

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
/// Compression and resizing live in presets, which you edit in Settings.
public enum ShiftAction: Hashable, Sendable, Identifiable {
    case imagePreset(ImagePreset)
    case convertImage(ImageFormat)
    case imagesToPDF
    case textToPDF
    case textToPlain
    case pdfPreset(PDFPreset)
    case pdfToImages(ImageFormat)
    case videoPreset(VideoPreset)
    case videoToMP4
    case extractAudio
    case audioToM4A
    /// Text out of anything: document conversion, PDF text, OCR for images, transcription for audio and video.
    case toMarkdown(FileKind)

    public var id: String {
        switch self {
        case .imagePreset(let p): return "preset-\(p.id)"
        case .videoPreset(let p): return "preset-\(p.id)"
        case .pdfPreset(let p): return "preset-\(p.id)"
        case .convertImage(let f): return "convert-\(f.rawValue)"
        case .imagesToPDF: return "images-to-pdf"
        case .textToPDF: return "text-to-pdf"
        case .textToPlain: return "text-to-txt"
        case .pdfToImages(let f): return "pdf-to-\(f.rawValue)"
        case .videoToMP4: return "video-mp4"
        case .extractAudio: return "extract-audio"
        case .audioToM4A: return "audio-m4a"
        case .toMarkdown(let kind): return "markdown-\(kind.rawValue)"
        }
    }

    /// Actions that exist regardless of presets, per kind.
    public static func builtIns(for kind: FileKind) -> [ShiftAction] {
        switch kind {
        case .image: return ImageFormat.allCases.map { .convertImage($0) } + [.imagesToPDF, .toMarkdown(.image)]
        case .document: return [.textToPDF, .toMarkdown(.document), .textToPlain]
        case .pdf: return [.toMarkdown(.pdf), .pdfToImages(.png), .pdfToImages(.jpeg)]
        case .video: return [.videoToMP4, .extractAudio, .toMarkdown(.video)]
        case .audio: return [.audioToM4A, .toMarkdown(.audio)]
        case .other: return []
        }
    }

    public var kind: FileKind {
        switch self {
        case .imagePreset, .convertImage, .imagesToPDF: return .image
        case .textToPDF, .textToPlain: return .document
        case .pdfPreset, .pdfToImages: return .pdf
        case .videoPreset, .videoToMP4, .extractAudio: return .video
        case .audioToM4A: return .audio
        case .toMarkdown(let kind): return kind
        }
    }

    public var isPreset: Bool {
        switch self {
        case .imagePreset, .videoPreset, .pdfPreset: return true
        default: return false
        }
    }

    /// Combining actions turn all input files into a single output.
    public var isCombining: Bool { self == .imagesToPDF }

    public var title: String {
        switch self {
        case .imagePreset(let p): return p.name
        case .videoPreset(let p): return p.name
        case .pdfPreset(let p): return p.name
        case .convertImage(let f): return "To \(f.displayName)"
        case .imagesToPDF: return "One PDF"
        case .textToPDF: return "To PDF"
        case .textToPlain: return "Plain text"
        case .pdfToImages(let f): return "Pages to \(f.displayName)"
        case .videoToMP4: return "To MP4"
        case .extractAudio: return "Audio only"
        case .audioToM4A: return "To M4A"
        case .toMarkdown: return "To Markdown"
        }
    }

    public var subtitle: String {
        switch self {
        case .imagePreset(let p): return p.summary
        case .videoPreset(let p): return p.summary
        case .pdfPreset(let p): return p.summary
        case .convertImage(.webp): return "Small and sharp, works across the web"
        case .convertImage(.avif): return "Even smaller than WebP"
        case .convertImage(.jpeg): return "Opens everywhere"
        case .convertImage(.png): return "Lossless, keeps transparency"
        case .convertImage(.heic): return "Apple format, small"
        case .convertImage(.tiff): return "Lossless, for print"
        case .imagesToPDF: return "All images in one document"
        case .textToPDF: return "A4, with page numbers"
        case .textToPlain: return "Formatting stripped, just the text"
        case .pdfToImages: return "Every page at 2x resolution"
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
        case .imagePreset(let p):
            switch (p.format, p.resize) {
            case (.format(.webp), _), (.format(.avif), _): return "globe"
            case (_, .none): return "arrow.down.to.line.compact"
            default: return "arrow.down.right.and.arrow.up.left"
            }
        case .pdfPreset: return "arrow.down.to.line.compact"
        case .convertImage: return "arrow.triangle.2.circlepath"
        case .imagesToPDF, .textToPDF: return "doc.richtext"
        case .textToPlain: return "text.alignleft"
        case .pdfToImages: return "photo.on.rectangle"
        case .videoPreset, .videoToMP4: return "film"
        case .extractAudio, .audioToM4A: return "waveform"
        case .toMarkdown(.image): return "text.viewfinder"
        case .toMarkdown(.video), .toMarkdown(.audio): return "captions.bubble"
        case .toMarkdown: return "number"
        }
    }
}
