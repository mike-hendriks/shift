import AppKit
import ShiftCore
import SwiftUI

/// A place in the bar you can drop files on.
enum DropSpot: Hashable {
    case action(Int)
    case park
}

@MainActor
final class DropModel: ObservableObject {
    enum Phase: Equatable { case hidden, choosing, working, failed }

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
    /// Width of the bar, the full width of the screen it appears on.
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

/// The action bar: slides in across the top of the screen while you drag with Shift held.
@MainActor
final class DropController {
    let model = DropModel()
    private let shelf: ShelfStore
    private let outputDirectory: () -> URL
    private var panel: FloatingPanel!
    private var dropTarget: DropTargetView!
    private var clickMonitor: Any?
    private var pendingSpot: DropSpot?
    private var isHiding = false

    init(shelf: ShelfStore, outputDirectory: @escaping () -> URL) {
        self.shelf = shelf
        self.outputDirectory = outputDirectory
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
                      self.model.phase == .choosing || self.model.phase == .failed else { return }
                self.hide()
            }
        }
    }

    /// Shift was pressed during a file drag: show the actions for what is being dragged.
    func showForDrag() {
        guard model.phase != .working else { return }
        let files = DropTargetView.previewURLs(NSPasteboard(name: .drag))
        guard !files.isEmpty else { return }
        log.notice("Bar shown for a drag of \(files.count) files")
        show(files, dragging: true)
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
        model.groups = Suggestions.groups(for: files).filter { !$0.actions.isEmpty }
        model.phase = .choosing
        model.isDragging = dragging
        model.isTargeted = false
        model.dropSpot = nil
        dropTarget.isHidden = !dragging
        dropTarget.superview?.addSubview(dropTarget, positioned: .above, relativeTo: nil)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        model.width = visible.width - 24

        // Pin the top edge under the menu bar; the panel then grows downward as SwiftUI lays out the tiles.
        let height = panel.isVisible ? panel.frame.height : 220
        let frame = NSRect(x: visible.minX + 12, y: visible.maxY - 8 - height, width: model.width, height: height)
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
        model.phase = .working
        model.isDragging = false
        model.workingTitle = action.title
        model.done = 0
        model.total = files.count
        dropTarget.isHidden = true
        let directory = outputDirectory()
        Task {
            let report = await Processor.run(action, on: files, outputDirectory: directory) { done, _ in
                Task { @MainActor in self.model.done = done }
            }
            shelf.add(report.results)
            if report.failures.isEmpty {
                hide()
            } else {
                model.failures = report.failures.map { "\($0.file.lastPathComponent): \($0.message)" }
                model.phase = .failed
                panel.makeKeyAndOrderFront(nil)
            }
        }
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
                Text("Niet alles is gelukt").font(.system(size: 15, weight: .semibold))
                ForEach(model.failures, id: \.self) { message in
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Sluiten") { controller.hide() }.keyboardShortcut(.defaultAction).controlSize(.large)
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
                Text("Shift weet nog niet wat het met dit type moet. Zet het op de shelf om het bij de hand te houden.")
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
            Text(model.isDragging ? "Laat los op een actie" : "Klik of druk 1–9 · Esc sluit")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            parkButton
            IconButton(symbol: "xmark", help: "Sluiten (Esc)") { controller.hide() }
        }
    }

    private var parkButton: some View {
        let highlighted = model.dropSpot == .park
        return Button {
            controller.park(model.files)
        } label: {
            Label("Op de shelf", systemImage: "tray.and.arrow.down")
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
                        ActionTile(action: action, index: index,
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
    var highlighted = false
    let perform: () -> Void
    @State private var hovering = false

    private var isPrimary: Bool { action == .webPreset }

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
