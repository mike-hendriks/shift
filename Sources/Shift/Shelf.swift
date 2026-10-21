import AppKit
import Combine
import QuickLookUI
import ShiftCore
import SwiftUI

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let sourceBytes: Int64?
    let outputBytes: Int64
    let note: String?
}

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var fresh: Set<UUID> = []
    @Published var collapsed = false
    /// The row you clicked, like a Finder selection: Space previews it, arrows move it.
    @Published var selection: UUID?
    /// The row under the mouse, previewed when nothing is selected.
    @Published var hovered: UUID?

    var selectedIndex: Int? { items.firstIndex { $0.id == selection } }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = selectedIndex ?? (delta > 0 ? -1 : items.count)
        selection = items[min(max(current + delta, 0), items.count - 1)].id
    }

    func add(_ results: [ShiftResult]) {
        insert(results.map { ShelfItem(url: $0.output, sourceBytes: $0.sourceBytes, outputBytes: $0.outputBytes, note: $0.note) })
    }

    /// Parks files on the shelf as they are, without processing.
    func addOriginals(_ urls: [URL]) {
        insert(urls.map { ShelfItem(url: $0, sourceBytes: nil, outputBytes: fileSize($0), note: nil) })
    }

    private func insert(_ newItems: [ShelfItem]) {
        let urls = Set(newItems.map(\.url))
        items.removeAll { urls.contains($0.url) }
        items.insert(contentsOf: newItems, at: 0)
        collapsed = false
        let ids = Set(newItems.map(\.id))
        fresh.formUnion(ids)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.6)) { fresh.subtract(ids) }
        }
    }

    func remove(_ item: ShelfItem) {
        guard let index = items.firstIndex(of: item) else { return }
        items.remove(at: index)
        if selection == item.id {
            selection = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        }
    }

    func clear() {
        items.removeAll()
        selection = nil
        hovered = nil
    }
}

/// Puts files on the clipboard. A single image also goes on as image data, so it pastes into Figma, Slack or Mail.
@MainActor
func copyToPasteboard(_ urls: [URL]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if urls.count == 1, FileKind.of(urls[0]) == .image, let image = NSImage(contentsOf: urls[0]) {
        let item = NSPasteboardItem()
        item.setString(urls[0].absoluteString, forType: .fileURL)
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        }
        pasteboard.writeObjects([item])
    } else {
        pasteboard.writeObjects(urls as [NSURL])
    }
}

@MainActor
final class ShelfController {
    let store: ShelfStore
    private var panel: FloatingPanel!
    private var quickLook: ShelfQuickLook!
    private var cancellables: Set<AnyCancellable> = []
    private var hasBeenPlaced = false
    private var showingHint = false

    init(store: ShelfStore, onDragChanged: @escaping (Bool) -> Void) {
        self.store = store
        panel = FloatingPanel(rootView: ShelfView(store: store, onDragChanged: onDragChanged, onClose: { [weak self] in self?.close() }))
        panel.isMovableByWindowBackground = true
        quickLook = ShelfQuickLook(store: store)
        panel.previewController = quickLook
        panel.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }

        store.$selection
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.quickLook.selectionChanged() }
            .store(in: &cancellables)

        store.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                if !items.isEmpty { self.showingHint = false; self.show() } else if !self.showingHint { self.panel.orderOut(nil) }
            }
            .store(in: &cancellables)
    }

    func show(hint: Bool = false) {
        if hint { showingHint = true }
        if !hasBeenPlaced, let screen = NSScreen.main?.visibleFrame {
            panel.layoutIfNeeded()
            let size = panel.contentViewController?.view.fittingSize ?? CGSize(width: 300, height: 120)
            panel.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16,
                                  width: size.width, height: size.height), display: false)
            hasBeenPlaced = true
        }
        panel.orderFrontRegardless()
    }

    /// Space toggles Quick Look, arrows move the selection, Delete takes it off the shelf, ⌘C copies it.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: togglePreview(); return true                       // Space
        case 125: store.moveSelection(by: 1); return true            // Down
        case 126: store.moveSelection(by: -1); return true           // Up
        case 51, 117:                                                // Delete, Forward Delete
            if let index = store.selectedIndex { store.remove(store.items[index]) }
            return true
        case 53:                                                     // Esc
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().orderOut(nil)
            } else {
                store.selection = nil
            }
            return true
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", let index = store.selectedIndex {
                copyToPasteboard([store.items[index].url])
                return true
            }
            return false
        }
    }

    private func togglePreview() {
        let preview = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists(), preview.isVisible {
            preview.orderOut(nil)
            return
        }
        if store.selection == nil { store.selection = store.hovered ?? store.items.first?.id }
        guard store.selection != nil else { return }
        // Quick Look looks for its controller in the key window's responder chain, so the shelf must be key.
        NSApp.activate()
        panel.makeKey()
        preview.makeKeyAndOrderFront(nil)
    }

    private func close() {
        showingHint = false
        store.clear()
        panel.orderOut(nil)
    }
}

// MARK: Views

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    var onDragChanged: (Bool) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !store.collapsed {
                if store.items.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(store.items) { item in
                                    ShelfRow(item: item, isFresh: store.fresh.contains(item.id), store: store, onDragChanged: onDragChanged)
                                        .id(item.id)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                        }
                        .onChange(of: store.selection) { _, selection in
                            if let selection { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selection) } }
                        }
                    }
                    .frame(height: min(CGFloat(store.items.count) * 56 + 6, 460))
                    .scrollIndicators(.never)
                }
            }
        }
        .frame(width: 300)
        .panelBackground(cornerRadius: 18)
        .animation(.snappy(duration: 0.25), value: store.items)
        .animation(.snappy(duration: 0.25), value: store.collapsed)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shift.fill").font(.system(size: 13, weight: .bold))
            Text(store.items.isEmpty ? "Shift" : "\(store.items.count) ready")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Spacer()
            if store.items.count > 1 {
                DragAllButton(urls: store.items.map(\.url), onDragChanged: onDragChanged)
            }
            if !store.items.isEmpty {
                Menu {
                    Button("Copy All") { copyToPasteboard(store.items.map(\.url)) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(store.items.map(\.url)) }
                    Divider()
                    Button("Clear Shelf", role: .destructive) { store.clear() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                IconButton(symbol: store.collapsed ? "chevron.down" : "chevron.up", help: store.collapsed ? "Expand" : "Collapse") {
                    store.collapsed.toggle()
                }
            }
            IconButton(symbol: "xmark", help: "Close and clear", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag files and hold ⇧ Shift.")
                .font(.system(size: 12, weight: .medium))
            Text("Results stay here. Drag them straight into your next tool.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

struct ShelfRow: View {
    let item: ShelfItem
    let isFresh: Bool
    @ObservedObject var store: ShelfStore
    var onDragChanged: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                FileThumbnail(url: item.url, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    meta
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(FileDragSource(urls: [item.url], onDragChanged: onDragChanged, onClick: { store.selection = item.id }))
            .help("Drag into any app, Space to preview, double-click to open")

            if hovering {
                HStack(spacing: 2) {
                    IconButton(symbol: "doc.on.doc", help: "Copy") { copyToPasteboard([item.url]) }
                    IconButton(symbol: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    IconButton(symbol: "xmark", help: "Remove from shelf") { store.remove(item) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(store.selection == item.id ? Color.accentColor.opacity(0.28)
                      : isFresh ? Color.accentColor.opacity(0.18)
                      : hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { inside in
            hovering = inside
            if inside { store.hovered = item.id } else if store.hovered == item.id { store.hovered = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var meta: some View {
        HStack(spacing: 5) {
            if let source = item.sourceBytes, source > 0 {
                Text("\(formatBytes(source)) → \(formatBytes(item.outputBytes))")
                let change = Int(((Double(item.outputBytes) / Double(source)) - 1) * 100)
                if change != 0 {
                    Text(change < 0 ? "−\(-change)%" : "+\(change)%")
                        .fontWeight(.semibold)
                        .foregroundStyle(change < 0 ? Color.green : Color.secondary)
                }
            } else {
                Text(formatBytes(item.outputBytes))
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        if let note = item.note {
            Text(note).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
        }
    }
}

struct DragAllButton: View {
    let urls: [URL]
    var onDragChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.draw")
            Text("Drag all")
        }
        .lineLimit(1)
        .fixedSize()
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .overlay(FileDragSource(urls: urls, onDragChanged: onDragChanged))
        .help("Drag every file into an app at once")
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Feeds the shelf to Quick Look and keeps its current item in sync with the shelf selection.
@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let store: ShelfStore

    init(store: ShelfStore) { self.store = store }

    func selectionChanged() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
              panel.isVisible, panel.dataSource === self, let index = store.selectedIndex,
              panel.currentPreviewItemIndex != index else { return }
        panel.currentPreviewItemIndex = index
    }

    func preparePanel(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = store.selectedIndex ?? 0
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { store.items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { store.items.indices.contains(index) ? store.items[index].url as NSURL : nil }
    }

    /// Arrow keys inside the preview move through the shelf, as in Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let delta: Int? = [125: 1, 124: 1, 126: -1, 123: -1][event.keyCode]
        guard let delta else { return false }
        MainActor.assumeIsolated { store.moveSelection(by: delta) }
        return true
    }
}
