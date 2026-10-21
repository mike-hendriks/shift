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
        }
    }

    public init?(id: String) {
        let all: [ShiftAction] = [.webPreset, .compressImage, .imagesToPDF, .textToPDF, .textToPlain, .compressPDF,
                                  .videoToMP4, .extractAudio, .audioToM4A,
                                  .compressVideo(height: 1080), .compressVideo(height: 720)]
            + ImageFormat.allCases.map { .convertImage($0) }
            + ImageFormat.allCases.map { .pdfToImages($0) }
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
        }
    }

    /// Combining actions turn all input files into a single output.
    public var isCombining: Bool { self == .imagesToPDF }

    public var title: String {
        switch self {
        case .webPreset: return "Web preset"
        case .convertImage(let f): return "Naar \(f.displayName)"
        case .resize(.percent(let p)): return "\(p)%"
        case .resize(.longEdge(let px)): return "Max \(px) px"
        case .compressImage: return "Comprimeren"
        case .imagesToPDF: return "Eén PDF"
        case .textToPDF: return "Naar PDF"
        case .textToPlain: return "Platte tekst"
        case .compressPDF: return "Comprimeren"
        case .pdfToImages(let f): return "Pagina's naar \(f.displayName)"
        case .compressVideo(let h): return "Web \(h)p"
        case .videoToMP4: return "Naar MP4"
        case .extractAudio: return "Alleen audio"
        case .audioToM4A: return "Naar M4A"
        }
    }

    public var subtitle: String {
        switch self {
        case .webPreset:
            return "WebP · max \(WebPreset.maxLongEdge) px · sRGB · zonder metadata"
        case .convertImage(.webp): return "Klein en scherp, overal op het web"
        case .convertImage(.avif): return "Nog kleiner dan WebP"
        case .convertImage(.jpeg): return "Opent overal"
        case .convertImage(.png): return "Lossless, met transparantie"
        case .convertImage(.heic): return "Apple-formaat, klein"
        case .convertImage(.tiff): return "Lossless, voor print"
        case .resize: return "Verkleinen, nooit vergroten"
        case .compressImage: return "Zelfde afmetingen, kleiner bestand"
        case .imagesToPDF: return "Alle afbeeldingen in één document"
        case .textToPDF: return "A4, met paginanummers"
        case .textToPlain: return "Opmaak eruit, alleen de tekst"
        case .compressPDF: return "Beelden op 144 dpi, JPEG"
        case .pdfToImages: return "Elke pagina op 2x resolutie"
        case .compressVideo(let h): return "H.264 MP4, max \(h)p, snel streamen"
        case .videoToMP4: return "Zelfde kwaliteit, beter compatibel"
        case .extractAudio: return "Audio als M4A"
        case .audioToM4A: return "AAC in M4A"
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
        }
    }
}

public enum WebPreset {
    public static let maxLongEdge = 2000
    public static let quality = 0.78
}
