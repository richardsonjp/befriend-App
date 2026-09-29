//
//  PetPanel.swift
//  befriend
//

import AppKit
import PetCore
import SwiftUI

/// Borderless, transparent, always-on-top panel. Non-activating, so clicking the pet never steals focus
/// (and never fires our own app-switch trigger). Only the friend and its bubble catch clicks; the rest of the
/// panel lets them through to whatever is behind it.
final class PetPanel: NSPanel {
    private static let size = NSSize(width: 240, height: 200)
    private static let screenMargin: CGFloat = 24

    /// The friend and its bubble, in SwiftUI's top-left coordinates of the panel's content.
    var hitAreas: [CGRect] = [] {
        didSet { updateClickThrough() }
    }

    private var mouseMonitors: [Any] = []

    /// `content` gets the panel, e.g. to report its hit areas.
    init(content: (PetPanel) -> some View) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false // dragged by hand: see DraggableHostingView

        let hostingView = DraggableHostingView(rootView: content(self))
        hostingView.sizingOptions = [] // keep the fixed frame; SwiftUI content lays out inside it
        contentView = hostingView
        placeBottomRight()
    }

    /// The friend walks up under the menu bar with the empty top of the panel above it; don't let AppKit push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// The display the character stands on (the panel's empty top can reach onto another one).
    var characterScreen: NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.minY + CharacterView.size / 2)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? screen ?? NSScreen.main
    }

    /// The whole panel, bubble room included, is on a display (not standing under the menu bar or on an unplugged one).
    var fitsOnScreen: Bool {
        NSScreen.screens.contains { $0.visibleFrame.contains(frame) }
    }

    func placeBottomRight() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: visible.maxX - Self.size.width - Self.screenMargin,
            y: visible.minY + Self.screenMargin
        ))
    }

    // MARK: Click-through

    var isMouseOverFriend: Bool {
        let point = convertPoint(fromScreen: NSEvent.mouseLocation)
        let topLeft = CGPoint(x: point.x, y: frame.height - point.y)
        return hitAreas.contains { $0.contains(topLeft) }
    }

    func updateClickThrough() {
        guard NSEvent.pressedMouseButtons == 0 else { return } // mid-click or mid-drag: leave it as it was
        ignoresMouseEvents = !isMouseOverFriend
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        startTrackingMouse()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        stopTrackingMouse()
    }

    override func close() {
        stopTrackingMouse()
        super.close()
    }

    /// Only while the friend is on screen. A clicked-through panel gets no mouse events of its own, so the global
    /// monitor watches the ones other apps get.
    private func startTrackingMouse() {
        guard mouseMonitors.isEmpty else { return }
        updateClickThrough()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp]
        let global = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            self?.updateClickThrough()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.updateClickThrough()
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
    }

    private func stopTrackingMouse() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
    }
}

/// Less movement than this is a click (a poke), not a drag.
private let dragThreshold: CGFloat = 3

/// Makes the friend a drag handle that goes anywhere, other displays and under the menu bar included. The panel is
/// moved by hand: AppKit's own window drag keeps a window's top below the menu bar, and the friend stands at the
/// bottom of a tall panel, so it could never reach the top of the screen.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var grab: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        grab = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        dragged = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, let window else { return super.mouseDragged(with: event) }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - grab.mouse.x, dy = mouse.y - grab.mouse.y
        guard dragged || hypot(dx, dy) >= dragThreshold else { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: grab.origin.x + dx, y: grab.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        grab = nil
        // A drag isn't a poke: end the press far outside the friend, so SwiftUI's tap gesture fails instead of firing.
        guard dragged, let away = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: 0
        ) else { return super.mouseUp(with: event) }
        super.mouseUp(with: away)
    }
}
