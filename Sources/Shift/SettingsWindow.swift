import AppKit
import ServiceManagement
import ShiftCore
import SwiftUI

/// Live settings for the app. Every change is saved right away.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: ShiftSettings {
        didSet { if settings != oldValue { settings.save() } }
    }

    init() { settings = ShiftSettings.load() }

    func binding<T>(_ keyPath: WritableKeyPath<ShiftSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { self.settings[keyPath: keyPath] = $0 })
    }
}

@MainActor
final class SettingsWindowController {
    enum Pane: String, CaseIterable, Identifiable {
        case general, actions, presets
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .actions: return "square.grid.2x2"
            case .presets: return "slider.horizontal.3"
            }
        }
    }

    private let store: SettingsStore
    private var window: NSWindow?
    private let selection = PaneSelection()

    init(store: SettingsStore) { self.store = store }

    func show(_ pane: Pane? = nil) {
        if let pane { selection.pane = pane }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store, selection: selection))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Shift Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 860, height: 600))
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var visibleWindow: NSWindow? { window?.isVisible == true ? window : nil }

    /// Snapshot mode only: a fresh window renders its first pane reliably for `cacheDisplay`.
    func closeForSnapshot() {
        window?.close()
        window = nil
    }
}

@MainActor
final class PaneSelection: ObservableObject {
    @Published var pane: SettingsWindowController.Pane = .actions
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var selection: PaneSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsWindowController.Pane.allCases, selection: Binding(get: { selection.pane }, set: { if let pane = $0 { selection.pane = pane } })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch selection.pane {
            case .general: GeneralPane(store: store)
            case .actions: ActionsPane(store: store)
            case .presets: PresetsPane(store: store)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

extension FileKind {
    /// Kinds that have actions.
    static var configurable: [FileKind] { [.image, .document, .pdf, .video, .audio] }

    var title: String {
        switch self {
        case .image: return "Images"
        case .document: return "Text"
        case .pdf: return "PDF"
        case .video: return "Video"
        case .audio: return "Audio"
        case .other: return "Other"
        }
    }
}

// MARK: General

struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Output") {
                LabeledContent("Save files to") {
                    HStack {
                        Text(store.settings.outputURL.path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        Button("Show") { NSWorkspace.shared.open(store.settings.outputURL) }
                    }
                }
                if store.settings.outputDirectory != nil {
                    Button("Use Downloads/Shift") { store.settings.outputDirectory = nil }
                }
            }
            Section("After processing") {
                Toggle("Copy results to the clipboard", isOn: store.binding(\.copyResultsToClipboard))
                Text("Results always land on the shelf. With this on, they are also ready to paste.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
                LabeledContent("WebP encoder") {
                    Text(Processor.canWriteWebP ? "cwebp found" : "Missing, install with brew install webp")
                        .foregroundStyle(Processor.canWriteWebP ? Color.secondary : Color.orange)
                }
            }
            Section("Trigger") {
                Text("Drag files anywhere and hold ⇧ Shift. The action bar slides in at the top of the screen.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.settings.outputURL
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let url = panel.url { store.settings.outputDirectory = url.path }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Actions

struct ActionsPane: View {
    @ObservedObject var store: SettingsStore
    @State private var kind: FileKind = .image

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("File type", selection: $kind) {
                ForEach(FileKind.configurable, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Pick the actions that appear in the bar for \(kind.label(count: 2)), and drag to set their order. The first one is highlighted and runs on Return. Actions that would not change a file stay hidden, like To JPG for a JPG.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(store.settings.orderedEntries(for: kind), id: \.action.id) { entry in
                    ActionRow(action: entry.action, enabled: Binding(
                        get: { entry.enabled },
                        set: { store.settings.setEnabled($0, actionID: entry.action.id, kind: kind) }
                    ))
                }
                .onMove { store.settings.moveActions(kind: kind, from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Text("Add your own compression and resize options under Presets.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { store.settings.resetLayout(kind: kind) }
            }
        }
        .padding(20)
        .navigationTitle("Actions")
    }
}

struct ActionRow: View {
    let action: ShiftAction
    @Binding var enabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.checkbox)
            Image(systemName: action.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(action.title).fontWeight(.medium)
                    if action.isPreset {
                        Text("PRESET").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(action.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .opacity(enabled ? 1 : 0.55)
    }
}

// MARK: Presets

struct PresetsPane: View {
    enum Kind: String, CaseIterable, Identifiable {
        case image, video, pdf
        var id: String { rawValue }
        var title: String {
            switch self {
            case .image: return "Images"
            case .video: return "Video"
            case .pdf: return "PDF"
            }
        }
    }

    @ObservedObject var store: SettingsStore
    @State private var kind: Kind = .image
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Preset type", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(rows, id: \.id) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).fontWeight(.medium)
                                Text(row.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(row.id)
                        }
                    }
                    .listStyle(.inset)
                    Divider()
                    HStack(spacing: 0) {
                        Button(action: add) { Image(systemName: "plus").frame(width: 26, height: 22) }
                            .help("New preset")
                        Button(action: duplicate) { Image(systemName: "plus.square.on.square").frame(width: 26, height: 22) }
                            .help("Duplicate preset").disabled(selection == nil)
                        Button(action: remove) { Image(systemName: "minus").frame(width: 26, height: 22) }
                            .help("Delete preset").disabled(selection == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(4)
                }
                .frame(width: 250)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))

                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .navigationTitle("Presets")
        .onChange(of: kind) { _, _ in selection = rows.first?.id }
        .onAppear { if selection == nil { selection = rows.first?.id } }
    }

    private var rows: [(id: String, name: String, summary: String)] {
        switch kind {
        case .image: return store.settings.imagePresets.map { ($0.id, $0.name, $0.summary) }
        case .video: return store.settings.videoPresets.map { ($0.id, $0.name, $0.summary) }
        case .pdf: return store.settings.pdfPresets.map { ($0.id, $0.name, $0.summary) }
        }
    }

    @ViewBuilder private var editor: some View {
        switch kind {
        case .image:
            if let index = store.settings.imagePresets.firstIndex(where: { $0.id == selection }) {
                ImagePresetEditor(preset: store.binding(\.imagePresets[index]))
            } else { placeholder }
        case .video:
            if let index = store.settings.videoPresets.firstIndex(where: { $0.id == selection }) {
                VideoPresetEditor(preset: store.binding(\.videoPresets[index]))
            } else { placeholder }
        case .pdf:
            if let index = store.settings.pdfPresets.firstIndex(where: { $0.id == selection }) {
                PDFPresetEditor(preset: store.binding(\.pdfPresets[index]))
            } else { placeholder }
        }
    }

    private var placeholder: some View {
        Text("Select a preset, or add one with +.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(rows.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func add() {
        let id = Presets.newID()
        switch kind {
        case .image:
            store.settings.imagePresets.append(ImagePreset(id: id, name: uniqueName("New preset"), format: .format(.jpeg),
                                                           resize: .longEdge(1600), quality: 0.8))
        case .video:
            store.settings.videoPresets.append(VideoPreset(id: id, name: uniqueName("New preset"), maxShortEdge: 1080,
                                                           quality: .standard, keepAudio: true))
        case .pdf:
            store.settings.pdfPresets.append(PDFPreset(id: id, name: uniqueName("New preset"), imageQuality: 0.7, imageDPI: 144))
        }
        selection = id
    }

    private func duplicate() {
        guard let selection else { return }
        let id = Presets.newID()
        switch kind {
        case .image:
            guard var copy = store.settings.imagePresets.first(where: { $0.id == selection }) else { return }
            copy.id = id; copy.name = uniqueName(copy.name + " copy")
            store.settings.imagePresets.append(copy)
        case .video:
            guard var copy = store.settings.videoPresets.first(where: { $0.id == selection }) else { return }
            copy.id = id; copy.name = uniqueName(copy.name + " copy")
            store.settings.videoPresets.append(copy)
        case .pdf:
            guard var copy = store.settings.pdfPresets.first(where: { $0.id == selection }) else { return }
            copy.id = id; copy.name = uniqueName(copy.name + " copy")
            store.settings.pdfPresets.append(copy)
        }
        self.selection = id
    }

    private func remove() {
        guard let selection, let index = rows.firstIndex(where: { $0.id == selection }) else { return }
        switch kind {
        case .image: store.settings.imagePresets.remove(at: index)
        case .video: store.settings.videoPresets.remove(at: index)
        case .pdf: store.settings.pdfPresets.remove(at: index)
        }
        let remaining = rows
        self.selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }
}

struct ImagePresetEditor: View {
    @Binding var preset: ImagePreset

    private enum SizeMode: Hashable { case none, longEdge, percent }

    private var sizeMode: Binding<SizeMode> {
        Binding(
            get: {
                switch preset.resize {
                case .none: return .none
                case .longEdge: return .longEdge
                case .percent: return .percent
                }
            },
            set: { mode in
                switch mode {
                case .none: preset.resize = .none
                case .longEdge: preset.resize = .longEdge(1920)
                case .percent: preset.resize = .percent(50)
                }
            }
        )
    }

    private var sizeValue: Binding<Int> {
        Binding(
            get: {
                switch preset.resize {
                case .longEdge(let px): return px
                case .percent(let p): return p
                case .none: return 0
                }
            },
            set: { value in
                switch preset.resize {
                case .longEdge: preset.resize = .longEdge(max(16, value))
                case .percent: preset.resize = .percent(min(max(1, value), 100))
                case .none: break
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                Picker("Format", selection: $preset.format) {
                    Text("Keep original").tag(PresetImageFormat.original)
                    Text("Smallest (auto)").tag(PresetImageFormat.auto)
                    Divider()
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.displayName).tag(PresetImageFormat.format($0)) }
                }
                if preset.format == .auto {
                    Text("Keeps JPG, HEIC, AVIF and WebP as they are. PNG and other lossless files become JPG, or WebP when they have transparency.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if case .format(.webp) = preset.format, !Processor.canWriteWebP {
                    Text("cwebp is not installed, so this falls back to JPG or PNG. Install it with brew install webp.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section("Size") {
                Picker("Resize", selection: sizeMode) {
                    Text("Keep size").tag(SizeMode.none)
                    Text("Longest side").tag(SizeMode.longEdge)
                    Text("Scale").tag(SizeMode.percent)
                }
                .pickerStyle(.segmented)
                switch preset.resize {
                case .longEdge:
                    LabeledContent("Max longest side") {
                        HStack {
                            TextField("", value: sizeValue, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                            Text("px").foregroundStyle(.secondary)
                            Stepper("", value: sizeValue, in: 16...16000, step: 100).labelsHidden()
                        }
                    }
                    Text("Images are only ever scaled down, never up.").font(.callout).foregroundStyle(.secondary)
                case .percent:
                    LabeledContent("Scale to \(sizeValue.wrappedValue)%") {
                        Slider(value: Binding(get: { Double(sizeValue.wrappedValue) }, set: { sizeValue.wrappedValue = Int($0) }),
                               in: 10...100, step: 5)
                    }
                case .none:
                    EmptyView()
                }
            }
            Section("Quality") {
                LabeledContent("Quality \(Int((preset.quality * 100).rounded()))") {
                    Slider(value: $preset.quality, in: 0.3...1, step: 0.01)
                }
                .disabled(preset.writesLossless)
                Text(preset.writesLossless ? "\(preset.format.label) is lossless, quality does not apply."
                     : "Around 75–80 is the sweet spot for the web: hard to tell apart, much smaller.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Result") {
                    Text("photo-\(Presets.slug(preset.name)).\(exampleExtension)").monospaced().foregroundStyle(.secondary)
                }
                LabeledContent("Summary") { Text(preset.summary).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private var exampleExtension: String {
        if case .format(let format) = preset.format { return format.fileExtension }
        return "jpg"
    }
}

struct VideoPresetEditor: View {
    @Binding var preset: VideoPreset

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                Picker("Resolution", selection: $preset.maxShortEdge) {
                    Text("Original").tag(0)
                    ForEach([2160, 1440, 1080, 720, 540, 480], id: \.self) { Text("\($0)p").tag($0) }
                }
                Picker("Quality", selection: $preset.quality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Keep audio", isOn: $preset.keepAudio)
            }
            Section {
                Text("Always H.264 in MP4, so it plays in every browser. The bitrate never goes far above the source's own, so a file does not grow for nothing.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Summary") { Text(preset.summary).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

struct PDFPresetEditor: View {
    @Binding var preset: PDFPreset

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                LabeledContent("Image quality \(Int((preset.imageQuality * 100).rounded()))") {
                    Slider(value: $preset.imageQuality, in: 0.3...1, step: 0.01)
                }
                Picker("Image resolution", selection: $preset.imageDPI) {
                    ForEach([72, 96, 144, 200, 300], id: \.self) { Text("\($0) dpi").tag($0) }
                }
            }
            Section {
                Text("Text and vector shapes stay sharp. Only images inside the PDF are recompressed. 144 dpi suits screens, 300 dpi suits print.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Summary") { Text(preset.summary).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}
