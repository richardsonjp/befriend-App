//
//  ScreenExplainFlow.swift
//  befriend
//
//  Explain part of the screen on the Mac (M31): the shortcut (or the menu) → drag a box → the friend explains it,
//  saved as its own chat. The shortcut recorder for the menu bar popover lives here too.
//

import AppKit
import Observation
import PetCore
import SwiftUI

@MainActor @Observable
final class ScreenExplainFlow {
    let hotkey = ExplainHotkey()
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var thread: ChatThread?
    private let library: ChatLibrary
    private let friend: () -> FriendProfile?
    private let openChat: (ChatStart) -> Void

    init(library: ChatLibrary, friend: @escaping () -> FriendProfile?, openChat: @escaping (ChatStart) -> Void) {
        self.library = library
        self.friend = friend
        self.openChat = openChat
        hotkey.onTrigger = { [weak self] in self?.begin() }
    }

    func start() { hotkey.start() }

    /// Dims the screens for a box to be dragged; one capture at a time.
    func begin() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let box = await ScreenCapture.pick() else { return }
            do {
                explain(try await ScreenCapture.capture(box))
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't capture that part of the screen"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // ponytail: shows the explanation in Chat; the card beside the box (slice C) replaces this.
    private func explain(_ png: Data) {
        let thread = ChatThread(Conversation(), library: library, friend: friend())
        self.thread = thread
        thread.explain(screenshot: png)
        Task {
            // The conversation is saved once the friend knows what it's looking at.
            for _ in 0..<300 where thread.conversation.messages.isEmpty && thread.failure == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let failure = thread.failure {
                let alert = NSAlert()
                alert.messageText = "Couldn't explain that"
                alert.informativeText = failure
                alert.runModal()
            } else {
                openChat(ChatStart(conversation: thread.conversation.id, draft: ""))
            }
        }
    }
}

/// "Explain Part of Screen" in the popover: the button, the shortcut and its recorder.
struct ExplainControls: View {
    let flow: ScreenExplainFlow
    @State private var recording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: flow.begin) {
                Label("Explain Part of Screen", systemImage: "text.viewfinder").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            HStack {
                Text("Shortcut").foregroundStyle(.secondary)
                Spacer()
                ShortcutRecorder(hotkey: flow.hotkey, recording: $recording)
            }
            .font(.callout)
            if flow.hotkey.needsPermission {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tapping \(flow.hotkey.shortcut.display) needs Input Monitoring.").font(.caption).foregroundStyle(.secondary)
                    Button("Allow…", action: flow.hotkey.requestPermission).font(.caption)
                }
            }
        }
    }
}

/// Shows the shortcut; click to record a new one. Modifiers alone (released with no key) or modifiers with a key;
/// Esc cancels.
private struct ShortcutRecorder: View {
    let hotkey: ExplainHotkey
    @Binding var recording: Bool
    @State private var monitor: Any?
    @State private var held: ExplainShortcut.Modifiers = []
    @State private var most: ExplainShortcut.Modifiers = []

    var body: some View {
        Button(recording ? (held.isEmpty ? "Type shortcut…" : held.symbols) : hotkey.shortcut.display) {
            recording ? stop() : record()
        }
        .monospaced()
        .accessibilityLabel(recording ? "Recording shortcut" : "Explain shortcut \(hotkey.shortcut.display), click to change")
        .onDisappear(perform: stop)
    }

    private func record() {
        recording = true
        hotkey.paused = true
        held = []
        most = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let mods = Self.modifiers(event.modifierFlags)
            if event.type == .flagsChanged {
                held = mods
                most.formUnion(mods)
                if mods.isEmpty, most.count >= 2 { save(ExplainShortcut(modifiers: most)) }
                if mods.isEmpty { most = [] }
            } else if event.keyCode == 53, mods.isEmpty { // Esc
                stop()
            } else if !mods.isEmpty {
                save(ExplainShortcut(modifiers: mods, keyCode: event.keyCode, keyName: Self.name(of: event)))
            }
            return nil
        }
    }

    private func save(_ shortcut: ExplainShortcut) {
        hotkey.change(to: shortcut)
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        hotkey.paused = false
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> ExplainShortcut.Modifiers {
        var result: ExplainShortcut.Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12",
    ]

    private static func name(of event: NSEvent) -> String {
        specialKeys[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }
}
