import AppKit
import QuickLookUI
import ScreenCaptureKit
import ShiftCore
import SwiftUI

/// Development aid: `SHIFT_SNAPSHOT=<dir> SHIFT_FILES=<a:b:c> Shift` renders each panel state to PNG and quits.
/// Lets you check layout without Screen Recording permission.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(drop: DropController, shelf: ShelfController, store: ShelfStore,
                               settings: SettingsWindowController) -> Bool {
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

            let report = await Processor.run(.imagePreset(Presets.defaultImage[0]), on: files.filter { FileKind.of($0) == .image },
                                             outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("shift-snapshot"))
            store.add(report.results)
            store.addOriginals(files.filter { FileKind.of($0) != .image })
            drop.hide()
            try? await Task.sleep(for: .milliseconds(1500))
            capture(title: "shelf", to: dir)

            // What would receive a mouse down: rows must hit a drag source, the header the window handle.
            if let shelfPanel = NSApp.windows.compactMap({ $0 as? FloatingPanel }).first(where: { $0.previewController != nil }),
               let content = shelfPanel.contentView {
                let height = content.bounds.height
                for (name, point) in [("header left", CGPoint(x: 60, y: height - 20)), ("header middle", CGPoint(x: 120, y: height - 20)), ("drag all", CGPoint(x: 180, y: height - 20)),
                                      ("row 1 name", CGPoint(x: 120, y: height - 75)), ("row 1 thumb", CGPoint(x: 30, y: height - 75)),
                                      ("row 2 name", CGPoint(x: 120, y: height - 131))] {
                    let hit = content.hitTest(point)
                    print("hit \(name): \(hit.map { String(describing: type(of: $0)) } ?? "nil"), moves window: \(hit?.mouseDownCanMoveWindow ?? false), panel movable: \(shelfPanel.isMovableByWindowBackground)")
                }
            }

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

            for pane in SettingsWindowController.Pane.allCases {
                settings.closeForSnapshot()
                settings.show(pane)
                try? await Task.sleep(for: .milliseconds(3000))
                if let window = settings.visibleWindow { await screenCapture(window, title: "settings-\(pane.rawValue)", to: dir) }
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func key(_ code: UInt16, _ characters: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// Captures what is really on screen. Falls back to cacheDisplay when capture is not allowed.
    private static func screenCapture(_ window: NSWindow, title: String, to dir: URL) async {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                print("screen capture: window not found"); captureWindow(window, title: title, to: dir); return
            }
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width * 2)
            config.height = Int(target.frame.height * 2)
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                                   configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(title).png"))
        } catch {
            print("screen capture failed: \(error.localizedDescription)")
            captureWindow(window, title: title, to: dir)
        }
    }

    private static func captureWindow(_ window: NSWindow, title: String, to dir: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(title).png"))
    }

    private static func capture(title: String, to dir: URL) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window is FloatingPanel {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(title)-\(index).png"))
        }
    }
}
