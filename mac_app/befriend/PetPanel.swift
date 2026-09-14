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
        isMovableByWindowBackground = true

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

/// SwiftUI content doesn't let the window drag by default; this makes the whole pet a drag handle.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}
