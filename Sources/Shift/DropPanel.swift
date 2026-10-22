import AppKit
import ImageIO
import ShiftCore
import SwiftUI

extension Notification.Name {
    /// The action bar opened for a drag; the object is the dragged files.
    static let shiftBarDidShow = Notification.Name("ShiftBarDidShow")
    /// An action finished; the object is the `[ShiftResult]`.
    static let shiftDidProcess = Notification.Name("ShiftDidProcess")
}

/// A place in the bar you can drop files on.
enum DropSpot: Hashable {
    case action(Int)
    case park
}

@MainActor
final class DropModel: ObservableObject {
    enum Phase: Equatable { case hidden, choosing, cropping, working, failed }

    @Published var phase: Phase = .hidden
    @Published var isTargeted = false
    @Published var files: [URL] = []
    @Published var groups: [ActionGroup] = []
    @Published var workingTitle = ""
    @Published var done = 0
    @Published var total = 0
    @Published var failures: [String] = []
    /// True while files are being dragged: letting go on a tile runs that action.
    @Published var isDragging = false
    @Published var dropSpot: DropSpot?
    /// The images and numbers for the Crop… form.
    @Published var cropFiles: [URL] = []
    @Published var crop = ImageCrop()
    @Published var cropOptions = CropOptions()
    @Published var cropSavedAsPreset = false
    /// Width of the bar: the screen width, capped at `DropController.maxWidth`.
    @Published var width: CGFloat = 1200
    /// Frames of the drop spots in the panel's top-left based coordinates, reported by the views.
    var spotFrames: [DropSpot: CGRect] = [:]

    func spot(at point: CGPoint) -> DropSpot? {
        spotFrames.first { $0.value.contains(point) }?.key
    }

    /// Actions in display order, used for the 1–9 shortcuts.
    var numbered: [(action: ShiftAction, files: [URL])] {
        groups.flatMap { group in group.actions.map { ($0, group.files) } }
    }

    func index(of action: ShiftAction, in group: ActionGroup) -> Int? {
        numbered.firstIndex { $0.action == action && $0.files == group.files }
    }
}

/// The action bar: slides in at the top of the screen, centred, while you drag with the trigger keys held.
@MainActor
final class DropController {
    static let maxWidth: CGFloat = 1600

    let model = DropModel()
    private let shelf: ShelfStore
    private let settings: SettingsStore
    private var panel: FloatingPanel!
    private var dropTarget: DropTargetView!
    private var clickMonitor: Any?
    private var pendingSpot: DropSpot?
    private var isHiding = false

    init(shelf: ShelfStore, settings: SettingsStore) {
        self.shelf = shelf
        self.settings = settings
        panel = FloatingPanel(rootView: DropBar(model: model, controller: self))
        panel.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }

        let content = panel.contentView!
        dropTarget = DropTargetView(frame: content.bounds)
        dropTarget.autoresizingMask = [.width, .height]
        dropTarget.onEnter = { [weak self] _ in self?.model.isTargeted = true }
        dropTarget.onMove = { [weak self] point in
            guard let self, self.model.isDragging else { return }
            let spot = self.model.spot(at: point)
            if spot != self.model.dropSpot { self.model.dropSpot = spot }
        }
        dropTarget.onExit = { [weak self] in
            self?.model.isTargeted = false
            self?.model.dropSpot = nil
        }
        dropTarget.onWillDrop = { [weak self] in
            guard let self else { return }
            self.pendingSpot = self.model.isDragging ? self.model.dropSpot : nil
            self.model.isDragging = false
        }
        dropTarget.onDrop = { [weak self] urls in self?.dropped(urls) }
        content.addSubview(dropTarget)

        // Close the bar when you click in another app. Not on resign-key: after a drop the source app
        // takes focus back, which would close the bar the moment it opens.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.isDragging,
                      [.choosing, .cropping, .failed].contains(self.model.phase) else { return }
                self.hide()
            }
        }
    }

    /// The trigger keys were pressed during a file drag: show the actions for what is being dragged.
    func showForDrag() {
        guard model.phase != .working else { return }
        let files = DropTargetView.previewURLs(NSPasteboard(name: .drag))
        guard !files.isEmpty else { return }
        log.notice("Bar shown for a drag of \(files.count) files")
        show(files, dragging: true)
        NotificationCenter.default.post(name: .shiftBarDidShow, object: files)
    }

    func dragEnded() {
        // The drop callback can land just after the mouse-up we polled.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if model.isDragging { hide() }
        }
    }

    /// Opens the bar for files to click through, e.g. from the menu bar or a drop next to the tiles.
    func present(_ urls: [URL], dragging: Bool = false) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { hide(); return }
        show(files, dragging: dragging)
        guard !dragging else { return }
        panel.makeKeyAndOrderFront(nil)
        // The drag source app grabs focus back when a drop ends; take it again so 1-9 and Esc reach us.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if model.phase == .choosing { panel.makeKey() }
        }
    }

    private func show(_ files: [URL], dragging: Bool) {
        model.files = files
        model.groups = Suggestions.groups(for: files, settings: settings.settings).filter { !$0.actions.isEmpty }
        model.phase = .choosing
        model.isDragging = dragging
        model.isTargeted = false
        model.dropSpot = nil
        dropTarget.isHidden = !dragging
        dropTarget.superview?.addSubview(dropTarget, positioned: .above, relativeTo: nil)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        model.width = min(visible.width - 24, Self.maxWidth)

        // Pin the top edge under the menu bar; the panel then grows downward as SwiftUI lays out the tiles.
        let height = panel.isVisible ? panel.frame.height : 220
        let frame = NSRect(x: visible.midX - model.width / 2, y: visible.maxY - 8 - height, width: model.width, height: height)
        if panel.isVisible {
            isHiding = false
            panel.setFrame(frame, display: true)
            panel.animator().alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(frame.offsetBy(dx: 0, dy: 24), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func dropped(_ urls: [URL]) {
        let spot = pendingSpot
        pendingSpot = nil
        model.dropSpot = nil
        model.isTargeted = false
        dropTarget.isHidden = true
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { hide(); return }
        log.notice("Dropped \(files.count) files on \(String(describing: spot), privacy: .public)")

        switch spot {
        case .action(let index)? where index < model.numbered.count:
            let action = model.numbered[index].action
            let matching = files.filter { FileKind.of($0) == action.kind }
            if matching.isEmpty { present(files) } else { perform(action, on: matching) }
        case .park?:
            park(files)
        default:
            present(files)
        }
    }

    func perform(_ action: ShiftAction, on files: [URL]) {
        if case .crop = action, model.phase != .cropping { startCrop(files); return }
        model.phase = .working
        model.isDragging = false
        model.workingTitle = action.title
        model.done = 0
        model.total = files.count
        dropTarget.isHidden = true
        let directory = settings.settings.resultDirectory
        Task {
            let report = await Processor.run(action, on: files, outputDirectory: directory) { done, _ in
                Task { @MainActor in self.model.done = done }
            }
            shelf.add(report.results)
            NotificationCenter.default.post(name: .shiftDidProcess, object: report.results)
            if settings.settings.copyResultsToClipboard, !report.results.isEmpty {
                copyToPasteboard(report.results.map(\.output))
            }
            if report.failures.isEmpty {
                hide()
            } else {
                model.failures = report.failures.map { "\($0.file.lastPathComponent): \($0.message)" }
                model.phase = .failed
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Crop needs numbers first: the bar turns into a crop editor, starting with nothing cut off.
    private func startCrop(_ files: [URL]) {
        model.cropFiles = files.filter { FileKind.of($0) == .image }
        model.crop = ImageCrop()
        // Starts from the defaults in Settings → General → Cropping; the form can still change them per crop.
        model.cropOptions = settings.settings.cropDefaults
        model.cropSavedAsPreset = false
        model.isDragging = false
        model.dropSpot = nil
        model.phase = .cropping
        dropTarget.isHidden = true
        panel.makeKeyAndOrderFront(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if model.phase == .cropping { panel.makeKey() }
        }
    }

    func applyCrop() {
        guard !model.crop.isEmpty, !model.cropFiles.isEmpty else { return }
        perform(.crop(model.crop, model.cropOptions), on: model.cropFiles)
    }

    /// Keeps these numbers as an image preset, so they become a tile of their own.
    func saveCropAsPreset() {
        let crop = model.crop
        guard !crop.isEmpty else { return }
        let name = crop.summary.prefix(1).uppercased() + crop.summary.dropFirst()
        settings.settings.imagePresets.append(ImagePreset(name: name, format: .original, resize: .none,
                                                          quality: model.cropOptions.quality, crop: crop))
        model.cropSavedAsPreset = true
    }

    func park(_ files: [URL]) {
        shelf.addOriginals(files)
        hide()
    }

    func hide() {
        model.isDragging = false
        model.isTargeted = false
        model.dropSpot = nil
        dropTarget.isHidden = true
        guard panel.isVisible else { reset(); return }
        // Fade out with the content still in place, then clear it.
        isHiding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // A new drag may have reopened the bar during the fade.
                guard self.isHiding else { return }
                self.isHiding = false
                self.panel.orderOut(nil)
                self.reset()
            }
        })
    }

    private func reset() {
        model.phase = .hidden
        model.isDragging = false
        model.isTargeted = false
        model.dropSpot = nil
        model.files = []
        model.groups = []
        model.failures = []
        model.cropFiles = []
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { hide(); return true } // Esc
        guard model.phase == .choosing, let chars = event.charactersIgnoringModifiers else { return false }
        if event.keyCode == 36, let first = model.numbered.first { // Return
            perform(first.action, on: first.files); return true
        }
        if let digit = Int(chars), (1...9).contains(digit), digit <= model.numbered.count {
            let choice = model.numbered[digit - 1]
            perform(choice.action, on: choice.files)
            return true
        }
        return false
    }
}

// MARK: Views

struct DropBar: View {
    @ObservedObject var model: DropModel
    let controller: DropController

    var body: some View {
        Group {
            switch model.phase {
            case .hidden: Color.clear.frame(height: 1)
            case .choosing: ActionBar(model: model, controller: controller)
            case .working: working
            case .cropping: CropForm(model: model, controller: controller)
            case .failed: failed
            }
        }
        .frame(width: model.width)
        .panelBackground(cornerRadius: 26)
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(model.isTargeted && model.isDragging ? 0.6 : 0), lineWidth: 2)
        )
        .coordinateSpace(.named(DropSpotFramesKey.space))
        .onPreferenceChange(DropSpotFramesKey.self) { model.spotFrames = $0 }
        .animation(.snappy(duration: 0.22), value: model.phase)
        .animation(.easeOut(duration: 0.15), value: model.isTargeted)
    }

    private var working: some View {
        HStack(spacing: 16) {
            ProgressView().controlSize(.regular)
            Text("\(model.workingTitle)…").font(.system(size: 17, weight: .semibold))
            ProgressView(value: Double(model.done), total: Double(max(model.total, 1)))
            Text("\(model.done)/\(model.total)").font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
    }

    private var failed: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Not everything worked").font(.system(size: 15, weight: .semibold))
                ForEach(model.failures, id: \.self) { message in
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Close") { controller.hide() }.keyboardShortcut(.defaultAction).controlSize(.large)
        }
        .padding(22)
    }
}

struct ActionBar: View {
    @ObservedObject var model: DropModel
    let controller: DropController

    private let spacing: CGFloat = 10
    private let minTileWidth: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.groups.isEmpty {
                Text("No actions for this type. Put it on the shelf to keep it at hand, or switch actions on in Settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if model.groups.count > 1 {
                        Text("\(group.files.count) \(group.kind.label(count: group.files.count))".uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    tiles(for: group)
                }
            }
        }
        .padding(18)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                ForEach(Array(model.files.prefix(3).enumerated().reversed()), id: \.offset) { index, url in
                    FileThumbnail(url: url, size: 36)
                        .rotationEffect(.degrees(Double(index) * -6))
                        .offset(x: CGFloat(index) * 3)
                }
            }
            .frame(width: 44, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                let bytes = model.files.reduce(0) { $0 + fileSize($1) }
                if bytes > 0 {
                    Text(formatBytes(bytes)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 20)
            Text(model.isDragging ? "Drop on an action" : "Click or press 1–9 · Esc closes")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            parkButton
            IconButton(symbol: "xmark", help: "Close (Esc)") { controller.hide() }
        }
    }

    private var parkButton: some View {
        let highlighted = model.dropSpot == .park
        return Button {
            controller.park(model.files)
        } label: {
            Label("To Shelf", systemImage: "tray.and.arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(highlighted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(highlighted ? 0.9 : 0), lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(highlighted ? Color.accentColor : .primary)
        .dropSpot(.park)
    }

    private var title: String {
        if model.files.count == 1 { return model.files[0].lastPathComponent }
        let counts = Dictionary(grouping: model.files, by: FileKind.of)
        return FileKind.allCases.compactMap { kind in
            counts[kind].map { "\($0.count) \(kind.label(count: $0.count))" }
        }.joined(separator: ", ")
    }

    /// One column count for the whole bar, so every tile has the same width. The largest group decides:
    /// as many tiles per row as fit, split into balanced rows when they do not.
    private var columns: Int {
        let maxPerRow = max(1, Int((model.width - 36 + spacing) / (minTileWidth + spacing)))
        let largest = max(1, model.groups.map(\.actions.count).max() ?? 1)
        let rowCount = Int((Double(largest) / Double(maxPerRow)).rounded(.up))
        return Int((Double(largest) / Double(rowCount)).rounded(.up))
    }

    @ViewBuilder
    private func tiles(for group: ActionGroup) -> some View {
        let perRow = columns
        let rows = stride(from: 0, to: group.actions.count, by: perRow).map {
            Array(group.actions[$0..<min($0 + perRow, group.actions.count)])
        }

        VStack(spacing: spacing) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: spacing) {
                    ForEach(rows[rowIndex]) { action in
                        let index = model.index(of: action, in: group)
                        ActionTile(action: action, index: index, isPrimary: action == group.actions.first,
                                   highlighted: index.map { model.dropSpot == .action($0) } ?? false) {
                            controller.perform(action, on: group.files)
                        }
                        .dropSpot(index.map(DropSpot.action))
                    }
                    // Pad short rows so their tiles stay as wide as the rest.
                    ForEach(0..<(perRow - rows[rowIndex].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }
}

struct ActionTile: View {
    let action: ShiftAction
    let index: Int?
    /// The first action of a group, the one Return runs.
    var isPrimary = false
    var highlighted = false
    let perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(isPrimary ? Color.white : Color.accentColor)
                    Spacer()
                    if let index, index < 9 { KeyCap(number: index + 1, inverted: isPrimary) }
                }
                Spacer(minLength: 10)
                Text(action.title)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(action.subtitle)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isPrimary ? 0.85 : 0.6)
                    .padding(.top, 2)
            }
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124, alignment: .leading)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isPrimary ? Color.white.opacity(highlighted ? 0.8 : 0) : Color.accentColor.opacity(highlighted ? 0.9 : 0),
                                  lineWidth: 2.5)
            )
            .scaleEffect(highlighted ? 1.04 : 1)
            .animation(.snappy(duration: 0.15), value: highlighted)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.subtitle)
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if isPrimary {
            shape.fill(Color.accentColor.gradient).brightness(hovering || highlighted ? 0.08 : 0)
        } else {
            shape.fill(highlighted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(hovering ? 0.11 : 0.06))
        }
    }
}

struct KeyCap: View {
    let number: Int
    var inverted = false

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(inverted ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .foregroundStyle(inverted ? Color.white : Color.secondary)
    }
}

/// Collects the frames of drop spots so the AppKit drop target can tell what is under the cursor.
struct DropSpotFramesKey: PreferenceKey {
    static let space = "dropPanel"
    static let defaultValue: [DropSpot: CGRect] = [:]

    static func reduce(value: inout [DropSpot: CGRect], nextValue: () -> [DropSpot: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func dropSpot(_ spot: DropSpot?) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: DropSpotFramesKey.self,
                                   value: spot.map { [$0: geometry.frame(in: .named(DropSpotFramesKey.space))] } ?? [:])
        })
    }
}

// MARK: Crop

struct CropForm: View {
    @ObservedObject var model: DropModel
    let controller: DropController

    private var first: URL? { model.cropFiles.first }
    private var count: Int { model.cropFiles.count }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            if let first {
                let size = imagePixelSize(first) ?? CGSize(width: 4, height: 3)
                CropEditor(url: first, pixelSize: size, crop: $model.crop)
                    .frame(width: displaySize(size).width, height: displaySize(size).height)
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Crop \(count) \(FileKind.image.label(count: count))").font(.system(size: 17, weight: .bold))
                    Text("Drag the edges or corners, drag inside to move, or type exact pixels. The same crop applies to every image.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                CropFields(crop: $model.crop)
                if model.crop.aspect != nil {
                    Text("The ratio crop stays centred inside the trimmed area (dashed).")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                CropOutputOptions(options: $model.cropOptions)
                    .padding(.top, 10)
                if let first, let size = imagePixelSize(first) {
                    let result = model.crop.rect(in: size)
                    Text(result.map { "\(first.lastPathComponent): \(Int(size.width))×\(Int(size.height)) → \(Int($0.width))×\(Int($0.height)) px" }
                         ?? "\(first.lastPathComponent) is too small for this crop")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(result == nil ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Cancel") { controller.hide() }
                    Button("Reset") { model.crop = ImageCrop() }.disabled(model.crop.isEmpty)
                    Spacer()
                    if model.cropSavedAsPreset {
                        Label("Saved as preset", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Button("Save as Preset") { controller.saveCropAsPreset() }.disabled(model.crop.isEmpty)
                    }
                    Button(model.cropOptions.overwrite ? "Crop and Replace \(count)" : "Crop \(count) \(FileKind.image.label(count: count))") {
                        controller.applyCrop()
                    }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.crop.isEmpty || count == 0)
                }
                .controlSize(.large)
            }
            .frame(width: 460)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// As large as fits next to the form, at most 420 pt high.
    private func displaySize(_ size: CGSize) -> CGSize {
        let maxWidth = max(240, model.width - 44 - 28 - 460)
        let scale = min(420 / size.height, maxWidth / size.width)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// Where cropped images go and whether they shrink, as two rows in the style of System Settings.
struct CropOutputOptions: View {
    @Binding var options: CropOptions

    var body: some View {
        VStack(spacing: 0) {
            row(symbol: options.overwrite ? "arrow.2.squarepath" : "plus.square.on.square",
                title: "Save",
                detail: options.overwrite ? "Replaces each original. The old version goes to the Trash."
                                          : "Adds a -cropped copy. Originals stay as they are.") {
                Picker("Save", selection: $options.overwrite) {
                    Text("Replace").tag(true)
                    Text("New files").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Divider().padding(.leading, 52)
            row(symbol: "arrow.down.to.line.compact",
                title: "Compress",
                detail: "JPG, HEIC, AVIF and WebP at quality \(Int(CropOptions.compressedQuality * 100)), same format. PNG stays lossless.") {
                Toggle("Compress", isOn: $options.compress)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .animation(.easeOut(duration: 0.15), value: options)
    }

    private func row<Control: View>(symbol: String, title: String, detail: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Pixels to cut per edge, plus an optional aspect ratio. Shared by the Crop… form and the preset editor.
struct CropFields: View {
    @Binding var crop: ImageCrop

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    edge("Top", \.top)
                    edge("Bottom", \.bottom)
                }
                GridRow {
                    edge("Left", \.left)
                    edge("Right", \.right)
                }
            }
            HStack(spacing: 10) {
                Text("Ratio").frame(width: 50, alignment: .leading)
                Picker("Ratio", selection: $crop.aspect) {
                    Text("Free").tag(AspectRatio?.none)
                    ForEach(AspectRatio.common, id: \.self) { Text($0.label).tag(AspectRatio?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func edge(_ title: String, _ keyPath: WritableKeyPath<ImageCrop, Int>) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 50, alignment: .leading)
            TextField(title, value: Binding(get: { crop[keyPath: keyPath] }, set: { crop[keyPath: keyPath] = max(0, $0) }),
                      format: .number)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text("px").foregroundStyle(.secondary)
            Stepper(title, value: Binding(get: { crop[keyPath: keyPath] }, set: { crop[keyPath: keyPath] = max(0, $0) }),
                    in: 0...100_000, step: 10)
                .labelsHidden()
        }
    }
}

/// The first image, large and sharp, with the crop on top. Drag an edge or corner to trim it, drag inside to move it.
/// Everything is in pixels of the original, so the numbers in the fields follow along.
struct CropEditor: View {
    let url: URL
    let pixelSize: CGSize
    @Binding var crop: ImageCrop
    @State private var image: CGImage?
    @State private var dragStart: ImageCrop?

    private enum Handle { case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight, move }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            } else {
                Color.primary.opacity(0.08)
                ProgressView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { GeometryReader { geometry in overlay(in: geometry.size) } }
        .task(id: url) { image = await Self.loadPreview(url) }
    }

    /// A real image decode at up to 2400 px, oriented; Quick Look thumbnails are too small to judge a crop on.
    private static func loadPreview(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    @ViewBuilder
    private func overlay(in view: CGSize) -> some View {
        let scale = view.width / pixelSize.width
        let trimmed = CGRect(x: CGFloat(crop.left), y: CGFloat(crop.top),
                             width: max(0, pixelSize.width - CGFloat(crop.left + crop.right)),
                             height: max(0, pixelSize.height - CGFloat(crop.top + crop.bottom))).scaled(scale)
        let kept = crop.rect(in: pixelSize)?.scaled(scale)

        ZStack(alignment: .topLeading) {
            // Everything that gets cut away is dimmed.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: view))
                if let kept { path.addRect(kept) }
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            if let kept {
                if dragStart != nil { thirds(kept).allowsHitTesting(false) }
                Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: kept.width, height: kept.height).position(x: kept.midX, y: kept.midY)
                    .allowsHitTesting(false)
            }
            if crop.aspect != nil {
                Rectangle().strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: trimmed.width, height: trimmed.height).position(x: trimmed.midX, y: trimmed.midY)
                    .allowsHitTesting(false)
            }
            handleMarks(trimmed).allowsHitTesting(false)

            // Hit areas: inside moves, edges trim one side, corners trim two. Corners sit on top.
            hitArea(.move, CGRect(x: trimmed.minX + 12, y: trimmed.minY + 12,
                                  width: max(0, trimmed.width - 24), height: max(0, trimmed.height - 24)), scale)
                .pointerStyle(.grabIdle)
            hitArea(.top, CGRect(x: trimmed.minX + 12, y: trimmed.minY - 8, width: max(0, trimmed.width - 24), height: 20), scale)
                .pointerStyle(.frameResize(position: .top))
            hitArea(.bottom, CGRect(x: trimmed.minX + 12, y: trimmed.maxY - 12, width: max(0, trimmed.width - 24), height: 20), scale)
                .pointerStyle(.frameResize(position: .bottom))
            hitArea(.left, CGRect(x: trimmed.minX - 8, y: trimmed.minY + 12, width: 20, height: max(0, trimmed.height - 24)), scale)
                .pointerStyle(.frameResize(position: .leading))
            hitArea(.right, CGRect(x: trimmed.maxX - 12, y: trimmed.minY + 12, width: 20, height: max(0, trimmed.height - 24)), scale)
                .pointerStyle(.frameResize(position: .trailing))
            hitArea(.topLeft, CGRect(x: trimmed.minX - 10, y: trimmed.minY - 10, width: 26, height: 26), scale)
                .pointerStyle(.frameResize(position: .topLeading))
            hitArea(.topRight, CGRect(x: trimmed.maxX - 16, y: trimmed.minY - 10, width: 26, height: 26), scale)
                .pointerStyle(.frameResize(position: .topTrailing))
            hitArea(.bottomLeft, CGRect(x: trimmed.minX - 10, y: trimmed.maxY - 16, width: 26, height: 26), scale)
                .pointerStyle(.frameResize(position: .bottomLeading))
            hitArea(.bottomRight, CGRect(x: trimmed.maxX - 16, y: trimmed.maxY - 16, width: 26, height: 26), scale)
                .pointerStyle(.frameResize(position: .bottomTrailing))
        }
    }

    private func hitArea(_ handle: Handle, _ rect: CGRect, _ scale: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .gesture(drag(handle, scale: scale))
    }

    private func drag(_ handle: Handle, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let dx = Int((value.translation.width / scale).rounded())
                let dy = Int((value.translation.height / scale).rounded())
                crop = Self.apply(handle, dx: dx, dy: dy, to: start, size: pixelSize)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Moves the dragged edges by whole pixels, keeping at least 16 px of image and never trimming past an edge.
    private static func apply(_ handle: Handle, dx: Int, dy: Int, to start: ImageCrop, size: CGSize) -> ImageCrop {
        let width = Int(size.width), height = Int(size.height), minimum = 16
        var c = start
        func clamp(_ value: Int, _ upper: Int) -> Int { min(max(value, 0), max(upper, 0)) }
        let left = { c.left = clamp(start.left + dx, width - c.right - minimum) }
        let right = { c.right = clamp(start.right - dx, width - c.left - minimum) }
        let top = { c.top = clamp(start.top + dy, height - c.bottom - minimum) }
        let bottom = { c.bottom = clamp(start.bottom - dy, height - c.top - minimum) }
        switch handle {
        case .left: left()
        case .right: right()
        case .top: top()
        case .bottom: bottom()
        case .topLeft: top(); left()
        case .topRight: top(); right()
        case .bottomLeft: bottom(); left()
        case .bottomRight: bottom(); right()
        case .move:
            let mx = min(max(dx, -start.left), start.right)
            let my = min(max(dy, -start.top), start.bottom)
            c.left = start.left + mx; c.right = start.right - mx
            c.top = start.top + my; c.bottom = start.bottom - my
        }
        return c
    }

    /// White corner brackets and edge bars on the trimmed area, like Photos.
    private func handleMarks(_ rect: CGRect) -> some View {
        Path { path in
            let arm: CGFloat = min(18, rect.width / 3, rect.height / 3)
            for (x, y, sx, sy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                                   (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
                path.move(to: CGPoint(x: x, y: y + sy * arm))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + sx * arm, y: y))
            }
            let bar: CGFloat = min(24, rect.width / 4, rect.height / 4)
            path.move(to: CGPoint(x: rect.midX - bar / 2, y: rect.minY)); path.addLine(to: CGPoint(x: rect.midX + bar / 2, y: rect.minY))
            path.move(to: CGPoint(x: rect.midX - bar / 2, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.midX + bar / 2, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.midY - bar / 2)); path.addLine(to: CGPoint(x: rect.minX, y: rect.midY + bar / 2))
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY - bar / 2)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + bar / 2))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        .shadow(color: .black.opacity(0.4), radius: 1.5)
    }

    /// Rule-of-thirds guides while dragging.
    private func thirds(_ rect: CGRect) -> some View {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.5), lineWidth: 0.75)
    }
}

private extension CGRect {
    func scaled(_ factor: CGFloat) -> CGRect {
        CGRect(x: minX * factor, y: minY * factor, width: width * factor, height: height * factor)
    }
}
