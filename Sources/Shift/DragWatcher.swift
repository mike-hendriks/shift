import AppKit

/// Detects "dragging files anywhere on the Mac while holding Shift".
///
/// Polls global input state instead of using event monitors: `NSEvent.pressedMouseButtons`, `modifierFlags` and the
/// drag pasteboard are readable without Accessibility or Input Monitoring permission.
@MainActor
final class DragWatcher {
    var onShiftDrag: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Set while Shift itself is the drag source, so dragging results out of the shelf does not reopen the drop zone.
    var isSuppressed = false

    private var timer: Timer?
    private var mouseWasDown = false
    private var baselineChangeCount = 0
    private var triggered = false

    func start() {
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let isDown = NSEvent.pressedMouseButtons & 1 != 0
        defer { mouseWasDown = isDown }

        if isDown && !mouseWasDown {
            // A new drag bumps the drag pasteboard's change count; remember where it was at mouse down.
            baselineChangeCount = NSPasteboard(name: .drag).changeCount
            triggered = false
        }
        if !isDown && mouseWasDown {
            if triggered { onDragEnded?() }
            triggered = false
            return
        }
        guard isDown, !triggered, !isSuppressed, NSEvent.modifierFlags.contains(.shift) else { return }

        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baselineChangeCount,
              let types = pasteboard.types, !Set(types).isDisjoint(with: DropTargetView.acceptedTypes) else { return }
        triggered = true
        onShiftDrag?(NSEvent.mouseLocation)
    }
}
