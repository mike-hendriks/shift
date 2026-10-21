import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Transparent overlay that lets you drag one or more files out of Shift into any app.
/// SwiftUI's `onDrag` handles one item only; this uses a real AppKit dragging session for multiple files.
struct FileDragSource: NSViewRepresentable {
    let urls: [URL]
    var onDragChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.urls = urls
        view.onDragChanged = onDragChanged
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.urls = urls
        view.onDragChanged = onDragChanged
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var onDragChanged: (Bool) -> Void = { _ in }
    private var mouseDownEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2, urls.count == 1 { NSWorkspace.shared.open(urls[0]) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !urls.isEmpty else { return }
        let start = convert(down.locationInWindow, from: nil)
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        mouseDownEvent = nil

        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = ThumbnailCache.shared.cached(url) ?? NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(index, 4)) * 6
            item.setDraggingFrame(NSRect(x: now.x - 28 + offset, y: now.y - 28 - offset, width: 56, height: 56), contents: icon)
            return item
        }
        onDragChanged(true)
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .link] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragChanged(false)
    }
}

/// QuickLook thumbnails, cached so drag images appear instantly.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [URL: NSImage] = [:]

    func cached(_ url: URL) -> NSImage? { images[url] }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage {
        if let image = images[url] { return image }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let image = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.nsImage
            ?? NSWorkspace.shared.icon(forFile: url.path)
        images[url] = image
        return image
    }
}

struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 40
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url, size: size * 2) }
    }
}
