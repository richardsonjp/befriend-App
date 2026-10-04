//
//  ScreenCapture.swift
//  befriend
//
//  Picking a part of the screen to explain (M31): every display dims, you drag a box with the crosshair, Esc or a
//  click without dragging cancels. The box is captured with ScreenCaptureKit (Screen Recording permission).
//

import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

enum ScreenCapture {
    /// A box smaller than this (points) is a click, not a selection.
    static let minimumSide: CGFloat = 8

    enum Failure: LocalizedError {
        case notAllowed
        var errorDescription: String? {
            "befriend needs Screen Recording to see that part of your screen. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        }
    }

    /// The box the user drags, in screen coordinates (origin bottom-left of the main display); nil if cancelled.
    @MainActor static func pick() async -> CGRect? {
        await withCheckedContinuation { continuation in
            SelectionOverlay(finish: continuation.resume(returning:)).show()
        }
    }

    /// The box as a PNG, at the display's full resolution.
    @MainActor static func capture(_ rect: CGRect) async throws -> Data {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw Failure.notAllowed }
        // ScreenCaptureKit counts from the top-left of the main display; AppKit from its bottom-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        let flipped = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        let image = try await SCScreenshotManager.captureImage(in: flipped)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.notAllowed }
        return png
    }
}

/// One dimmed window per display; the first finished drag (or Esc) ends them all.
@MainActor private final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var finish: ((CGRect?) -> Void)?
    /// Keeps itself alive until the user is done.
    private var retainSelf: SelectionOverlay?

    init(finish: @escaping (CGRect?) -> Void) { self.finish = finish }

    func show() {
        retainSelf = self
        NSApp.activate()
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = SelectionView { [weak self, weak window] box in
                guard let self, let window else { return }
                self.done(box.map { window.convertToScreen($0) })
            }
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }
        // The display under the pointer takes the keyboard (Esc).
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    private func done(_ box: CGRect?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let finish = finish
        self.finish = nil
        retainSelf = nil
        // Let the dimming leave the screen before it's captured.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            finish?(box)
        }
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    private let done: (CGRect?) -> Void
    private var start: NSPoint?
    private var box: NSRect?

    init(done: @escaping (CGRect?) -> Void) {
        self.done = done
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let box else { return }
        NSColor.clear.setFill()
        box.fill(using: .copy)
        NSColor.white.setStroke()
        let edge = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        box = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        box = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let box, box.width >= ScreenCapture.minimumSide, box.height >= ScreenCapture.minimumSide else { return done(nil) }
        done(convert(box, to: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { done(nil) } else { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) { done(nil) }
}
