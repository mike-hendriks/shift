import AppKit
import QuickLookUI
import SwiftUI

/// Borderless, always-on-top panel that never steals focus from the app you are working in.
final class FloatingPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Keep the top edge in place when SwiftUI content grows or shrinks.
    var keepsTopAnchored = true
    /// Lets this panel drive the Quick Look panel while it is key.
    weak var previewController: ShelfQuickLook?

    init<Content: View>(rootView: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        contentViewController = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if keepsTopAnchored, isVisible, rect.size != frame.size, rect.origin == frame.origin {
            rect.origin.y = frame.maxY - rect.height
        }
        super.setFrame(clampedToScreen(rect), display: flag)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { previewController != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        previewController?.preparePanel(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    func clampedToScreen(_ rect: NSRect) -> NSRect {
        guard let visible = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame else { return rect }
        var r = rect
        r.origin.x = min(max(r.minX, visible.minX + 8), visible.maxX - r.width - 8)
        r.origin.y = min(max(r.minY, visible.minY + 8), visible.maxY - r.height - 8)
        return r
    }
}

extension View {
    /// Liquid Glass on macOS 26, thick material before that.
    @ViewBuilder
    func panelBackground(cornerRadius: CGFloat = 20) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.thickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
