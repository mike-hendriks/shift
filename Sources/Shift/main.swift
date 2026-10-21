import AppKit
import ServiceManagement
import ShiftCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let watcher = DragWatcher()
    private let shelfStore = ShelfStore()
    private var shelf: ShelfController!
    private var drop: DropController!
    private var statusItem: NSStatusItem!

    private var outputDirectory: URL {
        get { UserDefaults.standard.url(forKey: "outputDirectory") ?? Processor.defaultOutputDirectory }
        set { UserDefaults.standard.set(newValue, forKey: "outputDirectory") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        shelf = ShelfController(store: shelfStore) { [weak self] dragging in self?.watcher.isSuppressed = dragging }
        drop = DropController(shelf: shelfStore) { [weak self] in self?.outputDirectory ?? Processor.defaultOutputDirectory }

        watcher.onShiftDrag = { [weak self] _ in self?.drop.showForDrag() }
        watcher.onDragEnded = { [weak self] in self?.drop.dragEnded() }
        watcher.start()

        setUpStatusItem()
        if DebugSnapshot.runIfRequested(drop: drop, shelf: shelf, store: shelfStore) { return }

        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            shelf.show(hint: true)
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shift", accessibilityDescription: "Shift")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Show Shelf", #selector(showShelf), key: ""))
        menu.addItem(item("Choose Files…", #selector(chooseFiles), key: "o"))
        menu.addItem(.separator())
        menu.addItem(item("Open Output Folder", #selector(openOutput), key: ""))
        let folder = item("Output Folder: \(outputDirectory.lastPathComponent)", #selector(changeOutput), key: "")
        folder.toolTip = outputDirectory.path
        menu.addItem(folder)
        let login = item("Launch at Login", #selector(toggleLogin), key: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if !Processor.canWriteWebP {
            menu.addItem(.separator())
            let warning = NSMenuItem(title: "WebP off: install with brew install webp", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Shift", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showShelf() { shelf.show(hint: true) }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        drop.present(panel.urls)
    }

    @objc private func openOutput() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDirectory)
    }

    @objc private func changeOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        panel.prompt = "Choose Folder"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
