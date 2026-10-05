//
//  ExplainCard.swift
//  befriend
//
//  The explanation's floating card beside the box you captured (M31). It doesn't take the keyboard until you click
//  into it; Esc, the close button or a click anywhere else closes it. Closing loses nothing: the explanation keeps
//  writing into its chat.
//

import AppKit
import PetCore
import SwiftUI

@MainActor final class ExplainCard {
    static let size = NSSize(width: 380, height: 440)
    private static let gap: CGFloat = 12

    let panel: NSPanel
    private var monitors: [Any] = []
    private var onClose: () -> Void

    init(thread: ChatThread, web: Bool, beside box: CGRect, openChat: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let frame = Self.frame(beside: box)
        panel = CardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScreenExplainView(thread: thread, web: web, openChat: openChat, close: { [weak self] in self?.close() })
            .frame(width: Self.size.width, height: Self.size.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        (panel as? CardPanel)?.cancel = { [weak self] in self?.close() }
        panel.orderFrontRegardless()
        // A click outside the card closes it: in other apps, and in befriend's other windows.
        let outside: (NSEvent) -> Void = { [weak self] _ in
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.close()
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside),
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { outside($0); return $0 },
        ].compactMap { $0 }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.orderOut(nil)
        let done = onClose
        onClose = {}
        done()
    }

    /// Right of the box if it fits on that display, else left, else below or above, kept on screen.
    static func frame(beside box: CGRect, size: NSSize = size, screens: [CGRect] = NSScreen.screens.map(\.visibleFrame)) -> CGRect {
        let visible = screens.first { $0.intersects(box) } ?? screens.first ?? box
        let candidates = [
            CGPoint(x: box.maxX + gap, y: box.maxY - size.height),
            CGPoint(x: box.minX - gap - size.width, y: box.maxY - size.height),
            CGPoint(x: box.minX, y: box.minY - gap - size.height),
            CGPoint(x: box.minX, y: box.maxY + gap),
        ]
        let fits = candidates.first { origin in
            origin.x >= visible.minX && origin.x + size.width <= visible.maxX
        } ?? CGPoint(x: box.maxX - size.width, y: box.maxY - size.height) // a box as big as the screen: inside it
        let x = min(max(fits.x, visible.minX), visible.maxX - size.width)
        let y = min(max(fits.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

private final class CardPanel: NSPanel {
    var cancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancel() }
}
