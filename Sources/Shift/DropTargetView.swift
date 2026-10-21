import AppKit
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "men.stuur.shift", category: "drop")

/// AppKit drop target laid over the drop panel. SwiftUI's `dropDestination` does not reliably receive drags
/// in a non-activating panel that appears mid-drag, and gives no cursor position, so drops are handled here.
/// Accepts plain file URLs and file promises (Photos, Mail, browsers).
final class DropTargetView: NSView {
    /// Files being dragged in. For file promises these are placeholders that only carry the file type.
    var onEnter: ([URL]) -> Void = { _ in }
    /// Cursor position in top-left based coordinates, matching SwiftUI's layout.
    var onMove: (CGPoint) -> Void = { _ in }
    var onExit: () -> Void = {}
    /// Called synchronously when the drop starts, before file promises resolve.
    var onWillDrop: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let files = Self.previewURLs(sender.draggingPasteboard)
        log.notice("Drag entered with \(files.count) files")
        onEnter(files)
        report(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        report(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onExit() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        report(sender)
        onWillDrop()
        let pasteboard = sender.draggingPasteboard
        let urls = Self.fileURLs(pasteboard)
        log.notice("Perform drop: \(urls.count) file URLs")
        if !urls.isEmpty {
            onDrop(urls)
            return true
        }

        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        guard !promises.isEmpty else { return false }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Shift-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let group = DispatchGroup()
        var received: [URL] = []
        for promise in promises {
            for _ in promise.fileTypes { group.enter() }
            promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { url, error in
                if let error { log.error("File promise failed: \(error.localizedDescription, privacy: .public)") } else { received.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in self?.onDrop(received) }
        return true
    }

    private func report(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        onMove(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
    }

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Real URLs when available. File promises only reveal their types before the drop, so those become
    /// placeholder URLs with the right extension: enough to pick suggestions.
    static func previewURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let urls = fileURLs(pasteboard)
        if !urls.isEmpty { return urls }
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        let types = promises.flatMap(\.fileTypes)
        return types.enumerated().map { index, identifier in
            let ext = UTType(identifier)?.preferredFilenameExtension ?? "data"
            return FileManager.default.temporaryDirectory.appendingPathComponent("promised-\(index + 1).\(ext)")
        }
    }
}
