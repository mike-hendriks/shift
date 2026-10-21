import Foundation

/// A set of files of one kind, plus the actions that make sense for them, most relevant first.
public struct ActionGroup: Identifiable, Sendable {
    public let kind: FileKind
    public let files: [URL]
    public let actions: [ShiftAction]
    public var id: String { kind.rawValue }
}

public enum Suggestions {
    /// Groups dropped files by kind and suggests actions per group, based on what the files are.
    public static func groups(for urls: [URL]) -> [ActionGroup] {
        let byKind = Dictionary(grouping: urls, by: FileKind.of)
        return FileKind.allCases.compactMap { kind in
            guard let files = byKind[kind], !files.isEmpty else { return nil }
            return ActionGroup(kind: kind, files: files, actions: actions(for: kind, files: files))
        }
    }

    public static func actions(for kind: FileKind, files: [URL]) -> [ShiftAction] {
        switch kind {
        case .image: return imageActions(files)
        case .document:
            let rich: Set<String> = ["doc", "docx", "odt", "rtf", "rtfd", "html", "htm", "pages"]
            let hasRich = files.contains { rich.contains($0.pathExtension.lowercased()) }
            let allMarkdown = files.allSatisfy { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            return [.textToPDF] + (allMarkdown ? [] : [.toMarkdown(.document)]) + (hasRich ? [.textToPlain] : [])
        case .pdf: return [.compressPDF, .toMarkdown(.pdf), .pdfToImages(.png), .pdfToImages(.jpeg)]
        case .video:
            let allMP4 = files.allSatisfy { $0.pathExtension.lowercased() == "mp4" }
            return [.compressVideo(height: 1080), .compressVideo(height: 720)]
                + (allMP4 ? [] : [.videoToMP4])
                + [.extractAudio, .toMarkdown(.video)]
        case .audio: return [.audioToM4A, .toMarkdown(.audio)]
        case .other: return []
        }
    }

    private static func imageActions(_ files: [URL]) -> [ShiftAction] {
        var actions: [ShiftAction] = [.webPreset]

        let formats = Set(files.compactMap(ImageFormat.of))
        let dominant = files.lazy.compactMap(ImageFormat.of).first
        let targets: [ImageFormat]
        switch dominant {
        case .heic: targets = [.jpeg, .png, .webp]
        case .png: targets = [.webp, .jpeg, .avif]
        case .jpeg: targets = [.webp, .avif, .png]
        case .webp: targets = [.jpeg, .png, .avif]
        case .avif: targets = [.jpeg, .png, .webp]
        default: targets = [.jpeg, .png, .webp]
        }
        // Skip a target only when every file already has that format.
        actions += targets.filter { !(formats.count == 1 && formats.contains($0)) }.map { .convertImage($0) }

        actions.append(.compressImage)

        // Only offer sizes that actually shrink the largest image.
        let largest = files.compactMap(imagePixelSize).map { max($0.width, $0.height) }.max() ?? .infinity
        actions.append(.resize(.percent(50)))
        actions += [1920, 1280, 640].filter { CGFloat($0) < largest }.map { .resize(.longEdge($0)) }

        if files.count > 1 { actions.append(.imagesToPDF) }
        actions.append(.toMarkdown(.image))
        return actions
    }
}
