import Foundation

/// A set of files of one kind, plus the actions that make sense for them, in your order.
public struct ActionGroup: Identifiable, Sendable {
    public let kind: FileKind
    public let files: [URL]
    public let actions: [ShiftAction]
    public var id: String { kind.rawValue }
}

public enum Suggestions {
    /// Groups dropped files by kind and lists the actions you switched on in Settings, minus the ones that
    /// do nothing for these files.
    public static func groups(for urls: [URL], settings: ShiftSettings = .load()) -> [ActionGroup] {
        let byKind = Dictionary(grouping: urls, by: FileKind.of)
        return FileKind.allCases.compactMap { kind in
            guard let files = byKind[kind], !files.isEmpty else { return nil }
            return ActionGroup(kind: kind, files: files, actions: actions(for: kind, files: files, settings: settings))
        }
    }

    public static func actions(for kind: FileKind, files: [URL], settings: ShiftSettings = .load()) -> [ShiftAction] {
        let context = Context(files)
        return settings.orderedEntries(for: kind).filter(\.enabled).map(\.action).filter { context.applies($0) }
    }

    /// What the dropped files are, to hide actions that would not change them.
    private struct Context {
        let files: [URL]
        let formats: Set<ImageFormat>
        let largestEdge: CGFloat

        init(_ files: [URL]) {
            self.files = files
            formats = Set(files.compactMap(ImageFormat.of))
            largestEdge = files.compactMap(imagePixelSize).map { max($0.width, $0.height) }.max() ?? .infinity
        }

        private var extensions: Set<String> { Set(files.map { $0.pathExtension.lowercased() }) }

        func applies(_ action: ShiftAction) -> Bool {
            switch action {
            case .convertImage(let format):
                // Skip a target only when every file already has that format.
                return !(formats.count == 1 && formats.contains(format))
            case .imagesToPDF:
                return files.count > 1
            case .imagePreset(let preset):
                // A resize that keeps the format is pointless when every image is already small enough.
                if preset.format == .original, case .longEdge(let px) = preset.resize { return CGFloat(px) < largestEdge }
                return true
            case .textToPlain:
                return !extensions.isDisjoint(with: ["doc", "docx", "odt", "rtf", "rtfd", "html", "htm", "pages"])
            case .toMarkdown(.document):
                return !extensions.isSubset(of: ["md", "markdown"])
            case .videoToMP4:
                return extensions != ["mp4"]
            default:
                return true
            }
        }
    }
}
