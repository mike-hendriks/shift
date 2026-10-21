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

public struct ImagePreset: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var format: PresetImageFormat
    public var resize: PresetResize
    /// 0...1. Ignored by lossless formats.
    public var quality: Double

    public init(id: String = Presets.newID(), name: String, format: PresetImageFormat, resize: PresetResize, quality: Double) {
        self.id = id
        self.name = name
        self.format = format
        self.resize = resize
        self.quality = quality
    }

    public var writesLossless: Bool {
        if case .format(let format) = format { return !format.isLossy }
        return false
    }

    public var summary: String {
        var parts: [String] = []
        if format != .original { parts.append(format.label) }
        switch resize {
        case .none: parts.append("same size")
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
