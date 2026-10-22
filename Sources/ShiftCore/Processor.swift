import AVFoundation
import Foundation

public enum ShiftError: LocalizedError {
    case unreadable(URL)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Could not read \(url.lastPathComponent)"
        case .failed(let message): return message
        }
    }
}

public struct ShiftResult: Sendable, Identifiable {
    public let id = UUID()
    public let sources: [URL]
    public let output: URL
    public let sourceBytes: Int64
    public let outputBytes: Int64
    public let note: String?

    init(sources: [URL], output: URL, note: String? = nil) {
        self.sources = sources
        self.output = output
        self.sourceBytes = sources.reduce(0) { $0 + fileSize($1) }
        self.outputBytes = fileSize(output)
        self.note = note
    }
}

public struct ShiftReport: Sendable {
    public var results: [ShiftResult] = []
    public var failures: [(file: URL, message: String)] = []
}

public enum OutputNamer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reserved = Set<String>()

    /// Appends " 2", " 3"... until the name is free. Reserves the name, so parallel jobs never pick the same one.
    public static func unique(_ url: URL) -> URL {
        lock.withLock {
            let fm = FileManager.default
            let dir = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var candidate = url
            var n = 2
            while fm.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
                candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
                n += 1
            }
            reserved.insert(candidate.path)
            return candidate
        }
    }

    static func url(for source: URL, suffix: String?, ext: String, in directory: URL) -> URL {
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix { base += "-\(suffix)" }
        return unique(directory.appendingPathComponent(base).appendingPathExtension(ext))
    }
}

public enum Processor {
    public static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Shift")
    }


    /// Runs an action on all files, a few at a time. Failures are collected per file instead of stopping the batch.
    public static func run(_ action: ShiftAction, on files: [URL], outputDirectory: URL,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ShiftReport {
        var report = ShiftReport()
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            report.failures = files.map { ($0, error.localizedDescription) }
            return report
        }

        if action.isCombining {
            do {
                report.results = try await process(action, files, outputDirectory)
            } catch {
                report.failures = [(files[0], error.localizedDescription)]
            }
            progress?(files.count, files.count)
            return report
        }

        let width = action.kind == .video || action.kind == .audio ? 2 : max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        var done = 0
        await withTaskGroup(of: (URL, Result<[ShiftResult], Error>).self) { group in
            var pending = files[...]
            func addNext() {
                guard let file = pending.popFirst() else { return }
                group.addTask {
                    do { return (file, .success(try await process(action, [file], outputDirectory))) }
                    catch { return (file, .failure(error)) }
                }
            }
            for _ in 0..<width { addNext() }
            for await (file, result) in group {
                switch result {
                case .success(let results): report.results += results
                case .failure(let error): report.failures.append((file, error.localizedDescription))
                }
                done += 1
                progress?(done, files.count)
                addNext()
            }
        }
        // Keep the drop order stable.
        report.results.sort { a, b in
            (files.firstIndex(of: a.sources[0]) ?? 0, a.output.lastPathComponent) < (files.firstIndex(of: b.sources[0]) ?? 0, b.output.lastPathComponent)
        }
        return report
    }

    private static func process(_ action: ShiftAction, _ files: [URL], _ dir: URL) async throws -> [ShiftResult] {
        let file = files[0]
        switch action {
        case .imagePreset(let preset):
            let image = try ImageProcessor.load(file, resize: preset.resize.mode)
            let source = ImageFormat.of(file)
            let format: ImageFormat
            switch preset.format {
            case .original:
                format = source ?? (image.isTransparent ? .png : .jpeg)
            case .auto:
                if let source, source.isLossy {
                    format = source
                } else {
                    format = image.isTransparent ? .webp : .jpeg
                }
            case .format(let target):
                format = target
            }
            let out = OutputNamer.url(for: file, suffix: Presets.slug(preset.name), ext: format.fileExtension, in: dir)
            try ImageProcessor.write(image, as: format, quality: preset.quality, to: out)
            // Pure compression must never make a file bigger.
            if preset.resize == .none, format == source { return [keepSmaller(source: file, output: out)] }
            return [ShiftResult(sources: files, output: out)]

        case .convertImage(let format):
            let image = try ImageProcessor.load(file)
            let quality: Double = [.jpeg: 0.88, .webp: 0.85, .avif: 0.7, .heic: 0.8][format] ?? 1
            let out = OutputNamer.url(for: file, suffix: nil, ext: format.fileExtension, in: dir)
            try ImageProcessor.write(image, as: format, quality: quality, to: out)
            return [ShiftResult(sources: files, output: out)]

        case .imagesToPDF:
            let out = OutputNamer.url(for: file, suffix: "bundle", ext: "pdf", in: dir)
            try ImageProcessor.combineIntoPDF(files, to: out)
            return [ShiftResult(sources: files, output: out)]

        case .textToPDF:
            let out = OutputNamer.url(for: file, suffix: nil, ext: "pdf", in: dir)
            try await MainActor.run { try DocumentProcessor.toPDF(file, output: out) }
            return [ShiftResult(sources: files, output: out)]

        case .textToPlain:
            let out = OutputNamer.url(for: file, suffix: nil, ext: "txt", in: dir)
            try await MainActor.run { try DocumentProcessor.toPlainText(file, output: out) }
            return [ShiftResult(sources: files, output: out)]

        case .pdfPreset(let preset):
            let out = OutputNamer.url(for: file, suffix: Presets.slug(preset.name), ext: "pdf", in: dir)
            try PDFProcessor.compress(file, imageQuality: preset.imageQuality, imageDPI: preset.imageDPI, output: out)
            return [keepSmaller(source: file, output: out)]

        case .pdfToImages(let format):
            return try PDFProcessor.toImages(file, format: format, outputDirectory: dir)
                .map { ShiftResult(sources: files, output: $0) }

        case .videoPreset(let preset):
            let out = OutputNamer.url(for: file, suffix: Presets.slug(preset.name), ext: "mp4", in: dir)
            try await MediaProcessor.transcodeForWeb(file, maxShortEdge: preset.maxShortEdge == 0 ? .max : preset.maxShortEdge,
                                                     bitsPerPixel: preset.quality.bitsPerPixel, sourceCap: preset.quality.sourceCap,
                                                     includeAudio: preset.keepAudio, to: out)
            return [ShiftResult(sources: files, output: out)]

        case .videoToMP4:
            let out = OutputNamer.url(for: file, suffix: nil, ext: "mp4", in: dir)
            try await MediaProcessor.transcodeForWeb(file, maxShortEdge: .max, bitsPerPixel: 0.15, sourceCap: 1.5, to: out)
            return [ShiftResult(sources: files, output: out)]

        case .toMarkdown(let kind):
            let out = OutputNamer.url(for: file, suffix: nil, ext: "md", in: dir)
            switch kind {
            case .document: try await MainActor.run { try MarkdownConverter.document(file, output: out) }
            case .pdf: try MarkdownConverter.pdf(file, output: out)
            case .image: try MarkdownConverter.image(file, output: out)
            case .video, .audio: try await MarkdownConverter.transcribe(file, output: out)
            case .other: throw ShiftError.failed("\(file.lastPathComponent) cannot be converted to Markdown")
            }
            return [ShiftResult(sources: files, output: out)]

        case .extractAudio, .audioToM4A:
            let out = OutputNamer.url(for: file, suffix: nil, ext: "m4a", in: dir)
            try await MediaProcessor.export(file, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: out)
            return [ShiftResult(sources: files, output: out)]
        }
    }

    /// If compression made the file bigger, ship the original instead.
    private static func keepSmaller(source: URL, output: URL) -> ShiftResult {
        guard source.pathExtension.lowercased() == output.pathExtension.lowercased(),
              fileSize(output) >= fileSize(source) else {
            return ShiftResult(sources: [source], output: output)
        }
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.copyItem(at: source, to: output)
        return ShiftResult(sources: [source], output: output, note: "Already optimal, kept the original")
    }
}
