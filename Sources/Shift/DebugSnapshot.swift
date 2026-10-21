import AppKit
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
            NSApp.terminate(nil)
        }
        return true
    }

    private static func capture(title: String, to dir: URL) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window is FloatingPanel {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(title)-\(index).png"))
        }
    }
}
