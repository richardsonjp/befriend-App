//
//  ExplainHotkey.swift
//  befriend
//
//  The explain-part-of-the-screen shortcut, anywhere on the Mac (M31). A tap of modifiers alone (⌘⌥) needs a
//  listen-only event tap, which takes the Input Monitoring permission and never blocks other apps' shortcuts. A
//  shortcut with a key (⌃⇧E) is a Carbon hot key: no permission, and the key doesn't reach the app in front.
//

import AppKit
import Carbon.HIToolbox
import Observation
import PetCore

@MainActor @Observable
final class ExplainHotkey {
    private static let defaultsKey = "explain.shortcut"

    private(set) var shortcut: ExplainShortcut
    /// A modifier tap is set but Input Monitoring isn't allowed yet.
    private(set) var needsPermission = false
    @ObservationIgnored var onTrigger: () -> Void = {}
    /// Paused while the shortcut recorder listens, so recording ⌘⌥ doesn't start a capture.
    @ObservationIgnored var paused = false

    @ObservationIgnored private var detector = ModifierTap(target: [])
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var hotKeyHandler: EventHandlerRef?
    @ObservationIgnored private var permissionRetry: Timer?

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(ExplainShortcut.self, from: $0) }
        shortcut = saved.flatMap { $0.isValid ? $0 : nil } ?? .standard
    }

    func start() {
        stop()
        if shortcut.keyCode != nil { registerHotKey() } else { startTap() }
    }

    func change(to new: ExplainShortcut) {
        guard new.isValid else { return }
        shortcut = new
        UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: Self.defaultsKey)
        start()
    }

    /// Asks for Input Monitoring (the system prompt once, then System Settings), and keeps trying until it's allowed.
    func requestPermission() {
        if !CGRequestListenEventAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
        permissionRetry?.invalidate()
        permissionRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if CGPreflightListenEventAccess() { timer.invalidate(); self.start() }
            }
        }
    }

    private func stop() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        tapSource = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        needsPermission = false
    }

    // MARK: Modifier tap

    private func startTap() {
        detector = ModifierTap(target: shortcut.modifiers)
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
                                              guard let info else { return Unmanaged.passUnretained(event) }
                                              let hotkey = Unmanaged<ExplainHotkey>.fromOpaque(info).takeUnretainedValue()
                                              MainActor.assumeIsolated { hotkey.handle(type, event) }
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            needsPermission = true
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            if detector.modifiers(Self.modifiers(event.flags), at: .now), !paused { onTrigger() }
        default:
            detector.otherInput()
        }
    }

    private static func modifiers(_ flags: CGEventFlags) -> ExplainShortcut.Modifiers {
        var result: ExplainShortcut.Modifiers = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    // MARK: Key shortcut

    private func registerHotKey() {
        guard let keyCode = shortcut.keyCode else { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, info in
                guard let info else { return noErr }
                let hotkey = Unmanaged<ExplainHotkey>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { if !hotkey.paused { hotkey.onTrigger() } }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let mods = shortcut.modifiers
        let carbon = (mods.contains(.command) ? cmdKey : 0) | (mods.contains(.option) ? optionKey : 0)
            | (mods.contains(.shift) ? shiftKey : 0) | (mods.contains(.control) ? controlKey : 0)
        RegisterEventHotKey(UInt32(keyCode), UInt32(carbon), EventHotKeyID(signature: 0x6266_7264, id: 1), // "bfrd"
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}
