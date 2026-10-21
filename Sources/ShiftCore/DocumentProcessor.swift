import AppKit
import UniformTypeIdentifiers

/// Text documents to PDF or plain text. Runs on the main actor because AppKit's HTML import requires it.
@MainActor
enum DocumentProcessor {
    static let pageSize = CGSize(width: 595.28, height: 841.89) // A4
    static let margin: CGFloat = 60

    static func toPDF(_ url: URL, output: URL) throws {
        try renderPDF(attributedString(from: url), title: url.deletingPathExtension().lastPathComponent, to: output)
    }

    static func toPlainText(_ url: URL, output: URL) throws {
        try attributedString(from: url).string.write(to: output, atomically: true, encoding: .utf8)
    }

    // MARK: Reading

    static func attributedString(from url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) {
            return MarkdownRenderer.render(try readText(url))
        }
        if ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"].contains(ext) {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
        let monospaced = !(["txt", "text"].contains(ext)) && isCode(url)
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular) : NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = monospaced ? 2 : 3
        return NSAttributedString(string: try readText(url), attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
        ])
    }

    static func isCode(_ url: URL) -> Bool {
        guard let type = contentType(of: url) else { return false }
        return type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml)
            || type.conforms(to: .yaml) || type.conforms(to: .commaSeparatedText) || type.conforms(to: .shellScript)
    }

    private static func readText(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }

    // MARK: Rendering

    static func renderPDF(_ text: NSAttributedString, title: String, to output: URL) throws {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        let contentSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        var pages: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            pages.append(container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs || range.length == 0 || pages.count > 5000 { break }
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Shift"] as CFDictionary
        guard let ctx = CGContext(output as CFURL, mediaBox: &mediaBox, info) else {
            throw ShiftError.failed("Kon PDF niet aanmaken")
        }

        // Dynamic colours like labelColor must resolve to their light variants on paper.
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            for (index, container) in pages.enumerated() {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: pageSize.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

                let range = layout.glyphRange(for: container)
                let origin = CGPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)

                if pages.count > 1 {
                    let label = "\(index + 1) / \(pages.count)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor(white: 0.55, alpha: 1),
                    ]
                    let size = label.size(withAttributes: attrs)
                    label.draw(at: CGPoint(x: (pageSize.width - size.width) / 2, y: pageSize.height - margin / 2 - size.height / 2),
                               withAttributes: attrs)
                }

                NSGraphicsContext.restoreGraphicsState()
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
    }
}

/// Small Markdown renderer for print: headings, lists, quotes, code blocks and inline styling.
@MainActor
enum MarkdownRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var inCode = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }

            if inCode {
                output.append(NSAttributedString(string: rawLine + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor(white: 0.2, alpha: 1),
                    .backgroundColor: NSColor(white: 0.95, alpha: 1),
                    .paragraphStyle: style(spacing: 0),
                ]))
                continue
            }
            if line.isEmpty { output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])); continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 {
                output.append(NSAttributedString(string: "\u{00B7}   \u{00B7}   \u{00B7}\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.7, alpha: 1),
                    .paragraphStyle: style(spacing: 8, alignment: .center),
                ]))
                continue
            }

            if let level = headingLevel(line) {
                let sizes: [CGFloat] = [22, 17, 14, 12.5, 11.5, 11]
                let text = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                output.append(inline(text, size: sizes[level - 1], weight: .bold, paragraph: style(spacing: 6, before: level <= 2 ? 10 : 6)))
            } else if let (marker, rest) = listItem(line) {
                let paragraph = style(spacing: 2)
                paragraph.headIndent = 16
                paragraph.firstLineHeadIndent = 0
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
                output.append(inline("\(marker)\t\(rest)", size: 11, paragraph: paragraph))
            } else if line.hasPrefix(">") {
                let paragraph = style(spacing: 4)
                paragraph.headIndent = 14
                paragraph.firstLineHeadIndent = 14
                output.append(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces), size: 11,
                                     color: NSColor(white: 0.4, alpha: 1), paragraph: paragraph))
            } else {
                output.append(inline(line, size: 11, paragraph: style(spacing: 4)))
            }
        }
        return output
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (String, String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            var rest = String(line.dropFirst(2))
            if rest.hasPrefix("[ ] ") { return ("\u{2610}", String(rest.dropFirst(4))) }
            if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { rest = String(rest.dropFirst(4)); return ("\u{2611}", rest) }
            return ("\u{2022}", rest)
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("\(digits).", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static func style(spacing: CGFloat, before: CGFloat = 0, alignment: NSTextAlignment = .natural) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.paragraphSpacingBefore = before
        p.lineSpacing = 2.5
        p.alignment = alignment
        return p
    }

    /// Applies bold, italic, code and links from inline Markdown.
    private static func inline(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                               color: NSColor = .black, paragraph: NSParagraphStyle) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font: NSFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
            } else {
                font = .systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor(red: 0.1, green: 0.35, blue: 0.85, alpha: 1)
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph]))
        return result
    }
}
