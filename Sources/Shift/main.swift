import AppKit
import Combine
import ShiftCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let watcher = DragWatcher()
    private let shelfStore = ShelfStore()
    private var shelf: ShelfController!
    private var drop: DropController!
    private var statusItem: NSStatusItem!
    private let settings = SettingsStore()
    private let updater = Updater()
    private var settingsWindow: SettingsWindowController!
    private var onboarding: OnboardingController!
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        shelf = ShelfController(store: shelfStore, settings: settings) { [weak self] dragging in self?.watcher.isSuppressed = dragging }
        drop = DropController(shelf: shelfStore, settings: settings)
        settingsWindow = SettingsWindowController(store: settings, updater: updater)
        onboarding = OnboardingController(settings: settings)

        watcher.onTriggerDrag = { [weak self] _ in self?.drop.showForDrag() }
        settings.$settings
            .map(\.triggerModifiers)
            .removeDuplicates()
            .sink { [weak self] modifiers in self?.watcher.requiredModifiers = modifiers.eventFlags }
            .store(in: &cancellables)
        watcher.onDragEnded = { [weak self] in self?.drop.dragEnded() }
        watcher.start()

        setUpStatusItem()
        setUpMainMenu()
        if DebugSnapshot.runIfRequested(drop: drop, shelf: shelf, store: shelfStore, settings: settingsWindow, onboarding: onboarding) { return }

        // The shelf no longer opens empty on first launch: people dropped files on it. The onboarding explains Shift
        // instead, once, including to everyone updating from a version without it.
        if onboarding.needsOnboarding { onboarding.show() }
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
        if !shelfStore.items.isEmpty { menu.addItem(item("Show Shelf", #selector(showShelf), key: "")) }
        menu.addItem(item("Choose Files…", #selector(chooseFiles), key: "o"))
        menu.addItem(.separator())
        if !settings.settings.saveNextToOriginal { menu.addItem(item("Open Output Folder", #selector(openOutput), key: "")) }
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Show Tutorial…", #selector(showTutorial), key: ""))
        if Updater.isConfigured { menu.addItem(item("Check for Updates…", #selector(checkForUpdates), key: "")) }
        menu.addItem(.separator())
        menu.addItem(item("Quit Shift", #selector(quit), key: "q"))
    }

    /// Shift has no Dock icon, but its settings window still needs ⌘W, ⌘, and editing shortcuts in text fields.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(item("Settings…", #selector(showSettings), key: ","))
        appMenu.addItem(item("Check for Updates…", #selector(checkForUpdates), key: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Shift", #selector(quit), key: "q"))
        main.addItem(submenu("Shift", appMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu("Edit", editMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu("Window", windowMenu))
        NSApp.mainMenu = main
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showShelf() { shelf.show() }

    @objc private func showTutorial() { onboarding.show() }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        drop.present(panel.urls)
    }

    @objc private func openOutput() {
        let folder = settings.settings.outputURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func showSettings() { settingsWindow.show() }

    @objc private func checkForUpdates() { updater.checkForUpdates() }

    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
