import AppKit
import AVFoundation
import PDFKit
import Speech
import Vision

/// Turns documents, PDFs, images (OCR) and audio or video (transcription) into Markdown.
enum MarkdownConverter {
    // MARK: Documents

    @MainActor
    static func document(_ url: URL, output: URL) throws {
        let ext = url.pathExtension.lowercased()
        let markdown: String
        if ["md", "markdown"].contains(ext) {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } else if ["txt", "text"].contains(ext) {
            markdown = try DocumentProcessor.attributedString(from: url).string
        } else if DocumentProcessor.isCode(url) {
            let code = try DocumentProcessor.attributedString(from: url).string
            markdown = "```\(ext)\n\(code.trimmingCharacters(in: .newlines))\n```\n"
        } else {
            markdown = render(try DocumentProcessor.attributedString(from: url))
        }
        try write(markdown, to: output)
    }

    // MARK: PDF

    /// Rebuilds paragraphs from line positions: a vertical gap or a change in font size starts a new one.
    static func pdf(_ url: URL, output: URL) throws {
        guard let document = PDFDocument(url: url) else { throw ShiftError.unreadable(url) }
        let text = NSMutableAttributedString()

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let selection = page.selection(for: page.bounds(for: .mediaBox)) else { continue }
            var previous: (bounds: CGRect, size: CGFloat)?
            for line in selection.selectionsByLine() {
                guard let attributed = line.attributedString?.trimmed, attributed.length > 0 else { continue }
                let bounds = line.bounds(for: page)
                let size = attributed.dominantFontSize

                if let previous {
                    let gap = previous.bounds.minY - bounds.maxY
                    let sizeChanged = abs(size - previous.size) > max(size, previous.size) * 0.1
                    let startsListItem = attributed.string.range(of: listMarkerPattern, options: .regularExpression) != nil
                    if gap > max(bounds.height, previous.bounds.height) * 0.6 || sizeChanged || startsListItem || gap < -bounds.height {
                        text.append(NSAttributedString(string: "\n"))
                    } else if text.string.hasSuffix("-") {
                        text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                    } else {
                        text.append(NSAttributedString(string: " "))
                    }
                }
                text.append(attributed)
                previous = (bounds, size)
            }
            text.append(NSAttributedString(string: "\n"))
        }

        let markdown = render(text)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ShiftError.failed("\(url.lastPathComponent) has no text (scanned? Export the pages as images and use OCR)")
        }
        try write(markdown, to: output)
    }

    // MARK: Images

    /// Recognises text with Vision. Larger text becomes a heading, vertical gaps become paragraph breaks.
    static func image(_ url: URL, output: URL) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["nl-NL", "en-US", "de-DE", "fr-FR"]
        try VNImageRequestHandler(url: url).perform([request])

        // Vision's coordinates are normalised with the origin bottom-left; sort top to bottom, then left to right.
        var lines: [(text: String, box: CGRect)] = []
        for observation in request.results ?? [] {
            if let candidate = observation.topCandidates(1).first { lines.append((candidate.string, observation.boundingBox)) }
        }
        lines.sort { a, b in
            let sameRow = abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) / 2
            return sameRow ? a.box.minX < b.box.minX : a.box.midY > b.box.midY
        }
        guard !lines.isEmpty else { throw ShiftError.failed("No text found in \(url.lastPathComponent)") }

        let heights = lines.map { $0.box.height }.sorted()
        let median = heights[heights.count / 2]
        var blocks: [String] = []
        var paragraph = ""
        var previous: CGRect?

        func flush() {
            if !paragraph.isEmpty { blocks.append(paragraph) }
            paragraph = ""
        }

        for (text, box) in lines {
            if let previous, abs(previous.midY - box.midY) < min(previous.height, box.height) / 2 {
                paragraph += " " + text
                continue
            }
            let gap = (previous?.minY ?? box.maxY) - box.maxY
            if box.height > median * 1.4, text.count < 120 {
                flush()
                blocks.append((box.height > median * 2 ? "# " : "## ") + text)
            } else {
                if gap > median * 0.9 { flush() }
                paragraph += paragraph.isEmpty ? text : " " + text
            }
            previous = box
        }
        flush()
        try write(blocks.joined(separator: "\n\n") + "\n", to: output)
    }

    // MARK: Audio and video

    /// On-device transcription. The language is picked automatically: a 30 second sample is transcribed in each of
    /// your preferred languages and the one with the highest recognition confidence wins.
    /// Paragraphs break at pauses and start with a timestamp.
    static func transcribe(_ url: URL, output: URL) async throws {
        guard #available(macOS 26, *) else { throw ShiftError.failed("Transcription needs macOS 26 or later") }

        let temp = FileManager.default.temporaryDirectory
        let audio = temp.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        try await MediaProcessor.export(url, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: audio)

        let languages = await Transcription.candidateLocales()
        guard !languages.isEmpty else { throw ShiftError.failed("No transcription language available") }

        var transcript: Transcription.Result?
        if languages.count > 1 {
            let duration = try await AVURLAsset(url: audio).load(.duration).seconds
            let sample = duration > 35 ? temp.appendingPathComponent(UUID().uuidString + ".m4a") : audio
            defer { if sample != audio { try? FileManager.default.removeItem(at: sample) } }
            if sample != audio {
                try await MediaProcessor.export(audio, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, to: sample,
                                                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 30, preferredTimescale: 600)))
            }
            var best: (locale: Locale, result: Transcription.Result)?
            for locale in languages {
                guard let result = try? await Transcription.run(sample, locale: locale) else { continue }
                log("Sample in \(locale.identifier): confidence \(result.confidence)")
                if best == nil || result.confidence > best!.result.confidence { best = (locale, result) }
            }
            guard let best else { throw ShiftError.failed("Transcription failed") }
            transcript = sample == audio ? best.result : try await Transcription.run(audio, locale: best.locale)
        } else {
            transcript = try await Transcription.run(audio, locale: languages[0])
        }

        let segments = (transcript?.segments ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !segments.isEmpty else { throw ShiftError.failed("No speech found in \(url.lastPathComponent)") }

        var paragraphs: [String] = []
        var current = ""
        var lastEnd = -Double.infinity
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            if current.isEmpty || segment.start - lastEnd > 1.5 || current.count > 700 {
                if !current.isEmpty { paragraphs.append(current) }
                current = "**[\(timestamp(segment.start))]** " + text
            } else {
                current += " " + text
            }
            lastEnd = segment.end
        }
        paragraphs.append(current)

        let title = "# \(url.deletingPathExtension().lastPathComponent)"
        try write(([title] + paragraphs).joined(separator: "\n\n") + "\n", to: output)
    }

    private static func log(_ message: String) {
        if ProcessInfo.processInfo.environment["SHIFT_VERBOSE"] != nil { print(message) }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? seconds : 0)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private static func write(_ markdown: String, to url: URL) throws {
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Attributed string to Markdown

    private enum Block {
        case paragraph(String)
        case heading(Int, String)
        case listItem(String)
        case table([[String]])
    }

    /// Headings come from font size relative to the body text, lists from text lists or bullet characters,
    /// tables from text table blocks, inline styling from font traits and link attributes.
    static func render(_ text: NSAttributedString) -> String {
        let body = text.dominantFontSize
        let string = text.string as NSString
        var blocks: [Block] = []
        var table: (id: ObjectIdentifier, rows: [[String]])?

        func flushTable() {
            if let table { blocks.append(.table(table.rows)) }
            table = nil
        }

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { raw, range, _, _ in
            guard let raw, range.length > 0 else { return }
            var paragraph = text.attributedSubstring(from: range)
            let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                let id = ObjectIdentifier(cell.table)
                if table?.id != id { flushTable(); table = (id, []) }
                while table!.rows.count <= cell.startingRow { table!.rows.append([]) }
                var row = table!.rows[cell.startingRow]
                while row.count <= cell.startingColumn { row.append("") }
                row[cell.startingColumn] = inline(paragraph).replacingOccurrences(of: "|", with: "\\|")
                table!.rows[cell.startingRow] = row
                return
            }
            flushTable()

            let trimmedRaw = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmedRaw.isEmpty else { return }

            if let lists = style?.textLists, !lists.isEmpty {
                // AppKit puts the marker in the text itself: "\t•\tItem".
                if let markerEnd = listMarkerEnd(raw) {
                    paragraph = paragraph.attributedSubstring(from: NSRange(location: markerEnd, length: paragraph.length - markerEnd))
                }
                let ordered = lists.last!.markerFormat.rawValue.contains("decimal")
                let indent = String(repeating: "  ", count: lists.count - 1)
                blocks.append(.listItem(indent + (ordered ? "1. " : "- ") + inline(paragraph)))
                return
            }
            // Lists without list attributes (docx, PDF): a bullet or number at the start, then a tab or space.
            let marker = (raw as NSString).range(of: listMarkerPattern, options: .regularExpression)
            if marker.location != NSNotFound {
                let ordered = trimmedRaw.first?.isNumber == true
                let rest = paragraph.attributedSubstring(from: NSRange(location: marker.upperBound, length: paragraph.length - marker.upperBound))
                blocks.append(.listItem((ordered ? "1. " : "- ") + inline(rest)))
                return
            }

            let size = paragraph.dominantFontSize
            if body > 0, size >= body * 1.15, trimmedRaw.count < 150 {
                let level = size >= body * 1.8 ? 1 : size >= body * 1.4 ? 2 : 3
                blocks.append(.heading(level, trimmedRaw))
            } else {
                blocks.append(.paragraph(inline(paragraph)))
            }
        }
        flushTable()

        var output = ""
        var previousWasListItem = false
        for block in blocks {
            let isListItem: Bool
            let chunk: String
            switch block {
            case .paragraph(let text): chunk = text; isListItem = false
            case .heading(let level, let text): chunk = String(repeating: "#", count: level) + " " + text; isListItem = false
            case .listItem(let text): chunk = text; isListItem = true
            case .table(let rows): chunk = markdownTable(rows); isListItem = false
            }
            if !output.isEmpty { output += isListItem && previousWasListItem ? "\n" : "\n\n" }
            output += chunk
            previousWasListItem = isListItem
        }
        return output + "\n"
    }

    /// "• item", "-\titem", "1. item", "2)\titem", "3\titem". Plain numbers followed by a space ("2026 was") are not lists.
    static let listMarkerPattern = #"^\s*(?:[•◦▪·–*-][\t ]+|\d{1,3}[.)][\t ]+|\d{1,3}\t)"#

    private static func listMarkerEnd(_ raw: String) -> Int? {
        let ns = raw as NSString
        guard ns.length > 0, ns.character(at: 0) == 9 /* tab */ else { return nil }
        let second = ns.range(of: "\t", options: [], range: NSRange(location: 1, length: ns.length - 1))
        return second.location == NSNotFound ? nil : second.upperBound
    }

    private static func markdownTable(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        let line = { (cells: [String]) in "| " + cells.joined(separator: " | ") + " |" }
        let separator = "|" + Array(repeating: " --- |", count: width).joined()
        return ([line(padded[0]), separator] + padded.dropFirst().map(line)).joined(separator: "\n")
    }

    private struct InlineStyle: Equatable {
        var bold = false, italic = false, code = false, strike = false
        var link: String?
    }

    /// Inline Markdown for one paragraph: runs with the same style are merged before wrapping in markers.
    private static func inline(_ paragraph: NSAttributedString) -> String {
        var runs: [(text: String, style: InlineStyle)] = []
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.enumerateAttributes(in: full) { attrs, range, _ in
            var style = InlineStyle()
            if let font = attrs[.font] as? NSFont {
                // PDF fonts often lack traits, so the font name counts too.
                let traits = font.fontDescriptor.symbolicTraits
                let name = font.fontName.lowercased()
                style.bold = traits.contains(.bold) || ["bold", "semibold", "heavy", "black"].contains { name.contains($0) }
                style.italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
                style.code = traits.contains(.monoSpace) || ["mono", "courier", "menlo", "consolas"].contains { name.contains($0) }
            }
            style.strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            if let url = attrs[.link] as? URL { style.link = url.absoluteString }
            if let string = attrs[.link] as? String { style.link = string }

            let text = (paragraph.string as NSString).substring(with: range).replacingOccurrences(of: "\u{2028}", with: " ")
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append((text, style))
            }
        }

        var output = ""
        for (text, style) in runs {
            let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { output += text.replacingOccurrences(of: "\n", with: " "); continue }
            let leading = text.prefix(while: { $0.isWhitespace }).isEmpty ? "" : " "
            let trailing = text.reversed().prefix(while: { $0.isWhitespace }).isEmpty ? "" : " "

            var piece = style.code ? "`\(core)`" : escape(core)
            if !style.code {
                if style.bold && style.italic { piece = "***\(piece)***" }
                else if style.bold { piece = "**\(piece)**" }
                else if style.italic { piece = "*\(piece)*" }
            }
            if style.strike { piece = "~~\(piece)~~" }
            if let link = style.link { piece = "[\(piece)](\(link))" }
            output += leading + piece + trailing
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    private static func escape(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "`", with: "\\`")
        if let first = escaped.first, "#>".contains(first) { escaped = "\\" + escaped }
        return escaped
    }
}

private extension NSAttributedString {
    /// The font size covering the most characters.
    var dominantFontSize: CGFloat {
        var lengths: [CGFloat: Int] = [:]
        enumerateAttribute(.font, in: NSRange(location: 0, length: length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            lengths[font.pointSize.rounded(), default: 0] += range.length
        }
        return lengths.max { $0.value < $1.value }?.key ?? 0
    }

    var trimmed: NSAttributedString {
        let string = self.string as NSString
        let start = string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard start.location != NSNotFound else { return NSAttributedString() }
        let end = string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)
        return attributedSubstring(from: NSRange(location: start.location, length: end.upperBound - start.location))
    }
}

/// Speech-to-text on top of SpeechAnalyzer. SpeechTranscriber covers the big languages; DictationTranscriber
/// covers the rest, Dutch included.
@available(macOS 26, *)
enum Transcription {
    struct Segment { let start: Double, end: Double, text: String }
    struct Result {
        let segments: [Segment]
        /// Average recognition confidence over all characters, 0...1.
        let confidence: Double
    }

    /// Your preferred languages, in order, that can be transcribed on this Mac, plus English.
    static func candidateLocales() async -> [Locale] {
        let speech = Set(await SpeechTranscriber.supportedLocales.map(\.identifier))
        let dictation = Set(await DictationTranscriber.supportedLocales.map(\.identifier))
        var result: [Locale] = []
        for identifier in Locale.preferredLanguages + ["en-US"] {
            let wanted = Locale(identifier: identifier)
            var match: Locale?
            // `supportedLocale(equivalentTo:)` can answer with a locale the module does not support; check it.
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted), speech.contains(locale.identifier) {
                match = locale
            } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted), dictation.contains(locale.identifier) {
                match = locale
            }
            if let match, !result.contains(where: { $0.language.languageCode == match.language.languageCode }) {
                result.append(match)
            }
        }
        return result
    }

    static func run(_ audio: URL, locale: Locale) async throws -> Result {
        let attributes: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange, .transcriptionConfidence]
        if await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier == locale.identifier }) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: attributes)
            return try await analyze(audio, module: module, results: module.results) { $0.text }
        }
        var preset = DictationTranscriber.Preset.longDictation
        preset.transcriptionOptions.insert(.punctuation)
        preset.attributeOptions = [.audioTimeRange, .transcriptionConfidence]
        let module = DictationTranscriber(locale: locale, preset: preset)
        return try await analyze(audio, module: module, results: module.results) { $0.text }
    }

    private static func analyze<Results: AsyncSequence>(_ audio: URL, module: any SpeechModule, results: Results,
                                                        text: @escaping (Results.Element) -> AttributedString) async throws -> Result
        where Results.Element: SpeechModuleResult {
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await install.downloadAndInstall()
        }
        let collector = Task {
            var segments: [Segment] = []
            var weighted = 0.0
            var characters = 0
            for try await result in results where result.isFinal {
                let string = text(result)
                for run in string.runs {
                    let length = string[run.range].characters.count
                    if let confidence = run.transcriptionConfidence {
                        weighted += confidence * Double(length)
                        characters += length
                    }
                }
                segments.append(Segment(start: result.range.start.seconds, end: result.range.end.seconds,
                                        text: String(string.characters)))
            }
            return Result(segments: segments, confidence: characters > 0 ? weighted / Double(characters) : 0)
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        if let end = try await analyzer.analyzeSequence(from: try AVAudioFile(forReading: audio)) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
