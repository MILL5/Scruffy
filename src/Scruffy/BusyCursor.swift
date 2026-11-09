import AppKit
import SwiftUI

/// A working cursor for asynchronous operations; events still reach normal controls.
struct BusyCursorRegion: NSViewRepresentable {
    let isBusy: Bool
    func makeNSView(context: Context) -> BusyCursorView { BusyCursorView() }
    func updateNSView(_ view: BusyCursorView, context: Context) { view.setBusy(isBusy) }
    static func dismantleNSView(_ view: BusyCursorView, coordinator: ()) { view.controller.stop() }
}

@MainActor
final class BusyCursorController {
    private weak var window: NSWindow?
    private var monitor: Any?
    private var wasAcceptingMouseMovedEvents = false
    private var installedCursor = false

    static let workingCursor: NSCursor = {
        let symbol = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Working")?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        let image = NSImage(size: NSSize(width: 24, height: 28), flipped: false) { bounds in
            let shadow = NSShadow()
            shadow.shadowColor = .black; shadow.shadowBlurRadius = 2
            shadow.set()
            symbol?.draw(in: bounds.insetBy(dx: 3, dy: 3))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 14))
    }()

    func update(isBusy: Bool, window nextWindow: NSWindow?) {
        if window !== nextWindow || !isBusy { stop() }
        guard isBusy, let nextWindow else { return }
        if window == nil {
            window = nextWindow
            wasAcceptingMouseMovedEvents = nextWindow.acceptsMouseMovedEvents
            nextWindow.acceptsMouseMovedEvents = true
            // Child text fields must not replace the working cursor with an I-beam.
            nextWindow.disableCursorRects()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate,
                                                                 .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.refreshAfterEvent() }
                return event
            }
        }
        refreshCursor()
        refreshAfterEvent()
    }

    private func refreshAfterEvent() {
        // SwiftUI can update hover cursors while handling the event. Apply ours afterward.
        DispatchQueue.main.async { [weak self] in self?.refreshCursor() }
    }

    func refreshCursor() {
        guard let window, NSApp.isActive, window.isKeyWindow,
              let content = window.contentView,
              content.bounds.contains(content.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else {
            restoreCursor()
            return
        }
        Self.workingCursor.set()
        installedCursor = true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let window {
            window.enableCursorRects()
            window.acceptsMouseMovedEvents = wasAcceptingMouseMovedEvents
            if let content = window.contentView { window.invalidateCursorRects(for: content) }
        }
        window = nil
        restoreCursor()
    }

    private func restoreCursor() {
        if installedCursor {
            NSCursor.arrow.set()
            installedCursor = false
        }
    }
}

final class BusyCursorView: NSView {
    let controller = BusyCursorController()
    private var isBusy = false
    private var tracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller.update(isBusy: isBusy, window: window)
    }
    func setBusy(_ value: Bool) {
        isBusy = value
        controller.update(isBusy: value, window: window)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(tracking); self.tracking = tracking
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { controller.refreshCursor() }
    override func mouseExited(with event: NSEvent) { controller.refreshCursor() }
}
