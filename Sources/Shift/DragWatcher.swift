import AppKit
import ShiftCore

/// Detects "dragging files anywhere on the Mac while holding the trigger keys" (Shift by default).
///
/// Polls global input state instead of using event monitors: `NSEvent.pressedMouseButtons`, `modifierFlags` and the
/// drag pasteboard are readable without Accessibility or Input Monitoring permission.
@MainActor
final class DragWatcher {
    var onTriggerDrag: ((NSPoint) -> Void)?
    /// The keys that must be held, set from Settings. Extra keys held on top still count.
    var requiredModifiers: NSEvent.ModifierFlags = .shift
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
        guard isDown, !triggered, !isSuppressed, !requiredModifiers.isEmpty,
              NSEvent.modifierFlags.contains(requiredModifiers) else { return }

        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baselineChangeCount,
              let types = pasteboard.types, !Set(types).isDisjoint(with: DropTargetView.acceptedTypes) else { return }
        triggered = true
        onTriggerDrag?(NSEvent.mouseLocation)
    }
}

extension TriggerModifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        if contains(.function) { flags.insert(.function) }
        return flags
    }

    init(eventFlags flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.function) { insert(.function) }
    }
}
