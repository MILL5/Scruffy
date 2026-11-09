import AppKit
import XCTest
@testable import Scruffy

final class BusyCursorTests: XCTestCase {
    @MainActor
    private func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
    }

    @MainActor
    func testBusyCursorRestoresCursorRectsAndMouseEventsOnSuccessOrFailure() {
        let window = window(), controller = BusyCursorController()
        window.acceptsMouseMovedEvents = false
        controller.update(isBusy: true, window: window)
        XCTAssertFalse(window.areCursorRectsEnabled)
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        controller.update(isBusy: true, window: window) // Repeated SwiftUI updates must not nest disables.
        controller.update(isBusy: false, window: window)
        XCTAssertTrue(window.areCursorRectsEnabled)
        XCTAssertFalse(window.acceptsMouseMovedEvents)
        controller.stop()
        XCTAssertTrue(window.areCursorRectsEnabled)
    }

    @MainActor
    func testWindowSwitchAndTeardownReleaseCursorOwnership() {
        let first = window(), second = window(), controller = BusyCursorController()
        second.acceptsMouseMovedEvents = true
        controller.update(isBusy: true, window: first)
        controller.update(isBusy: true, window: second)
        XCTAssertTrue(first.areCursorRectsEnabled)
        XCTAssertFalse(second.areCursorRectsEnabled)
        controller.stop()
        XCTAssertTrue(second.areCursorRectsEnabled)
        XCTAssertTrue(second.acceptsMouseMovedEvents)
    }

    @MainActor
    func testIdleOrDetachedRegionDoesNotChangeWindowCursorHandling() {
        let window = window(), controller = BusyCursorController()
        controller.update(isBusy: false, window: window)
        XCTAssertTrue(window.areCursorRectsEnabled)
        controller.update(isBusy: true, window: nil)
        XCTAssertTrue(window.areCursorRectsEnabled)
        controller.update(isBusy: true, window: window)
        controller.update(isBusy: true, window: nil)
        XCTAssertTrue(window.areCursorRectsEnabled)
    }
}
