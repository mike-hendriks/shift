import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The broad category of a file, used to pick context-aware actions.
public enum FileKind: String, CaseIterable, Sendable {
    case image, document, pdf, video, audio, other

    public static func of(_ url: URL) -> FileKind {
        guard let type = contentType(of: url) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .svg) { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) || type.conforms(to: .rtf) || type.conforms(to: .rtfd)
            || documentExtensions.contains(url.pathExtension.lowercased()) {
            return .document
        }
        return .other
    }

    /// Dutch label shown in the UI, singular or plural.
    public func label(count: Int) -> String {
        let one = count == 1
        switch self {
        case .image: return one ? "afbeelding" : "afbeeldingen"
        case .document: return one ? "tekstbestand" : "tekstbestanden"
        case .pdf: return one ? "PDF" : "PDF's"
        case .video: return one ? "video" : "video's"
        case .audio: return one ? "audiobestand" : "audiobestanden"
        case .other: return one ? "overig bestand" : "overige bestanden"
        }
    }

    static let documentExtensions: Set<String> = ["doc", "docx", "odt", "pages", "rtf", "rtfd", "md", "markdown", "txt", "html", "htm"]
}

func contentType(of url: URL) -> UTType? {
    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type }
    return UTType(filenameExtension: url.pathExtension)
}

/// Pixel dimensions of an image after applying its EXIF orientation.
public func imagePixelSize(_ url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
}

public func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
}
