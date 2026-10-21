import AppKit
import os

let log = Logger(subsystem: "men.stuur.shift", category: "drop")

/// AppKit drop target laid over the drop zone. SwiftUI's `dropDestination` does not reliably receive drags
/// in a non-activating panel that appears mid-drag, so drops are handled here directly.
/// Accepts plain file URLs and file promises (Photos, Mail, browsers).
final class DropTargetView: NSView {
    var onTargetChanged: (Bool) -> Void = { _ in }
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
        log.notice("Drag entered, types: \(sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "-", privacy: .public)")
        onTargetChanged(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargetChanged(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetChanged(false)
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
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
}
