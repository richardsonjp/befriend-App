//
//  PetPanel.swift
//  befriend
//

import AppKit
import SwiftUI

/// Borderless, transparent, always-on-top panel. Non-activating, so clicking the pet never steals focus
/// (and never fires our own app-switch trigger).
final class PetPanel: NSPanel {
    private static let size = NSSize(width: 240, height: 200)
    private static let screenMargin: CGFloat = 24
    private static let autosaveName = "PetPanel"

    init(rootView: some View) {
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

        let hostingView = DraggableHostingView(rootView: rootView)
        hostingView.sizingOptions = [] // keep the fixed frame; SwiftUI content lays out inside it
        contentView = hostingView

        if !setFrameUsingName(Self.autosaveName) || !isOnScreen { placeBottomRight() }
        setFrameAutosaveName(Self.autosaveName)
    }

    /// A saved position can point at a display that's since been unplugged, and an off-screen pet can't even be quit.
    private var isOnScreen: Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    private func placeBottomRight() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: visible.maxX - Self.size.width - Self.screenMargin,
            y: visible.minY + Self.screenMargin
        ))
    }
}

/// SwiftUI content doesn't let the window drag by default; this makes the whole pet a drag handle.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}
