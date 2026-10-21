import AppKit
import ShiftCore
import SwiftUI

@MainActor
final class DropModel: ObservableObject {
    enum Phase: Equatable { case waiting, choosing, working, failed }

    @Published var phase: Phase = .waiting
    @Published var isTargeted = false
    @Published var files: [URL] = []
    @Published var groups: [ActionGroup] = []
    @Published var workingTitle = ""
    @Published var done = 0
    @Published var total = 0
    @Published var failures: [String] = []

    /// Actions in display order, used for the 1–9 shortcuts.
    var numbered: [(action: ShiftAction, files: [URL])] {
        groups.flatMap { group in group.actions.map { ($0, group.files) } }
    }

    func index(of action: ShiftAction, in group: ActionGroup) -> Int? {
        numbered.firstIndex { $0.action == action && $0.files == group.files }
    }
}

@MainActor
final class DropController {
    let model = DropModel()
    private let shelf: ShelfStore
    private let outputDirectory: () -> URL
    private var panel: FloatingPanel!
    private var dropTarget: DropTargetView!
    private var clickMonitor: Any?

    init(shelf: ShelfStore, outputDirectory: @escaping () -> URL) {
        self.shelf = shelf
        self.outputDirectory = outputDirectory
        panel = FloatingPanel(rootView: DropView(model: model, controller: self))
        panel.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }

        let content = panel.contentView!
        dropTarget = DropTargetView(frame: content.bounds)
        dropTarget.autoresizingMask = [.width, .height]
        dropTarget.onTargetChanged = { [weak self] in self?.model.isTargeted = $0 }
        dropTarget.onDrop = { [weak self] urls in self?.present(urls) }
        content.addSubview(dropTarget)

        // Close the picker when you click in another app. Not on resign-key: after a drop the source app
        // takes focus back, which would close the picker the moment it opens.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .choosing || self.model.phase == .failed else { return }
                self.hide()
            }
        }
    }

    /// Shows the drop target centred under the cursor, so you can let go right away.
    func showDropZone(at point: NSPoint) {
        guard model.phase != .working else { return }
        model.phase = .waiting
        model.isTargeted = false
        dropTarget.isHidden = false
        place(centeredAt: point, size: CGSize(width: 200, height: 140))
        panel.orderFrontRegardless()
        log.notice("Drop zone shown")
    }

    func dragEnded() {
        // The drop callback can land just after the mouse-up we polled.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if model.phase == .waiting { hide() }
        }
    }

    /// Opens the action picker for files, e.g. from a drop or the menu bar.
    func present(_ urls: [URL], at point: NSPoint? = nil) {
        let files = urls.filter(\.isFileURL)
        log.notice("Presenting \(files.count) files")
        guard !files.isEmpty else { hide(); return }
        dropTarget.isHidden = true
        model.files = files
        model.groups = Suggestions.groups(for: files).filter { !$0.actions.isEmpty }
        model.phase = .choosing
        if let point { place(centeredAt: point) }
        if !panel.isVisible { place(centeredAt: NSEvent.mouseLocation) }
        panel.makeKeyAndOrderFront(nil)
        // The drag source app grabs focus back when the drop ends; take it again so 1-9 and Esc reach us.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if model.phase == .choosing { panel.makeKey() }
        }
    }

    func perform(_ action: ShiftAction, on files: [URL]) {
        model.phase = .working
        model.workingTitle = action.title
        model.done = 0
        model.total = files.count
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
        panel.orderOut(nil)
        model.phase = .waiting
        model.files = []
        model.groups = []
        model.failures = []
    }

    private func place(centeredAt point: NSPoint, size knownSize: CGSize? = nil) {
        panel.layoutIfNeeded()
        let size = knownSize ?? panel.contentViewController?.view.fittingSize ?? CGSize(width: 220, height: 150)
        let frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
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

struct DropView: View {
    @ObservedObject var model: DropModel
    let controller: DropController

    var body: some View {
        Group {
            switch model.phase {
            case .waiting: dropZone
            case .choosing: ActionPicker(model: model, controller: controller)
            case .working: working
            case .failed: failed
            }
        }
        .panelBackground(cornerRadius: 22)
        .animation(.snappy(duration: 0.22), value: model.phase)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "shift.fill")
                .font(.system(size: 34, weight: .bold))
                .symbolEffect(.bounce, value: model.isTargeted)
            Text(model.isTargeted ? "Loslaten" : "Sleep hierheen")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(model.isTargeted ? Color.accentColor : Color.primary)
        .frame(width: 200, height: 140)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(model.isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(10)
        )
        .scaleEffect(model.isTargeted ? 1.04 : 1)
        .animation(.snappy(duration: 0.18), value: model.isTargeted)
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ProgressView().controlSize(.small)
                Text("\(model.workingTitle)…").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.done)/\(model.total)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(model.done), total: Double(max(model.total, 1)))
        }
        .padding(18)
        .frame(width: 300)
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Niet alles is gelukt", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            ForEach(model.failures, id: \.self) { message in
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Sluiten") { controller.hide() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

struct ActionPicker: View {
    @ObservedObject var model: DropModel
    let controller: DropController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.groups.isEmpty {
                Text("Shift weet nog niet wat het met dit type moet. Zet het op de shelf om het bij de hand te houden.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if model.groups.count > 1 {
                        Text("\(group.files.count) \(group.kind.label(count: group.files.count))".uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    actions(for: group)
                }
            }
            footer
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                ForEach(Array(model.files.prefix(3).enumerated().reversed()), id: \.offset) { index, url in
                    FileThumbnail(url: url, size: 34)
                        .rotationEffect(.degrees(Double(index) * -6))
                        .offset(x: CGFloat(index) * 3)
                }
            }
            .frame(width: 42, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Text(formatBytes(model.files.reduce(0) { $0 + fileSize($1) }))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(symbol: "xmark", help: "Sluiten (Esc)") { controller.hide() }
        }
    }

    private var title: String {
        if model.files.count == 1 { return model.files[0].lastPathComponent }
        let counts = Dictionary(grouping: model.files, by: FileKind.of)
        return FileKind.allCases.compactMap { kind in
            counts[kind].map { "\($0.count) \(kind.label(count: $0.count))" }
        }.joined(separator: ", ")
    }

    @ViewBuilder
    private func actions(for group: ActionGroup) -> some View {
        let primary = group.actions.first == .webPreset ? ShiftAction.webPreset : nil
        let rest = group.actions.filter { $0 != primary }

        if let primary {
            PrimaryActionButton(action: primary, index: model.index(of: primary, in: group)) {
                controller.perform(primary, on: group.files)
            }
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(rest) { action in
                ActionButton(action: action, index: model.index(of: action, in: group)) {
                    controller.perform(action, on: group.files)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                controller.park(model.files)
            } label: {
                Label("Op de shelf zetten", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            Spacer()
            Text("1–9 kiezen · Esc sluiten")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

struct PrimaryActionButton: View {
    let action: ShiftAction
    let index: Int?
    let perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.22)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: 14, weight: .bold))
                    Text(action.subtitle).font(.system(size: 11)).opacity(0.85)
                }
                Spacer()
                if let index, index < 9 { KeyCap(number: index + 1, inverted: true) }
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .brightness(hovering ? 0.06 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ActionButton: View {
    let action: ShiftAction
    let index: Int?
    let perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: action.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(Color.accentColor)
                Text(action.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if let index, index < 9 { KeyCap(number: index + 1) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.12 : 0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.subtitle)
    }
}

struct KeyCap: View {
    let number: Int
    var inverted = false

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .frame(width: 17, height: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(inverted ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .foregroundStyle(inverted ? Color.white : Color.secondary)
    }
}
