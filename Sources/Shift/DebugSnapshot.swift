import AppKit
import QuickLookUI
import ShiftCore

/// Development aid: `SHIFT_SNAPSHOT=<dir> SHIFT_FILES=<a:b:c> Shift` renders each panel state to PNG and quits.
/// Lets you check layout without Screen Recording permission.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(drop: DropController, shelf: ShelfController, store: ShelfStore) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SHIFT_SNAPSHOT"].map({ URL(fileURLWithPath: $0) }) else { return false }
        let files = (env["SHIFT_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        Task {
            drop.present(files, dragging: true)
            try? await Task.sleep(for: .milliseconds(1200))
            capture(title: "bar", to: dir)

            // Simulate dragging over the third action and check hit-testing lands on it.
            drop.model.isDragging = true
            for (spot, frame) in drop.model.spotFrames.sorted(by: { $0.value.minY < $1.value.minY }) {
                print("spot \(spot): \(frame)")
            }
            if let frame = drop.model.spotFrames[.action(2)] {
                let hit = drop.model.spot(at: CGPoint(x: frame.midX, y: frame.midY))
                print("hit test at action 2 centre -> \(String(describing: hit))")
                drop.model.dropSpot = hit
            }
            try? await Task.sleep(for: .milliseconds(600))
            capture(title: "bar-hover", to: dir)
            drop.model.isDragging = false
            drop.model.dropSpot = nil

            let report = await Processor.run(.webPreset, on: files.filter { FileKind.of($0) == .image },
                                             outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("shift-snapshot"))
            store.add(report.results)
            store.addOriginals(files.filter { FileKind.of($0) != .image })
            drop.hide()
            try? await Task.sleep(for: .milliseconds(1500))
            capture(title: "shelf", to: dir)

            // Press Space on the shelf, then Down, and report what Quick Look shows.
            if let shelfPanel = NSApp.windows.compactMap({ $0 as? FloatingPanel }).first(where: { $0.previewController != nil }) {
                store.selection = store.items.first?.id
                shelfPanel.keyDown(with: key(49, " ", in: shelfPanel))
                try? await Task.sleep(for: .milliseconds(1500))
                let preview = QLPreviewPanel.shared()!
                print("quick look visible: \(preview.isVisible), item: \((preview.currentPreviewItem as? URL)?.lastPathComponent ?? "-")")
                shelfPanel.keyDown(with: key(125, "", in: shelfPanel))
                try? await Task.sleep(for: .milliseconds(800))
                print("after down: \((preview.currentPreviewItem as? URL)?.lastPathComponent ?? "-"), selection index \(store.selectedIndex ?? -1)")
                shelfPanel.keyDown(with: key(49, " ", in: shelfPanel))
                try? await Task.sleep(for: .milliseconds(800))
                print("after second space visible: \(preview.isVisible)")
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func key(_ code: UInt16, _ characters: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private static func capture(title: String, to dir: URL) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window is FloatingPanel {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(title)-\(index).png"))
        }
    }
}
