import CoreGraphics
import Foundation

/// What format an image preset writes.
public enum PresetImageFormat: Hashable, Codable, Sendable {
    /// Keep the source format.
    case original
    /// Lossy formats stay as they are; lossless ones become JPG, or WebP when they have transparency.
    case auto
    case format(ImageFormat)

    public var label: String {
        switch self {
        case .original: return "Original format"
        case .auto: return "Smallest (auto)"
        case .format(let format): return format.displayName
        }
    }
}

public enum PresetResize: Hashable, Codable, Sendable {
    case none
    case longEdge(Int)
    case percent(Int)

    var mode: ResizeMode? {
        switch self {
        case .none: return nil
        case .longEdge(let px): return .longEdge(px)
        case .percent(let p): return .percent(p)
        }
    }
}

/// A width to height ratio, like 16:9.
public struct AspectRatio: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    public var label: String { "\(width):\(height)" }
    public static let common: [AspectRatio] = [.init(1, 1), .init(4, 5), .init(4, 3), .init(3, 2), .init(16, 9), .init(9, 16)]
}

/// How cropped images are saved.
public struct CropOptions: Hashable, Sendable {
    /// Replace each original in place; the original goes to the Trash first.
    public var overwrite = false
    /// Save lossy formats at `compressedQuality` instead of near-lossless. Formats never change, so overwriting works.
    public var compress = false

    public static let compressedQuality = 0.72
    public static let defaultQuality = 0.92

    public init(overwrite: Bool = false, compress: Bool = false) {
        self.overwrite = overwrite
        self.compress = compress
    }

    public var quality: Double { compress ? Self.compressedQuality : Self.defaultQuality }
}

/// Cuts pixels off each edge, then optionally crops the rest to an aspect ratio around the centre.
/// The same numbers apply to every image in a batch.
public struct ImageCrop: Hashable, Codable, Sendable {
    public var top = 0
    public var right = 0
    public var bottom = 0
    public var left = 0
    public var aspect: AspectRatio?

    public init(top: Int = 0, right: Int = 0, bottom: Int = 0, left: Int = 0, aspect: AspectRatio? = nil) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.aspect = aspect
    }

    public var isEmpty: Bool { top == 0 && right == 0 && bottom == 0 && left == 0 && aspect == nil }

    /// The part to keep, in pixels with the origin top left, or nil when the image is too small for this crop.
    public func rect(in size: CGSize) -> CGRect? {
        var rect = CGRect(x: CGFloat(left), y: CGFloat(top),
                          width: size.width - CGFloat(left + right), height: size.height - CGFloat(top + bottom))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        if let aspect, aspect.width > 0, aspect.height > 0 {
            let ratio = CGFloat(aspect.width) / CGFloat(aspect.height)
            if rect.width / rect.height > ratio {
                let width = (rect.height * ratio).rounded()
                rect.origin.x += ((rect.width - width) / 2).rounded(.down)
                rect.size.width = width
            } else {
                let height = (rect.width / ratio).rounded()
                rect.origin.y += ((rect.height - height) / 2).rounded(.down)
                rect.size.height = height
            }
        }
        return rect.integral
    }

    public var summary: String {
        var parts: [String] = []
        let edges = [("top", top), ("right", right), ("bottom", bottom), ("left", left)].filter { $0.1 > 0 }
        if edges.count == 4, Set([top, right, bottom, left]).count == 1 {
            parts.append("trim \(top) px all round")
        } else if !edges.isEmpty {
            parts.append("trim " + edges.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + " px")
        }
        if let aspect { parts.append("crop \(aspect.label)") }
        return parts.isEmpty ? "no crop" : parts.joined(separator: " · ")
    }
}

public struct ImagePreset: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var format: PresetImageFormat
    public var resize: PresetResize
    /// 0...1. Ignored by lossless formats.
    public var quality: Double
    /// Applied before resizing.
    public var crop: ImageCrop

    public init(id: String = Presets.newID(), name: String, format: PresetImageFormat, resize: PresetResize, quality: Double,
                crop: ImageCrop = ImageCrop()) {
        self.id = id
        self.name = name
        self.format = format
        self.resize = resize
        self.quality = quality
        self.crop = crop
    }

    /// Presets saved before cropping existed have no crop key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        format = try c.decode(PresetImageFormat.self, forKey: .format)
        resize = try c.decode(PresetResize.self, forKey: .resize)
        quality = try c.decode(Double.self, forKey: .quality)
        crop = try c.decodeIfPresent(ImageCrop.self, forKey: .crop) ?? ImageCrop()
    }

    public var writesLossless: Bool {
        if case .format(let format) = format { return !format.isLossy }
        return false
    }

    public var summary: String {
        var parts: [String] = []
        if !crop.isEmpty { parts.append(crop.summary) }
        if format != .original { parts.append(format.label) }
        switch resize {
        case .none: if crop.isEmpty { parts.append("same size") }
        case .longEdge(let px): parts.append("max \(px) px")
        case .percent(let p): parts.append("\(p)%")
        }
        if !writesLossless { parts.append("quality \(Int((quality * 100).rounded()))") }
        return parts.joined(separator: " · ")
    }
}

public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    case low, standard, high

    public var label: String { rawValue.capitalized }

    /// Bits per pixel per frame for H.264.
    var bitsPerPixel: Double {
        switch self {
        case .low: return 0.06
        case .standard: return 0.1
        case .high: return 0.15
        }
    }

    /// How far above the source bitrate the result may go.
    var sourceCap: Double { self == .high ? 1.5 : 1.1 }
}

public struct VideoPreset: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Short edge in pixels, 0 keeps the original resolution.
    public var maxShortEdge: Int
    public var quality: VideoQuality
    public var keepAudio: Bool

    public init(id: String = Presets.newID(), name: String, maxShortEdge: Int, quality: VideoQuality, keepAudio: Bool) {
        self.id = id
        self.name = name
        self.maxShortEdge = maxShortEdge
        self.quality = quality
        self.keepAudio = keepAudio
    }

    public var summary: String {
        let size = maxShortEdge == 0 ? "original size" : "max \(maxShortEdge)p"
        return ["H.264 MP4", size, "\(quality.label.lowercased()) quality", keepAudio ? nil : "no audio"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

public struct PDFPreset: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// JPEG quality for images inside the PDF, 0...1.
    public var imageQuality: Double
    /// Images are downsampled to this resolution.
    public var imageDPI: Int

    public init(id: String = Presets.newID(), name: String, imageQuality: Double, imageDPI: Int) {
        self.id = id
        self.name = name
        self.imageQuality = imageQuality
        self.imageDPI = imageDPI
    }

    public var summary: String { "Images at \(imageDPI) dpi · quality \(Int((imageQuality * 100).rounded()))" }
}

public enum Presets {
    public static func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// Turns a preset name into a file name suffix: "Instagram 1080" -> "instagram-1080", "Web preset" -> "web".
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let parts = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && $0 != "preset" }
        return parts.isEmpty ? "preset" : parts.joined(separator: "-")
    }

    public static let defaultImage: [ImagePreset] = [
        ImagePreset(id: "web", name: "Web preset", format: .format(.webp), resize: .longEdge(2000), quality: 0.78),
        ImagePreset(id: "compress", name: "Compress", format: .auto, resize: .none, quality: 0.72),
        ImagePreset(id: "half", name: "50%", format: .original, resize: .percent(50), quality: 0.88),
        ImagePreset(id: "1920", name: "Max 1920 px", format: .original, resize: .longEdge(1920), quality: 0.88),
        ImagePreset(id: "1280", name: "Max 1280 px", format: .original, resize: .longEdge(1280), quality: 0.88),
        ImagePreset(id: "640", name: "Max 640 px", format: .original, resize: .longEdge(640), quality: 0.88),
    ]

    public static let defaultVideo: [VideoPreset] = [
        VideoPreset(id: "video-1080", name: "Web 1080p", maxShortEdge: 1080, quality: .standard, keepAudio: true),
        VideoPreset(id: "video-720", name: "Web 720p", maxShortEdge: 720, quality: .standard, keepAudio: true),
    ]

    public static let defaultPDF: [PDFPreset] = [
        PDFPreset(id: "pdf-compress", name: "Compress", imageQuality: 0.7, imageDPI: 144),
    ]
}
