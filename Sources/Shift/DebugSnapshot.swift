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
                               settings: SettingsWindowController, onboarding: OnboardingController) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SHIFT_SNAPSHOT"].map({ URL(fileURLWithPath: $0) }) else { return false }
        let files = (env["SHIFT_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if env["SHIFT_SNAPSHOT_ONBOARDING"] != nil {
            Task {
                for step in OnboardingModel.Step.allCases {
                    onboarding.show(step: step)
                    try? await Task.sleep(for: .milliseconds(step == .welcome ? 4000 : 2500))
                    if let window = onboarding.visibleWindow { await screenCapture(window, title: "onboarding-\(step.rawValue)", to: dir) }
                }
                // Click the location cards like a user would and check what gets saved.
                onboarding.show(step: .location)
                try? await Task.sleep(for: .milliseconds(1500))
                if let window = onboarding.visibleWindow, let content = window.contentView {
                    let store = onboarding.model.settings
                    func click(_ x: CGFloat, _ yFromTop: CGFloat) async {
                        let point = NSPoint(x: x, y: content.bounds.height - yFromTop)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                            NSApp.postEvent(event, atStart: false)
                            try? await Task.sleep(for: .milliseconds(60))
                        }
                        try? await Task.sleep(for: .milliseconds(700))
                    }
                    // Start from Downloads/Shift so both directions are tested, and make the window key so clicks land.
                    store.settings.saveNextToOriginal = false
                    store.settings.outputDirectory = nil
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    await click(940 / 2, 120) // a click on the title, in case the first one only activates the window
                    print("location start: nextToOriginal=\(store.settings.saveNextToOriginal) folder=\(store.settings.outputDirectory ?? "Downloads/Shift")")
                    await click(470, 250)
                    print("after clicking Next to the original: nextToOriginal=\(store.settings.saveNextToOriginal)")
                    await screenCapture(window, title: "location-next", to: dir)
                    await click(178, 250)
                    print("after clicking Downloads/Shift: nextToOriginal=\(store.settings.saveNextToOriginal) folder=\(store.settings.outputDirectory ?? "Downloads/Shift")")
                    await screenCapture(window, title: "location-downloads", to: dir)
                }

                // The tutorial once the bar has shown and the demo photo went through the web preset.
                onboarding.show(step: .tryIt)
                try? await Task.sleep(for: .milliseconds(1500))
                if let demo = onboarding.model.demoFile {
                    NotificationCenter.default.post(name: .shiftBarDidShow, object: [demo])
                    let report = await Processor.run(.imagePreset(Presets.defaultImage[0]), on: [demo],
                                                     outputDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("shift-snapshot"))
                    NotificationCenter.default.post(name: .shiftDidProcess, object: report.results)
                    try? await Task.sleep(for: .milliseconds(1500))
                    if let window = onboarding.visibleWindow { await screenCapture(window, title: "onboarding-tryit-done", to: dir) }
                }
                NSApp.terminate(nil)
            }
            return true
        }

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

            // The Crop… form, as it opens when you pick the Crop tile.
            drop.perform(.crop(ImageCrop(), CropOptions()), on: files)
            try? await Task.sleep(for: .milliseconds(1500))
            capture(title: "crop", to: dir)

            // Drag the bottom edge of the crop up with real mouse events, as a user would.
            drop.model.crop = ImageCrop(top: 40, right: 60, bottom: 200, left: 60)
            drop.model.cropOptions = CropOptions(overwrite: false, compress: true)
            try? await Task.sleep(for: .milliseconds(800))
            capture(title: "crop-set", to: dir)
            if let panel = NSApp.windows.first(where: { $0.isVisible && $0 is FloatingPanel && $0.isKeyWindow || ($0 is FloatingPanel && $0.frame.width > 600) }),
               let first = files.first, let size = imagePixelSize(first) {
                let maxWidth = max(240, drop.model.width - 44 - 28 - 460)
                let scale = min(420 / size.height, maxWidth / size.width)
                let height = panel.contentView!.bounds.height
                let x = 22 + size.width * scale / 2
                let edgeY = 22 + (size.height - CGFloat(drop.model.crop.bottom)) * scale
                let start = NSPoint(x: x, y: height - edgeY)
                func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    NSApp.postEvent(event, atStart: false)
                }
                print("hit at bottom edge: \(panel.contentView?.hitTest(start).map { String(describing: type(of: $0)) } ?? "nil")")
                let before = drop.model.crop.bottom
                mouse(.leftMouseDown, start)
                try? await Task.sleep(for: .milliseconds(50))
                for step in 1...7 {
                    try? await Task.sleep(for: .milliseconds(30))
                    mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y + CGFloat(step) * 5))
                }
                mouse(.leftMouseUp, NSPoint(x: start.x, y: start.y + 35))
                try? await Task.sleep(for: .milliseconds(500))
                print("drag bottom edge up 35 pt at scale \(scale): bottom \(before) -> \(drop.model.crop.bottom) px")
                capture(title: "crop-dragged", to: dir)
            }

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
